//! Thin wrapper over the `snow` Noise implementation.
//!
//! zalos uses `Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s` on every channel. The
//! client is always the initiator and knows the server static key and a
//! per-device psk up front. The server (responder) does not know the psk until
//! it reads handshake message 1 and learns the initiator static key, so the psk
//! is bound late via [`Session::set_psk`].

use snow::TransportState;
use zeroize::Zeroize;

pub const SUITE: &str = "Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s";

/// Noise messages are at most 65535 bytes on the wire; add margin for tags.
const MAX_MESSAGE: usize = 65535 + 64;

#[derive(Debug)]
pub enum NoiseError {
    Snow(snow::Error),
    NotReady(&'static str),
}

impl std::fmt::Display for NoiseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            NoiseError::Snow(e) => write!(f, "{e}"),
            NoiseError::NotReady(m) => write!(f, "{m}"),
        }
    }
}

impl std::error::Error for NoiseError {}

impl From<snow::Error> for NoiseError {
    fn from(e: snow::Error) -> Self {
        NoiseError::Snow(e)
    }
}

#[derive(Debug, Clone)]
pub struct Keypair {
    pub public: Vec<u8>,
    pub private: Vec<u8>,
}

impl Drop for Keypair {
    fn drop(&mut self) {
        self.private.zeroize();
    }
}

pub fn generate_keypair() -> Result<Keypair, NoiseError> {
    let kp = snow::Builder::new(SUITE.parse()?).generate_keypair()?;
    Ok(Keypair {
        public: kp.public,
        private: kp.private,
    })
}

enum State {
    Handshake(snow::HandshakeState),
    Transport(Box<TransportState>),
    Finished,
}

pub struct Session {
    state: State,
    handshake_hash: Vec<u8>,
}

impl Drop for Session {
    fn drop(&mut self) {
        self.handshake_hash.zeroize();
    }
}

impl Session {
    /// Initiator side of IKpsk2: knows the remote static key and the psk.
    pub fn initiator(
        prologue: &[u8],
        local_private: &[u8],
        remote_public: &[u8],
        psk: &[u8],
    ) -> Result<Session, NoiseError> {
        let psk: &[u8; 32] = psk
            .try_into()
            .map_err(|_| NoiseError::NotReady("psk must be 32 bytes"))?;
        let hs = snow::Builder::new(SUITE.parse()?)
            .prologue(prologue)?
            .local_private_key(local_private)?
            .remote_public_key(remote_public)?
            .psk(2, psk)?
            .build_initiator()?;
        Ok(Session {
            state: State::Handshake(hs),
            handshake_hash: Vec::new(),
        })
    }

    /// Responder side of IKpsk2: the psk is not known yet. After reading
    /// handshake message 1, call [`Session::remote_static`] to learn the
    /// initiator static key, then [`Session::set_psk`] before writing message 2.
    pub fn responder(prologue: &[u8], local_private: &[u8]) -> Result<Session, NoiseError> {
        let hs = snow::Builder::new(SUITE.parse()?)
            .prologue(prologue)?
            .local_private_key(local_private)?
            .build_responder()?;
        Ok(Session {
            state: State::Handshake(hs),
            handshake_hash: Vec::new(),
        })
    }

    fn handshake_mut(&mut self) -> Result<&mut snow::HandshakeState, NoiseError> {
        match &mut self.state {
            State::Handshake(hs) => Ok(hs),
            _ => Err(NoiseError::NotReady("handshake already finished")),
        }
    }


    fn transport_mut(&mut self) -> Result<&mut TransportState, NoiseError> {
        match &mut self.state {
            State::Transport(t) => Ok(t),
            _ => Err(NoiseError::NotReady("handshake not finished")),
        }
    }

    fn finish_if_done(&mut self) -> Result<(), NoiseError> {
        let done = matches!(&self.state, State::Handshake(hs) if hs.is_handshake_finished());
        if done {
            if let State::Handshake(hs) = &self.state {
                self.handshake_hash = hs.get_handshake_hash().to_vec();
            }
            if let State::Handshake(hs) =
                std::mem::replace(&mut self.state, State::Finished)
            {
                self.state = State::Transport(Box::new(hs.into_transport_mode()?));
            }
        }
        Ok(())
    }

    /// Write the next handshake message (payload may be empty).
    pub fn write_handshake(&mut self, payload: &[u8]) -> Result<Vec<u8>, NoiseError> {
        let mut buf = vec![0u8; MAX_MESSAGE];
        let n = self.handshake_mut()?.write_message(payload, &mut buf)?;
        buf.truncate(n);
        self.finish_if_done()?;
        Ok(buf)
    }

    /// Read a handshake message, returns the decrypted payload.
    pub fn read_handshake(&mut self, message: &[u8]) -> Result<Vec<u8>, NoiseError> {
        let mut buf = vec![0u8; MAX_MESSAGE];
        let n = self.handshake_mut()?.read_message(message, &mut buf)?;
        buf.truncate(n);
        self.finish_if_done()?;
        Ok(buf)
    }

    /// Remote party's static public key, once revealed by the handshake.
    pub fn remote_static(&self) -> Option<Vec<u8>> {
        match &self.state {
            State::Handshake(hs) => hs.get_remote_static().map(|s| s.to_vec()),
            State::Transport(t) => t.get_remote_static().map(|s| s.to_vec()),
            State::Finished => None,
        }
    }

    /// Bind the psk late, on a responder that was built without one.
    /// Must be called after reading message 1 and before writing message 2.
    pub fn set_psk(&mut self, psk: &[u8]) -> Result<(), NoiseError> {
        self.handshake_mut()?.set_psk(2, psk)?;
        Ok(())
    }

    pub fn is_handshake_finished(&self) -> bool {
        matches!(self.state, State::Transport(_))
    }

    pub fn handshake_hash(&self) -> Vec<u8> {
        match &self.state {
            State::Handshake(hs) => hs.get_handshake_hash().to_vec(),
            _ => self.handshake_hash.clone(),
        }
    }

    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>, NoiseError> {
        let mut buf = vec![0u8; MAX_MESSAGE];
        let n = self.transport_mut()?.write_message(plaintext, &mut buf)?;
        buf.truncate(n);
        Ok(buf)
    }

    pub fn decrypt(&mut self, ciphertext: &[u8]) -> Result<Vec<u8>, NoiseError> {
        let mut buf = vec![0u8; MAX_MESSAGE];
        let n = self.transport_mut()?.read_message(ciphertext, &mut buf)?;
        buf.truncate(n);
        Ok(buf)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PROLOGUE: &[u8] = b"zalos/1/control";

    struct Pair {
        init: Session,
        resp: Session,
        server_kp: Keypair,
        device_kp: Keypair,
    }

    fn handshaken(psk: &[u8]) -> Pair {
        let server_kp = generate_keypair().unwrap();
        let device_kp = generate_keypair().unwrap();
        let mut init =
            Session::initiator(PROLOGUE, &device_kp.private, &server_kp.public, psk).unwrap();
        let mut resp = Session::responder(PROLOGUE, &server_kp.private).unwrap();

        let m1 = init.write_handshake(&[]).unwrap();
        resp.read_handshake(&m1).unwrap();
        resp.set_psk(psk).unwrap();
        let m2 = resp.write_handshake(&[]).unwrap();
        init.read_handshake(&m2).unwrap();

        Pair {
            init,
            resp,
            server_kp,
            device_kp,
        }
    }

    fn psk() -> Vec<u8> {
        vec![0x42; 32]
    }

    #[test]
    fn full_handshake_and_transport_round_trip() {
        let mut p = handshaken(&psk());
        assert!(p.init.is_handshake_finished());
        assert!(p.resp.is_handshake_finished());
        assert_eq!(p.init.handshake_hash(), p.resp.handshake_hash());

        let c = p.init.encrypt(b"hello server").unwrap();
        assert_eq!(p.resp.decrypt(&c).unwrap(), b"hello server");
        let c = p.resp.encrypt(b"hello client").unwrap();
        assert_eq!(p.init.decrypt(&c).unwrap(), b"hello client");
    }

    #[test]
    fn responder_learns_remote_static_after_message_1() {
        let server_kp = generate_keypair().unwrap();
        let device_kp = generate_keypair().unwrap();
        let mut init =
            Session::initiator(PROLOGUE, &device_kp.private, &server_kp.public, &psk()).unwrap();
        let mut resp = Session::responder(PROLOGUE, &server_kp.private).unwrap();
        assert!(resp.remote_static().is_none());
        let m1 = init.write_handshake(&[]).unwrap();
        resp.read_handshake(&m1).unwrap();
        assert_eq!(resp.remote_static().unwrap(), device_kp.public);
    }

    #[test]
    fn wrong_psk_fails() {
        let server_kp = generate_keypair().unwrap();
        let device_kp = generate_keypair().unwrap();
        let mut init =
            Session::initiator(PROLOGUE, &device_kp.private, &server_kp.public, &psk()).unwrap();
        let mut resp = Session::responder(PROLOGUE, &server_kp.private).unwrap();
        let m1 = init.write_handshake(&[]).unwrap();
        resp.read_handshake(&m1).unwrap();
        resp.set_psk(&vec![0x13; 32]).unwrap();
        let m2 = resp.write_handshake(&[]).unwrap();
        assert!(init.read_handshake(&m2).is_err());
    }

    #[test]
    fn mismatched_prologue_fails() {
        let server_kp = generate_keypair().unwrap();
        let device_kp = generate_keypair().unwrap();
        let mut init =
            Session::initiator(PROLOGUE, &device_kp.private, &server_kp.public, &psk()).unwrap();
        let mut resp =
            Session::responder(b"zalos/1/account/9", &server_kp.private).unwrap();
        let m1 = init.write_handshake(&[]).unwrap();
        assert!(resp.read_handshake(&m1).is_err());
    }

    #[test]
    fn wrong_server_static_fails() {
        let server_kp = generate_keypair().unwrap();
        let attacker_kp = generate_keypair().unwrap();
        let device_kp = generate_keypair().unwrap();
        // Initiator is pinned to the real server key; an impostor holds a
        // different private key, so the handshake cannot complete.
        let mut init = Session::initiator(
            PROLOGUE,
            &device_kp.private,
            &server_kp.public,
            &psk(),
        )
        .unwrap();
        let mut resp = Session::responder(PROLOGUE, &attacker_kp.private).unwrap();
        let m1 = init.write_handshake(&[]).unwrap();
        assert!(resp.read_handshake(&m1).is_err());
    }

    #[test]
    fn tampered_ciphertext_fails() {
        let mut p = handshaken(&psk());
        let mut c = p.init.encrypt(b"secret").unwrap();
        let last = c.len() - 1;
        c[last] ^= 1;
        assert!(p.resp.decrypt(&c).is_err());
    }

    #[test]
    fn unknown_psk_never_set_fails() {
        // Responder that never calls set_psk must not be able to produce a
        // valid message 2 for a psk-protected initiator.
        let server_kp = generate_keypair().unwrap();
        let device_kp = generate_keypair().unwrap();
        let mut init =
            Session::initiator(PROLOGUE, &device_kp.private, &server_kp.public, &psk()).unwrap();
        let mut resp = Session::responder(PROLOGUE, &server_kp.private).unwrap();
        let m1 = init.write_handshake(&[]).unwrap();
        resp.read_handshake(&m1).unwrap();
        if let Ok(m2) = resp.write_handshake(&[]) {
            assert!(init.read_handshake(&m2).is_err());
        }
    }
}
