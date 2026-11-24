// Server-side vault integration tests.
import { test, expect, beforeAll, afterAll } from "bun:test";
import { readFileSync, existsSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";
import {
  makeEnv,
  pairDevice,
  controlClient,
  accountClient,
  loginQrAccount,
  vaultRoot,
  setVaultKey,
  openRecord,
  openMedia,
  type TestEnv,
} from "./support/helpers.ts";
import type { Client } from "./support/client.ts";
import type { PairedDevice } from "./support/helpers.ts";
import type { FakeGateway } from "../src/gateway/fake.ts";
import { sealFile } from "../src/media.ts";
import { msgAad } from "../src/vault.ts";

const require = createRequire(import.meta.url);
const vault = require("../vendor/zalos-vault/zalos_vault.js");

const MARKER = "vault-integ-marker-7f3a9";
const SENDER = "sender-marker-4b2c8";

let env: TestEnv;
let slot: string;
let gw: FakeGateway;
let control: Client;
let admin: PairedDevice;

function dbBytes(env: TestEnv): Uint8Array[] {
  const out: Uint8Array[] = [];
  for (const name of ["zalos.db", "zalos.db-wal", "zalos.db-shm"]) {
    const p = join(env.dir, name);
    if (existsSync(p)) out.push(readFileSync(p));
  }
  return out;
}

function containsMarker(needles: string[]): string | null {
  for (const bytes of dbBytes(env)) {
    const text = Buffer.from(bytes).toString("latin1");
    for (const n of needles) {
      if (text.includes(n)) return n;
    }
  }
  return null;
}

beforeAll(async () => {
  env = await makeEnv();
  admin = await pairDevice(env, { name: "admin", role: "admin" });
  control = await controlClient(env, admin);
  slot = await loginQrAccount(env, control);
  gw = env.factory.gateways.at(-1)!;
});

afterAll(() => env.cleanup());

test("records carry plaintext body before a vault key exists", async () => {
  const a = await accountClient(env, admin, slot);
  const evt = a.waitEvent("message.new");
  const res = (await a.request("messages.sendText", {
    threadId: "friend-1",
    threadType: "user",
    cliId: "cli-pre",
    text: MARKER,
  })) as { msgId: string };
  const e = await evt;
  const rec = (e.data as { message: { id: string; body?: { text?: string } } })
    .message;
  expect(rec.id).toBe(res.msgId);
  expect(rec.body?.text).toBe(MARKER);
  a.close();
});

test("vault.setKey seals existing rows and the db contains no marker", async () => {
  // Inject an incoming message so a sender name is in plaintext too.
  const a = await accountClient(env, admin, slot);
  const incoming = a.waitEvent("message.new");
  gw.injectIncoming({
    threadId: "friend-1",
    text: `incoming ${MARKER}`,
    senderName: SENDER,
  });
  await incoming;
  a.close();

  await setVaultKey(env, control, slot);

  // Scans db, -wal and -shm exactly as the server left them: setKey must
  // have checkpointed the WAL itself.
  const hit = containsMarker([MARKER, SENDER]);
  expect(hit).toBeNull();

  // Records are sealed and openable.
  const rows = env.server.store.allMessageRows(slot);
  expect(rows.length).toBeGreaterThan(0);
  for (const row of rows) {
    const rec = JSON.parse(row.body_json) as {
      id: string;
      sealed?: string;
      body?: unknown;
    };
    expect(rec.sealed).toBeTypeOf("string");
    expect(rec.body).toBeUndefined();
    const body = openRecord(env, slot, { id: rec.id, sealed: rec.sealed });
    expect(body.senderName).toBeTypeOf("string");
  }
});

test("a second different key is rejected with conflict; same key revalidates", async () => {
  const otherRoot = vault.generate_root();
  const otherPk = vault.derive_public_key(otherRoot, slot);
  let err: unknown;
  try {
    await control.request("vault.setKey", {
      slot,
      publicKey: Buffer.from(otherPk).toString("base64"),
    });
  } catch (e) {
    err = e;
  }
  expect((err as { code?: string }).code).toBe("conflict");
  const pk = vault.derive_public_key(vaultRoot(env), slot);
  const res = await control.request("vault.setKey", {
    slot,
    publicKey: Buffer.from(pk).toString("base64"),
  });
  expect((res as { ok: boolean }).ok).toBe(true);
});

test("new messages after setKey arrive sealed and open via the root", async () => {
  const dev = await pairDevice(env, { name: "post" });
  env.server.store.setAcl(dev.deviceId, [slot]);
  const a = await accountClient(env, dev, slot);
  const wait = a.waitEvent("message.new");
  const res = (await a.request("messages.sendText", {
    threadId: "friend-1",
    threadType: "user",
    cliId: "cli-post",
    text: `post ${MARKER}`,
  })) as { msgId: string };
  const e = await wait;
  const rec = (e.data as {
    message: { id: string; sealed?: string; body?: unknown };
  }).message;
  expect(rec.sealed).toBeTypeOf("string");
  const body = openRecord(env, slot, rec as { id: string; sealed: string });
  expect(body.text).toBe(`post ${MARKER}`);
  void res;
  a.close();
});

test("wrong aad (slot or msg id) fails to open", () => {
  const pt = new TextEncoder().encode(JSON.stringify({ senderName: "x" }));
  const pk = vault.derive_public_key(vaultRoot(env), slot);
  const sealed = vault.seal(pk, msgAad(slot, "msg-1"), pt);
  expect(
    vault.open_with_root(vaultRoot(env), slot, msgAad(slot, "msg-1"), sealed),
  ).toBeTypeOf("object");
  expect(() =>
    vault.open_with_root(vaultRoot(env), slot, msgAad(slot, "msg-2"), sealed),
  ).toThrow();
  expect(() =>
    vault.open_with_root(vaultRoot(env), "other", msgAad("other", "msg-1"), sealed),
  ).toThrow();
});

test("sealed media cache has no plaintext marker and round-trips; multi-chunk open", async () => {
  const dev = await pairDevice(env, { name: "med" });
  env.server.store.setAcl(dev.deviceId, [slot]);
  const a = await accountClient(env, dev, slot);
  const url = "https://cdn.example.com/sealed.bin";
  const res = (await a.request("media.fetch", { url })) as {
    stream: number;
    size: number;
    contentType: string;
    sealed: boolean;
  };
  expect(res.sealed).toBe(true);
  const blob = await a.waitBlob(res.stream);
  // The blob is the stored ciphertext: no plaintext marker inside.
  const text = Buffer.from(blob).toString("latin1");
  expect(text.includes("fake media bytes")).toBe(false);
  const opened = openMedia(env, slot, url, res.size, blob);
  expect(new TextDecoder().decode(opened)).toContain("fake media bytes");
  a.close();

  // Multi-chunk: seal a >1MiB file and open each chunk.
  const dir = join(env.dir, "tmp");
  const src = join(dir, "big.tmp");
  const dst = join(dir, "big.sealed");
  const data = crypto.getRandomValues(new Uint8Array(2.5 * 1024 * 1024));
  writeFileSync(src, data);
  const pk = vault.derive_public_key(vaultRoot(env), slot);
  const hash = "deadbeef";
  await sealFile(src, dst, slot, hash, data.length, pk);
  const sealed = readFileSync(dst);
  expect(sealed.length).toBeGreaterThan(data.length);
  const aad = new TextEncoder().encode(`zalos/1/media/${slot}/${hash}/${data.length}`);
  const opener = vault.file_opener_with_root(vaultRoot(env), slot, aad, sealed.subarray(0, 32));
  const out: Uint8Array[] = [];
  const CHUNK = 1024 * 1024 + 16;
  for (let off = 32; off < sealed.length; off += CHUNK) {
    out.push(opener.open_chunk(sealed.subarray(off, off + CHUNK)));
  }
  const total = out.reduce((n, c) => n + c.length, 0);
  const joined = new Uint8Array(total);
  let at = 0;
  for (const c of out) {
    joined.set(c, at);
    at += c.length;
  }
  expect(Buffer.from(joined).equals(Buffer.from(data))).toBe(true);
  rmSync(src, { force: true });
  rmSync(dst, { force: true });
});

test("sealed media fetch over multiple chunks round-trips", async () => {
  const dev = await pairDevice(env, { name: "medbig" });
  env.server.store.setAcl(dev.deviceId, [slot]);
  const a = await accountClient(env, dev, slot);
  const url = "https://cdn.example.com/big.bin?size=2500000";
  const res = (await a.request("media.fetch", { url })) as {
    stream: number;
    size: number;
    sealed: boolean;
  };
  expect(res.sealed).toBe(true);
  expect(res.size).toBe(2500000);
  const blob = await a.waitBlob(res.stream);
  // header(32) + ceil(2.5MiB/1MiB)=3 chunks of plaintext+16
  expect(blob.length).toBe(32 + 2500000 + 3 * 16);
  const opened = openMedia(env, slot, url, res.size, blob);
  expect(opened.length).toBe(2500000);
  // Fake payload is i % 251.
  expect(opened[0]).toBe(0);
  expect(opened[251]).toBe(0);
  expect(opened[2500000 - 1]).toBe((2500000 - 1) % 251);
  a.close();
});

test("vault.request/grant/fetch flow; non-admin rejected; revoke clears", async () => {
  const requester = await pairDevice(env, { name: "req" });
  const reqControl = await controlClient(env, requester);
  const adminDev = env.server.store
    .listDevices()
    .find((d) => d.role === "admin")!;
  const adminControl = await controlClient(
    env,
    (await pairDevice(env, { name: "adm2", role: "admin" })),
  );

  // Non-admin cannot grant.
  const memberDev = await pairDevice(env, { name: "member" });
  const memberControl = await controlClient(env, memberDev);
  let denied = false;
  try {
    await memberControl.request("vault.grant", {
      deviceId: requester.deviceId,
      wrapped: "AAAA",
    });
  } catch {
    denied = true;
  }
  expect(denied).toBe(true);

  const grantedEvt = reqControl.waitEvent("vault.granted");
  const adminEvt = adminControl.waitEvent("vault.requested");
  await reqControl.request("vault.request", {});

  const list = (await adminControl.request("vault.requests.list", {})) as {
    requests: { deviceId: string; boxPublicKey: string; fingerprint: string }[];
  };
  const entry = list.requests.find((r) => r.deviceId === requester.deviceId);
  expect(entry).toBeDefined();
  const evt = await adminEvt;
  const data = evt.data as {
    deviceId: string;
    boxPublicKey: string;
    fingerprint: string;
  };
  expect(data.deviceId).toBe(requester.deviceId);

  await adminControl.request("vault.grant", {
    deviceId: requester.deviceId,
    wrapped: Buffer.from("wrapped-root-blob").toString("base64"),
  });
  await grantedEvt;

  const fetched = (await reqControl.request("vault.fetch", {})) as {
    wrapped: string | null;
  };
  expect(fetched.wrapped).toBe(
    Buffer.from("wrapped-root-blob").toString("base64"),
  );
  // Gone after fetch.
  const again = (await reqControl.request("vault.fetch", {})) as {
    wrapped: string | null;
  };
  expect(again.wrapped).toBeNull();

  // Revocation clears pending request and blob.
  const rev = await pairDevice(env, { name: "rev" });
  const revControl = await controlClient(env, rev);
  await revControl.request("vault.request", {});
  await adminControl.request("vault.grant", {
    deviceId: rev.deviceId,
    wrapped: "AAAA",
  });
  await adminControl.request("devices.revoke", { deviceId: rev.deviceId });
  const row = env.server.store.deviceById(rev.deviceId)!;
  expect(row.vault_requested_at).toBeNull();
  expect(row.vault_wrapped).toBeNull();

  reqControl.close();
  adminControl.close();
  memberControl.close();
  void adminDev;
});

test("recall drops the sealed body but keeps clear fields", async () => {
  const dev = await pairDevice(env, { name: "rec" });
  env.server.store.setAcl(dev.deviceId, [slot]);
  const a = await accountClient(env, dev, slot);
  const sent = (await a.request("messages.sendText", {
    threadId: "friend-1",
    threadType: "user",
    cliId: "cli-recall-vault",
    text: `recall ${MARKER}`,
  })) as { msgId: string };
  const wait = a.waitEvent("message.updated");
  await a.request("messages.recall", {
    msgId: sent.msgId,
    threadId: "friend-1",
    threadType: "user",
  });
  const evt = await wait;
  const rec = (evt.data as {
    message: { recalled: boolean; sealed?: string; body?: unknown };
  }).message;
  expect(rec.recalled).toBe(true);
  expect(rec.sealed).toBeUndefined();
  expect(rec.body).toBeUndefined();
  a.close();
});

test("manifest exposes account uid; vault.claim is single-use", async () => {
  const m = (await control.request("manifest.get")) as {
    accounts: { slot: string; uid: string | null; vaultKey: string | null }[];
  };
  const acct = m.accounts.find((a) => a.slot === slot)!;
  expect(acct.uid).toBe(gw.self.uid);
  expect(acct.vaultKey).toBeTypeOf("string");

  // A member cannot win the global bootstrap claim.
  const other = await controlClient(env, await pairDevice(env, { name: "c2" }));
  const denied = await other.request("vault.claim", {}).then(
    () => "ok",
    (e: Error & { code?: string }) => e.code,
  );
  expect(denied).toBe("forbidden");
  const first = (await control.request("vault.claim", {})) as {
    claimed: boolean;
  };
  expect(first.claimed).toBe(true);
  const second = (await control.request("vault.claim", {})) as {
    claimed: boolean;
  };
  expect(second.claimed).toBe(false);
  other.close();
});

test("vault reset clears keys, claims, requests and drops sealed content", async () => {
  // Pending request state to clear.
  const dev = await pairDevice(env, { name: "rst" });
  const rc = await controlClient(env, dev);
  await rc.request("vault.request", {});
  env.server.store.grantVault(dev.deviceId, "AAAA");

  env.server.store.vaultReset();

  const acct = env.server.store.accountBySlot(slot)!;
  expect(acct.vault_public_key).toBeNull();
  const row = env.server.store.deviceById(dev.deviceId)!;
  expect(row.vault_requested_at).toBeNull();
  expect(row.vault_wrapped).toBeNull();
  expect(env.server.store.vaultRequesters()).toEqual([]);
  // Sealed content dropped; clear fields survive.
  for (const r of env.server.store.allMessageRows(slot)) {
    const rec = JSON.parse(r.body_json) as Record<string, unknown>;
    expect(rec.sealed).toBeUndefined();
    expect(rec.body).toBeUndefined();
    expect(rec.id).toBeTypeOf("string");
  }
  for (const ev of env.server.store.allEventRows(slot)) {
    expect(ev.data_json).not.toContain('"sealed"');
  }
  // Claim flag reset: next claim wins again.
  const claim = (await control.request("vault.claim", {})) as {
    claimed: boolean;
  };
  expect(claim.claimed).toBe(true);
  rc.close();
});

test("vault.reject clears the request and notifies the device", async () => {
  const dev = await pairDevice(env, { name: "rej" });
  const rc = await controlClient(env, dev);
  const rejected = rc.waitEvent("vault.rejected");
  await rc.request("vault.request", {});
  expect(
    env.server.store.vaultRequesters().map((d) => d.id),
  ).toContain(dev.deviceId);

  // Non-admin cannot reject.
  let denied = false;
  try {
    await rc.request("vault.reject", { deviceId: dev.deviceId });
  } catch {
    denied = true;
  }
  expect(denied).toBe(true);

  await control.request("vault.reject", { deviceId: dev.deviceId });
  await rejected;
  expect(env.server.store.vaultRequesters()).toEqual([]);
  rc.close();
});
