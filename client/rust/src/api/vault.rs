pub struct BoxKeypair {
    pub public: Vec<u8>,
    pub private: Vec<u8>,
}

#[flutter_rust_bridge::frb(sync)]
pub fn generate_root() -> Vec<u8> {
    zalos_vault::generate_root().to_vec()
}

#[flutter_rust_bridge::frb(sync)]
pub fn derive_public_key(root: &[u8], slot: &str) -> Result<Vec<u8>, String> {
    zalos_vault::derive_public_key(root, slot).map_err(|e| e.to_string())
}

#[flutter_rust_bridge::frb(sync)]
pub fn box_keypair() -> BoxKeypair {
    let kp = zalos_vault::box_keypair();
    BoxKeypair {
        public: kp.public.clone(),
        private: kp.private.clone(),
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn seal(public_key: &[u8], aad: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, String> {
    zalos_vault::seal(public_key, aad, plaintext).map_err(|e| e.to_string())
}

#[flutter_rust_bridge::frb(sync)]
pub fn open_with_root(
    root: &[u8],
    slot: &str,
    aad: &[u8],
    sealed: &[u8],
) -> Result<Vec<u8>, String> {
    zalos_vault::open_with_root(root, slot, aad, sealed).map_err(|e| e.to_string())
}

#[flutter_rust_bridge::frb(sync)]
pub fn open_with_private(
    private_key: &[u8],
    aad: &[u8],
    sealed: &[u8],
) -> Result<Vec<u8>, String> {
    zalos_vault::open_with_private(private_key, aad, sealed).map_err(|e| e.to_string())
}

#[flutter_rust_bridge::frb(sync)]
pub fn fingerprint(public_key: &[u8]) -> String {
    zalos_vault::fingerprint(public_key)
}

/// Lowercase hex SHA-256, used to build the aad of sealed media.
#[flutter_rust_bridge::frb(sync)]
pub fn sha256_hex(data: &[u8]) -> String {
    zalos_vault::sha256_hex(data)
}

#[flutter_rust_bridge::frb(opaque)]
pub struct FileOpener {
    inner: zalos_vault::FileOpener,
}

impl FileOpener {
    pub fn with_root(
        root: &[u8],
        slot: &str,
        aad: &[u8],
        header: &[u8],
    ) -> Result<FileOpener, String> {
        zalos_vault::FileOpener::with_root(root, slot, aad, header)
            .map(|inner| FileOpener { inner })
            .map_err(|e| e.to_string())
    }

    pub fn open_chunk(&mut self, chunk: &[u8]) -> Result<Vec<u8>, String> {
        self.inner.open_chunk(chunk).map_err(|e| e.to_string())
    }
}

/// Sealing side of [FileOpener]. The app never seals files; this exists so
/// client tests can produce multi-chunk sealed media.
#[flutter_rust_bridge::frb(opaque)]
pub struct FileSealer {
    inner: zalos_vault::FileSealer,
    header: Vec<u8>,
}

impl FileSealer {
    pub fn create(public_key: &[u8], aad: &[u8]) -> Result<FileSealer, String> {
        zalos_vault::FileSealer::new(public_key, aad)
            .map(|(inner, header)| FileSealer { inner, header })
            .map_err(|e| e.to_string())
    }

    pub fn header(&self) -> Vec<u8> {
        self.header.clone()
    }

    pub fn seal_chunk(&mut self, chunk: &[u8]) -> Result<Vec<u8>, String> {
        self.inner.seal_chunk(chunk).map_err(|e| e.to_string())
    }
}
