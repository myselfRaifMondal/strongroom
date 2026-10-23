//! Password and passphrase generator. All choices use unbiased rejection
//! sampling over bytes from the OS CSPRNG (`vtf_core::keys::fill_random`).

use std::sync::OnceLock;

use zeroize::{Zeroize, Zeroizing};

use crate::error::{Error, Result};

/// EFF large wordlist (7776 words), CC BY 3.0 US. See `NOTICE`.
const EFF_LARGE: &str = include_str!("../data/eff_large_wordlist.txt");

pub fn wordlist() -> &'static [&'static str] {
    static WORDS: OnceLock<Vec<&'static str>> = OnceLock::new();
    WORDS.get_or_init(|| {
        let w: Vec<&str> = EFF_LARGE
            .lines()
            .filter_map(|l| l.split('\t').nth(1))
            .map(str::trim)
            .collect();
        assert_eq!(w.len(), 7776, "embedded EFF wordlist is incomplete");
        w
    })
}

pub struct PasswordPolicy {
    pub length: u8,
    pub lowercase: bool,
    pub uppercase: bool,
    pub digits: bool,
    pub symbols: bool,
    pub avoid_ambiguous: bool,
}

pub struct PassphrasePolicy {
    pub words: u8,
    pub separator: String,
    pub capitalize: bool,
    pub include_number: bool,
}

pub const MIN_PASSWORD_LEN: u8 = 4;
pub const MAX_PASSWORD_LEN: u8 = 128;
pub const MIN_WORDS: u8 = 3;
pub const MAX_WORDS: u8 = 20;

const LOWER: &str = "abcdefghijklmnopqrstuvwxyz";
const UPPER: &str = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const DIGITS: &str = "0123456789";
const SYMBOLS: &str = "!#$%&*+-=?@^_~.,:;()[]{}<>/";
/// Characters that are easy to confuse when read or typed.
const AMBIGUOUS: &str = "Il1O0o";

/// Uniform random integer in `0..n` by rejection sampling (no modulo bias).
pub fn uniform(n: u32) -> Result<u32> {
    assert!(n > 0);
    // Largest multiple of n that fits in 2^32; reject draws at or above it.
    let zone = (1u64 << 32) - ((1u64 << 32) % u64::from(n));
    loop {
        let mut b = [0u8; 4];
        vtf_core::keys::fill_random(&mut b).map_err(|_| Error::Internal)?;
        let x = u64::from(u32::from_be_bytes(b));
        b.zeroize();
        if x < zone {
            return Ok((x % u64::from(n)) as u32);
        }
    }
}

pub fn generate_password(p: &PasswordPolicy) -> Result<Zeroizing<String>> {
    if !(MIN_PASSWORD_LEN..=MAX_PASSWORD_LEN).contains(&p.length) {
        return Err(Error::InvalidInput("password length must be 4 to 128"));
    }
    let keep = |set: &str| -> Vec<u8> {
        set.bytes()
            .filter(|c| !(p.avoid_ambiguous && AMBIGUOUS.as_bytes().contains(c)))
            .collect()
    };
    let classes: Vec<Vec<u8>> = [
        (p.lowercase, LOWER),
        (p.uppercase, UPPER),
        (p.digits, DIGITS),
        (p.symbols, SYMBOLS),
    ]
    .into_iter()
    .filter(|(on, _)| *on)
    .map(|(_, s)| keep(s))
    .collect();
    if classes.is_empty() {
        return Err(Error::InvalidInput("select at least one character class"));
    }
    if usize::from(p.length) < classes.len() {
        return Err(Error::InvalidInput(
            "length is shorter than the number of character classes",
        ));
    }
    let alphabet: Vec<u8> = classes.concat();
    // Draw the whole password uniformly from the alphabet and reject any
    // draw that misses a selected class: the result is uniform over all
    // passwords that contain every selected class.
    for _ in 0..10_000 {
        let mut out = Zeroizing::new(String::with_capacity(usize::from(p.length)));
        for _ in 0..p.length {
            out.push(alphabet[uniform(alphabet.len() as u32)? as usize] as char);
        }
        if classes.iter().all(|c| out.bytes().any(|b| c.contains(&b))) {
            return Ok(out);
        }
    }
    Err(Error::Internal)
}

pub fn generate_passphrase(p: &PassphrasePolicy) -> Result<Zeroizing<String>> {
    if !(MIN_WORDS..=MAX_WORDS).contains(&p.words) {
        return Err(Error::InvalidInput("passphrase must have 3 to 20 words"));
    }
    if p.separator.chars().count() > 4 {
        return Err(Error::InvalidInput("separator is longer than 4 characters"));
    }
    let words = wordlist();
    let n = usize::from(p.words);
    let number_at = if p.include_number {
        Some(uniform(u32::from(p.words))? as usize)
    } else {
        None
    };
    let cap = n * (9 + 1 + p.separator.len()) + 1;
    let mut out = Zeroizing::new(String::with_capacity(cap));
    for i in 0..n {
        if i > 0 {
            out.push_str(&p.separator);
        }
        let w = words[uniform(words.len() as u32)? as usize];
        if p.capitalize {
            let mut cs = w.chars();
            if let Some(f) = cs.next() {
                out.extend(f.to_uppercase());
                out.push_str(cs.as_str());
            }
        } else {
            out.push_str(w);
        }
        if number_at == Some(i) {
            out.push(char::from(b'0' + uniform(10)? as u8));
        }
    }
    Ok(out)
}

pub fn generate_secret_key() -> Result<Zeroizing<String>> {
    let sk = vtf_core::SecretKey::generate().map_err(|_| Error::Internal)?;
    Ok(sk.to_display())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pol(length: u8) -> PasswordPolicy {
        PasswordPolicy {
            length,
            lowercase: true,
            uppercase: true,
            digits: true,
            symbols: true,
            avoid_ambiguous: false,
        }
    }

    #[test]
    fn wordlist_is_complete() {
        let w = wordlist();
        assert_eq!(w.len(), 7776);
        assert_eq!(w[0], "abacus");
        assert_eq!(w[7775], "zoom");
        let mut s = w.to_vec();
        s.sort_unstable();
        s.dedup();
        assert_eq!(s.len(), 7776);
    }

    #[test]
    fn uniform_covers_range_without_obvious_bias() {
        let mut counts = [0u32; 6];
        for _ in 0..6000 {
            counts[uniform(6).unwrap() as usize] += 1;
        }
        for c in counts {
            assert!((800..1200).contains(&c), "{counts:?}");
        }
        assert_eq!(uniform(1).unwrap(), 0);
    }

    #[test]
    fn password_respects_policy() {
        for _ in 0..50 {
            let pw = generate_password(&pol(16)).unwrap();
            assert_eq!(pw.len(), 16);
            assert!(pw.bytes().any(|b| b.is_ascii_lowercase()));
            assert!(pw.bytes().any(|b| b.is_ascii_uppercase()));
            assert!(pw.bytes().any(|b| b.is_ascii_digit()));
            assert!(pw.bytes().any(|b| SYMBOLS.as_bytes().contains(&b)));
        }
        let mut p = pol(64);
        p.avoid_ambiguous = true;
        p.symbols = false;
        for _ in 0..20 {
            let pw = generate_password(&p).unwrap();
            assert!(!pw.chars().any(|c| AMBIGUOUS.contains(c)));
            assert!(pw.chars().all(|c| c.is_ascii_alphanumeric()));
        }
        let digits_only = PasswordPolicy {
            length: 6,
            lowercase: false,
            uppercase: false,
            digits: true,
            symbols: false,
            avoid_ambiguous: false,
        };
        assert!(generate_password(&digits_only)
            .unwrap()
            .chars()
            .all(|c| c.is_ascii_digit()));
        assert!(generate_password(&pol(3)).is_err());
        assert!(generate_password(&pol(129)).is_err());
        let none = PasswordPolicy {
            length: 10,
            lowercase: false,
            uppercase: false,
            digits: false,
            symbols: false,
            avoid_ambiguous: false,
        };
        assert!(generate_password(&none).is_err());
        assert_ne!(
            *generate_password(&pol(20)).unwrap(),
            *generate_password(&pol(20)).unwrap()
        );
    }

    #[test]
    fn passphrase_respects_policy() {
        let p = PassphrasePolicy {
            words: 6,
            separator: "-".into(),
            capitalize: true,
            include_number: true,
        };
        let s = generate_passphrase(&p).unwrap();
        let parts: Vec<&str> = s.split('-').collect();
        assert_eq!(parts.len(), 6);
        assert!(parts
            .iter()
            .all(|w| w.chars().next().unwrap().is_uppercase()));
        assert_eq!(s.chars().filter(|c| c.is_ascii_digit()).count(), 1);
        let plain = PassphrasePolicy {
            words: 4,
            separator: " ".into(),
            capitalize: false,
            include_number: false,
        };
        let s = generate_passphrase(&plain).unwrap();
        assert!(s.split(' ').all(|w| wordlist().contains(&w)));
        assert!(generate_passphrase(&PassphrasePolicy { words: 2, ..plain }).is_err());
    }

    #[test]
    fn secret_key_display() {
        let k = generate_secret_key().unwrap();
        assert!(k.starts_with("SR1-") && k.len() == 34);
        assert!(vtf_core::SecretKey::parse(&k).is_ok());
    }
}
