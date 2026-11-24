use wasm_bindgen::prelude::*;

fn to_err(e: zalos_vault::VaultError) -> JsError {
    JsError::new(&e.0)
}

#[wasm_bindgen]
pub fn generate_root() -> Vec<u8> {
    zalos_vault::generate_root().to_vec()
}

#[wasm_bindgen]
pub fn derive_public_key(root: &[u8], slot: &str) -> Result<Vec<u8>, JsError> {
    zalos_vault::derive_public_key(root, slot).map_err(to_err)
}

#[wasm_bindgen]
pub fn box_keypair() -> Vec<u8> {
    let kp = zalos_vault::box_keypair();
    // public || private, 32 bytes each
    let mut out = kp.public.clone();
    out.extend_from_slice(&kp.private);
    out
}

#[wasm_bindgen]
pub fn seal(public_key: &[u8], aad: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, JsError> {
    zalos_vault::seal(public_key, aad, plaintext).map_err(to_err)
}

#[wasm_bindgen]
pub fn open_with_root(
    root: &[u8],
    slot: &str,
    aad: &[u8],
    sealed: &[u8],
) -> Result<Vec<u8>, JsError> {
    zalos_vault::open_with_root(root, slot, aad, sealed).map_err(to_err)
}

#[wasm_bindgen]
pub fn open_with_private(
    private_key: &[u8],
    aad: &[u8],
    sealed: &[u8],
) -> Result<Vec<u8>, JsError> {
    zalos_vault::open_with_private(private_key, aad, sealed).map_err(to_err)
}

#[wasm_bindgen]
pub struct FileSealer {
    inner: zalos_vault::FileSealer,
    header: Vec<u8>,
}

#[wasm_bindgen]
impl FileSealer {
    #[wasm_bindgen(constructor)]
    pub fn new(public_key: &[u8], aad: &[u8]) -> Result<FileSealer, JsError> {
        let (inner, header) =
            zalos_vault::FileSealer::new(public_key, aad).map_err(to_err)?;
        Ok(FileSealer { inner, header })
    }

    /// The file header: the HPKE encapped key (32 bytes). Stored with the
    /// file so a FileOpener can open the chunks later.
    #[wasm_bindgen(getter)]
    pub fn header(&self) -> Vec<u8> {
        self.header.clone()
    }

    pub fn seal_chunk(&mut self, chunk: &[u8]) -> Result<Vec<u8>, JsError> {
        self.inner.seal_chunk(chunk).map_err(to_err)
    }
}

#[wasm_bindgen]
pub struct FileOpener {
    inner: zalos_vault::FileOpener,
}

#[wasm_bindgen]
impl FileOpener {
    pub fn open_chunk(&mut self, chunk: &[u8]) -> Result<Vec<u8>, JsError> {
        self.inner.open_chunk(chunk).map_err(to_err)
    }
}

#[wasm_bindgen]
pub fn file_opener_with_root(
    root: &[u8],
    slot: &str,
    aad: &[u8],
    header: &[u8],
) -> Result<FileOpener, JsError> {
    let inner = zalos_vault::FileOpener::with_root(root, slot, aad, header).map_err(to_err)?;
    Ok(FileOpener { inner })
}

#[wasm_bindgen]
pub fn file_opener_with_private(
    private_key: &[u8],
    aad: &[u8],
    header: &[u8],
) -> Result<FileOpener, JsError> {
    let inner =
        zalos_vault::FileOpener::with_private(private_key, aad, header).map_err(to_err)?;
    Ok(FileOpener { inner })
}

#[wasm_bindgen]
pub fn fingerprint(public_key: &[u8]) -> String {
    zalos_vault::fingerprint(public_key)
}

#[wasm_bindgen]
pub fn sha256_hex(data: &[u8]) -> String {
    zalos_vault::sha256_hex(data)
}
