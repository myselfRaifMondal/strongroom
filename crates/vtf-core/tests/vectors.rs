//! The VTF1 vector suite: committed vectors must match the generator
//! byte-for-byte, every positive vector must open, every negative vector must
//! be rejected by exactly the check its manifest names.

mod common;

use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;

use common::*;
use vtf_core::*;

fn vectors_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../vectors")
}

fn read(rel: &str) -> Vec<u8> {
    fs::read(vectors_dir().join(rel)).unwrap_or_else(|e| panic!("missing vector {rel}: {e} (run gen_vectors)"))
}

#[test]
fn positive_vectors_reproduce_and_open() {
    let sk = SecretKey::from_bytes(SECRET_KEY);
    for p in positives() {
        assert_eq!(read(&format!("positive/{}.vtf", p.name)), p.file, "{}: file bytes differ", p.name);
        assert_eq!(read(&format!("positive/{}.cbor", p.name)), p.cbor, "{}: payload bytes differ", p.name);
        let mut opened = Vec::new();
        if let Some(pw) = p.password {
            for form in std::iter::once(pw).chain(p.password_alternates.iter().copied()) {
                opened.push(import_with_password(&p.file, &Password::new(form).unwrap(), &sk).unwrap());
            }
        }
        for d in &p.devices {
            opened.push(import_with_device(&p.file, &SoftDevice::new(d)).unwrap());
        }
        assert!(!opened.is_empty());
        for payload in opened {
            assert_eq!(*payload::encode(&payload).unwrap(), p.cbor, "{}: decoded payload differs", p.name);
        }
        let info = inspect(&p.file).unwrap();
        assert_eq!(info.password_slots as usize, usize::from(p.password.is_some()));
        assert_eq!(info.device_slots as usize, p.devices.len());
    }
}

#[test]
fn negative_vectors_rejected_by_named_check() {
    for n in negatives() {
        assert_eq!(read(&format!("negative/{}.vtf", n.name)), n.file, "{}: file bytes differ", n.name);
        let got = reject(n);
        assert_eq!(got, n.check, "{}: rejected by `{}`, manifest says `{}`", n.name, got, n.check);
    }
}

#[test]
fn every_check_has_a_negative_vector() {
    let covered: HashSet<Check> = negatives().iter().map(|n| n.check).collect();
    for c in Check::ALL {
        assert!(covered.contains(&c), "no negative vector for check `{c}`");
    }
}

#[test]
fn manifest_is_current() {
    let committed = String::from_utf8(read("manifest.json")).unwrap();
    assert_eq!(committed, manifest_json(), "vectors/manifest.json is stale (run gen_vectors)");
}

#[test]
fn fresh_export_round_trips_and_never_repeats() {
    let sk = SecretKey::generate().unwrap();
    let pw = Password::new("a fresh password").unwrap();
    let p = payload_unbound();
    let a = export(&p, creds(&pw, &sk), &[pk(&DEVICE_A_SK)]).unwrap();
    let b = export(&p, creds(&pw, &sk), &[pk(&DEVICE_A_SK)]).unwrap();
    assert_ne!(a, b, "two exports must not share randomness");
    assert!(import_with_password(&a, &pw, &sk).unwrap() == p);
    assert!(import_with_device(&b, &SoftDevice::new(&DEVICE_A_SK)).unwrap() == p);
    // Every wrong credential fails with the same, single error.
    let wrong_pw = import_with_password(&a, &Password::new("nope").unwrap(), &sk).err().unwrap();
    let wrong_sk = import_with_password(&a, &pw, &SecretKey::generate().unwrap()).err().unwrap();
    let wrong_dev = import_with_device(&a, &SoftDevice::new(&DEVICE_C_SK)).err().unwrap();
    assert_eq!(wrong_pw, wrong_sk);
    assert_eq!(wrong_pw, wrong_dev);
    assert!(wrong_pw.is_unlock_failure());
}

#[test]
fn export_input_validation() {
    let p = payload_small();
    assert!(export(&p, None, &[]).is_err());
    let a = pk(&DEVICE_A_SK);
    assert!(export(&p, None, &[a, a]).is_err());
    assert!(export(&p, None, &[a; 17]).is_err());
    let mut bad = a;
    bad[10] ^= 1;
    assert!(export(&p, None, &[bad]).is_err());
}
