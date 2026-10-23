//! TOTP (RFC 6238) over HOTP (RFC 4226) with SHA-1, SHA-256 and SHA-512,
//! and `otpauth://totp/` URI parsing.

use hmac::{Hmac, KeyInit, Mac};
use zeroize::{Zeroize, Zeroizing};

use crate::encoding::base32_decode;
use crate::error::{Error, Result};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Algorithm {
    Sha1,
    Sha256,
    Sha512,
}

pub struct TotpParams {
    secret: Zeroizing<Vec<u8>>,
    pub algorithm: Algorithm,
    pub digits: u32,
    pub period: u32,
}

pub struct TotpCode {
    pub code: String,
    pub period: u32,
    pub seconds_remaining: u32,
}

const BAD: Error = Error::InvalidInput("malformed TOTP secret");

fn percent_decode(s: &str) -> Option<Zeroizing<String>> {
    let b = s.as_bytes();
    let mut out = Zeroizing::new(Vec::with_capacity(b.len()));
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'%' => {
                let h = b.get(i + 1..i + 3)?;
                let hs = core::str::from_utf8(h).ok()?;
                out.push(u8::from_str_radix(hs, 16).ok()?);
                i += 3;
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    core::str::from_utf8(&out).ok()?;
    let mut s = Zeroizing::new(String::with_capacity(out.len()));
    s.push_str(core::str::from_utf8(&out).ok()?);
    Some(s)
}

impl TotpParams {
    /// Parses a base32 secret (defaults SHA-1, 6 digits, 30 s) or an
    /// `otpauth://totp/...` URI.
    pub fn parse(input: &str) -> Result<TotpParams> {
        let t = input.trim();
        let lower_prefix = t
            .get(..10)
            .map(|p| p.eq_ignore_ascii_case("otpauth://"))
            .unwrap_or(false);
        if !lower_prefix {
            let secret = base32_decode(t).ok_or(BAD)?;
            return Self::checked(secret, Algorithm::Sha1, 6, 30);
        }
        let rest = &t[10..];
        let (kind, rest) = rest.split_once('/').ok_or(BAD)?;
        if kind.eq_ignore_ascii_case("hotp") {
            return Err(Error::Unsupported(
                "HOTP counters are not supported; use TOTP",
            ));
        }
        if !kind.eq_ignore_ascii_case("totp") {
            return Err(BAD);
        }
        let query = rest.split_once('?').map(|(_, q)| q).unwrap_or("");
        let query = query.split('#').next().unwrap_or("");
        let mut secret = None;
        let (mut alg, mut digits, mut period) = (Algorithm::Sha1, 6u32, 30u32);
        for pair in query.split('&').filter(|p| !p.is_empty()) {
            let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
            let v = percent_decode(v).ok_or(BAD)?;
            match k.to_ascii_lowercase().as_str() {
                "secret" => secret = Some(base32_decode(&v).ok_or(BAD)?),
                "algorithm" => {
                    alg = match v.to_ascii_uppercase().as_str() {
                        "SHA1" => Algorithm::Sha1,
                        "SHA256" => Algorithm::Sha256,
                        "SHA512" => Algorithm::Sha512,
                        _ => return Err(Error::InvalidInput("unsupported TOTP algorithm")),
                    }
                }
                "digits" => digits = v.parse().map_err(|_| BAD)?,
                "period" => period = v.parse().map_err(|_| BAD)?,
                _ => {} // issuer, image, etc.
            }
        }
        Self::checked(secret.ok_or(BAD)?, alg, digits, period)
    }

    fn checked(
        secret: Zeroizing<Vec<u8>>,
        algorithm: Algorithm,
        digits: u32,
        period: u32,
    ) -> Result<TotpParams> {
        if secret.is_empty() {
            return Err(BAD);
        }
        if !(6..=10).contains(&digits) {
            return Err(Error::InvalidInput("TOTP digits must be 6 to 10"));
        }
        if !(1..=3600).contains(&period) {
            return Err(Error::InvalidInput("TOTP period must be 1 to 3600 seconds"));
        }
        Ok(TotpParams {
            secret,
            algorithm,
            digits,
            period,
        })
    }

    pub fn new(
        secret: &[u8],
        algorithm: Algorithm,
        digits: u32,
        period: u32,
    ) -> Result<TotpParams> {
        Self::checked(Zeroizing::new(secret.to_vec()), algorithm, digits, period)
    }

    /// RFC 4226 HOTP value for `counter`.
    pub fn hotp(&self, counter: u64) -> String {
        let msg = counter.to_be_bytes();
        let mut mac: Zeroizing<Vec<u8>> = Zeroizing::new(match self.algorithm {
            Algorithm::Sha1 => mac_bytes::<Hmac<sha1::Sha1>>(&self.secret, &msg),
            Algorithm::Sha256 => mac_bytes::<Hmac<sha2::Sha256>>(&self.secret, &msg),
            Algorithm::Sha512 => mac_bytes::<Hmac<sha2::Sha512>>(&self.secret, &msg),
        });
        let off = usize::from(mac[mac.len() - 1] & 0x0f);
        let bin = (u32::from(mac[off] & 0x7f) << 24)
            | (u32::from(mac[off + 1]) << 16)
            | (u32::from(mac[off + 2]) << 8)
            | u32::from(mac[off + 3]);
        mac.zeroize();
        let modulus = 10u64.pow(self.digits);
        let v = u64::from(bin) % modulus;
        format!("{:0width$}", v, width = self.digits as usize)
    }

    /// RFC 6238 TOTP at Unix time `now`.
    pub fn code(&self, now: i64) -> Result<TotpCode> {
        if now < 0 {
            return Err(Error::InvalidInput("time before 1970"));
        }
        let now = now as u64;
        let p = u64::from(self.period);
        Ok(TotpCode {
            code: self.hotp(now / p),
            period: self.period,
            seconds_remaining: (p - now % p) as u32,
        })
    }
}

fn mac_bytes<M: Mac + KeyInit>(key: &[u8], msg: &[u8]) -> Vec<u8> {
    let mut m = <M as KeyInit>::new_from_slice(key).expect("HMAC accepts any key length");
    m.update(msg);
    m.finalize().into_bytes().to_vec()
}

pub fn totp_code(secret_or_uri: &str, now: i64) -> Result<TotpCode> {
    TotpParams::parse(secret_or_uri)?.code(now)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rfc4226_appendix_d() {
        let p = TotpParams::new(b"12345678901234567890", Algorithm::Sha1, 6, 30).unwrap();
        let want = [
            "755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583",
            "399871", "520489",
        ];
        for (c, w) in want.iter().enumerate() {
            assert_eq!(p.hotp(c as u64), *w);
        }
    }

    #[test]
    fn rfc6238_appendix_b() {
        let s1 = b"12345678901234567890".to_vec();
        let s256 = b"12345678901234567890123456789012".to_vec();
        let s512 = b"1234567890123456789012345678901234567890123456789012345678901234".to_vec();
        let rows: [(i64, &str, &str, &str); 6] = [
            (59, "94287082", "46119246", "90693936"),
            (1111111109, "07081804", "68084774", "25091201"),
            (1111111111, "14050471", "67062674", "99943326"),
            (1234567890, "89005924", "91819424", "93441116"),
            (2000000000, "69279037", "90698825", "38618901"),
            (20000000000, "65353130", "77737706", "47863826"),
        ];
        for (t, w1, w256, w512) in rows {
            for (s, alg, w) in [
                (&s1, Algorithm::Sha1, w1),
                (&s256, Algorithm::Sha256, w256),
                (&s512, Algorithm::Sha512, w512),
            ] {
                let p = TotpParams::new(s, alg, 8, 30).unwrap();
                assert_eq!(p.code(t).unwrap().code, w, "t={t}");
            }
        }
    }

    #[test]
    fn otpauth_uri() {
        // base32("12345678901234567890") = GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ
        let uri = "otpauth://totp/ACME%20Co:john@example.com?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=ACME%20Co&algorithm=SHA1&digits=8&period=30";
        let c = totp_code(uri, 59).unwrap();
        assert_eq!(c.code, "94287082");
        assert_eq!(c.period, 30);
        assert_eq!(c.seconds_remaining, 1);
        assert_eq!(
            totp_code("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", 59)
                .unwrap()
                .code,
            "287082"
        );
        assert_eq!(
            totp_code("gezd gnbv gy3t qojq gezd gnbv gy3t qojq", 59)
                .unwrap()
                .code,
            "287082"
        );
        let p = TotpParams::parse(
            "otpauth://totp/x?secret=GEZDGNBV&algorithm=sha512&digits=7&period=60",
        )
        .unwrap();
        assert!(p.algorithm == Algorithm::Sha512 && p.digits == 7 && p.period == 60);
        assert!(TotpParams::parse("otpauth://hotp/x?secret=GEZDGNBV&counter=1").is_err());
        assert!(TotpParams::parse("otpauth://totp/x?issuer=a").is_err());
        assert!(TotpParams::parse("otpauth://totp/x?secret=GEZDGNBV&digits=5").is_err());
        assert!(TotpParams::parse("otpauth://totp/x?secret=GEZDGNBV&algorithm=MD5").is_err());
        assert!(TotpParams::parse("not base32 !").is_err());
        assert!(totp_code("GEZDGNBV", -1).is_err());
    }
}
