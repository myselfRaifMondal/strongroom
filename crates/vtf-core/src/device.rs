//! HPKE (RFC 9180) base mode, DHKEM(P-256, HKDF-SHA256), HKDF-SHA256,
//! export-only AEAD, for device-bound key wrapping (SPEC-VTF 4.5).
//!
//! The sender side is the `hpke` crate. The receiver side cannot be: device
//! private keys live in Secure Enclave / TPM / Android Keystore and are not
//! exportable, and `hpke` requires the private key. So the receiver performs
//! the one ECDH through [`DeviceKey::agree`] (in hardware) and then runs the
//! RFC 9180 `ExtractAndExpand` and key schedule over the `hkdf` crate. That
//! composition is checked in tests against the RFC 9180 A.3 vectors and
//! against `hpke`'s own receiver.

use hkdf::Hkdf;
use hpke::kem::DhP256HkdfSha256;
use hpke::{Deserializable, Kem, OpModeS, Serializable};
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, Zeroizing};

use crate::error::{Error, Result};
use crate::keys::{Key, KEY_LEN};

pub const PUBLIC_KEY_LEN: usize = 65;
pub const ENC_LEN: usize = 65;
pub const KEY_ID_LEN: usize = 8;

const KEM_ID: u16 = 0x0010;
const KDF_ID: u16 = 0x0001;
const AEAD_EXPORT_ONLY: u16 = 0xFFFF;

/// A P-256 key in secure hardware. Implemented by each platform.
pub trait DeviceKey {
    /// 65-byte uncompressed SEC1 public key.
    fn public_key(&self) -> [u8; PUBLIC_KEY_LEN];
    /// Raw ECDH shared secret (x-coordinate) with `peer` (uncompressed SEC1).
    /// Any failure must be reported as `Err`; the core maps it to the generic
    /// unlock failure.
    fn agree(&self, peer: &[u8; PUBLIC_KEY_LEN]) -> core::result::Result<Zeroizing<[u8; 32]>, ()>;
}

/// `key_id` = first 8 bytes of SHA-256 of the uncompressed public key.
pub fn key_id(public_key: &[u8; PUBLIC_KEY_LEN]) -> [u8; KEY_ID_LEN] {
    let digest = Sha256::digest(public_key);
    let mut id = [0u8; KEY_ID_LEN];
    id.copy_from_slice(&digest[..KEY_ID_LEN]);
    id
}

/// Validates that `pk` is an uncompressed SEC1 point on P-256.
pub fn validate_public_key(pk: &[u8; PUBLIC_KEY_LEN]) -> Result<()> {
    if pk[0] != 0x04 {
        return Err(Error::InvalidInput(
            "device public key must be uncompressed SEC1",
        ));
    }
    <DhP256HkdfSha256 as Kem>::PublicKey::from_bytes(pk)
        .map(|_| ())
        .map_err(|_| Error::InvalidInput("device public key is not a valid P-256 point"))
}

/// A CryptoRng that replays fixed bytes. Used to feed `hpke` an ephemeral
/// `ikm` drawn by the caller, so all randomness has one source.
struct ReplayRng<'a> {
    bytes: &'a [u8],
}

impl hpke::rand_core::TryRng for ReplayRng<'_> {
    type Error = core::convert::Infallible;
    fn try_next_u32(&mut self) -> core::result::Result<u32, Self::Error> {
        let mut b = [0u8; 4];
        self.try_fill_bytes(&mut b)?;
        Ok(u32::from_le_bytes(b))
    }
    fn try_next_u64(&mut self) -> core::result::Result<u64, Self::Error> {
        let mut b = [0u8; 8];
        self.try_fill_bytes(&mut b)?;
        Ok(u64::from_le_bytes(b))
    }
    fn try_fill_bytes(&mut self, dst: &mut [u8]) -> core::result::Result<(), Self::Error> {
        assert!(dst.len() <= self.bytes.len(), "replay rng exhausted");
        let (head, tail) = self.bytes.split_at(dst.len());
        dst.copy_from_slice(head);
        self.bytes = tail;
        Ok(())
    }
}

impl hpke::rand_core::TryCryptoRng for ReplayRng<'_> {}

/// Sender: `SetupBaseS(pkR, info)` then `Export(exporter_context, 32)`.
///
/// `ikm_e` is the 32 bytes of ephemeral keying material (RFC 9180
/// `DeriveKeyPair(ikmE)`), drawn by the caller from the OS CSPRNG.
pub fn seal_export(
    pk_r: &[u8; PUBLIC_KEY_LEN],
    info: &[u8],
    exporter_context: &[u8],
    ikm_e: &[u8; 32],
) -> Result<([u8; ENC_LEN], Key)> {
    validate_public_key(pk_r)?;
    let pk = <DhP256HkdfSha256 as Kem>::PublicKey::from_bytes(pk_r)
        .map_err(|_| Error::InvalidInput("device public key"))?;
    let mut rng = ReplayRng { bytes: ikm_e };
    let (enc, ctx) = hpke::setup_sender_with_rng::<
        hpke::aead::ExportOnlyAead,
        hpke::kdf::HkdfSha256,
        DhP256HkdfSha256,
    >(&OpModeS::Base, &pk, info, &mut rng)
    .map_err(|_| Error::InvalidInput("hpke setup"))?;
    let mut out = Zeroizing::new([0u8; KEY_LEN]);
    ctx.export(exporter_context, out.as_mut())
        .map_err(|_| Error::InvalidInput("hpke export"))?;
    let mut enc_bytes = [0u8; ENC_LEN];
    enc_bytes.copy_from_slice(&enc.to_bytes());
    Ok((enc_bytes, out))
}

/// Receiver: RFC 9180 `Decap` with a hardware ECDH, base-mode key schedule,
/// then `Export(exporter_context, 32)`. Bit-identical to `SetupBaseR` +
/// `Export`. Returns `None` on any failure.
pub fn open_export(
    device: &dyn DeviceKey,
    enc: &[u8; ENC_LEN],
    info: &[u8],
    exporter_context: &[u8],
) -> Option<Key> {
    // Reject anything that is not a valid point before it reaches hardware.
    <DhP256HkdfSha256 as Kem>::EncappedKey::from_bytes(enc).ok()?;
    let pk_rm = device.public_key();
    let dh = device.agree(enc).ok()?;
    Some(open_export_with_dh(
        &dh,
        enc,
        &pk_rm,
        info,
        exporter_context,
        AEAD_EXPORT_ONLY,
    ))
}

fn suite_kem() -> [u8; 5] {
    let k = KEM_ID.to_be_bytes();
    [b'K', b'E', b'M', k[0], k[1]]
}

fn suite_hpke(aead_id: u16) -> [u8; 10] {
    let (k, f, a) = (
        KEM_ID.to_be_bytes(),
        KDF_ID.to_be_bytes(),
        aead_id.to_be_bytes(),
    );
    [b'H', b'P', b'K', b'E', k[0], k[1], f[0], f[1], a[0], a[1]]
}

/// `LabeledExtract(salt, label, ikm) = Extract(salt, "HPKE-v1" || suite_id || label || ikm)`
fn labeled_extract(salt: &[u8], suite_id: &[u8], label: &[u8], ikm: &[u8]) -> Zeroizing<[u8; 32]> {
    let mut labeled = Zeroizing::new(Vec::with_capacity(
        7 + suite_id.len() + label.len() + ikm.len(),
    ));
    labeled.extend_from_slice(b"HPKE-v1");
    labeled.extend_from_slice(suite_id);
    labeled.extend_from_slice(label);
    labeled.extend_from_slice(ikm);
    let (prk, _) = Hkdf::<Sha256>::extract(Some(salt), &labeled);
    let mut out = Zeroizing::new([0u8; 32]);
    out.copy_from_slice(&prk);
    out
}

/// `LabeledExpand(prk, label, info, L) = Expand(prk, I2OSP(L,2) || "HPKE-v1" || suite_id || label || info, L)`
fn labeled_expand(prk: &[u8; 32], suite_id: &[u8], label: &[u8], info: &[u8], out: &mut [u8]) {
    let len = u16::try_from(out.len())
        .expect("output length fits u16")
        .to_be_bytes();
    let hk = Hkdf::<Sha256>::from_prk(prk).expect("32-byte PRK");
    hk.expand_multi_info(&[&len, b"HPKE-v1", suite_id, label, info], out)
        .expect("valid HKDF output length");
}

/// The software part of the receiver, separated so tests can run it against
/// RFC 9180 vectors for any AEAD id.
pub(crate) fn open_export_with_dh(
    dh: &[u8; 32],
    enc: &[u8; ENC_LEN],
    pk_rm: &[u8; PUBLIC_KEY_LEN],
    info: &[u8],
    exporter_context: &[u8],
    aead_id: u16,
) -> Key {
    let shared_secret = extract_and_expand(dh, enc, pk_rm);
    let exporter_secret = exporter_secret(&shared_secret, info, aead_id);
    let mut out = Zeroizing::new([0u8; KEY_LEN]);
    labeled_expand(
        &exporter_secret,
        &suite_hpke(aead_id),
        b"sec",
        exporter_context,
        out.as_mut(),
    );
    out
}

pub(crate) fn extract_and_expand(
    dh: &[u8; 32],
    enc: &[u8; ENC_LEN],
    pk_rm: &[u8; PUBLIC_KEY_LEN],
) -> Zeroizing<[u8; 32]> {
    let suite = suite_kem();
    let mut kem_context = [0u8; ENC_LEN + PUBLIC_KEY_LEN];
    kem_context[..ENC_LEN].copy_from_slice(enc);
    kem_context[ENC_LEN..].copy_from_slice(pk_rm);
    let eae_prk = labeled_extract(b"", &suite, b"eae_prk", dh);
    let mut shared = Zeroizing::new([0u8; 32]);
    labeled_expand(
        &eae_prk,
        &suite,
        b"shared_secret",
        &kem_context,
        shared.as_mut(),
    );
    kem_context.zeroize();
    shared
}

pub(crate) fn exporter_secret(
    shared_secret: &[u8; 32],
    info: &[u8],
    aead_id: u16,
) -> Zeroizing<[u8; 32]> {
    let suite = suite_hpke(aead_id);
    let psk_id_hash = labeled_extract(b"", &suite, b"psk_id_hash", b"");
    let info_hash = labeled_extract(b"", &suite, b"info_hash", info);
    let mut ksc = [0u8; 65];
    ksc[0] = 0x00; // mode_base
    ksc[1..33].copy_from_slice(psk_id_hash.as_ref());
    ksc[33..].copy_from_slice(info_hash.as_ref());
    let secret = labeled_extract(shared_secret, &suite, b"secret", b"");
    let mut exp = Zeroizing::new([0u8; 32]);
    labeled_expand(&secret, &suite, b"exp", &ksc, exp.as_mut());
    exp
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use p256::elliptic_curve::sec1::ToSec1Point;

    pub fn hex(s: &str) -> Vec<u8> {
        let s: String = s.split_whitespace().collect();
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    /// Software stand-in for a hardware key (tests only).
    pub struct SoftDevice(pub p256::SecretKey);

    impl DeviceKey for SoftDevice {
        fn public_key(&self) -> [u8; 65] {
            let p = self.0.public_key().to_sec1_point(false);
            p.as_bytes().try_into().unwrap()
        }
        fn agree(&self, peer: &[u8; 65]) -> core::result::Result<Zeroizing<[u8; 32]>, ()> {
            let peer = p256::PublicKey::from_sec1_bytes(peer).map_err(|_| ())?;
            let shared = p256::ecdh::diffie_hellman(self.0.to_nonzero_scalar(), peer.as_affine());
            let mut out = Zeroizing::new([0u8; 32]);
            out.copy_from_slice(shared.raw_secret_bytes());
            Ok(out)
        }
    }

    /// RFC 9180 A.3.1: DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, AES-128-GCM, base mode.
    #[test]
    fn rfc9180_a3_1_vectors() {
        let sk_rm = hex("f3ce7fdae57e1a310d87f1ebbde6f328be0a99cdbcadf4d6589cf29de4b8ffd2");
        let pk_rm: [u8; 65] = hex(
            "04fe8c19ce0905191ebc298a9245792531f26f0cece2460639e8bc39cb7f70
             6a826a779b4cf969b8a0e539c7f62fb3d30ad6aa8f80e30f1d128aafd68a2ce72ea0",
        )
        .try_into()
        .unwrap();
        let enc: [u8; 65] = hex(
            "04a92719c6195d5085104f469a8b9814d5838ff72b60501e2c4466e5e67b325
             ac98536d7b61a1af4b78e5b7f951c0900be863c403ce65c9bfcb9382657222d18c4",
        )
        .try_into()
        .unwrap();
        let info = hex("4f6465206f6e2061204772656369616e2055726e");
        let dev = SoftDevice(p256::SecretKey::from_slice(&sk_rm).unwrap());
        assert_eq!(dev.public_key(), pk_rm);
        let dh = dev.agree(&enc).unwrap();

        let ss = extract_and_expand(&dh, &enc, &pk_rm);
        assert_eq!(
            ss.as_slice(),
            hex("c0d26aeab536609a572b07695d933b589dcf363ff9d93c93adea537aeabb8cb8")
        );
        let es = exporter_secret(&ss, &info, 0x0001);
        assert_eq!(
            es.as_slice(),
            hex("14ad94af484a7ad3ef40e9f3be99ecc6fa9036df9d4920548424df127ee0d99f")
        );

        for (ctx, want) in [
            (
                "",
                "5e9bc3d236e1911d95e65b576a8a86d478fb827e8bdfe77b741b289890490d4d",
            ),
            (
                "00",
                "6cff87658931bda83dc857e6353efe4987a201b849658d9b047aab4cf216e796",
            ),
            (
                "54657374436f6e74657874",
                "d8f1ea7942adbba7412c6d431c62d01371ea476b823eb697e1f6e6cae1dab85a",
            ),
        ] {
            let got = open_export_with_dh(&dh, &enc, &pk_rm, &info, &hex(ctx), 0x0001);
            assert_eq!(got.as_slice(), hex(want));
        }
    }

    /// The composed receiver agrees with the `hpke` crate's sender for the
    /// VTF ciphersuite (export-only AEAD).
    #[test]
    fn composed_receiver_matches_hpke_crate() {
        for seed in 1u8..=8 {
            let dev = SoftDevice(p256::SecretKey::from_slice(&[seed; 32]).unwrap());
            let pk = dev.public_key();
            let ikm_e = [seed.wrapping_mul(37); 32];
            let (enc, k_send) =
                seal_export(&pk, b"VTF1/hpke-info test", b"VTF1/device-wrap", &ikm_e).unwrap();
            let k_recv =
                open_export(&dev, &enc, b"VTF1/hpke-info test", b"VTF1/device-wrap").unwrap();
            assert_eq!(k_send.as_slice(), k_recv.as_slice());
            // Wrong info or exporter context gives a different key.
            let other = open_export(&dev, &enc, b"other", b"VTF1/device-wrap").unwrap();
            assert_ne!(k_send.as_slice(), other.as_slice());
        }
    }

    #[test]
    fn invalid_points_rejected() {
        let mut pk = [0u8; 65];
        pk[0] = 0x04;
        assert!(validate_public_key(&pk).is_err());
        let dev = SoftDevice(p256::SecretKey::from_slice(&[7; 32]).unwrap());
        assert!(open_export(&dev, &pk, b"", b"").is_none());
    }
}
