// Mirrors zca-js dist/utils.js cryptography exactly:
// - encodeAES/decodeAES: AES-128-CBC, iv=0, Pkcs7, key is the base64
//   session secret (zpw_enk). Implemented with node:crypto so the mock
//   needs no crypto-js.
// - loginKey: ParamsEncryptor key derivation for the unauthenticated
//   getLoginInfo exchange, from the request's zcid/zcid_ext.
import { createCipheriv, createDecipheriv, createHash } from "node:crypto";

const IV = Buffer.alloc(16, 0);

function aesEncrypt(keyBytes: Uint8Array, data: string): Buffer {
  // crypto-js picks the AES width from the key length: 16-byte session
  // key (zpw_enk, base64) -> AES-128; 32-char login encryptKey (utf8) ->
  // AES-256.
  const algo =
    keyBytes.length === 16 ? "aes-128-cbc" : "aes-256-cbc";
  const c = createCipheriv(algo, Buffer.from(keyBytes), IV);
  return Buffer.concat([c.update(data, "utf8"), c.final()]);
}

export function aesEncryptToBase64(keyBytes: Uint8Array, data: string): string {
  return aesEncrypt(keyBytes, data).toString("base64");
}

function aesDecrypt(keyBytes: Uint8Array, dataB64: string): Buffer {
  const algo =
    keyBytes.length === 16 ? "aes-128-cbc" : "aes-256-cbc";
  const d = createDecipheriv(algo, Buffer.from(keyBytes), IV);
  return Buffer.concat([d.update(dataB64, "base64"), d.final()]);
}

// Session encryption: utils.encodeAES(secretKey, data) where the key is a
// base64 string parsed with cryptojs.enc.Base64.
export function sessionEncrypt(secretKeyB64: string, data: string): string {
  return aesEncryptToBase64(Buffer.from(secretKeyB64, "base64"), data);
}
export function sessionDecrypt(secretKeyB64: string, data: string): string {
  return aesDecrypt(
    Buffer.from(secretKeyB64, "base64"),
    decodeURIComponent(data),
  ).toString("utf8");
}

function splitEvenOdd(s: string): { even: string[]; odd: string[] } {
  const even: string[] = [];
  const odd: string[] = [];
  for (let i = 0; i < s.length; i++) (i % 2 === 0 ? even : odd).push(s[i]);
  return { even, odd };
}

// ParamsEncryptor.createEncryptKey: even(MD5(zcid_ext))[0:8] +
// even(zcid)[0:12] + reversed odd(zcid)[0:12]. The result is used as a
// UTF-8 AES key and the params are encrypted with the hex/uppercase=false
// variant (base64 output).
export function loginEncryptKey(zcid: string, zcidExt: string): string {
  const md5 = createHash("md5").update(zcidExt).digest("hex").toUpperCase();
  const e = splitEvenOdd(md5);
  const z = splitEvenOdd(zcid);
  return e.even.slice(0, 8).join("") + z.even.slice(0, 12).join("") + z.odd.reverse().slice(0, 12).join("");
}

// ParamsEncryptor.encodeAES: key is parsed as Utf8 text.
export function loginEncrypt(encryptKey: string, data: string): string {
  return aesEncryptToBase64(Buffer.from(encryptKey, "utf8"), data);
}
export function loginDecrypt(encryptKey: string, data: string): string {
  return aesDecrypt(
    Buffer.from(encryptKey, "utf8"),
    decodeURIComponent(data),
  ).toString("utf8");
}
