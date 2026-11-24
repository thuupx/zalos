import { test, expect } from "bun:test";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const vault = require("../vendor/zalos-vault/zalos_vault.js") as {
  generate_root(): Uint8Array;
  derive_public_key(root: Uint8Array, slot: string): Uint8Array;
  box_keypair(): Uint8Array;
  seal(pk: Uint8Array, aad: Uint8Array, pt: Uint8Array): Uint8Array;
  open_with_root(root: Uint8Array, slot: string, aad: Uint8Array, sealed: Uint8Array): Uint8Array;
  open_with_private(sk: Uint8Array, aad: Uint8Array, sealed: Uint8Array): Uint8Array;
  FileSealer: new (pk: Uint8Array, aad: Uint8Array) => {
    header: Uint8Array;
    seal_chunk(c: Uint8Array): Uint8Array;
  };
  file_opener_with_root(root: Uint8Array, slot: string, aad: Uint8Array, header: Uint8Array): {
    open_chunk(c: Uint8Array): Uint8Array;
  };
  file_opener_with_private(sk: Uint8Array, aad: Uint8Array, header: Uint8Array): {
    open_chunk(c: Uint8Array): Uint8Array;
  };
  fingerprint(pk: Uint8Array): string;
};

const SLOT = "slot-1";

test("record round trip via root and box key", () => {
  const root = vault.generate_root();
  const pk = vault.derive_public_key(root, SLOT);
  const pt = new TextEncoder().encode("hello vault");
  const sealed = vault.seal(pk, new TextEncoder().encode("aad"), pt);
  // encapped key 32 bytes + ciphertext
  expect(sealed.length).toBe(32 + pt.length + 16);
  const opened = vault.open_with_root(root, SLOT, new TextEncoder().encode("aad"), sealed);
  expect(opened).toEqual(pt);

  const box = vault.box_keypair();
  const wrapped = vault.seal(box.subarray(0, 32), new TextEncoder().encode("box"), root);
  const unwrapped = vault.open_with_private(
    box.subarray(32),
    new TextEncoder().encode("box"),
    wrapped,
  );
  expect(unwrapped).toEqual(root);
});

test("tamper and wrong key fail", () => {
  const root = vault.generate_root();
  const pk = vault.derive_public_key(root, SLOT);
  const sealed = vault.seal(pk, new Uint8Array(0), new Uint8Array([1, 2, 3]));
  const bad = sealed.slice();
  bad[bad.length - 1] ^= 1;
  expect(() =>
    vault.open_with_root(root, SLOT, new Uint8Array(0), bad),
  ).toThrow();
  expect(() =>
    vault.open_with_root(vault.generate_root(), SLOT, new Uint8Array(0), sealed),
  ).toThrow();
  expect(() =>
    vault.open_with_root(root, "other", new Uint8Array(0), sealed),
  ).toThrow();
});

test("5 MiB file in 1 MiB chunks, order enforced", () => {
  const root = vault.generate_root();
  const pk = vault.derive_public_key(root, SLOT);
  const aad = new TextEncoder().encode("file-1");
  const sealer = new vault.FileSealer(pk, aad);
  expect(sealer.header.length).toBe(32);

  const chunks: Uint8Array[] = [];
  const sealed: Uint8Array[] = [];
  for (let i = 0; i < 5; i++) {
    const c = new Uint8Array(1024 * 1024).fill(i);
    chunks.push(c);
    sealed.push(sealer.seal_chunk(c));
  }
  const opener = vault.file_opener_with_root(root, SLOT, aad, sealer.header);
  for (let i = 0; i < 5; i++) {
    expect(opener.open_chunk(sealed[i])).toEqual(chunks[i]);
  }
  // reorder fails
  const op2 = vault.file_opener_with_root(root, SLOT, aad, sealer.header);
  expect(() => op2.open_chunk(sealed[1])).toThrow();
  // duplicate fails
  const op3 = vault.file_opener_with_root(root, SLOT, aad, sealer.header);
  op3.open_chunk(sealed[0]);
  expect(() => op3.open_chunk(sealed[0])).toThrow();
});

test("fingerprint is 8 groups of 4 hex", () => {
  const fp = vault.fingerprint(vault.box_keypair().subarray(0, 32));
  expect(fp).toMatch(/^([0-9a-f]{4} ){7}[0-9a-f]{4}$/);
});
