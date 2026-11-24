/* tslint:disable */
/* eslint-disable */
export const memory: WebAssembly.Memory;
export const __wbg_keypair_free: (a: number, b: number) => void;
export const __wbg_session_free: (a: number, b: number) => void;
export const generate_keypair: () => [number, number, number];
export const keypair_private: (a: number) => [number, number];
export const keypair_public: (a: number) => [number, number];
export const session_decrypt: (a: number, b: number, c: number) => [number, number, number, number];
export const session_encrypt: (a: number, b: number, c: number) => [number, number, number, number];
export const session_handshake_hash: (a: number) => [number, number];
export const session_initiator: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: number) => [number, number, number];
export const session_is_handshake_finished: (a: number) => number;
export const session_read_handshake: (a: number, b: number, c: number) => [number, number, number, number];
export const session_remote_static: (a: number) => [number, number];
export const session_responder: (a: number, b: number, c: number, d: number) => [number, number, number];
export const session_set_psk: (a: number, b: number, c: number) => [number, number];
export const session_write_handshake: (a: number, b: number, c: number) => [number, number, number, number];
export const __wbindgen_exn_store: (a: number) => void;
export const __externref_table_alloc: () => number;
export const __wbindgen_externrefs: WebAssembly.Table;
export const __externref_table_dealloc: (a: number) => void;
export const __wbindgen_free: (a: number, b: number, c: number) => void;
export const __wbindgen_malloc: (a: number, b: number) => number;
export const __wbindgen_start: () => void;
