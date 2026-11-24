/* tslint:disable */
/* eslint-disable */

export class FileOpener {
    private constructor();
    free(): void;
    [Symbol.dispose](): void;
    open_chunk(chunk: Uint8Array): Uint8Array;
}

export class FileSealer {
    free(): void;
    [Symbol.dispose](): void;
    constructor(public_key: Uint8Array, aad: Uint8Array);
    seal_chunk(chunk: Uint8Array): Uint8Array;
    /**
     * The file header: the HPKE encapped key (32 bytes). Stored with the
     * file so a FileOpener can open the chunks later.
     */
    readonly header: Uint8Array;
}

export function box_keypair(): Uint8Array;

export function derive_public_key(root: Uint8Array, slot: string): Uint8Array;

export function file_opener_with_private(private_key: Uint8Array, aad: Uint8Array, header: Uint8Array): FileOpener;

export function file_opener_with_root(root: Uint8Array, slot: string, aad: Uint8Array, header: Uint8Array): FileOpener;

export function fingerprint(public_key: Uint8Array): string;

export function generate_root(): Uint8Array;

export function open_with_private(private_key: Uint8Array, aad: Uint8Array, sealed: Uint8Array): Uint8Array;

export function open_with_root(root: Uint8Array, slot: string, aad: Uint8Array, sealed: Uint8Array): Uint8Array;

export function seal(public_key: Uint8Array, aad: Uint8Array, plaintext: Uint8Array): Uint8Array;

export function sha256_hex(data: Uint8Array): string;
