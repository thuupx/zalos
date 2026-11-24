// Server-side use of the vault wasm: the server only ever SEALS. It never
// holds a root or a private key.
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const wasm = require("../vendor/zalos-vault/zalos_vault.js") as {
  seal(pk: Uint8Array, aad: Uint8Array, pt: Uint8Array): Uint8Array;
  FileSealer: new (
    pk: Uint8Array,
    aad: Uint8Array,
  ) => { header: Uint8Array; seal_chunk(c: Uint8Array): Uint8Array };
  fingerprint(pk: Uint8Array): string;
  sha256_hex(data: Uint8Array): string;
};

export function fingerprint(publicKey: Uint8Array): string {
  return wasm.fingerprint(publicKey);
}

const enc = new TextEncoder();

export function msgAad(slot: string, msgId: string): Uint8Array {
  return enc.encode(`zalos/1/msg/${slot}/${msgId}`);
}

export function sealRecord(
  publicKey: Uint8Array,
  aad: Uint8Array,
  plaintextJson: string,
): string {
  return Buffer.from(
    wasm.seal(publicKey, aad, enc.encode(plaintextJson)),
  ).toString("base64");
}

export function mediaAad(
  slot: string,
  urlHash: string,
  size: number,
): Uint8Array {
  return enc.encode(`zalos/1/media/${slot}/${urlHash}/${size}`);
}

export class FileSealer {
  private inner: { seal_chunk(c: Uint8Array): Uint8Array };
  readonly header: Uint8Array;
  constructor(publicKey: Uint8Array, aad: Uint8Array) {
    const s = new wasm.FileSealer(publicKey, aad);
    this.inner = s;
    this.header = new Uint8Array(s.header);
  }
  sealChunk(chunk: Uint8Array): Uint8Array {
    return new Uint8Array(this.inner.seal_chunk(chunk));
  }
}

export function sha256Hex(data: Uint8Array | string): string {
  const bytes = typeof data === "string" ? enc.encode(data) : data;
  return wasm.sha256_hex(bytes);
}
