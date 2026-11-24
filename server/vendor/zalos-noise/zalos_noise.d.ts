/* tslint:disable */
/* eslint-disable */

export class Keypair {
    private constructor();
    free(): void;
    [Symbol.dispose](): void;
    readonly private: Uint8Array;
    readonly public: Uint8Array;
}

export class Session {
    private constructor();
    free(): void;
    [Symbol.dispose](): void;
    decrypt(ciphertext: Uint8Array): Uint8Array;
    encrypt(plaintext: Uint8Array): Uint8Array;
    handshake_hash(): Uint8Array;
    static initiator(prologue: Uint8Array, local_private: Uint8Array, remote_public: Uint8Array, psk: Uint8Array): Session;
    is_handshake_finished(): boolean;
    read_handshake(message: Uint8Array): Uint8Array;
    remote_static(): Uint8Array | undefined;
    static responder(prologue: Uint8Array, local_private: Uint8Array): Session;
    set_psk(psk: Uint8Array): void;
    write_handshake(payload: Uint8Array): Uint8Array;
}

export function generate_keypair(): Keypair;
