//! Password strength estimator: a small, self-contained pattern-aware
//! entropy model (no zxcvbn).
//!
//! The password is segmented into the cheapest sequence of tokens, where a
//! token is one of: a single character (log2 of its character-class pool), a
//! dictionary word from the embedded EFF list (with simple leet and case
//! variations), a repeated run, an alphabetic/numeric sequence, a keyboard
//! row run, a 4-digit year, or the whole password matching a short list of
//! very common passwords. The minimum total over all segmentations (dynamic
//! programming) is the entropy estimate. It is deliberately conservative and
//! is an estimate of guessing cost, not a guarantee.

use std::collections::HashSet;
use std::sync::OnceLock;

use zeroize::Zeroizing;

use crate::generator::wordlist;

pub struct StrengthReport {
    pub score: u8,
    pub entropy_bits: f64,
    pub warnings: Vec<String>,
}

/// Very common passwords (lowercase); whole-password matches only.
const COMMON: &[&str] = &[
    "123456", "password", "123456789", "12345678", "12345", "qwerty", "1234567", "111111", "1234567890",
    "123123", "abc123", "1234", "password1", "iloveyou", "1q2w3e4r", "000000", "qwerty123", "zaq12wsx",
    "dragon", "sunshine", "princess", "letmein", "654321", "monkey", "27653", "1qaz2wsx", "123321",
    "qwertyuiop", "superman", "asdfghjkl", "trustno1", "football", "baseball", "welcome", "admin",
    "login", "starwars", "master", "hello", "freedom", "whatever", "qazwsx", "passw0rd", "shadow",
    "michael", "jennifer", "666666", "121212", "ashley", "bailey", "access", "mustang", "flower",
    "hottie", "loveme", "charlie", "donald", "batman", "secret", "changeme", "p@ssw0rd", "letmein1",
    "welcome1", "password123", "admin123", "root", "toor", "default", "guest", "test", "test123",
];

const KEYBOARD_ROWS: &[&str] = &["`1234567890-=", "qwertyuiop[]\\", "asdfghjkl;'", "zxcvbnm,./", "1qaz2wsx3edc4rfv5tgb6yhn7ujm8ik9ol0p"];

const WEAK_BITS: [f64; 4] = [28.0, 40.0, 56.0, 72.0];
const MAX_ANALYZED: usize = 256;

fn dictionary() -> &'static HashSet<&'static str> {
    static SET: OnceLock<HashSet<&'static str>> = OnceLock::new();
    SET.get_or_init(|| wordlist().iter().copied().filter(|w| w.len() >= 4 && w.chars().all(|c| c.is_ascii_lowercase())).collect())
}

fn pool(c: char) -> f64 {
    if c.is_ascii_lowercase() || c.is_ascii_uppercase() {
        26.0
    } else if c.is_ascii_digit() {
        10.0
    } else if c.is_ascii() {
        33.0
    } else {
        100.0
    }
}

fn unleet(c: char) -> char {
    match c {
        '@' | '4' => 'a',
        '3' => 'e',
        '1' | '!' => 'i',
        '0' => 'o',
        '$' | '5' => 's',
        '7' | '+' => 't',
        c => c.to_ascii_lowercase(),
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Char,
    Word,
    Repeat,
    Sequence,
    Keyboard,
    Year,
}

pub fn estimate(password: &str) -> StrengthReport {
    let chars: Zeroizing<Vec<char>> = Zeroizing::new(password.chars().collect());
    let n_all = chars.len();
    if n_all == 0 {
        return StrengthReport { score: 0, entropy_bits: 0.0, warnings: vec!["Password is empty.".into()] };
    }
    let lower: Zeroizing<String> = Zeroizing::new(password.to_lowercase());
    if COMMON.contains(&lower.as_str()) {
        let rank = COMMON.iter().position(|c| *c == lower.as_str()).unwrap_or(0) as f64;
        return StrengthReport {
            score: 0,
            entropy_bits: (rank + 2.0).log2(),
            warnings: vec!["This is one of the most common passwords.".into()],
        };
    }

    let n = n_all.min(MAX_ANALYZED);
    let c = &chars[..n];
    let unl: Zeroizing<Vec<char>> = Zeroizing::new(c.iter().map(|&x| unleet(x)).collect());
    let low: Zeroizing<Vec<char>> = Zeroizing::new(c.iter().map(|x| x.to_ascii_lowercase()).collect());

    // dp[i] = (min bits for c[..i], kind of last token, start of last token)
    let mut dp: Vec<(f64, Kind, usize)> = vec![(f64::INFINITY, Kind::Char, 0); n + 1];
    dp[0].0 = 0.0;
    let dict = dictionary();
    // A brute-force character costs log2 of the union of the character
    // classes present anywhere in the password.
    let union_bits = {
        let mut seen = [false; 5];
        for &x in chars.iter() {
            let k = match x {
                'a'..='z' => 0,
                'A'..='Z' => 1,
                '0'..='9' => 2,
                x if x.is_ascii() => 3,
                _ => 4,
            };
            seen[k] = true;
        }
        [26.0f64, 26.0, 10.0, 33.0, 100.0].iter().zip(seen).filter(|(_, s)| *s).map(|(z, _)| z).sum::<f64>().log2()
    };
    let mut buf = Zeroizing::new(String::with_capacity(16));
    for i in 0..n {
        let base = dp[i].0;
        if !base.is_finite() {
            continue;
        }
        let relax = |end: usize, bits: f64, kind: Kind, dp: &mut Vec<(f64, Kind, usize)>| {
            if base + bits < dp[end].0 {
                dp[end] = (base + bits, kind, i);
            }
        };
        relax(i + 1, union_bits, Kind::Char, &mut dp);

        // Dictionary words (EFF words are 3..=9 letters; we use >= 4).
        for len in 4..=9usize.min(n - i) {
            buf.clear();
            buf.extend(unl[i..i + len].iter());
            if dict.contains(buf.as_str()) {
                let seg = &c[i..i + len];
                let mut bits = (dict.len() as f64).log2();
                if seg.iter().any(|x| x.is_uppercase()) {
                    bits += if seg[0].is_uppercase() && seg[1..].iter().all(|x| !x.is_uppercase()) { 1.0 } else { 2.0 };
                }
                if seg.iter().zip(low[i..i + len].iter()).any(|(a, b)| a.to_ascii_lowercase() != *b) || seg.iter().any(|x| !x.is_alphabetic()) {
                    bits += 1.0;
                }
                relax(i + len, bits, Kind::Word, &mut dp);
            }
        }

        // Repeated character runs.
        let mut j = i + 1;
        while j < n && c[j] == c[i] {
            j += 1;
        }
        if j - i >= 3 {
            for end in i + 3..=j {
                relax(end, pool(c[i]).log2() + ((end - i) as f64).log2(), Kind::Repeat, &mut dp);
            }
        }

        // Ascending / descending sequences (step +1 or -1).
        for step in [1i32, -1] {
            let mut j = i + 1;
            while j < n && (low[j] as i32 - low[j - 1] as i32) == step && low[j].is_ascii_alphanumeric() {
                j += 1;
            }
            if j - i >= 3 {
                for end in i + 3..=j {
                    relax(end, pool(c[i]).log2() + ((end - i) as f64).log2() + 1.0, Kind::Sequence, &mut dp);
                }
            }
        }

        // Keyboard row runs.
        for row in KEYBOARD_ROWS {
            let r: Vec<char> = row.chars().collect();
            if let Some(start) = r.iter().position(|&x| x == low[i]) {
                let mut k = 1;
                while i + k < n && start + k < r.len() && r[start + k] == low[i + k] {
                    k += 1;
                }
                if k >= 4 {
                    for len in 4..=k {
                        relax(i + len, (KEYBOARD_ROWS.len() as f64 * 13.0).log2() + (len as f64).log2(), Kind::Keyboard, &mut dp);
                    }
                }
            }
        }

        // Years 1900..=2099.
        if i + 4 <= n && c[i..i + 4].iter().all(|x| x.is_ascii_digit()) {
            let y: u32 = c[i..i + 4].iter().fold(0, |a, d| a * 10 + d.to_digit(10).unwrap_or(0));
            if (1900..=2099).contains(&y) {
                relax(i + 4, 200f64.log2(), Kind::Year, &mut dp);
            }
        }
    }

    // Recover the token kinds used by the cheapest segmentation.
    let mut kinds = Vec::new();
    let mut at = n;
    while at > 0 {
        kinds.push(dp[at].1);
        at = dp[at].2;
    }
    let mut bits = dp[n].0;
    // Characters beyond the analyzed prefix count at their pool rate.
    bits += chars[n..].iter().map(|&x| pool(x).log2()).sum::<f64>();

    let mut warnings = Vec::new();
    if n_all < 8 {
        warnings.push("Password is shorter than 8 characters.".to_string());
    }
    let classes = [
        chars.iter().any(|x| x.is_ascii_lowercase()),
        chars.iter().any(|x| x.is_ascii_uppercase()),
        chars.iter().any(|x| x.is_ascii_digit()),
        chars.iter().any(|x| !x.is_ascii_alphanumeric()),
    ];
    if classes.iter().filter(|&&b| b).count() == 1 && n_all < 16 && !kinds.contains(&Kind::Word) {
        warnings.push("Uses only one kind of character.".to_string());
    }
    for (k, msg) in [
        (Kind::Word, "Contains a dictionary word."),
        (Kind::Repeat, "Contains repeated characters."),
        (Kind::Sequence, "Contains a predictable sequence."),
        (Kind::Keyboard, "Contains a keyboard pattern."),
        (Kind::Year, "Contains a year."),
    ] {
        if kinds.contains(&k) && !(k == Kind::Word && kinds.iter().all(|&x| x == Kind::Word || x == Kind::Char) && bits >= WEAK_BITS[3]) {
            warnings.push(msg.to_string());
        }
    }
    let score = WEAK_BITS.iter().filter(|&&t| bits >= t).count() as u8;
    StrengthReport { score, entropy_bits: (bits * 100.0).round() / 100.0, warnings }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ordering_and_scores() {
        assert_eq!(estimate("").score, 0);
        assert_eq!(estimate("password").score, 0);
        assert_eq!(estimate("P@ssw0rd").score, 0);
        let weak = ["aaaaaaaa", "abcdefgh", "qwertyuiop12", "monkey1990", "12345678987"];
        for w in weak {
            assert!(estimate(w).score <= 1, "{w}: {}", estimate(w).entropy_bits);
        }
        // Random 16 characters from all classes: very strong.
        let r = estimate("x7#Kq!v9Lm2$Rt8@");
        assert_eq!(r.score, 4, "{}", r.entropy_bits);
        // Six random EFF words: strong (~77 bits by dictionary).
        let p = estimate("abacus-zoom-quarry-lumber-viewing-ember");
        assert!(p.score >= 3, "{}", p.entropy_bits);
        assert!(p.entropy_bits >= 60.0 && p.entropy_bits < 110.0, "{}", p.entropy_bits);
        // Dictionary word costs much less than its length suggests.
        assert!(estimate("zoology").entropy_bits < 20.0);
        assert!(estimate("Zoology").warnings.iter().any(|w| w.contains("dictionary")));
        assert!(estimate("abc").warnings.iter().any(|w| w.contains("shorter")));
        assert!(estimate("Tr0ub4dor&3").entropy_bits < estimate("x7#Kq!v9Lm2Rt").entropy_bits);
        assert!(estimate("Summer2024").warnings.iter().any(|w| w.contains("year")));
    }

    #[test]
    fn handles_long_and_unicode_input() {
        let long: String = "x7#Kq!v9".repeat(100);
        assert_eq!(estimate(&long).score, 4);
        let u = estimate("Grüße aus Köln 🔒 Tresor");
        assert!(u.entropy_bits > 0.0);
    }
}
