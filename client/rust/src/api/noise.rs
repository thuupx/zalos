pub struct Keypair {
    pub public: Vec<u8>,
    pub private: Vec<u8>,
}

pub fn generate_keypair() -> Result<Keypair, String> {
    zalos_noise::generate_keypair()
        .map(|kp| Keypair {
            public: kp.public,
            private: kp.private,
        })
        .map_err(|e| e.to_string())
}

#[flutter_rust_bridge::frb(opaque)]
pub struct Session {
    inner: zalos_noise::Session,
}

impl Session {
    pub fn initiator(
        prologue: &[u8],
        local_private: &[u8],
        remote_public: &[u8],
        psk: &[u8],
    ) -> Result<Session, String> {
        zalos_noise::Session::initiator(prologue, local_private, remote_public, psk)
            .map(|inner| Session { inner })
            .map_err(|e| e.to_string())
    }

    pub fn responder(prologue: &[u8], local_private: &[u8]) -> Result<Session, String> {
        zalos_noise::Session::responder(prologue, local_private)
            .map(|inner| Session { inner })
            .map_err(|e| e.to_string())
    }

    pub fn write_handshake(&mut self, payload: &[u8]) -> Result<Vec<u8>, String> {
        self.inner.write_handshake(payload).map_err(|e| e.to_string())
    }

    pub fn read_handshake(&mut self, message: &[u8]) -> Result<Vec<u8>, String> {
        self.inner.read_handshake(message).map_err(|e| e.to_string())
    }

    pub fn remote_static(&self) -> Option<Vec<u8>> {
        self.inner.remote_static()
    }

    pub fn set_psk(&mut self, psk: &[u8]) -> Result<(), String> {
        self.inner.set_psk(psk).map_err(|e| e.to_string())
    }

    pub fn is_handshake_finished(&self) -> bool {
        self.inner.is_handshake_finished()
    }

    pub fn handshake_hash(&self) -> Vec<u8> {
        self.inner.handshake_hash()
    }

    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>, String> {
        self.inner.encrypt(plaintext).map_err(|e| e.to_string())
    }

    pub fn decrypt(&mut self, ciphertext: &[u8]) -> Result<Vec<u8>, String> {
        self.inner.decrypt(ciphertext).map_err(|e| e.to_string())
    }
}
