import { describe, expect, test } from "bun:test";
import { randomBytes } from "node:crypto";
import {
  loginDecrypt,
  loginEncrypt,
  loginEncryptKey,
  sessionDecrypt,
  sessionEncrypt,
} from "../../../mock/gateway/src/crypto.ts";
import {
  computeSignKey,
  decodeAES,
  decodeWsPayload,
  decodeZCallIpc,
  encodeAES,
  encodeWsPayload,
  encodeZCallIpc,
  encryptPassword,
  ParamsEncryptor,
  parseJsonSafe,
} from "../src/core/crypto.ts";

describe("Zalo crypto parity & primitives", () => {
  test("encodeAES/decodeAES matches mock/gateway session crypto (AES-128-CBC)", () => {
    const keyB64 = randomBytes(16).toString("base64");
    const payload = JSON.stringify({ toid: "777000222", message: "Xin chào tiếng Việt 🎉", ttl: 0 });

    const sdkCipher = encodeAES(keyB64, payload);
    const mockDecrypted = sessionDecrypt(keyB64, sdkCipher);
    expect(mockDecrypted).toBe(payload);

    const mockCipher = sessionEncrypt(keyB64, payload);
    expect(decodeAES(keyB64, mockCipher)).toBe(payload);
    expect(decodeAES(keyB64, encodeURIComponent(mockCipher))).toBe(payload);
  });

  test("ParamsEncryptor matches mock/gateway login key derivation & AES-256-CBC", () => {
    const pe = new ParamsEncryptor(30, "imei-test-123", 1732400000000, "abc123ef");
    const mockKey = loginEncryptKey(pe.zcid, pe.zcidExt);
    expect(pe.enk).toBe(mockKey);
    expect(pe.enk.length).toBe(32);

    const body = { imei: "imei-test-123", language: "vi", ts: 1732400000000 };
    const sdkCipher = pe.encrypt(body);
    expect(JSON.parse(loginDecrypt(mockKey, sdkCipher))).toEqual(body);

    const serverReply = loginEncrypt(mockKey, JSON.stringify({ error_code: 0, data: { uid: "123" } }));
    expect(pe.decrypt<unknown>(serverReply)).toEqual({ error_code: 0, data: { uid: "123" } });
  });

  test("computeSignKey & encryptPassword produce deterministic signatures", () => {
    const sign = computeSignKey("getlogininfo", {
      type: 30,
      client_version: 685,
      zcid: "ZCID",
      zcid_ext: "EXT",
      enc_ver: "v2",
      params: "PARAM",
    });
    expect(sign).toMatch(/^[a-f0-9]{32}$/);

    const p1 = encryptPassword("0912345678", "imei-1", "secretPass", "salt1234");
    const p2 = encryptPassword("0912345678", "imei-1", "secretPass", "salt1234");
    expect(p1.encryptedPassword).toBe(p2.encryptedPassword);
    expect(p1.encryptedPassword.length).toBeGreaterThan(16);
  });

  test("decodeWsPayload decodes encrypt modes 0, 1, 2, 3 (plaintext, zlib, AES-256-GCM+zlib, AES-256-GCM)", () => {
    const key256 = randomBytes(32).toString("base64");
    const key128 = randomBytes(16).toString("base64");
    const msg = { error_code: 0, data: { msgs: [{ msgId: "9007199254740995123", content: "ok" }] } };

    // Mode 0: plaintext JSON
    expect(decodeWsPayload<unknown>({ encrypt: 0, data: JSON.stringify(msg) })).toEqual(msg);

    // Mode 1: base64 + zlib
    const enc1 = encodeWsPayload(msg, 1);
    expect(decodeWsPayload<unknown>({ encrypt: 1, data: enc1 })).toEqual(msg);

    // Mode 2: AES-256-GCM (16B IV + 16B AAD + ct + 16B tag) + zlib
    const enc2 = encodeWsPayload(msg, 2, key256);
    expect(decodeWsPayload<unknown>({ encrypt: 2, data: encodeURIComponent(enc2) }, key256)).toEqual(msg);

    // Mode 3: AES-128-GCM raw UTF-8
    const enc3 = encodeWsPayload(msg, 3, key128);
    expect(decodeWsPayload<unknown>({ encrypt: 3, data: enc3 }, key128)).toEqual(msg);
  });

  test("encodeZCallIpc & decodeZCallIpc round-trip and strip trailing NUL bytes", () => {
    const payload = { type: "request", command: "makeCall", data: { partner: [{ id: "123" }], type: 3 } };
    const hex = encodeZCallIpc(payload);
    expect(hex).toMatch(/^[a-f0-9]+$/);
    expect(decodeZCallIpc<unknown>(hex)).toEqual(payload);
  });

  test("parseJsonSafe preserves 64-bit integers beyond MAX_SAFE_INTEGER as strings", () => {
    const raw = '{"msgId":9007199254740999876,"cliMsgId":9007199254740991234,"ok":true}';
    const parsed = parseJsonSafe<{ msgId: string; cliMsgId: string; ok: boolean }>(raw);
    expect(String(parsed.msgId)).toBe("9007199254740999876");
    expect(String(parsed.cliMsgId)).toBe("9007199254740991234");
    expect(parsed.ok).toBe(true);
  });
});
