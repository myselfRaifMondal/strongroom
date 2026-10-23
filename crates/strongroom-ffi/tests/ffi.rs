//! End-to-end tests through the FFI surface (the same calls the apps make).
//! All credentials here are deliberate public test fixtures.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

use p256::elliptic_curve::sec1::ToSec1Point;
use strongroom_ffi::*;

const PW: &str = "ffi test fixture password";
const T0: i64 = 1_760_000_000;

fn tmp(name: &str) -> String {
    static N: AtomicU32 = AtomicU32::new(0);
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("ffi-tests");
    std::fs::create_dir_all(&dir).unwrap();
    let p = dir.join(format!(
        "{name}-{}-{}.db",
        std::process::id(),
        N.fetch_add(1, Ordering::SeqCst)
    ));
    let _ = std::fs::remove_file(&p);
    let _ = std::fs::remove_file(format!("{}.hdr", p.display()));
    p.to_string_lossy().into_owned()
}

fn cleanup(p: &str) {
    let _ = std::fs::remove_file(p);
    let _ = std::fs::remove_file(format!("{p}.hdr"));
}

/// Software P-256 key standing in for Secure Enclave / TPM / Keystore.
struct SoftDevice(p256::SecretKey);

impl SoftDevice {
    fn new(seed: u8) -> Self {
        SoftDevice(p256::SecretKey::from_slice(&[seed; 32]).unwrap())
    }
}

impl DeviceKeyAgreement for SoftDevice {
    fn public_key(&self) -> Vec<u8> {
        self.0.public_key().to_sec1_point(false).as_bytes().to_vec()
    }
    fn agree(&self, peer_public_key: Vec<u8>) -> Result<Vec<u8>, StrongroomError> {
        let peer = p256::PublicKey::from_sec1_bytes(&peer_public_key)
            .map_err(|_| StrongroomError::UnlockFailed)?;
        let shared = p256::ecdh::diffie_hellman(self.0.to_nonzero_scalar(), peer.as_affine());
        Ok(shared.raw_secret_bytes().to_vec())
    }
}

fn input(title: &str, user: &str, pw: &str, url: &str) -> ItemInput {
    ItemInput {
        kind: ItemKind::Login,
        title: title.into(),
        username: Some(user.into()),
        password: Some(pw.into()),
        urls: vec![url.into()],
        notes: None,
        totp: None,
        folder: Some("Personal".into()),
        tags: vec!["web".into()],
        fields: vec![CustomField {
            name: "Hint".into(),
            value: "none".into(),
            concealed: false,
        }],
        travel_safe: false,
    }
}

fn b32(bytes: &[u8]) -> String {
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    let (mut acc, mut bits, mut out) = (0u32, 0u32, String::new());
    for &b in bytes {
        acc = (acc << 8) | u32::from(b);
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            out.push(A[((acc >> bits) & 31) as usize] as char);
        }
        acc &= (1 << bits) - 1;
    }
    if bits > 0 {
        out.push(A[((acc << (5 - bits)) & 31) as usize] as char);
    }
    out
}

#[test]
fn namespace_functions() {
    let sk = generate_secret_key();
    assert!(sk.starts_with("SR1-") && sk.len() == 34);
    assert_ne!(sk, generate_secret_key());
    let pw = generate_password(PasswordPolicy {
        length: 20,
        lowercase: true,
        uppercase: true,
        digits: true,
        symbols: false,
        avoid_ambiguous: true,
    })
    .unwrap();
    assert_eq!(pw.len(), 20);
    assert!(generate_password(PasswordPolicy {
        length: 2,
        lowercase: true,
        uppercase: false,
        digits: false,
        symbols: false,
        avoid_ambiguous: false
    })
    .is_err());
    let pp = generate_passphrase(PassphrasePolicy {
        words: 5,
        separator: ".".into(),
        capitalize: false,
        include_number: false,
    })
    .unwrap();
    assert_eq!(pp.split('.').count(), 5);
    assert_eq!(estimate_strength("password".into()).score, 0);
    assert_eq!(estimate_strength(pw).score, 4);

    // RFC 6238 Appendix B through the FFI (8 digits, SHA-1/256/512).
    let secrets = [
        (b"12345678901234567890".to_vec(), "SHA1"),
        (b"12345678901234567890123456789012".to_vec(), "SHA256"),
        (
            b"1234567890123456789012345678901234567890123456789012345678901234".to_vec(),
            "SHA512",
        ),
    ];
    let rows: [(i64, [&str; 3]); 6] = [
        (59, ["94287082", "46119246", "90693936"]),
        (1111111109, ["07081804", "68084774", "25091201"]),
        (1111111111, ["14050471", "67062674", "99943326"]),
        (1234567890, ["89005924", "91819424", "93441116"]),
        (2000000000, ["69279037", "90698825", "38618901"]),
        (20000000000, ["65353130", "77737706", "47863826"]),
    ];
    for (t, want) in rows {
        for ((s, alg), w) in secrets.iter().zip(want) {
            let uri = format!(
                "otpauth://totp/RFC6238?secret={}&algorithm={alg}&digits=8&period=30",
                b32(s)
            );
            let c = totp_code(uri, t).unwrap();
            assert_eq!(c.code, w, "{alg} t={t}");
            assert_eq!(c.period, 30);
        }
    }
    let c = totp_code(b32(b"12345678901234567890"), 59).unwrap();
    assert_eq!((c.code.as_str(), c.seconds_remaining), ("287082", 1));
    assert!(matches!(
        totp_code("!!".into(), 0),
        Err(StrongroomError::InvalidInput { .. })
    ));

    // Pairing QR payload.
    let dev = SoftDevice::new(9);
    let payload = pairing_payload(dev.public_key());
    let paired = parse_pairing_payload(payload).unwrap();
    assert_eq!(paired.public_key, dev.public_key());
    assert_eq!(paired.fingerprint.len(), 19);
    assert!(parse_pairing_payload("hello".into()).is_err());

    assert!(
        matches!(vtf_inspect(vec![0; 10]), Err(StrongroomError::FormatRejected { check }) if check == "length-min")
    );
}

#[test]
fn vault_round_trip_through_vtf_and_device_unlock() {
    let sk = generate_secret_key();
    let (pa, pb) = (tmp("a"), tmp("b"));
    let a = Vault::create(pa.clone(), PW.into(), sk.clone(), T0).unwrap();
    assert!(!a.is_locked());
    let id = a
        .add_item(
            input(
                "Example Mail",
                "alice@example.com",
                "Tr0ub4dor&3",
                "https://mail.example.com/",
            ),
            T0,
        )
        .unwrap();
    let mut with_totp = input(
        "Bank",
        "bob",
        "x7#Kq!v9Lm2$Rt8@zW",
        "https://www.bank.co.uk/",
    );
    with_totp.totp = Some(format!(
        "otpauth://totp/Bank?secret={}&digits=8",
        b32(b"12345678901234567890")
    ));
    let bank = a.add_item(with_totp, T0).unwrap();

    let hits = a.search("mail".into(), None, None).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].id, id);
    assert_eq!(hits[0].subtitle.as_deref(), Some("alice@example.com"));
    assert_eq!(
        a.search(String::new(), Some("Personal".into()), Some("web".into()))
            .unwrap()
            .len(),
        2
    );
    assert_eq!(a.match_domain("bank.co.uk".into()).unwrap()[0].id, bank);
    assert_eq!(a.item_totp(bank.clone(), 59).unwrap().code, "94287082");
    assert_eq!(a.list_folders().unwrap(), ["Personal"]);
    let mut upd = a.get_item(id.clone()).unwrap().data;
    upd.password = Some("changed".into());
    a.update_item(id.clone(), upd, T0 + 5).unwrap();
    assert_eq!(a.item_history(id.clone()).unwrap().len(), 1);
    assert!(a
        .password_health(T0 + 10)
        .unwrap()
        .weak_item_ids
        .contains(&id));

    // Export -> import into a second vault with different credentials.
    let file = a
        .export_vtf(PW.into(), sk.clone(), vec![], T0 + 20)
        .unwrap();
    let info = vtf_inspect(file.clone()).unwrap();
    assert_eq!(
        (info.version, info.password_slots, info.device_slots),
        (1, 1, 0)
    );
    let sk_b = generate_secret_key();
    let b = Vault::create(pb.clone(), "second vault pw".into(), sk_b.clone(), T0).unwrap();
    assert!(matches!(
        b.import_vtf(file.clone(), "wrong".into(), sk.clone(), T0 + 21),
        Err(StrongroomError::UnlockFailed)
    ));
    let s = b
        .import_vtf(file.clone(), PW.into(), sk.clone(), T0 + 21)
        .unwrap();
    assert_eq!(
        s,
        ImportSummary {
            added: 2,
            updated: 0,
            unchanged: 0,
            conflicts: 0
        }
    );
    for item_id in [&id, &bank] {
        let (x, y) = (
            a.get_item(item_id.clone()).unwrap(),
            b.get_item(item_id.clone()).unwrap(),
        );
        assert!(x == y, "item differs after round trip");
    }
    assert_eq!(b.item_history(id.clone()).unwrap().len(), 1);

    // Biometric unlock with a (software) hardware key.
    let dev = SoftDevice::new(0x42);
    let blob = a.wrap_vault_key_for_device(dev.public_key()).unwrap();
    a.lock();
    assert!(a.is_locked());
    assert!(matches!(
        a.search(String::new(), None, None),
        Err(StrongroomError::Locked)
    ));
    let again =
        Vault::unlock_with_device_key(pa.clone(), blob.clone(), Box::new(SoftDevice::new(0x42)))
            .unwrap();
    assert_eq!(
        again.get_item(id.clone()).unwrap().data.password.as_deref(),
        Some("changed")
    );
    assert!(matches!(
        Vault::unlock_with_device_key(pa.clone(), blob, Box::new(SoftDevice::new(0x43))),
        Err(StrongroomError::UnlockFailed)
    ));

    // Device-slot export, imported with the device key only.
    let dfile = again
        .export_vtf(PW.into(), sk.clone(), vec![dev.public_key()], T0 + 30)
        .unwrap();
    assert_eq!(vtf_inspect(dfile.clone()).unwrap().device_slots, 1);
    let s = b
        .import_vtf_with_device_key(dfile, Box::new(SoftDevice::new(0x42)), T0 + 31)
        .unwrap();
    assert_eq!(s.unchanged, 2);

    // Password unlock, wrong credentials, decoys.
    drop(again);
    assert!(Vault::unlock_with_password(pa.clone(), PW.into(), sk.clone(), T0).is_ok());
    for (p, k) in [
        ("nope".to_string(), sk.clone()),
        (PW.to_string(), sk_b.clone()),
    ] {
        assert!(matches!(
            Vault::unlock_with_password(pa.clone(), p, k, T0),
            Err(StrongroomError::UnlockFailed)
        ));
    }
    let v = Vault::unlock_first_matching(
        vec![pa.clone(), pb.clone()],
        "second vault pw".into(),
        sk_b,
        T0,
    )
    .unwrap();
    assert_eq!(v.search(String::new(), None, None).unwrap().len(), 2);

    // Unlock gate.
    let gpath = tmp("gate");
    let g = UnlockGate::new(gpath.clone()).unwrap();
    assert_eq!(
        g.check(T0, false, false, true),
        PasswordRequiredReason::PeriodicCheck
    );
    g.record_password_unlock(T0).unwrap();
    assert_eq!(
        g.check(T0 + 1, false, false, true),
        PasswordRequiredReason::NotRequired
    );

    // CSV import and backup.
    let n = v
        .import_csv(
            CsvSource::LastPass,
            "url,username,password,totp,extra,name,grouping,fav\nhttps://x.example,u,p,,,X,G,0\n"
                .into(),
            T0 + 40,
        )
        .unwrap();
    assert_eq!(n.added, 1);
    let bk = tmp("backup");
    v.backup_to(bk.clone()).unwrap();
    assert!(Vault::unlock_with_password(
        bk.clone(),
        "second vault pw".into(),
        generate_secret_key(),
        T0
    )
    .is_err());

    drop((v, b));
    for p in [&pa, &pb, &bk] {
        cleanup(p);
    }
    let _ = std::fs::remove_file(&gpath);
}
