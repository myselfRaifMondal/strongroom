//! Store-level tests. Each create/unlock/import runs Argon2id at the frozen
//! cost (256 MiB); run with `--test-threads=2` on small machines.
//! All passwords and keys here are deliberate public test fixtures.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

use p256::elliptic_curve::sec1::ToSec1Point;
use vault_core::csv::CsvSource;
use vault_core::store::{header_path, TRASH_RETENTION_SECS};
use vault_core::*;
use vtf_core::device::DeviceKey;
use zeroize::Zeroizing;

const PW: &str = "test fixture password";
const DAY: i64 = 86_400;
const T0: i64 = 1_760_000_000;

fn sk() -> String {
    vtf_core::SecretKey::from_bytes([7; 16])
        .to_display()
        .to_string()
}

fn other_sk() -> String {
    vtf_core::SecretKey::from_bytes([8; 16])
        .to_display()
        .to_string()
}

fn tmp(name: &str) -> PathBuf {
    static N: AtomicU32 = AtomicU32::new(0);
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("vault-core-tests");
    std::fs::create_dir_all(&dir).unwrap();
    let p = dir.join(format!(
        "{name}-{}-{}.db",
        std::process::id(),
        N.fetch_add(1, Ordering::SeqCst)
    ));
    let _ = std::fs::remove_file(&p);
    let _ = std::fs::remove_file(header_path(&p));
    p
}

fn cleanup(p: &Path) {
    let _ = std::fs::remove_file(p);
    let _ = std::fs::remove_file(header_path(p));
}

pub struct SoftDevice(p256::SecretKey);

impl SoftDevice {
    fn new(seed: u8) -> Self {
        SoftDevice(p256::SecretKey::from_slice(&[seed; 32]).unwrap())
    }
}

impl DeviceKey for SoftDevice {
    fn public_key(&self) -> [u8; 65] {
        self.0
            .public_key()
            .to_sec1_point(false)
            .as_bytes()
            .try_into()
            .unwrap()
    }
    fn agree(&self, peer: &[u8; 65]) -> std::result::Result<Zeroizing<[u8; 32]>, ()> {
        let peer = p256::PublicKey::from_sec1_bytes(peer).map_err(|_| ())?;
        let shared = p256::ecdh::diffie_hellman(self.0.to_nonzero_scalar(), peer.as_affine());
        let mut out = Zeroizing::new([0u8; 32]);
        out.copy_from_slice(shared.raw_secret_bytes());
        Ok(out)
    }
}

fn login(title: &str, user: &str, pw: &str, url: &str) -> ItemData {
    ItemData {
        kind: ItemKind::Login,
        title: title.into(),
        username: Some(user.into()),
        password: Some(pw.into()),
        urls: vec![url.into()],
        notes: None,
        totp: None,
        folder: None,
        tags: vec![],
        fields: vec![],
        travel_safe: false,
    }
}

#[test]
fn create_unlock_and_generic_failures() {
    let p = tmp("unlock");
    {
        let mut v = Vault::create(&p, PW, &sk(), T0).unwrap();
        v.add_item(login("A", "a", "pw", "a.example"), T0).unwrap();
    }
    assert!(matches!(
        Vault::create(&p, PW, &sk(), T0),
        Err(Error::InvalidInput(_))
    ));
    let v = Vault::unlock_with_password(&p, PW, &sk()).unwrap();
    assert_eq!(v.search("", None, None).unwrap().len(), 1);
    drop(v);
    for (pw, s) in [
        ("wrong", sk()),
        (PW, other_sk()),
        (PW, "garbage".to_string()),
        ("", sk()),
    ] {
        assert!(matches!(
            Vault::unlock_with_password(&p, pw, &s),
            Err(Error::UnlockFailed)
        ));
    }
    assert!(matches!(
        Vault::unlock_with_password(&tmp("missing"), PW, &sk()),
        Err(Error::UnlockFailed)
    ));
    // The database file is unreadable without the vault key.
    let raw = std::fs::read(&p).unwrap();
    assert!(!raw.windows(6).any(|w| w == b"SQLite"));
    assert!(!raw.windows(13).any(|w| w == b"a.example"));
    // A tampered header fails generically.
    let hp = header_path(&p);
    let mut h = std::fs::read(&hp).unwrap();
    let last = h.len() - 1;
    h[last] ^= 1;
    std::fs::write(&hp, &h).unwrap();
    assert!(matches!(
        Vault::unlock_with_password(&p, PW, &sk()),
        Err(Error::UnlockFailed)
    ));
    cleanup(&p);
}

#[test]
fn items_search_history_trash_totp_health() {
    let p = tmp("items");
    let mut v = Vault::create(&p, PW, &sk(), T0).unwrap();
    let mut mail = login(
        "Example Mail",
        "alice@example.com",
        "Tr0ub4dor&3",
        "https://mail.example.com/",
    );
    mail.folder = Some("Work".into());
    mail.tags = vec!["email".into()];
    mail.totp = Some("otpauth://totp/x?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8".into());
    mail.fields = vec![
        Field {
            name: "Recovery PIN".into(),
            value: "4815".into(),
            concealed: true,
        },
        Field {
            name: "Account number".into(),
            value: "12".into(),
            concealed: false,
        },
    ];
    let a = v.add_item(mail.clone(), T0).unwrap();
    let b = v
        .add_item(
            login("Bank", "bob", "Tr0ub4dor&3", "https://www.bank.co.uk/login"),
            T0,
        )
        .unwrap();
    let c = v
        .add_item(
            login(
                "Strong",
                "carol",
                "x7#Kq!v9Lm2$Rt8@zW",
                "https://other.example.org",
            ),
            T0,
        )
        .unwrap();

    // search
    assert_eq!(v.search("MAIL", None, None).unwrap().len(), 1);
    assert_eq!(v.search("account", None, None).unwrap()[0].id, a);
    assert!(
        v.search("recovery", None, None).unwrap().is_empty(),
        "concealed field names are not searchable"
    );
    assert_eq!(v.search("", Some("work"), None).unwrap().len(), 1);
    assert_eq!(v.search("", None, Some("EMAIL")).unwrap().len(), 1);
    assert_eq!(v.search("", None, None).unwrap().len(), 3);
    let s = &v.search("bank", None, None).unwrap()[0];
    assert_eq!(s.subtitle.as_deref(), Some("bob"));
    assert!(v.search("example mail", None, None).unwrap()[0].has_totp);

    // registrable-domain matching
    assert_eq!(
        v.match_domain("https://login.example.com/x").unwrap()[0].id,
        a
    );
    assert_eq!(v.match_domain("bank.co.uk").unwrap()[0].id, b);
    assert!(v.match_domain("example.net").unwrap().is_empty());
    assert!(v.match_domain("co.uk").unwrap().is_empty());

    // update + history
    let mut m2 = mail.clone();
    m2.password = Some("password1".into());
    v.update_item(&a, m2.clone(), T0 + 10).unwrap();
    v.update_item(&a, m2.clone(), T0 + 11).unwrap(); // no-op
    let h = v.item_history(&a).unwrap();
    assert_eq!(h.len(), 1);
    assert_eq!(h[0].modified_at, T0);
    assert_eq!(h[0].data.password.as_deref(), Some("Tr0ub4dor&3"));
    let got = v.get_item(&a).unwrap();
    assert!(got.data == m2 && got.modified_at == T0 + 10 && got.created_at == T0);
    for i in 0..70 {
        let mut m = m2.clone();
        m.notes = Some(format!("rev {i}"));
        v.update_item(&a, m, T0 + 100 + i).unwrap();
    }
    assert_eq!(
        v.item_history(&a).unwrap().len(),
        64,
        "history is capped at 64"
    );

    // folders / tags
    assert_eq!(v.list_folders().unwrap(), ["Work"]);
    assert_eq!(v.list_tags().unwrap(), ["email"]);

    // TOTP: RFC 6238 SHA-1 vector at t = 59
    assert_eq!(v.item_totp(&a, 59).unwrap().code, "94287082");
    assert!(matches!(v.item_totp(&b, 59), Err(Error::NotFound)));

    // health: a and b... a now has a fresh password; b reuses nothing.
    let mut b2 = v.get_item(&b).unwrap().data;
    b2.password = Some("x7#Kq!v9Lm2$Rt8@zW".into()); // reuse c's password
    v.update_item(&b, b2, T0 + 500).unwrap();
    let r = v.password_health(T0 + 400 * DAY).unwrap();
    assert!(r.reused_item_ids.contains(&b) && r.reused_item_ids.contains(&c));
    assert!(r.weak_item_ids.contains(&a), "{:?}", r);
    assert!(r.old_item_ids.contains(&c) && r.old_item_ids.contains(&a));
    assert_eq!(r.security_score, 0);
    let fresh = v.password_health(T0 + 600).unwrap();
    assert!(fresh.old_item_ids.is_empty());

    // trash / restore / purge
    v.trash_item(&c, T0 + 1000).unwrap();
    assert_eq!(v.search("", None, None).unwrap().len(), 2);
    let t = v.list_trash().unwrap();
    assert_eq!(t.len(), 1);
    assert_eq!(t[0].purge_at, T0 + 1000 + TRASH_RETENTION_SECS);
    assert!(matches!(
        v.update_item(&c, login("x", "y", "z", "w"), T0 + 1001),
        Err(Error::InvalidInput(_))
    ));
    v.restore_item(&c, T0 + 1002).unwrap();
    assert!(v.list_trash().unwrap().is_empty());
    v.trash_item(&c, T0 + 2000).unwrap();
    assert_eq!(
        v.purge_expired_trash(T0 + 2000 + TRASH_RETENTION_SECS - 1)
            .unwrap(),
        0
    );
    assert_eq!(
        v.purge_expired_trash(T0 + 2000 + TRASH_RETENTION_SECS)
            .unwrap(),
        1
    );
    assert!(matches!(v.get_item(&c), Err(Error::NotFound)));
    assert!(matches!(v.get_item("zz"), Err(Error::NotFound)));

    // limits
    let mut huge = login("h", "u", "p", "x");
    huge.urls = vec!["u".into(); 65];
    assert!(matches!(v.add_item(huge, T0), Err(Error::InvalidInput(_))));
    cleanup(&p);
}

#[test]
fn export_import_merge_and_rollback() {
    let (pa, pb) = (tmp("merge-a"), tmp("merge-b"));
    let mut a = Vault::create(&pa, PW, &sk(), T0).unwrap();
    let mut b = Vault::create(&pb, "other password", &other_sk(), T0).unwrap();
    let x = a
        .add_item(login("X", "x", "px", "x.example"), T0 + 1)
        .unwrap();
    let y = a
        .add_item(login("Y", "y", "py", "y.example"), T0 + 2)
        .unwrap();

    // Export requires this vault's own credentials.
    assert!(matches!(
        a.export_vtf("wrong", &sk(), &[], T0 + 3),
        Err(Error::UnlockFailed)
    ));
    let f1 = a.export_vtf(PW, &sk(), &[], T0 + 100).unwrap();
    assert!(matches!(
        b.import_vtf(&f1, PW, &other_sk(), T0 + 101),
        Err(Error::UnlockFailed)
    ));
    let s = b.import_vtf(&f1, PW, &sk(), T0 + 101).unwrap();
    assert_eq!(
        s,
        ImportSummary {
            added: 2,
            updated: 0,
            unchanged: 0,
            conflicts: 0
        }
    );
    assert!(b.get_item(&x).unwrap().data == a.get_item(&x).unwrap().data);
    // Same file again: nothing changes, not a rollback.
    let s = b.import_vtf(&f1, PW, &sk(), T0 + 102).unwrap();
    assert_eq!(
        s,
        ImportSummary {
            added: 0,
            updated: 0,
            unchanged: 2,
            conflicts: 0
        }
    );

    // Concurrent edits of X: B's is newer and wins; A's is kept in history.
    let mut xa = a.get_item(&x).unwrap().data;
    xa.password = Some("from A".into());
    a.update_item(&x, xa.clone(), T0 + 1500).unwrap();
    let mut xb = b.get_item(&x).unwrap().data;
    xb.password = Some("from B".into());
    b.update_item(&x, xb.clone(), T0 + 2000).unwrap();
    // A adds Z and trashes Y.
    let z = a
        .add_item(login("Z", "z", "pz", "z.example"), T0 + 1600)
        .unwrap();
    a.trash_item(&y, T0 + 1700).unwrap();
    let f2 = a.export_vtf(PW, &sk(), &[], T0 + 2100).unwrap();
    let s = b.import_vtf(&f2, PW, &sk(), T0 + 2101).unwrap();
    assert_eq!(
        s,
        ImportSummary {
            added: 1,
            updated: 1,
            unchanged: 1,
            conflicts: 1
        }
    );
    assert_eq!(
        b.get_item(&x).unwrap().data.password.as_deref(),
        Some("from B")
    );
    assert!(b
        .item_history(&x)
        .unwrap()
        .iter()
        .any(|h| h.data.password.as_deref() == Some("from A")));
    assert!(b.get_item(&y).unwrap().trashed_at.is_some());
    assert!(b.get_item(&z).is_ok());

    // B's newer state flows back to A (last writer wins), fast-forward.
    let fb = b
        .export_vtf("other password", &other_sk(), &[], T0 + 2200)
        .unwrap();
    let s = a
        .import_vtf(&fb, "other password", &other_sk(), T0 + 2201)
        .unwrap();
    assert_eq!(s.updated, 1);
    assert_eq!(
        a.get_item(&x).unwrap().data.password.as_deref(),
        Some("from B")
    );

    // Purge on A leaves a tombstone that deletes Y on B.
    assert_eq!(
        a.purge_expired_trash(T0 + 1700 + TRASH_RETENTION_SECS)
            .unwrap(),
        1
    );
    let f3 = a
        .export_vtf(PW, &sk(), &[], T0 + 1700 + TRASH_RETENTION_SECS + 1)
        .unwrap();
    let s = b
        .import_vtf(&f3, PW, &sk(), T0 + 1700 + TRASH_RETENTION_SECS + 2)
        .unwrap();
    assert_eq!(s.updated, 1);
    assert!(matches!(b.get_item(&y), Err(Error::NotFound)));
    // An older file still holding Y cannot resurrect it (tombstone wins).
    assert!(matches!(
        b.import_vtf(&f2, PW, &sk(), T0 + 1700 + TRASH_RETENTION_SECS + 3),
        Err(Error::FormatRejected("rollback"))
    ));
    assert!(matches!(b.get_item(&y), Err(Error::NotFound)));
    // Stale file with nothing new: refused as rollback.
    assert!(matches!(
        b.import_vtf(&f1, PW, &sk(), T0 + 1700 + TRASH_RETENTION_SECS + 4),
        Err(Error::FormatRejected("rollback"))
    ));

    // Tampered file: named VTF check.
    let mut bad = f3.clone();
    let n = bad.len();
    bad[n - 1] ^= 1;
    assert!(matches!(
        b.import_vtf(&bad, PW, &sk(), T0 + 1700 + TRASH_RETENTION_SECS + 5),
        Err(Error::FormatRejected("chunk-auth"))
    ));
    drop((a, b));
    cleanup(&pa);
    cleanup(&pb);
}

#[test]
fn device_key_unlock_and_device_bound_import() {
    let (p, q) = (tmp("device"), tmp("device-other"));
    let dev = SoftDevice::new(0x11);
    let other = SoftDevice::new(0x22);
    let (blob, id, file) = {
        let mut v = Vault::create(&p, PW, &sk(), T0).unwrap();
        let id = v.add_item(login("D", "d", "pd", "d.example"), T0).unwrap();
        assert!(matches!(
            v.wrap_vault_key_for_device(&[4u8; 65]),
            Err(Error::InvalidInput(_))
        ));
        let blob = v.wrap_vault_key_for_device(&dev.public_key()).unwrap();
        let file = v
            .export_vtf(PW, &sk(), &[dev.public_key().to_vec()], T0 + 1)
            .unwrap();
        (blob, id, file)
    };
    let v = Vault::unlock_with_device_key(&p, &blob, &dev).unwrap();
    assert_eq!(v.get_item(&id).unwrap().data.title, "D");
    drop(v);
    assert!(matches!(
        Vault::unlock_with_device_key(&p, &blob, &other),
        Err(Error::UnlockFailed)
    ));
    let mut tampered = blob.clone();
    tampered[100] ^= 1;
    assert!(matches!(
        Vault::unlock_with_device_key(&p, &tampered, &dev),
        Err(Error::UnlockFailed)
    ));
    // A blob is bound to its vault.
    let mut w = Vault::create(&q, PW, &sk(), T0).unwrap();
    assert!(matches!(
        Vault::unlock_with_device_key(&q, &blob, &dev),
        Err(Error::UnlockFailed)
    ));
    // Device-slot import into another vault.
    assert_eq!(
        w.import_vtf_with_device_key(&file, &dev, T0 + 2)
            .unwrap()
            .added,
        1
    );
    assert!(matches!(
        w.import_vtf_with_device_key(&file, &other, T0 + 3),
        Err(Error::UnlockFailed)
    ));
    drop(w);
    cleanup(&p);
    cleanup(&q);
}

#[test]
fn decoy_first_matching() {
    let (real, decoy, missing) = (tmp("real"), tmp("decoy"), tmp("missing"));
    {
        let mut r = Vault::create(&real, PW, &sk(), T0).unwrap();
        r.add_item(login("real", "u", "p", "r.example"), T0)
            .unwrap();
        let mut d = Vault::create(&decoy, "decoy password", &sk(), T0).unwrap();
        d.add_item(login("decoy", "u", "p", "d.example"), T0)
            .unwrap();
    }
    let paths = [missing.as_path(), decoy.as_path(), real.as_path()];
    let v = Vault::unlock_first_matching(&paths, PW, &sk()).unwrap();
    assert_eq!(v.search("", None, None).unwrap()[0].title, "real");
    let v = Vault::unlock_first_matching(&paths, "decoy password", &sk()).unwrap();
    assert_eq!(v.search("", None, None).unwrap()[0].title, "decoy");
    assert!(matches!(
        Vault::unlock_first_matching(&paths, "nope", &sk()),
        Err(Error::UnlockFailed)
    ));
    assert!(Vault::unlock_first_matching(&[], PW, &sk()).is_err());
    cleanup(&real);
    cleanup(&decoy);
}

#[test]
fn travel_mode_backup_and_csv() {
    let (p, bk) = (tmp("travel"), tmp("backup"));
    let mut v = Vault::create(&p, PW, &sk(), T0).unwrap();
    let mut safe = login("Safe", "s", "ps", "s.example");
    safe.travel_safe = true;
    let safe_id = v.add_item(safe, T0).unwrap();
    let home_id = v
        .add_item(login("Home", "h", "ph", "h.example"), T0)
        .unwrap();
    let full = v.export_vtf(PW, &sk(), &[], T0 + 1).unwrap();
    v.backup_to(&bk).unwrap();
    assert!(matches!(v.backup_to(&bk), Err(Error::InvalidInput(_))));

    assert!(!v.travel_mode().unwrap());
    v.set_travel_mode(true, T0 + 2).unwrap();
    assert!(v.travel_mode().unwrap());
    assert!(v.get_item(&safe_id).is_ok());
    assert!(matches!(v.get_item(&home_id), Err(Error::NotFound)));
    // While travelling, imports skip non-travel-safe items.
    let s = v.import_vtf(&full, PW, &sk(), T0 + 3).unwrap();
    assert_eq!(s.added, 0);
    assert!(matches!(v.get_item(&home_id), Err(Error::NotFound)));
    v.set_travel_mode(false, T0 + 4).unwrap();
    let s = v.import_vtf(&full, PW, &sk(), T0 + 5).unwrap();
    assert_eq!(s.added, 1);
    assert!(v.get_item(&home_id).is_ok());

    // The backup is a standalone encrypted vault with the same credentials.
    let b = Vault::unlock_with_password(&bk, PW, &sk()).unwrap();
    assert_eq!(b.search("", None, None).unwrap().len(), 2);
    assert!(matches!(
        Vault::unlock_with_password(&bk, "wrong", &sk()),
        Err(Error::UnlockFailed)
    ));

    let csv = "name,url,username,password,note\nShop,https://shop.example,dave,pw3,\n";
    let s = v.import_csv(CsvSource::Chrome, csv, T0 + 6).unwrap();
    assert_eq!(s.added, 1);
    assert_eq!(v.match_domain("shop.example").unwrap().len(), 1);
    drop((v, b));
    cleanup(&p);
    cleanup(&bk);
}

#[test]
fn unlock_gate_rules() {
    let p = tmp("gate");
    let g = UnlockGate::new(&p).unwrap();
    use PasswordRequiredReason::*;
    assert_eq!(g.check(T0, false, false, false), NoBiometricKey);
    assert_eq!(
        g.check(T0, false, false, true),
        PeriodicCheck,
        "never unlocked with password"
    );
    g.record_password_unlock(T0).unwrap();
    assert_eq!(g.check(T0 + 10, false, false, true), NotRequired);
    assert_eq!(g.check(T0 + 10, true, false, true), FirstLaunchAfterReboot);
    assert_eq!(
        g.check(T0 + 10, true, true, true),
        BiometricEnrollmentChanged
    );
    assert_eq!(g.check(T0 + 7 * DAY - 1, false, false, true), NotRequired);
    assert_eq!(g.check(T0 + 7 * DAY, false, false, true), PeriodicCheck);
    assert_eq!(
        g.check(T0 - 1, false, false, true),
        PeriodicCheck,
        "clock went backwards"
    );
    for _ in 0..4 {
        g.record_biometric_failure().unwrap();
    }
    assert_eq!(g.check(T0 + 10, false, false, true), NotRequired);
    g.record_biometric_success().unwrap();
    for _ in 0..5 {
        g.record_biometric_failure().unwrap();
    }
    assert_eq!(
        g.check(T0 + 10, false, false, true),
        TooManyBiometricFailures
    );
    g.record_biometric_success().unwrap();
    assert_eq!(
        g.check(T0 + 10, false, false, true),
        TooManyBiometricFailures
    );
    g.record_password_unlock(T0 + 20).unwrap();
    assert_eq!(g.check(T0 + 30, false, false, true), NotRequired);
    std::fs::write(&p, "garbage").unwrap();
    assert_eq!(
        g.check(T0 + 30, false, false, true),
        PeriodicCheck,
        "malformed state fails safe"
    );
    let _ = std::fs::remove_file(&p);
}

#[test]
fn pairing_payload_round_trip() {
    let pk = SoftDevice::new(0x33).public_key();
    let payload = pairing::payload(&pk);
    assert!(payload.starts_with("SR1PAIR:"));
    let (back, fp) = pairing::parse(&payload).unwrap();
    assert_eq!(back, pk);
    assert_eq!(fp.len(), 19);
    assert_eq!(fp, pairing::fingerprint(&pk));
    assert_ne!(
        fp,
        pairing::fingerprint(&SoftDevice::new(0x34).public_key())
    );
    assert!(pairing::parse(&payload.to_lowercase()).is_ok());
    assert!(pairing::parse("SR1PAIR:AAAA").is_err());
    assert!(pairing::parse(&payload.replace("SR1PAIR:", "XX:")).is_err());
    let mut not_on_curve = [0u8; 65];
    not_on_curve[0] = 4;
    assert!(pairing::parse(&pairing::payload(&not_on_curve)).is_err());
}
