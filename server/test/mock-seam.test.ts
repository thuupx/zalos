import { afterEach, describe, expect, test } from "bun:test";
import { isZaloHost, mockGatewayFetch } from "../src/gateway/mock.ts";
import {
  sessionEncrypt,
  sessionDecrypt,
  loginEncryptKey,
  loginEncrypt,
  loginDecrypt,
} from "../../mock/gateway/src/crypto.ts";
// Relative path on purpose: zca-js's exports map only exposes the
// package root, and we want its real primitives for the round-trip.
import { decodeAES, encodeAES } from "../node_modules/zca-js/dist/utils.js";

describe("mock fetch rewrite", () => {
  const realFetch = globalThis.fetch;
  afterEach(() => {
    globalThis.fetch = realFetch;
  });

  function captured(): { urls: string[]; impl: typeof fetch } {
    const urls: string[] = [];
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      urls.push(String(input instanceof Request ? input.url : input));
      return new Response("ok");
    }) as typeof fetch;
    return { urls, impl: mockGatewayFetch("http://127.0.0.1:7355") };
  }

  test("rewrites zalo.me hosts", async () => {
    const { urls, impl } = captured();
    await impl("https://chat.zalo.me/api/message?a=1");
    await impl(new URL("https://id.zalo.me/account"));
    expect(urls).toEqual([
      "http://127.0.0.1:7355/chat.zalo.me/api/message?a=1",
      "http://127.0.0.1:7355/id.zalo.me/account",
    ]);
  });

  test("rewrites cdn hosts, leaves others alone", async () => {
    const { urls, impl } = captured();
    await impl("http://mock-media.zdn.vn/files/x.jpg");
    await impl("https://example.com/nope");
    expect(urls).toEqual([
      "http://127.0.0.1:7355/mock-media.zdn.vn/files/x.jpg",
      "https://example.com/nope",
    ]);
  });

  test("host predicate", () => {
    expect(isZaloHost("mock-media.zadn.vn")).toBe(true);
    expect(isZaloHost("res.zaloapp.com")).toBe(true);
    expect(isZaloHost("zalo.me")).toBe(true);
    expect(isZaloHost("evilzalo.me.evil.com")).toBe(false);
    expect(isZaloHost("example.com")).toBe(false);
  });
});

describe("mock crypto round-trips through zca-js", () => {
  const key = "MDEyMzQ1Njc4OUFCQ0RFRg==";
  const msg = JSON.stringify({ error_code: 0, data: { hello: "xin chào" } });

  test("session encrypt is decoded by zca decodeAES", () => {
    const enc = sessionEncrypt(key, msg);
    expect(decodeAES(key, enc)).toBe(msg);
  });

  test("zca encodeAES output is decoded by the mock", () => {
    const enc = encodeAES(key, msg);
    expect(enc).not.toBeNull();
    expect(sessionDecrypt(key, enc!)).toBe(msg);
  });

  test("login params encrypt round-trips both ways", () => {
    const ek = loginEncryptKey(
      "3FC4F0D2AB50057BCE0D90D9187A22B1ABCD",
      "zzext",
    );
    const enc = loginEncrypt(ek, msg);
    expect(loginDecrypt(ek, enc)).toBe(msg);
    // Key derivation is stable and 32 chars, matching ParamsEncryptor.
    expect(ek).toHaveLength(32);
    expect(
      loginEncryptKey("3FC4F0D2AB50057BCE0D90D9187A22B1ABCD", "zzext"),
    ).toBe(ek);
  });
});
