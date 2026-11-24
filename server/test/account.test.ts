import { test, expect, beforeAll, afterAll } from "bun:test";
import {
  makeEnv,
  pairDevice,
  controlClient,
  accountClient,
  loginQrAccount,
  type TestEnv,
  type PairedDevice,
} from "./support/helpers.ts";
import { Client, fromHex } from "./support/client.ts";
import type { FakeGateway } from "../src/gateway/fake.ts";
import type { Message } from "../src/gateway/types.ts";

let env: TestEnv;
let admin: PairedDevice;
let deviceB: PairedDevice;
let slot: string;
let gw: FakeGateway;

beforeAll(async () => {
  env = await makeEnv();
  admin = await pairDevice(env, { name: "admin" });
  deviceB = await pairDevice(env, { name: "b" });
  const control = await controlClient(env, admin);
  slot = await loginQrAccount(env, control);
  env.server.store.setAcl(deviceB.deviceId, [slot]);
  gw = env.factory.gateways.at(-1)!;
  control.close();
});

afterAll(() => env.cleanup());

test("sendText from device A reaches A and B with the same seq", async () => {
  const a = await accountClient(env, admin, slot);
  const b = await accountClient(env, deviceB, slot);
  a.events.length = 0;
  b.events.length = 0;
  const bWait = b.waitEvent("message.new");
  const res = (await a.request("messages.sendText", {
    threadId: "friend-1",
    threadType: "user",
    cliId: "cli-1",
    text: "hi there",
  })) as { msgId: string };
  const evtA = await a.waitEvent("message.new");
  const evtB = await bWait;
  expect(evtA.seq).toBe(evtB.seq!);
  const msgA = (evtA.data as { message: Message }).message;
  expect(msgA.id).toBe(res.msgId);
  expect(msgA.cliId).toBe("cli-1");
  // gateway recorded exactly one send
  const calls = gw.calls.filter((c) => c.method === "sendText");
  expect(calls.length).toBe(1);
  a.close();
  b.close();
});

test("incoming gateway message bumps unread and reaches both devices", async () => {
  const a = await accountClient(env, admin, slot);
  const b = await accountClient(env, deviceB, slot);
  a.events.length = 0;
  b.events.length = 0;
  const aWait = a.waitEvent("message.new");
  const bWait = b.waitEvent("message.new");
  gw.injectIncoming({ threadId: "friend-1", text: "hello back", ts: Date.now() });
  const [ea, eb] = await Promise.all([aWait, bWait]);
  expect(ea.seq).toBe(eb.seq!);
  const thread = env.server.store.getThread(slot, "friend-1", "user")!;
  expect(thread.unread).toBeGreaterThan(0);
  a.close();
  b.close();
});

test("sync returns gap and reset semantics", async () => {
  const a = await accountClient(env, admin, slot);
  const sync = (await a.request("sync", { sinceSeq: 0 })) as {
    reset: boolean;
    latestSeq: number;
    events: { seq: number }[];
  };
  expect(sync.reset).toBe(true);
  expect(sync.latestSeq).toBeGreaterThan(0);
  expect(sync.events[0].seq).toBe(1);
  const gap = (await a.request("sync", { sinceSeq: sync.latestSeq })) as {
    reset: boolean;
    events: unknown[];
  };
  expect(gap.reset).toBe(false);
  expect(gap.events).toEqual([]);
  a.close();
});

test("react produces message.updated", async () => {
  const a = await accountClient(env, admin, slot);
  const sent = (await a.request("messages.sendText", {
    threadId: "friend-1",
    threadType: "user",
    cliId: "cli-react",
    text: "react to me",
  })) as { msgId: string };
  // First message.updated is our own optimistic reaction; the second is the
  // friend echo.
  const wait = a.waitEvent(
    "message.updated",
    5000,
    (e) =>
      (
        (e.data as { message: { reactions: Record<string, string[]> } })
          .message.reactions["/-heart"] ?? []
      ).includes("friend-1"),
  );
  await a.request("messages.react", {
    msgId: sent.msgId,
    threadId: "friend-1",
    threadType: "user",
    icon: "/-heart",
  });
  gw.emit("reaction", {
    threadId: "friend-1",
    threadType: "user",
    msgId: sent.msgId,
    icon: "/-heart",
    userId: "friend-1",
    isSelf: false,
  });
  const evt = await wait;
  const msg = evt.data as { message: { reactions: Record<string, string[]> } };
  expect(msg.message.reactions["/-heart"]).toContain("friend-1");
  a.close();
});

test("recall produces message.updated with recalled flag", async () => {
  const a = await accountClient(env, admin, slot);
  const sent = (await a.request("messages.sendText", {
    threadId: "friend-1",
    threadType: "user",
    cliId: "cli-recall",
    text: "recall me",
  })) as { msgId: string };
  const wait = a.waitEvent("message.updated");
  await a.request("messages.recall", {
    msgId: sent.msgId,
    threadId: "friend-1",
    threadType: "user",
  });
  const evt = await wait;
  const msg = (evt.data as { message: Message }).message;
  expect(msg.recalled).toBe(true);
  a.close();
});

test("sendMedia: multi-chunk blob upload reaches gateway intact", async () => {
  const a = await accountClient(env, admin, slot);
  const payload = crypto.getRandomValues(new Uint8Array(240_000));
  const stream = a.sendBlob(payload); // chunked into 60KB frames
  await a.request("messages.sendMedia", {
    threadId: "friend-1",
    threadType: "user",
    cliId: "cli-media",
    kind: "file",
    name: "big.bin",
    stream,
  });
  expect(gw.lastUpload).not.toBeNull();
  expect(gw.lastUpload!.length).toBe(payload.length);
  expect(Buffer.from(gw.lastUpload!).equals(Buffer.from(payload))).toBe(true);
  a.close();
});

test("media.fetch: download, multi-chunk, cache hit", async () => {
  const a = await accountClient(env, admin, slot);
  const url = "https://cdn.example.com/pic.png";
  const res = (await a.request("media.fetch", { url })) as {
    stream: number;
    size: number;
    contentType: string;
  };
  const blob = await a.waitBlob(res.stream);
  expect(new TextDecoder().decode(blob)).toContain("fake media bytes");
  const calls = gw.calls.filter((c) => c.method === "fetchMedia").length;
  await a.request("media.fetch", { url });
  expect(
    gw.calls.filter((c) => c.method === "fetchMedia").length,
  ).toBe(calls); // cache hit: no second gateway call
  a.close();
});

test("manifest shows account with unread count", async () => {
  const c = await controlClient(env, admin);
  const m = (await c.request("manifest.get")) as {
    accounts: { slot: string; unread: number; status: string }[];
  };
  const acct = m.accounts.find((a) => a.slot === slot)!;
  expect(acct.status).toBe("online");
  expect(acct.unread).toBeGreaterThan(0);
  c.close();
});

test("a second login of the same Zalo uid renews its slot instead of adding one", async () => {
  const before = env.server.store.listAccounts().length;
  const first = env.factory.gateways.at(-1)!;
  const res = await env.server.accounts.addAccount({
    credentials: { imei: "i2", cookie: [], userAgent: "ua" },
    self: { ...first.self },
  });
  expect(res.slot).toBe(slot);
  expect(env.server.store.listAccounts().length).toBe(before);
  // the old session is stopped: one live gateway per Zalo account
  expect(first.status).toBe("offline");
  gw = env.factory.gateways.at(-1)!;
  expect(gw).not.toBe(first);
  expect(env.server.accounts.gateway(slot)).toBe(gw);
});

test("replayed history is not re-counted as unread nor re-announced", async () => {
  const msg: Message = {
    id: "hist-1",
    cliId: "hist-1",
    threadId: "friend-9",
    threadType: "user",
    senderId: "friend-9",
    senderName: "F9",
    ts: 1700000000000,
    isSelf: false,
    kind: "text",
    text: "old",
    reactions: {},
    recalled: false,
  };
  gw.emit("history", [msg]);
  const unread = () =>
    env.server.store.getThread(slot, "friend-9", "user")?.unread;
  expect(unread()).toBe(1);
  const seq = env.server.store.latestSeq(slot);
  gw.emit("history", [{ ...msg }]);
  expect(unread()).toBe(1);
  expect(env.server.store.latestSeq(slot)).toBe(seq);
});

test("rotated credentials from the gateway are persisted", () => {
  gw.emit("credentials", {
    imei: "i2",
    cookie: [{ key: "zpw_sek", value: "rotated" }],
    userAgent: "ua",
  });
  expect(env.server.store.accountBySlot(slot)?.credentials_json).toContain(
    "rotated",
  );
});

test("users.avatar is fetched once and then served from the profiles cache", async () => {
  const a = await accountClient(env, admin, slot);
  const r1 = (await a.request("users.avatar", { uid: "u7" })) as { url: string };
  const r2 = (await a.request("users.avatar", { uid: "u7" })) as { url: string };
  expect(r1.url).toBe("https://example.com/full/u7.jpg");
  expect(r2.url).toBe(r1.url);
  expect(gw.calls.filter((c) => c.method === "fullAvatar").length).toBe(1);
  a.close();
});
