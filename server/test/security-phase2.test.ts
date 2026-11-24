import { expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  assertPublicUrl,
  createPinnedLookup,
  isAllowedEgressHost,
} from "../src/media.ts";
import { OaGateway } from "../src/gateway/oa.ts";
import {
  setAuditSink,
  setErrorLogSink,
  logSafeError,
  redactValue,
  type AuditEvent,
} from "../src/security/audit.ts";
import { createZalosServer } from "../src/server.ts";
import { parseFunnelStatus } from "../src/doctor.ts";
import {
  makeEnv,
  pairDevice,
  controlClient,
  accountClient,
  loginQrAccount,
} from "./support/helpers.ts";

test("pinned lookup blocks DNS rebinding and enforces hybrid/strict egress", async () => {
  // Two-stage DNS rebinding: first answer is public, second is loopback -> lookup rejects!
  let call = 0;
  const rebindingResolver = async () => {
    call++;
    return call === 1 ? ["93.184.216.34"] : ["127.0.0.1"];
  };
  await assertPublicUrl("https://rebind.example.com/a.jpg", {
    allowHttp: false,
    resolve: rebindingResolver,
  });

  const lookup = createPinnedLookup(rebindingResolver);
  const err = await new Promise<Error | null>((resolve) => {
    lookup("rebind.example.com", {}, (e) => resolve(e));
  });
  expect(err).not.toBeNull();
  expect(err!.message).toContain("address not allowed");

  // Strict HTTPS rejects plain http:
  await expect(
    assertPublicUrl("http://8.8.8.8/file.png", { allowHttp: false }),
  ).rejects.toMatchObject({ code: "forbidden" });

  // Hybrid allowlist helper
  expect(isAllowedEgressHost("f48-zpg-r.zdn.vn")).toBe(true);
  expect(isAllowedEgressHost("evil.example.com")).toBe(false);
  await expect(
    assertPublicUrl("https://8.8.8.8/x", { allowlistOnly: true }),
  ).rejects.toMatchObject({ code: "forbidden" });
});

test("concurrent sendBankCard serializes and reused cliId with different body rejects as conflict", async () => {
  const env = await makeEnv();
  try {
    const admin = await pairDevice(env, { name: "admin", role: "admin" });
    const control = await controlClient(env, admin);
    const slot = await loginQrAccount(env, control);
    const account = await accountClient(env, admin, slot);
    const gw = env.factory.gateways.at(-1)!;

    let release!: () => void;
    const gate = new Promise<void>((r) => {
      release = r;
    });
    const origBank = gw.sendBankCard.bind(gw);
    let bankCalls = 0;
    gw.sendBankCard = async (...args) => {
      bankCalls++;
      await gate;
      return origBank(...args);
    };

    const params = {
      threadId: "bank-peer",
      threadType: "user",
      cliId: "bank-cli-1",
      bin: 970436,
      accountNumber: "0123456789",
      holderName: "THU",
    };
    const p1 = account.request("messages.sendBankCard", params);
    await Bun.sleep(20);
    const p2 = account.request("messages.sendBankCard", params);
    await Bun.sleep(20);
    expect(bankCalls).toBe(1);

    // Different accountNumber with same cliId -> conflict!
    await expect(
      account.request("messages.sendBankCard", {
        ...params,
        accountNumber: "9999999999",
      }),
    ).rejects.toMatchObject({ code: "conflict" });

    release();
    const [r1, r2] = await Promise.all([p1, p2]);
    expect(r2).toEqual(r1);
    expect(bankCalls).toBe(1);
    account.close();
    control.close();
  } finally {
    await env.cleanup();
  }
});

test("OA tokens stay out of URLs, error logs redact secrets, and security actions emit audit events", async () => {
  const seenUrls: string[] = [];
  const seenHeaders: Headers[] = [];
  const fakeFetch = (async (input: string | URL | Request, init?: RequestInit) => {
    seenUrls.push(String(input));
    seenHeaders.push(new Headers(init?.headers));
    return new Response(
      JSON.stringify({
        error: 0,
        data: { oa_id: "oa-1", name: "Test OA", avatar: "" },
      }),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  }) as unknown as typeof fetch;

  const secretToken = "oa-canary-secret-token-9911";
  const gw = new OaGateway(
    {
      appId: "app1",
      appSecret: "app-secret-canary-7722",
      accessToken: secretToken,
      refreshToken: "rt-canary-8833",
      accessTokenExpiresAt: Date.now() + 3600_000,
    },
    { uid: "", displayName: "", avatarUrl: "" },
    { onCredentials: () => {}, clientConnected: () => false },
    fakeFetch,
  );
  await gw.start();
  await gw.stop();
  expect(seenUrls.length).toBeGreaterThan(0);
  for (const u of seenUrls) {
    expect(u).not.toContain("access_token=");
    expect(u).not.toContain(secretToken);
  }
  expect(seenHeaders[0]!.get("access_token")).toBe(secretToken);

  // Synthetic-secret redaction test over logger
  const logged: Record<string, unknown>[] = [];
  setErrorLogSink((e) => logged.push(e));
  try {
    logSafeError(
      "test",
      new Error(`boom https://api.zalo.me/x?access_token=${secretToken}&ok=1 Bearer supersecretvalue`),
      { cookie: "zpw_sek=canary-cookie", pin: "1234", safeField: "visible" },
    );
    const dumped = JSON.stringify(logged);
    expect(dumped).not.toContain(secretToken);
    expect(dumped).not.toContain("canary-cookie");
    expect(dumped).not.toContain("supersecretvalue");
    expect(dumped).not.toContain("1234");
    expect(dumped).toContain("visible");
    expect(redactValue({ psk: "abc", nested: { refreshToken: "xyz" } })).toEqual({
      psk: "[REDACTED]",
      nested: { refreshToken: "[REDACTED]" },
    });
  } finally {
    setErrorLogSink(null);
  }

  // Audit events emitted on pairing, auth, and denied authorization
  const events: AuditEvent[] = [];
  setAuditSink((e) => events.push(e));
  const env = await makeEnv();
  try {
    const admin = await pairDevice(env, { name: "admin", role: "admin" });
    const member = await pairDevice(env, { name: "member" });
    const memberCtrl = await controlClient(env, member);
    await expect(memberCtrl.request("devices.list", {})).rejects.toMatchObject({
      code: "forbidden",
    });
    const names = events.map((e) => e.event);
    expect(names).toContain("pair.complete");
    expect(names).toContain("auth.ok");
    expect(names).toContain("authz.denied");
    memberCtrl.close();
  } finally {
    setAuditSink(null);
    await env.cleanup();
  }
});

test("composition root refuses fake/mock without allowDev, and Funnel parser fails closed", () => {
  const dir = mkdtempSync(join(tmpdir(), "zalos-f09-"));
  try {
    expect(() =>
      createZalosServer({ dataDir: dir, fake: true, allowDev: false }),
    ).toThrow(/forbidden outside dev/);
    expect(() =>
      createZalosServer({
        dataDir: dir,
        fake: false,
        mockUrl: "http://127.0.0.1:9999",
        allowDev: false,
      }),
    ).toThrow(/forbidden outside dev/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }

  expect(parseFunnelStatus("not-json", 7443).ok).toBe(false);
  expect(parseFunnelStatus("{}", 7443)).toMatchObject({ ok: true, exposed: false });
  expect(
    parseFunnelStatus(
      JSON.stringify({
        AllowFunnel: { "h.ts.net:443": true },
        Web: { "h.ts.net:443": { Handlers: { "/": { Proxy: "http://127.0.0.1:7443" } } } },
      }),
      7443,
    ),
  ).toMatchObject({ ok: true, exposed: true });
});

test("vault.rotate is admin-only, enforces compare-and-set version, and tags new records with kv", async () => {
  const env = await makeEnv();
  try {
    const admin = await pairDevice(env, { name: "admin", role: "admin" });
    const member = await pairDevice(env, { name: "member" });
    const adminCtrl = await controlClient(env, admin);
    const memberCtrl = await controlClient(env, member);
    const slot = await loginQrAccount(env, adminCtrl);

    const pk1 = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64");
    const pk2 = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64");
    await adminCtrl.request("vault.setKey", { slot, publicKey: pk1 });

    // Non-admin cannot rotate
    await expect(
      memberCtrl.request("vault.rotate", { slot, expectedVersion: 1, publicKey: pk2 }),
    ).rejects.toMatchObject({ code: "forbidden" });

    // Stale expectedVersion rejected as conflict
    await expect(
      adminCtrl.request("vault.rotate", { slot, expectedVersion: 99, publicKey: pk2 }),
    ).rejects.toMatchObject({ code: "conflict" });

    // Admin rotates 1 -> 2
    const rotated = (await adminCtrl.request("vault.rotate", {
      slot,
      expectedVersion: 1,
      publicKey: pk2,
    })) as { ok: boolean; version: number };
    expect(rotated.ok).toBe(true);
    expect(rotated.version).toBe(2);
    expect(env.server.store.accountBySlot(slot)!.vault_key_version).toBe(2);

    // New messages are tagged with kv=2
    const account = await accountClient(env, admin, slot);
    const sent = (await account.request("messages.sendText", {
      threadId: "rot-1",
      threadType: "user",
      cliId: "rot-cli-1",
      text: "sealed under gen 2",
    })) as { msgId: string };
    const stored = env.server.store.getMessage(slot, sent.msgId)!;
    const rec = JSON.parse(stored.body_json) as { kv?: number; sealed?: string };
    expect(rec.kv).toBe(2);
    expect(typeof rec.sealed).toBe("string");

    account.close();
    memberCtrl.close();
    adminCtrl.close();
  } finally {
    await env.cleanup();
  }
});
