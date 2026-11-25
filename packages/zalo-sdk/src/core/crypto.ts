import {
  createCipheriv,
  createDecipheriv,
  createHash,
  randomUUID,
} from "node:crypto";
import {
  deflateSync,
  gunzipSync,
  inflateRawSync,
  inflateSync,
} from "node:zlib";
import JSONBigFactory from "json-bigint";

import {
  PARAM_CIPHER_KEY,
  PASSWORD_CIPHER_KEY,
  ZCALL_V2_IPC_AES_KEY_B64,
} from "./constants.ts";
import { ZaloCryptoError } from "./errors.ts";

const JSONBig = JSONBigFactory({ storeAsString: true });
const ZERO_IV_16 = Buffer.alloc(16, 0);

export function parseJsonSafe<T = unknown>(text: string): T {
  return JSONBig.parse(text) as T;
}

export function stringifyJsonSafe(value: unknown): string {
  return JSONBig.stringify(value);
}

export function md5Hex(data: string | Uint8Array): string {
  return createHash("md5").update(data).digest("hex");
}

export function generateImei(userAgent: string): string {
  return `${randomUUID()}-${md5Hex(userAgent)}`;
}

export function decodeAesKey(secretKeyB64: string, utf8Literal = false): Buffer {
  const key = utf8Literal
    ? Buffer.from(secretKeyB64, "utf8")
    : Buffer.from(secretKeyB64, "base64");
  if (key.length !== 16 && key.length !== 24 && key.length !== 32) {
    throw new ZaloCryptoError(
      `Invalid AES key length: expected 16/24/32 bytes, got ${key.length}`,
    );
  }
  return key;
}

function aesAlgorithmForKey(key: Buffer): "aes-128-cbc" | "aes-192-cbc" | "aes-256-cbc" {
  if (key.length === 16) return "aes-128-cbc";
  if (key.length === 24) return "aes-192-cbc";
  return "aes-256-cbc";
}

/**
 * Encrypts plaintext with AES-CBC (128/192/256 depending on key length),
 * 16-byte all-zero IV, and PKCS#7 padding.
 */
export function encodeAES(
  secretKey: string,
  message: string,
  outputFormat: "base64" | "hex" = "base64",
  utf8Key = false,
): string {
  try {
    const key = decodeAesKey(secretKey, utf8Key);
    const cipher = createCipheriv(aesAlgorithmForKey(key), key, ZERO_IV_16);
    cipher.setAutoPadding(true);
    const encrypted = Buffer.concat([
      cipher.update(message, "utf8"),
      cipher.final(),
    ]);
    return encrypted.toString(outputFormat);
  } catch (err) {
    if (err instanceof ZaloCryptoError) throw err;
    throw new ZaloCryptoError(
      `AES encryption failed: ${err instanceof Error ? err.message : String(err)}`,
      18060,
      err,
    );
  }
}

/**
 * Decrypts base64 or hex AES-CBC (zero IV, PKCS#7) ciphertext back to UTF-8.
 */
export function decodeAES(
  secretKey: string,
  ciphertext: string,
  inputFormat: "base64" | "hex" = "base64",
  utf8Key = false,
): string {
  try {
    const normalized =
      inputFormat === "base64" ? tryDecodeURIComponent(ciphertext) : ciphertext;
    const key = decodeAesKey(secretKey, utf8Key);
    const decipher = createDecipheriv(aesAlgorithmForKey(key), key, ZERO_IV_16);
    decipher.setAutoPadding(true);
    const decrypted = Buffer.concat([
      decipher.update(Buffer.from(normalized, inputFormat)),
      decipher.final(),
    ]);
    return decrypted.toString("utf8");
  } catch (err) {
    if (err instanceof ZaloCryptoError) throw err;
    throw new ZaloCryptoError(
      `AES decryption failed: ${err instanceof Error ? err.message : String(err)}`,
      18060,
      err,
    );
  }
}

function tryDecodeURIComponent(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function extractEvenOddChars(input: string): { even: string; odd: string } {
  let even = "";
  let odd = "";
  for (let i = 0; i < input.length; i++) {
    if (i % 2 === 0) even += input[i]!;
    else odd += input[i]!;
  }
  return { even, odd };
}

/**
 * Pre-session login parameter encryption (`enc_ver = "v2"`).
 */
export class ParamsEncryptor {
  readonly zcid: string;
  readonly zcidExt: string;
  readonly encVer = "v2";
  readonly enk: string;

  constructor(type: number, imei: string, firstLaunchTime: number = Date.now(), zcidExt?: string) {
    const zcidPlain = `${type},${imei},${firstLaunchTime}`;
    this.zcid = encodeAES(PARAM_CIPHER_KEY, zcidPlain, "hex", true).toUpperCase();
    this.zcidExt = zcidExt ?? ParamsEncryptor.randomString();
    this.enk = ParamsEncryptor.deriveKey(this.zcid, this.zcidExt);
  }

  static randomString(minLen = 6, maxLen = 12): string {
    const span = maxLen - minLen + 1;
    const len = minLen + Math.floor(Math.random() * span);
    let out = "";
    while (out.length < len) {
      out += Math.random().toString(16).slice(2);
    }
    return out.slice(0, len);
  }

  static deriveKey(zcid: string, zcidExt: string): string {
    const md5Ext = md5Hex(zcidExt).toUpperCase();
    const { even: evenExt } = extractEvenOddChars(md5Ext);
    const { even: evenZcid, odd: oddZcid } = extractEvenOddChars(zcid);
    const reversedOddZcid = [...oddZcid].reverse().join("");
    const enk = evenExt.slice(0, 8) + evenZcid.slice(0, 12) + reversedOddZcid.slice(0, 12);
    if (enk.length !== 32) {
      throw new ZaloCryptoError(`Derived ParamsEncryptor key has invalid length ${enk.length}`);
    }
    return enk;
  }

  getParams(): { zcid: string; zcid_ext: string; enc_ver: string } {
    return {
      zcid: this.zcid,
      zcid_ext: this.zcidExt,
      enc_ver: this.encVer,
    };
  }

  encrypt(payload: unknown): string {
    const serialized = typeof payload === "string" ? payload : JSON.stringify(payload);
    return encodeAES(this.enk, serialized, "base64", true);
  }

  decrypt<T = unknown>(ciphertext: string): T {
    const text = decodeAES(this.enk, ciphertext, "base64", true);
    return parseJsonSafe<T>(text);
  }
}

/**
 * Computes MD5 signature over `"zsecure" + actionName + sorted_param_values`.
 */
export function computeSignKey(
  actionName: string,
  params: Record<string, string | number | boolean | undefined>,
): string {
  const sortedKeys = Object.keys(params)
    .filter((k) => params[k] !== undefined)
    .sort();
  let concat = `zsecure${actionName}`;
  for (const key of sortedKeys) {
    concat += String(params[key]);
  }
  return md5Hex(concat).toLowerCase();
}

/**
 * Encrypts a password for `/api/login/loginByPasswv2`.
 */
export function encryptPassword(
  phone: string,
  imei: string,
  password: string,
  salt: string = ParamsEncryptor.randomString(8, 12),
): { encryptedPassword: string; salt: string } {
  const hash = createHash("sha256")
    .update(`${PASSWORD_CIPHER_KEY}-${phone}-${imei}-${salt}`)
    .digest("hex")
    .toUpperCase();
  const { even, odd } = extractEvenOddChars(hash);
  const key = even.slice(0, 16) + [...odd].reverse().join("").slice(0, 16);
  const payload = salt + [...password].reverse().join("");
  return {
    salt,
    encryptedPassword: encodeAES(key, payload, "base64", true),
  };
}

export interface WsEnvelope {
  error_code?: number;
  error_message?: string;
  encrypt?: number;
  data?: unknown;
  key?: string;
}

/**
 * Decodes inbound WebSocket JSON envelopes across all 4 Zalo encrypt types:
 * - `0`: plaintext JSON string
 * - `1`: base64 -> zlib inflate
 * - `2`: URL-decode -> base64 -> AES-GCM (iv[0..16], aad[16..32], ct+tag[32..]) -> zlib inflate
 * - `3`: URL-decode -> base64 -> AES-GCM (raw UTF-8)
 */
function decompressWsPlaintext(plaintext: Buffer): Buffer {
  if (plaintext.length === 0) return plaintext;
  try {
    return inflateSync(plaintext);
  } catch {
    if (plaintext[0] === 0x1f && plaintext[1] === 0x8b) {
      return gunzipSync(plaintext);
    }
    try {
      return inflateRawSync(plaintext);
    } catch {
      const trimmed = plaintext.toString("utf8").trimStart();
      if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
        return plaintext;
      }
      throw new ZaloCryptoError(
        `Unable to inflate WS encrypt=2 payload (hdr=${plaintext.subarray(0, 4).toString("hex")})`,
      );
    }
  }
}

export function decodeWsPayload<T = unknown>(
  envelope: WsEnvelope,
  cipherKeyB64?: string,
): T {
  const encrypt = Number(envelope.encrypt ?? 0);
  if (envelope.data === undefined || envelope.data === null) {
    return {} as T;
  }
  if (typeof envelope.data !== "string") {
    return envelope.data as T;
  }

  const raw = envelope.data;
  if (encrypt === 0) {
    return parseJsonSafe<T>(raw);
  }

  if (encrypt === 1) {
    const rawBuf = Buffer.from(raw, "base64");
    const inflated = decompressWsPlaintext(rawBuf);
    return parseJsonSafe<T>(inflated.toString("utf8"));
  }

  if (encrypt === 2 || encrypt === 3) {
    if (!cipherKeyB64) {
      throw new ZaloCryptoError("Missing WebSocket cipherKey for encrypted frame");
    }
    const decoded = Buffer.from(tryDecodeURIComponent(raw), "base64");
    if (decoded.length < 48) {
      throw new ZaloCryptoError(
        `Encrypted WS payload too short: ${decoded.length} bytes (expected >= 48)`,
      );
    }
    const key = Buffer.from(cipherKeyB64, "base64");
    const iv = decoded.subarray(0, 16);
    const aad = decoded.subarray(16, 32);
    const tag = decoded.subarray(decoded.length - 16);
    const ciphertext = decoded.subarray(32, decoded.length - 16);

    const algo = key.length === 16 ? "aes-128-gcm" : "aes-256-gcm";
    const decipher = createDecipheriv(algo, key, iv);
    decipher.setAAD(aad);
    decipher.setAuthTag(tag);
    const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
    const finalBytes = encrypt === 2 ? decompressWsPlaintext(plaintext) : plaintext;
    return parseJsonSafe<T>(finalBytes.toString("utf8"));
  }

  throw new ZaloCryptoError(`Unsupported WebSocket encrypt type: ${encrypt}`);
}

/**
 * Encodes an outbound/test WebSocket payload using the same format as `decodeWsPayload`.
 */
export function encodeWsPayload(
  payload: unknown,
  encrypt: 0 | 1 | 2 | 3,
  cipherKeyB64?: string,
  iv: Buffer = Buffer.alloc(16, 1),
  aad: Buffer = Buffer.alloc(16, 2),
): string {
  const json = typeof payload === "string" ? payload : stringifyJsonSafe(payload);
  if (encrypt === 0) return json;
  const utf8 = Buffer.from(json, "utf8");
  if (encrypt === 1) {
    return deflateSync(utf8).toString("base64");
  }
  if (!cipherKeyB64) {
    throw new ZaloCryptoError("Missing cipherKey for WS AES-GCM encode");
  }
  const key = Buffer.from(cipherKeyB64, "base64");
  const algo = key.length === 16 ? "aes-128-gcm" : "aes-256-gcm";
  const cipher = createCipheriv(algo, key, iv);
  cipher.setAAD(aad);
  const input = encrypt === 2 ? deflateSync(utf8) : utf8;
  const ct = Buffer.concat([cipher.update(input), cipher.final()]);
  const tag = cipher.getAuthTag();
  return Buffer.concat([iv, aad, ct, tag]).toString("base64");
}

/**
 * Encrypts a JSON frame for the `zcall-v2` local UNIX socket / named pipe IPC bridge.
 */
export function encodeZCallIpc(payload: unknown): string {
  const json = typeof payload === "string" ? payload : JSON.stringify(payload);
  return encodeAES(ZCALL_V2_IPC_AES_KEY_B64, json, "hex").toLowerCase();
}

/**
 * Decrypts a hex frame received from the `ZaloCall` native helper over `zcall-v2` IPC.
 */
export function decodeZCallIpc<T = unknown>(hexCiphertext: string): T {
  const cleaned = hexCiphertext.replace(/[\s$]+/g, "");
  const plain = decodeAES(ZCALL_V2_IPC_AES_KEY_B64, cleaned, "hex").replace(/\0+$/g, "");
  return JSON.parse(plain) as T;
}
