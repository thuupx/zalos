use wasm_bindgen::prelude::*;

fn js_err(e: zalos_noise::NoiseError) -> JsValue {
    JsValue::from_str(&e.to_string())
}

#[wasm_bindgen]
pub struct Keypair {
    inner: zalos_noise::Keypair,
}

#[wasm_bindgen]
impl Keypair {
    #[wasm_bindgen(getter)]
    pub fn public(&self) -> Vec<u8> {
        self.inner.public.clone()
    }

    #[wasm_bindgen(getter)]
    pub fn private(&self) -> Vec<u8> {
        self.inner.private.clone()
    }
}

#[wasm_bindgen]
pub fn generate_keypair() -> Result<Keypair, JsValue> {
    zalos_noise::generate_keypair()
        .map(|inner| Keypair { inner })
        .map_err(js_err)
}

#[wasm_bindgen]
pub struct Session {
    inner: zalos_noise::Session,
}

#[wasm_bindgen]
impl Session {
    pub fn initiator(
        prologue: &[u8],
        local_private: &[u8],
        remote_public: &[u8],
        psk: &[u8],
    ) -> Result<Session, JsValue> {
        zalos_noise::Session::initiator(prologue, local_private, remote_public, psk)
            .map(|inner| Session { inner })
            .map_err(js_err)
    }

    pub fn responder(prologue: &[u8], local_private: &[u8]) -> Result<Session, JsValue> {
        zalos_noise::Session::responder(prologue, local_private)
            .map(|inner| Session { inner })
            .map_err(js_err)
    }

    pub fn write_handshake(&mut self, payload: &[u8]) -> Result<Vec<u8>, JsValue> {
        self.inner.write_handshake(payload).map_err(js_err)
    }

    pub fn read_handshake(&mut self, message: &[u8]) -> Result<Vec<u8>, JsValue> {
        self.inner.read_handshake(message).map_err(js_err)
    }

    pub fn remote_static(&self) -> Option<Vec<u8>> {
        self.inner.remote_static()
    }

    pub fn set_psk(&mut self, psk: &[u8]) -> Result<(), JsValue> {
        self.inner.set_psk(psk).map_err(js_err)
    }

    pub fn is_handshake_finished(&self) -> bool {
        self.inner.is_handshake_finished()
    }

    pub fn handshake_hash(&self) -> Vec<u8> {
        self.inner.handshake_hash()
    }

    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>, JsValue> {
        self.inner.encrypt(plaintext).map_err(js_err)
    }

    pub fn decrypt(&mut self, ciphertext: &[u8]) -> Result<Vec<u8>, JsValue> {
        self.inner.decrypt(ciphertext).map_err(js_err)
    }
}
