import { expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";
import {
  controlClient,
  accountClient,
  loginQrAccount,
  makeEnv,
  openMedia,
  pairDevice,
  pairDeviceWith,
  setVaultKey,
  vaultRoot,
  fromHex,
  type TestEnv,
} from "./support/helpers.ts";
import { fetchAndCache } from "../src/media.ts";
import { createZalosServer } from "../src/server.ts";
import { FakeGatewayFactory } from "../src/gateway/fake.ts";

const require = createRequire(import.meta.url);
const vault = require("../vendor/zalos-vault/zalos_vault.js") as {
  derive_public_key(root: Uint8Array, slot: string): Uint8Array;
};

async function rpcCode(request: Promise<unknown>): Promise<string> {
  return request.then(
    () => "ok",
    (error: Error & { code?: string }) => error.code ?? "error",
  );
}

function publicKey(env: TestEnv, slot: string): Uint8Array {
  return vault.derive_public_key(vaultRoot(env), slot);
}

function databaseContains(env: TestEnv, marker: string): boolean {
  return ["zalos.db", "zalos.db-wal", "zalos.db-shm"].some((name) => {
    const path = join(env.dir, name);
    return existsSync(path) && readFileSync(path).toString("latin1").includes(marker);
  });
}

test("member cannot log out an ACL account or claim the vault root", async () => {
  const env = await makeEnv();
  try {
    const admin = await pairDevice(env, { name: "admin", role: "admin" });
    const adminControl = await controlClient(env, admin);
    const slot = await loginQrAccount(env, adminControl);
    const member = await pairDevice(env, { name: "member" });
    const memberControl = await controlClient(env, member);
    const credentials = env.server.store.accountBySlot(slot)!.credentials_json;

    expect(await rpcCode(memberControl.request("accounts.logout", { slot }))).toBe(
      "forbidden",
    );
    env.server.store.setAcl(member.deviceId, [slot]);
    expect(await rpcCode(memberControl.request("accounts.logout", { slot }))).toBe(
      "forbidden",
    );
    expect(env.server.store.accountBySlot(slot)!.credentials_json).toBe(credentials);
    expect(env.server.accounts.gateway(slot)).toBeDefined();

    expect(await rpcCode(memberControl.request("vault.claim", {}))).toBe(
      "forbidden",
    );
    expect(env.server.store.getMeta("vault_claimed")).toBe("0");
    const claimed = (await adminControl.request("vault.claim", {})) as {
      claimed: boolean;
    };
    expect(claimed.claimed).toBe(true);

    await adminControl.request("accounts.logout", { slot });
    expect(env.server.store.accountBySlot(slot)!.credentials_json).toBe("");
    memberControl.close();
  } finally {
    await env.cleanup();
  }
});

test("pairing and account creation grant implicit access only to admins", async () => {
  const env = await makeEnv();
  try {
    const admin = await pairDevice(env, { name: "admin", role: "admin" });
    const adminControl = await controlClient(env, admin);
    const member = await pairDevice(env, { name: "member" });
    const firstSlot = await loginQrAccount(env, adminControl);

    expect(env.server.store.deviceAcl(admin.deviceId)).toEqual([firstSlot]);
    expect(env.server.store.deviceAcl(member.deviceId)).toEqual([]);
    env.server.store.setAcl(member.deviceId, [firstSlot]);

    // The test client retains events; do not let the second login resolve
    // against the first loginQr.done notification.
    adminControl.events.length = 0;
    const secondSlot = await loginQrAccount(env, adminControl);
    expect(new Set(env.server.store.deviceAcl(admin.deviceId))).toEqual(
      new Set([firstSlot, secondSlot]),
    );
    expect(env.server.store.deviceAcl(member.deviceId)).toEqual([firstSlot]);

    const newMember = await pairDevice(env, { name: "new-member" });
    const newAdmin = await pairDevice(env, { name: "new-admin", role: "admin" });
    expect(env.server.store.deviceAcl(newMember.deviceId)).toEqual([]);
    expect(new Set(env.server.store.deviceAcl(newAdmin.deviceId))).toEqual(
      new Set([firstSlot, secondSlot]),
    );

    const pairing = env.server.store.createPairing("member");
    const repaired = await pairDeviceWith(
      env,
      pairing.id,
      fromHex(pairing.secret),
      { name: "member-repaired" },
      member.keypair,
    );
    expect(repaired.deviceId).toBe(member.deviceId);
    expect(env.server.store.deviceAcl(member.deviceId)).toEqual([firstSlot]);
  } finally {
    await env.cleanup();
  }
});

test("vault staging and database failures do not install a key or replace media", async () => {
  const env = await makeEnv();
  try {
    const admin = await pairDevice(env, { name: "admin", role: "admin" });
    const control = await controlClient(env, admin);
    const slot = await loginQrAccount(env, control);
    const account = await accountClient(env, admin, slot);
    await account.request("messages.sendText", {
      threadId: "friend-1",
      threadType: "user",
      cliId: "vault-failure",
      text: "plaintext-before-vault",
    });
    account.close();

    const cacheDir = join(env.dir, "media-cache", slot);
    mkdirSync(cacheDir, { recursive: true });
    const dataPath = join(cacheDir, "cached.bin");
    const metaPath = join(cacheDir, "cached.meta");
    const plaintext = new TextEncoder().encode("cached-plaintext");
    writeFileSync(dataPath, plaintext);
    writeFileSync(metaPath, "not-json");
    const pk = publicKey(env, slot);
    const encoded = Buffer.from(pk).toString("base64");

    expect(
      await rpcCode(
        control.request("vault.setKey", { slot, publicKey: encoded }),
      ),
    ).not.toBe("ok");
    expect(env.server.store.accountBySlot(slot)!.vault_public_key).toBeNull();
    expect(readFileSync(dataPath)).toEqual(Buffer.from(plaintext));

    writeFileSync(
      metaPath,
      JSON.stringify({
        contentType: "application/octet-stream",
        size: plaintext.length,
        sealed: false,
      }),
    );
    const manager = env.server.accounts;
    const originalSeal = manager.sealExistingRows;
    manager.sealExistingRows = () => {
      throw new Error("injected database sealing failure");
    };
    expect(
      await rpcCode(
        control.request("vault.setKey", { slot, publicKey: encoded }),
      ),
    ).not.toBe("ok");
    manager.sealExistingRows = originalSeal;
    expect(env.server.store.accountBySlot(slot)!.vault_public_key).toBeNull();
    expect(readFileSync(dataPath)).toEqual(Buffer.from(plaintext));

    await control.request("vault.setKey", { slot, publicKey: encoded });
    expect(env.server.store.accountBySlot(slot)!.vault_public_key).toBe(encoded);
    expect(readFileSync(dataPath).toString("latin1")).not.toContain(
      "cached-plaintext",
    );
    expect(JSON.parse(readFileSync(metaPath, "utf8")).sealed).toBe(true);
    for (const row of env.server.store.allMessageRows(slot)) {
      expect(JSON.parse(row.body_json).sealed).toBeTypeOf("string");
    }

    // Emulate plaintext left by an interrupted older implementation. Repeating
    // the same key must resume sealing rather than returning a false no-op.
    writeFileSync(dataPath, plaintext);
    writeFileSync(
      metaPath,
      JSON.stringify({
        contentType: "application/octet-stream",
        size: plaintext.length,
        sealed: false,
      }),
    );
    await control.request("vault.setKey", { slot, publicKey: encoded });
    expect(readFileSync(dataPath).toString("latin1")).not.toContain(
      "cached-plaintext",
    );
    expect(JSON.parse(readFileSync(metaPath, "utf8")).sealed).toBe(true);
  } finally {
    await env.cleanup();
  }
});

test("a download paused across vault enablement publishes only sealed media", async () => {
  const env = await makeEnv();
  try {
    const admin = await pairDevice(env, { name: "admin", role: "admin" });
    const control = await controlClient(env, admin);
    const slot = await loginQrAccount(env, control);
    const url = "https://cdn.example.com/paused-vault-download";
    const plaintext = new TextEncoder().encode("paused-download-plaintext");
    let notifyStarted!: () => void;
    const started = new Promise<void>((resolve) => {
      notifyStarted = resolve;
    });
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });

    const pending = fetchAndCache(env.dir, url, {
      slot,
      fake: true,
      getVaultKey: () => env.server.accounts.vaultKey(slot),
      gatewayFetch: async () => {
        notifyStarted();
        await gate;
        return { data: plaintext, contentType: "application/octet-stream" };
      },
    });
    await started;
    await setVaultKey(env, control, slot);
    release();
    const hit = await pending;

    expect(hit.sealed).toBe(true);
    const sealed = readFileSync(hit.path);
    expect(sealed.toString("latin1")).not.toContain("paused-download-plaintext");
    expect(openMedia(env, slot, url, plaintext.length, sealed)).toEqual(plaintext);
    expect(existsSync(join(env.dir, "tmp", slot))).toBe(true);
  } finally {
    await env.cleanup();
  }
});

test("thread deletion, logout, and removal erase only the target account files", async () => {
  const env = await makeEnv();
  try {
    const admin = await pairDevice(env, { name: "admin", role: "admin" });
    const control = await controlClient(env, admin);
    const firstSlot = await loginQrAccount(env, control);
    control.events.length = 0;
    const secondSlot = await loginQrAccount(env, control);
    const account = await accountClient(env, admin, firstSlot);
    await account.request("messages.sendText", {
      threadId: "delete-me",
      threadType: "user",
      cliId: "delete-thread-media",
      text: "thread with cached media",
    });

    const seed = async (slot: string, suffix: string) => {
      const hit = await fetchAndCache(env.dir, `https://cdn.example.com/${suffix}`, {
        slot,
        fake: true,
        gatewayFetch: async () => ({
          data: new TextEncoder().encode(`media-${suffix}`),
          contentType: "application/octet-stream",
        }),
      });
      const tmpDir = join(env.dir, "tmp", slot);
      mkdirSync(tmpDir, { recursive: true });
      writeFileSync(join(tmpDir, "stale-download"), `tmp-${suffix}`);
      return hit;
    };
    const firstHit = await seed(firstSlot, "first");
    const secondHit = await seed(secondSlot, "second");

    await account.request("threads.delete", {
      threadId: "delete-me",
      threadType: "user",
    });
    expect(existsSync(join(env.dir, "media-cache", firstSlot))).toBe(false);
    expect(existsSync(join(env.dir, "tmp", firstSlot))).toBe(false);
    expect(readFileSync(secondHit.path).toString()).toBe("media-second");
    expect(existsSync(join(env.dir, "tmp", secondSlot, "stale-download"))).toBe(
      true,
    );

    await seed(firstSlot, "first-logout");
    const logoutMarker = "logout-credential-marker-7c19";
    const removalMarker = "remove-credential-marker-4a21";
    const secondCredentials = JSON.stringify({ session: removalMarker });
    env.server.store.updateAccountCredentials(
      firstSlot,
      JSON.stringify({ session: logoutMarker }),
    );
    env.server.store.updateAccountCredentials(secondSlot, secondCredentials);
    env.server.store.checkpoint();
    expect(databaseContains(env, logoutMarker)).toBe(true);

    await control.request("accounts.logout", { slot: firstSlot });
    expect(env.server.store.accountBySlot(firstSlot)!.credentials_json).toBe("");
    expect(env.server.store.accountBySlot(secondSlot)!.credentials_json).toBe(
      secondCredentials,
    );
    expect(existsSync(join(env.dir, "media-cache", firstSlot))).toBe(false);
    expect(existsSync(join(env.dir, "tmp", firstSlot))).toBe(false);
    expect(existsSync(secondHit.path)).toBe(true);
    expect(databaseContains(env, logoutMarker)).toBe(false);
    expect(databaseContains(env, removalMarker)).toBe(true);

    await control.request("accounts.remove", { slot: secondSlot });
    expect(env.server.store.accountBySlot(secondSlot)).toBeNull();
    expect(env.server.store.accountBySlot(firstSlot)).not.toBeNull();
    expect(existsSync(join(env.dir, "media-cache", secondSlot))).toBe(false);
    expect(existsSync(join(env.dir, "tmp", secondSlot))).toBe(false);
    expect(databaseContains(env, removalMarker)).toBe(false);
    account.close();
  } finally {
    await env.cleanup();
  }
});

test("startup resumes a keyed account with unpublished plaintext media", async () => {
  const env = await makeEnv();
  let restarted: ReturnType<typeof createZalosServer> | undefined;
  let originalClosed = false;
  try {
    const admin = await pairDevice(env, { name: "admin", role: "admin" });
    const control = await controlClient(env, admin);
    const slot = await loginQrAccount(env, control);
    const pk = await setVaultKey(env, control, slot);
    const cacheDir = join(env.dir, "media-cache", slot);
    mkdirSync(cacheDir, { recursive: true });
    const dataPath = join(cacheDir, "restart.bin");
    const metaPath = join(cacheDir, "restart.meta");
    const plaintext = new TextEncoder().encode("restart-plaintext");
    writeFileSync(dataPath, plaintext);
    writeFileSync(
      metaPath,
      JSON.stringify({
        contentType: "application/octet-stream",
        size: plaintext.length,
        sealed: false,
      }),
    );
    await env.cleanup();
    originalClosed = true;

    restarted = createZalosServer({
      dataDir: env.dir,
      fake: true,
      factory: new FakeGatewayFactory(),
    });
    await restarted.ready;
    expect(readFileSync(dataPath).toString("latin1")).not.toContain(
      "restart-plaintext",
    );
    expect(JSON.parse(readFileSync(metaPath, "utf8")).sealed).toBe(true);
    expect(restarted.store.accountBySlot(slot)!.vault_public_key).toBe(
      Buffer.from(pk).toString("base64"),
    );
  } finally {
    if (!originalClosed) await env.cleanup();
    if (restarted !== undefined) await restarted.close();
  }
});

test("every admin-only control RPC rejects members with no side effects", async () => {
  const env = await makeEnv();
  try {
    const admin = await pairDevice(env, { name: "admin", role: "admin" });
    const adminControl = await controlClient(env, admin);
    const slot = await loginQrAccount(env, adminControl);
    const member = await pairDevice(env, { name: "member" });
    env.server.store.setAcl(member.deviceId, [slot]);
    const memberControl = await controlClient(env, member);

    const pkBase64 = Buffer.from(publicKey(env, slot)).toString("base64");
    const adminOnlyCalls: [string, Record<string, unknown>][] = [
      ["devices.list", {}],
      ["devices.revoke", { deviceId: admin.deviceId }],
      ["devices.setAcl", { deviceId: member.deviceId, slots: [] }],
      ["pairing.create", { role: "member" }],
      ["vault.claim", {}],
      ["vault.setKey", { slot, publicKey: pkBase64 }],
      ["vault.requests.list", {}],
      ["vault.grant", { deviceId: member.deviceId, wrapped: "x" }],
      ["vault.reject", { deviceId: member.deviceId }],
      ["accounts.loginQr.start", {}],
      [
        "accounts.addOa",
        { appId: "a", appSecret: "s", accessToken: "t", refreshToken: "r" },
      ],
      [
        "accounts.updateOaTokens",
        { slot, accessToken: "t2", refreshToken: "r2" },
      ],
      ["accounts.logout", { slot }],
      ["accounts.remove", { slot }],
    ];

    for (const [method, params] of adminOnlyCalls) {
      expect(await rpcCode(memberControl.request(method, params))).toBe(
        "forbidden",
      );
    }

    // Verify zero side effects occurred from any denied call.
    expect(env.server.store.accountBySlot(slot)!.vault_public_key).toBeNull();
    expect(env.server.store.accountBySlot(slot)!.vault_state).toBe("unsealed");
    expect(env.server.store.getMeta("vault_claimed")).toBe("0");
    expect(env.server.store.deviceById(admin.deviceId)!.revoked_at).toBeNull();
    memberControl.close();
  } finally {
    await env.cleanup();
  }
});

test("message delete, recall, and TTL expiry remove unreferenced media cache files", async () => {
  const env = await makeEnv({ autoDeleteSweepMs: 0, messageTtlSweepMs: 0 });
  try {
    const admin = await pairDevice(env, { name: "admin", role: "admin" });
    const control = await controlClient(env, admin);
    const slot = await loginQrAccount(env, control);
    const account = await accountClient(env, admin, slot);
    const gw = env.factory.gateways.at(-1)!;

    const urlShared = "https://cdn.example.com/shared-photo.jpg";
    const urlDelete = "https://cdn.example.com/delete-only.jpg";
    const urlRecall = "https://cdn.example.com/recall-only.jpg";
    const urlTtl = "https://cdn.example.com/ttl-only.jpg";

    const seedUrl = async (url: string) =>
      fetchAndCache(env.dir, url, {
        slot,
        fake: true,
        gatewayFetch: async () => ({
          data: new TextEncoder().encode(`bytes:${url}`),
          contentType: "image/jpeg",
        }),
      });

    const hitShared = await seedUrl(urlShared);
    const hitDelete = await seedUrl(urlDelete);
    const hitRecall = await seedUrl(urlRecall);
    const hitTtl = await seedUrl(urlTtl);

    // Inject incoming messages referencing these URLs.
    const now = Date.now();
    const emitImg = (id: string, urls: string[], ttl?: number) => {
      gw.emit("message", {
        id,
        cliId: null,
        threadId: "peer-media",
        threadType: "user",
        senderId: "peer-media",
        senderName: "Peer",
        ts: now,
        isSelf: false,
        kind: "image",
        reactions: {},
        recalled: false,
        attachments: urls.map((u) => ({ kind: "image" as const, url: u })),
        ...(ttl !== undefined ? { ttl, expiresAt: now - 1000 } : {}),
      });
    };

    emitImg("m-keep", [urlShared]);
    emitImg("m-del", [urlShared, urlDelete]);
    emitImg("m-rec", [urlRecall]);
    emitImg("m-ttl", [urlTtl], 1000);
    await Bun.sleep(20);

    // 1) Delete message -> deletes urlDelete, keeps urlShared (still referenced by m-keep)
    await account.request("messages.delete", {
      msgId: "m-del",
      threadId: "peer-media",
      threadType: "user",
    });
    expect(existsSync(hitDelete.path)).toBe(false);
    expect(existsSync(hitShared.path)).toBe(true);

    // 2) Recall event -> deletes urlRecall
    gw.emit("recall", {
      msgId: "m-rec",
      threadId: "peer-media",
      threadType: "user",
      isSelf: false,
    });
    await Bun.sleep(50);
    expect(existsSync(hitRecall.path)).toBe(false);

    // 3) TTL sweep -> deletes urlTtl
    const swept = await env.server.accounts.sweepTtl(slot);
    expect(swept).toBeGreaterThanOrEqual(1);
    expect(existsSync(hitTtl.path)).toBe(false);
    expect(existsSync(hitShared.path)).toBe(true);

    account.close();
  } finally {
    await env.cleanup();
  }
});

test("aggregate limits enforce stale upload cleanup, per-device connections, and rate limits", async () => {
  const env = await makeEnv({
    limits: {
      maxConnectionsPerDevice: 2,
      maxUnclaimedUploadsPerChannel: 1,
      uploadTimeoutMs: 80,
      rateLimitSend: { burst: 2, refillPerSec: 0.01 },
    },
  });
  try {
    const admin = await pairDevice(env, { name: "admin", role: "admin" });
    const c1 = await controlClient(env, admin);
    const slot = await loginQrAccount(env, c1);
    const a1 = await accountClient(env, admin, slot);

    // 1) Per-device connection cap (already at 2: c1 + a1 -> 3rd must fail).
    let thirdFailed = false;
    try {
      const c2 = await controlClient(env, admin);
      c2.close();
    } catch {
      thirdFailed = true;
    }
    expect(thirdFailed).toBe(true);

    // 2) Stale unclaimed upload file is deleted from disk after uploadTimeoutMs.
    const tmpDir = join(env.dir, "tmp");
    a1.sendBlob(new TextEncoder().encode("stale-upload-bytes"));
    await Bun.sleep(30);
    const filesDuring = (await import("node:fs")).readdirSync(tmpDir).filter((n) => n.startsWith("up-"));
    expect(filesDuring.length).toBeGreaterThanOrEqual(1);
    await Bun.sleep(150);
    const filesAfter = (await import("node:fs")).readdirSync(tmpDir).filter((n) => n.startsWith("up-"));
    expect(filesAfter.length).toBe(0);

    // 3) Token-bucket rate limiter rejects burst > 2 on messages.sendText.
    await a1.request("messages.sendText", {
      threadId: "rl-1",
      threadType: "user",
      cliId: "rl-1",
      text: "one",
    });
    await a1.request("messages.sendText", {
      threadId: "rl-1",
      threadType: "user",
      cliId: "rl-2",
      text: "two",
    });
    expect(
      await rpcCode(
        a1.request("messages.sendText", {
          threadId: "rl-1",
          threadType: "user",
          cliId: "rl-3",
          text: "three",
        }),
      ),
    ).toBe("rate_limited");

    a1.close();
    c1.close();
  } finally {
    await env.cleanup();
  }
});
