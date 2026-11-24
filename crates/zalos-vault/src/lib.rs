//! HPKE (RFC 9180) sealing for zalos vault: encryption at rest with
//! client-held keys. All cryptography goes through the `hpke`, `hkdf` and
//! `sha2` crates; nothing here implements a primitive.
//!
//! Suite: DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20-Poly1305, base mode.
//!
//! Wire layout:
//! - record: `sealed = encapped_key (32 bytes) || ciphertext || 16-byte tag`
//! - file: `header = encapped_key (32 bytes)`, then each `seal_chunk`
//!   produces `ciphertext || 16-byte tag`; chunk order is enforced by the
//!   HPKE context sequence number.
//!
//! IMPORTANT: chunking authenticates order, not length. A truncated tail is
//! undetectable; callers must store the chunk count or total plaintext size
//! in authenticated metadata (for example the aad of the record that
//! references the file).

use std::convert::Infallible;

use hpke::aead::{AeadCtxR, AeadCtxS, ChaCha20Poly1305};
use hpke::kdf::HkdfSha256;
use hpke::kem::{Kem as KemTrait, X25519HkdfSha256};
use hpke::rand_core::{TryCryptoRng, TryRng};
use hpke::{Deserializable, OpModeR, OpModeS, Serializable};
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, Zeroizing};

type Kem = X25519HkdfSha256;
type Kdf = HkdfSha256;
type Aead = ChaCha20Poly1305;
type PublicKey = <Kem as KemTrait>::PublicKey;
type PrivateKey = <Kem as KemTrait>::PrivateKey;

const RECORD_INFO: &[u8] = b"zalos/vault/1/record";
const FILE_INFO: &[u8] = b"zalos/vault/1/file";
const ENCAP_LEN: usize = 32; // X25519 encapped key size
const TAG_LEN: usize = 16; // ChaCha20-Poly1305 tag size

#[derive(Debug)]
pub struct VaultError(pub String);

impl std::fmt::Display for VaultError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}
impl std::error::Error for VaultError {}

fn err<E: std::fmt::Debug>(e: E) -> VaultError {
    VaultError(format!("{e:?}"))
}

// CSPRNG over getrandom implementing the rand_core 0.10 traits hpke takes.
struct OsRng;
impl TryRng for OsRng {
    type Error = Infallible;
    fn try_next_u32(&mut self) -> Result<u32, Infallible> {
        let mut b = [0u8; 4];
        self.try_fill_bytes(&mut b)?;
        Ok(u32::from_le_bytes(b))
    }
    fn try_next_u64(&mut self) -> Result<u64, Infallible> {
        let mut b = [0u8; 8];
        self.try_fill_bytes(&mut b)?;
        Ok(u64::from_le_bytes(b))
    }
    fn try_fill_bytes(&mut self, dst: &mut [u8]) -> Result<(), Infallible> {
        getrandom::fill(dst).expect("getrandom failed");
        Ok(())
    }
}
impl TryCryptoRng for OsRng {}

#[derive(Clone, Debug)]
pub struct Keypair {
    pub public: Vec<u8>,
    pub private: Vec<u8>,
}

impl Drop for Keypair {
    fn drop(&mut self) {
        self.private.zeroize();
    }
}

pub fn generate_root() -> [u8; 32] {
    let mut root = [0u8; 32];
    getrandom::fill(&mut root).expect("getrandom failed");
    root
}

fn derive_keypair_version(
    root: &[u8],
    slot: &str,
    key_version: u32,
) -> Result<(PrivateKey, PublicKey), VaultError> {
    // HKDF-SHA256 with explicit key-version domain separation:
    // key_version <= 1 preserves the v1 derivation for backwards compatibility;
    // key_version >= 2 derives an independent rotated key generation.
    let hk = hkdf::Hkdf::<Sha256>::new(None, root);
    let info = if key_version <= 1 {
        format!("zalos/vault/1/{slot}")
    } else {
        format!("zalos/vault/2/{slot}/kv/{key_version}")
    };
    let mut ikm = Zeroizing::new([0u8; 32]);
    hk.expand(info.as_bytes(), ikm.as_mut()).map_err(err)?;
    Ok(Kem::derive_keypair(ikm.as_ref()))
}

/// Deterministic per-slot public key (generation 1).
pub fn derive_public_key(root: &[u8], slot: &str) -> Result<Vec<u8>, VaultError> {
    derive_public_key_version(root, slot, 1)
}

/// Deterministic per-slot public key for a specific key generation (`kv`).
pub fn derive_public_key_version(
    root: &[u8],
    slot: &str,
    key_version: u32,
) -> Result<Vec<u8>, VaultError> {
    let (_, pk) = derive_keypair_version(root, slot, key_version)?;
    Ok(pk.to_bytes().to_vec())
}

/// Random X25519 KEM keypair a device publishes as its "box key" so an
/// existing device can wrap the vault root to it.
pub fn box_keypair() -> Keypair {
    // derive_keypair is deterministic over its ikm, so 64 random bytes give a
    // fresh uniform KEM keypair without needing a rand backend.
    let mut ikm = Zeroizing::new([0u8; 64]);
    getrandom::fill(ikm.as_mut()).expect("getrandom failed");
    let (sk, pk) = Kem::derive_keypair(ikm.as_ref());
    Keypair {
        public: pk.to_bytes().to_vec(),
        private: sk.to_bytes().to_vec(),
    }
}

fn parse_public(bytes: &[u8]) -> Result<PublicKey, VaultError> {
    PublicKey::from_bytes(bytes).map_err(err)
}

fn parse_private(bytes: &[u8]) -> Result<PrivateKey, VaultError> {
    PrivateKey::from_bytes(bytes).map_err(err)
}

/// Base-mode single shot seal. Output is encapped_key || ciphertext.
pub fn seal(public_key: &[u8], aad: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, VaultError> {
    let pk = parse_public(public_key)?;
    let (encapped, ct) = hpke::single_shot_seal_with_rng::<Aead, Kdf, Kem>(
        &OpModeS::Base,
        &pk,
        RECORD_INFO,
        plaintext,
        aad,
        &mut OsRng,
    )
    .map_err(err)?;
    let mut out = encapped.to_bytes().to_vec();
    out.extend_from_slice(&ct);
    Ok(out)
}

fn open(
    private: &PrivateKey,
    info: &[u8],
    aad: &[u8],
    sealed: &[u8],
) -> Result<Vec<u8>, VaultError> {
    if sealed.len() < ENCAP_LEN + TAG_LEN {
        return Err(VaultError("sealed input too short".into()));
    }
    let (enc, ct) = sealed.split_at(ENCAP_LEN);
    let encapped = <Kem as KemTrait>::EncappedKey::from_bytes(enc).map_err(err)?;
    hpke::single_shot_open::<Aead, Kdf, Kem>(
        &OpModeR::Base,
        private,
        &encapped,
        info,
        ct,
        aad,
    )
    .map_err(err)
}

pub fn open_with_root(
    root: &[u8],
    slot: &str,
    aad: &[u8],
    sealed: &[u8],
) -> Result<Vec<u8>, VaultError> {
    open_with_root_version(root, slot, 1, aad, sealed)
}

pub fn open_with_root_version(
    root: &[u8],
    slot: &str,
    key_version: u32,
    aad: &[u8],
    sealed: &[u8],
) -> Result<Vec<u8>, VaultError> {
    let (sk, _) = derive_keypair_version(root, slot, key_version)?;
    open(&sk, RECORD_INFO, aad, sealed)
}

pub fn open_with_private(
    private_key: &[u8],
    aad: &[u8],
    sealed: &[u8],
) -> Result<Vec<u8>, VaultError> {
    let sk = parse_private(private_key)?;
    open(&sk, RECORD_INFO, aad, sealed)
}

pub struct FileSealer {
    ctx: AeadCtxS<Aead, Kdf, Kem>,
    aad: Vec<u8>,
}

impl FileSealer {
    /// One HPKE context per file; the header is the encapped key.
    pub fn new(public_key: &[u8], aad: &[u8]) -> Result<(FileSealer, Vec<u8>), VaultError> {
        let pk = parse_public(public_key)?;
        let (encapped, ctx) = hpke::setup_sender_with_rng::<Aead, Kdf, Kem>(
            &OpModeS::Base,
            &pk,
            FILE_INFO,
            &mut OsRng,
        )
        .map_err(err)?;
        Ok((
            FileSealer {
                ctx,
                aad: aad.to_vec(),
            },
            encapped.to_bytes().to_vec(),
        ))
    }

    pub fn seal_chunk(&mut self, chunk: &[u8]) -> Result<Vec<u8>, VaultError> {
        self.ctx.seal(chunk, &self.aad).map_err(err)
    }
}

pub struct FileOpener {
    ctx: AeadCtxR<Aead, Kdf, Kem>,
    aad: Vec<u8>,
}

impl FileOpener {
    fn new(private: &PrivateKey, aad: &[u8], header: &[u8]) -> Result<FileOpener, VaultError> {
        let encapped = <Kem as KemTrait>::EncappedKey::from_bytes(header).map_err(err)?;
        let ctx = hpke::setup_receiver::<Aead, Kdf, Kem>(
            &OpModeR::Base,
            private,
            &encapped,
            FILE_INFO,
        )
        .map_err(err)?;
        Ok(FileOpener {
            ctx,
            aad: aad.to_vec(),
        })
    }

    pub fn with_root(
        root: &[u8],
        slot: &str,
        aad: &[u8],
        header: &[u8],
    ) -> Result<FileOpener, VaultError> {
        FileOpener::with_root_version(root, slot, 1, aad, header)
    }

    pub fn with_root_version(
        root: &[u8],
        slot: &str,
        key_version: u32,
        aad: &[u8],
        header: &[u8],
    ) -> Result<FileOpener, VaultError> {
        let (sk, _) = derive_keypair_version(root, slot, key_version)?;
        FileOpener::new(&sk, aad, header)
    }

    pub fn with_private(
        private_key: &[u8],
        aad: &[u8],
        header: &[u8],
    ) -> Result<FileOpener, VaultError> {
        let sk = parse_private(private_key)?;
        FileOpener::new(&sk, aad, header)
    }

    pub fn open_chunk(&mut self, chunk: &[u8]) -> Result<Vec<u8>, VaultError> {
        self.ctx.open(chunk, &self.aad).map_err(err)
    }
}

/// Lowercase hex SHA-256 of arbitrary data (media aad url hash).
pub fn sha256_hex(data: &[u8]) -> String {
    Sha256::digest(data)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// SHA-256 of the public key, first 16 bytes, hex grouped in 4s. Same
/// display format the server uses for its Noise key fingerprint.
pub fn fingerprint(public_key: &[u8]) -> String {
    let digest = Sha256::digest(public_key);
    let hex = digest[..16]
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    hex.as_bytes()
        .chunks(4)
        .map(|c| std::str::from_utf8(c).unwrap().to_string())
        .collect::<Vec<_>>()
        .join(" ")
}
