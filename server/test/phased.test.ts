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
import type { FakeGateway } from "../src/gateway/fake.ts";
import type { Label, Thread } from "../src/gateway/types.ts";
import type { Client } from "./support/client.ts";

let env: TestEnv;
let admin: PairedDevice;
let deviceB: PairedDevice;
let slot: string;
let gw: FakeGateway;

beforeAll(async () => {
  // The timer is off for the RPC tests; the lifecycle test uses its own
  // env with a short interval.
  env = await makeEnv({ autoDeleteSweepMs: 0 });
  admin = await pairDevice(env, { name: "admin" });
  deviceB = await pairDevice(env, { name: "b" });
  const control = await controlClient(env, admin);
  slot = await loginQrAccount(env, control);
  env.server.store.setAcl(deviceB.deviceId, [slot]);
  gw = env.factory.gateways.at(-1)!;
  control.close();
});

afterAll(() => env.cleanup());

async function clients() {
  const a = await accountClient(env, admin, slot);
  const b = await accountClient(env, deviceB, slot);
  a.events.length = 0;
  b.events.length = 0;
  return { a, b };
}

async function seedThread(
  a: Client,
  threadId: string,
  threadType: "user" | "group" = "user",
) {
  await a.request("messages.sendText", {
    threadId,
    threadType,
    cliId: `cli-${threadId}-${Date.now()}-${Math.random()}`,
    text: "seed",
  });
}

function threadOf(evt: { data?: unknown }): Thread {
  return (evt.data as { thread: Thread }).thread;
}

function label(id: number, text: string, conversations: string[]): Label {
  return {
    id,
    text,
    textKey: "",
    conversations,
    color: "#2196f3",
    offset: id,
    emoji: "",
    createTime: 1_700_000_000_000,
  };
}

test("hidden conversations persist, fan out and never expose the PIN", async () => {
  const { a, b } = await clients();
  await seedThread(a, "friend-1");
  a.events.length = 0;
  b.events.length = 0;

  const aUpd = a.waitEvent(
    "thread.updated",
    5000,
    (e) => threadOf(e).id === "friend-1" && threadOf(e).hidden,
  );
  const bUpd = b.waitEvent(
    "thread.updated",
    5000,
    (e) => threadOf(e).id === "friend-1" && threadOf(e).hidden,
  );
  await a.request("threads.setHidden", {
    threadId: "friend-1",
    threadType: "user",
    hidden: true,
  });
  const evt = await aUpd;
  expect(evt.seq).toBeGreaterThan(0);
  await bUpd;

  let list = (await a.request("threads.list")) as { threads: Thread[] };
  expect(list.threads.find((t) => t.id === "friend-1")?.hidden).toBe(true);

  const hidden = (await a.request("hidden.list")) as {
    pinSet: boolean;
    threads: unknown[];
  };
  expect(hidden.pinSet).toBe(false);
  expect(hidden.threads).toEqual([
    { threadId: "friend-1", threadType: "user" },
  ]);

  await expect(
    a.request("threads.setHidden", {
      threadId: "friend-1",
      threadType: "user",
    }),
  ).rejects.toMatchObject({ code: "bad_request" });
  await expect(
    a.request("threads.setHidden", {
      threadId: "friend-1",
      threadType: "user",
      hidden: "yes",
    }),
  ).rejects.toMatchObject({ code: "bad_request" });
  await expect(
    a.request("threads.setHidden", {
      threadId: "",
      threadType: "user",
      hidden: true,
    }),
  ).rejects.toMatchObject({ code: "bad_request" });

  await expect(a.request("hidden.setPin", { pin: "12a4" })).rejects.toMatchObject(
    { code: "bad_request" },
  );
  await expect(a.request("hidden.setPin", { pin: 1234 })).rejects.toMatchObject(
    { code: "bad_request" },
  );
  const pinRes = (await a.request("hidden.setPin", { pin: "1234" })) as {
    ok: boolean;
  };
  expect(pinRes).toEqual({ ok: true });
  expect(JSON.stringify(pinRes)).not.toContain("1234");
  // Even the test double keeps only a redacted marker.
  expect(gw.calls.find((c) => c.method === "setHiddenPin")!.args).toEqual([
    "****",
  ]);
  expect(gw.hiddenPinSets).toBe(1);

  const withPin = (await a.request("hidden.list")) as {
    pinSet: boolean;
    threads: unknown[];
  };
  expect(withPin.pinSet).toBe(true);
  expect(JSON.stringify(withPin)).not.toContain("1234");

  // No pin column and no pin material in server metadata.
  const columns = env.server.store.db
    .query("PRAGMA table_info(threads)")
    .all() as { name: string }[];
  expect(
    columns.some((c) => /(^|_)pin($|_)/.test(c.name.toLowerCase())),
  ).toBe(false);
  const meta = env.server.store.db
    .query("SELECT key, value FROM meta")
    .all() as { key: string; value: string }[];
  expect(JSON.stringify(meta)).not.toContain("1234");

  await a.request("hidden.resetPin");
  expect(
    ((await a.request("hidden.list")) as { pinSet: boolean }).pinSet,
  ).toBe(false);

  await a.request("threads.setHidden", {
    threadId: "friend-1",
    threadType: "user",
    hidden: false,
  });
  list = (await a.request("threads.list")) as { threads: Thread[] };
  expect(list.threads.find((t) => t.id === "friend-1")?.hidden).toBe(false);
  a.close();
  b.close();
});

test("archived conversations persist, fan out and list from the gateway", async () => {
  const { a, b } = await clients();
  await seedThread(a, "group-1", "group");
  a.events.length = 0;
  b.events.length = 0;

  const aUpd = a.waitEvent(
    "thread.updated",
    5000,
    (e) => threadOf(e).id === "group-1" && threadOf(e).archived,
  );
  const bUpd = b.waitEvent(
    "thread.updated",
    5000,
    (e) => threadOf(e).id === "group-1" && threadOf(e).archived,
  );
  const res = (await a.request("threads.setArchived", {
    threadId: "group-1",
    threadType: "group",
    archived: true,
  })) as { ok: boolean; needResync: boolean; version: number };
  expect(res.ok).toBe(true);
  expect(res.needResync).toBe(false);
  expect(res.version).toBe(2);
  const evt = await aUpd;
  expect(evt.seq).toBeGreaterThan(0);
  await bUpd;

  const list = (await a.request("threads.list")) as { threads: Thread[] };
  expect(list.threads.find((t) => t.id === "group-1")?.archived).toBe(true);

  const archive = (await a.request("archive.list")) as {
    threads: unknown[];
    version: number;
  };
  expect(archive.version).toBe(2);
  expect(archive.threads).toContainEqual({
    threadId: "group-1",
    threadType: "group",
  });

  await expect(
    a.request("threads.setArchived", {
      threadId: "group-1",
      threadType: "group",
      archived: 1,
    }),
  ).rejects.toMatchObject({ code: "bad_request" });

  await a.request("threads.setArchived", {
    threadId: "group-1",
    threadType: "group",
    archived: false,
  });
  const after = (await a.request("threads.list")) as { threads: Thread[] };
  expect(after.threads.find((t) => t.id === "group-1")?.archived).toBe(false);
  a.close();
  b.close();
});

test("labels list, update with versioning, conflict and clear metadata", async () => {
  const { a, b } = await clients();
  const first = label(1, "Gia đình", ["friend-1"]);
  gw.labelsValue = { labels: [first], version: 5, lastUpdateTime: 111 };

  const listed = (await a.request("labels.list")) as {
    labels: Label[];
    version: number;
    lastUpdateTime: number;
  };
  expect(listed).toEqual(gw.labelsValue);
  // Labels are clear metadata, readable server-side.
  expect(env.server.store.listLabels(slot)).toEqual([first]);
  expect(env.server.store.labelState(slot)).toEqual({
    version: 5,
    lastUpdateTime: 111,
  });

  const second = label(2, "Công việc", ["group-1"]);
  const aChanged = a.waitEvent(
    "labels.changed",
    5000,
    (e) => (e.data as { version: number }).version === 6,
  );
  const bChanged = b.waitEvent(
    "labels.changed",
    5000,
    (e) => (e.data as { version: number }).version === 6,
  );
  const updated = (await a.request("labels.update", {
    labels: [second],
    version: 5,
  })) as { labels: Label[]; version: number };
  expect(updated.version).toBe(6);
  expect(updated.labels).toEqual([second]);
  const evt = await aChanged;
  expect(evt.seq).toBeGreaterThan(0);
  await bChanged;
  expect(env.server.store.listLabels(slot)).toEqual([second]);

  // Stale version: conflict, no gateway write, no local change.
  await expect(
    a.request("labels.update", { labels: [first], version: 5 }),
  ).rejects.toMatchObject({ code: "conflict" });
  expect(gw.labelsValue.version).toBe(6);
  expect(env.server.store.listLabels(slot)).toEqual([second]);

  // Validation.
  await expect(
    a.request("labels.update", { labels: "nope", version: 6 }),
  ).rejects.toMatchObject({ code: "bad_request" });
  await expect(
    a.request("labels.update", {
      labels: [{ ...first, text: "  " }],
      version: 6,
    }),
  ).rejects.toMatchObject({ code: "bad_request" });
  await expect(
    a.request("labels.update", { labels: [first, { ...first }], version: 6 }),
  ).rejects.toMatchObject({ code: "bad_request" });
  await expect(
    a.request("labels.update", { labels: [first], version: -1 }),
  ).rejects.toMatchObject({ code: "bad_request" });

  // Two whole-set writes at the same version: the per-account queue lets
  // exactly one through.
  gw.labelsValue = { labels: [first], version: 10, lastUpdateTime: 222 };
  const third = label(3, "Bạn bè", []);
  const results = await Promise.allSettled([
    a.request("labels.update", { labels: [second], version: 10 }),
    b.request("labels.update", { labels: [third], version: 10 }),
  ]);
  expect(results.filter((r) => r.status === "fulfilled")).toHaveLength(1);
  const rejected = results.find((r) => r.status === "rejected");
  expect((rejected as PromiseRejectedResult).reason).toMatchObject({
    code: "conflict",
  });
  expect(gw.labelsValue.version).toBe(11);
  a.close();
  b.close();
});

test("auto-delete stores the TTL, expires old content and scrubs events", async () => {
  const { a, b } = await clients();
  await seedThread(a, "friend-1");
  const recent = gw.injectIncoming({
    threadId: "friend-1",
    ts: Date.now(),
    text: "recent",
  });
  const old = gw.injectIncoming({
    threadId: "friend-1",
    ts: Date.now() - 2 * 86_400_000,
    text: "old secret",
  });
  const otherOld = gw.injectIncoming({
    threadId: "friend-2",
    ts: Date.now() - 2 * 86_400_000,
    text: "no ttl",
  });
  a.events.length = 0;
  b.events.length = 0;

  let checkpoints = 0;
  const realCheckpoint = env.server.store.checkpoint.bind(env.server.store);
  env.server.store.checkpoint = () => {
    checkpoints++;
    realCheckpoint();
  };

  const aDeleted = a.waitEvent(
    "message.deleted",
    5000,
    (e) => (e.data as { msgId: string }).msgId === old.id,
  );
  const bDeleted = b.waitEvent(
    "message.deleted",
    5000,
    (e) => (e.data as { msgId: string }).msgId === old.id,
  );
  const aUpdated = a.waitEvent(
    "thread.updated",
    5000,
    (e) =>
      threadOf(e).id === "friend-1" &&
      threadOf(e).autoDeleteTtl === 86_400_000 &&
      threadOf(e).lastMessage?.id === recent.id,
  );
  const res = (await a.request("threads.setAutoDelete", {
    threadId: "friend-1",
    threadType: "user",
    ttl: 86_400_000,
  })) as { ok: boolean };
  expect(res).toEqual({ ok: true });
  const delEvt = await aDeleted;
  expect(delEvt.seq).toBeGreaterThan(0);
  await bDeleted;
  await aUpdated;
  expect(checkpoints).toBeGreaterThan(0);

  expect(env.server.store.getMessage(slot, old.id)).toBeNull();
  expect(env.server.store.getMessage(slot, recent.id)).not.toBeNull();
  // A thread without a TTL is untouched.
  expect(env.server.store.getMessage(slot, otherOld.id)).not.toBeNull();

  // The deleted message's event-log content is gone, the entry remains.
  const oldEvent = env.server.store
    .allEventRows(slot)
    .map((r) => JSON.parse(r.data_json) as { message?: Record<string, unknown> })
    .find((d) => d.message?.id === old.id);
  expect(oldEvent).toBeDefined();
  expect(oldEvent!.message!.body).toBeUndefined();
  expect(oldEvent!.message!.sealed).toBeUndefined();

  const list = (await a.request("threads.list")) as { threads: Thread[] };
  const friend = list.threads.find((t) => t.id === "friend-1")!;
  expect(friend.autoDeleteTtl).toBe(86_400_000);
  expect(friend.lastMessage?.id).toBe(recent.id);
  expect(friend.lastTs).toBe(recent.ts);

  const auto = (await a.request("threads.autoDelete")) as {
    conversations: unknown[];
  };
  expect(auto.conversations).toContainEqual({
    threadId: "friend-1",
    threadType: "user",
    ttl: 86_400_000,
  });

  await expect(
    a.request("threads.setAutoDelete", {
      threadId: "friend-1",
      threadType: "user",
      ttl: 30_000,
    }),
  ).rejects.toMatchObject({ code: "bad_request" });
  await expect(
    a.request("threads.setAutoDelete", {
      threadId: "friend-1",
      threadType: "user",
      ttl: "1d",
    }),
  ).rejects.toMatchObject({ code: "bad_request" });

  // Two sweeps in the same tick share one promise, so timers can never
  // overlap.
  const p1 = env.server.accounts.sweepAutoDelete(slot);
  const p2 = env.server.accounts.sweepAutoDelete(slot);
  expect(p1).toBe(p2);
  await p1;

  env.server.store.checkpoint = realCheckpoint;
  a.close();
  b.close();
});

test("syncConversationState converges hidden, archived and auto-delete", async () => {
  const { a, b } = await clients();
  await seedThread(a, "friend-1");
  await seedThread(a, "group-1", "group");
  a.events.length = 0;
  b.events.length = 0;

  gw.syncPinned = [{ threadId: "friend-1", threadType: "user" }];
  gw.syncMuted = [{ threadId: "group-1", threadType: "group" }];
  gw.hiddenThreads = [{ threadId: "friend-1", threadType: "user" }];
  gw.archivedThreads = [{ threadId: "group-1", threadType: "group" }];
  gw.autoDeleteConversations = [
    { threadId: "friend-1", threadType: "user", ttl: 604_800_000 },
  ];

  const friendUpd = a.waitEvent(
    "thread.updated",
    5000,
    (e) =>
      threadOf(e).id === "friend-1" &&
      threadOf(e).hidden &&
      threadOf(e).pinned &&
      threadOf(e).autoDeleteTtl === 604_800_000,
  );
  const groupUpd = a.waitEvent(
    "thread.updated",
    5000,
    (e) =>
      threadOf(e).id === "group-1" &&
      threadOf(e).archived &&
      threadOf(e).muted,
  );
  gw.emit("status", "online");
  await friendUpd;
  await groupUpd;

  let list = (await a.request("threads.list")) as { threads: Thread[] };
  const friend = list.threads.find((t) => t.id === "friend-1")!;
  expect(friend.hidden).toBe(true);
  expect(friend.pinned).toBe(true);
  expect(friend.autoDeleteTtl).toBe(604_800_000);
  const group = list.threads.find((t) => t.id === "group-1")!;
  expect(group.archived).toBe(true);
  expect(group.muted).toBe(true);

  // Zalo-side truth changes: the next sync clears them again.
  gw.syncPinned = [];
  gw.syncMuted = [];
  gw.hiddenThreads = [];
  gw.archivedThreads = [];
  gw.autoDeleteConversations = [];
  const cleared = a.waitEvent(
    "thread.updated",
    5000,
    (e) =>
      threadOf(e).id === "friend-1" &&
      !threadOf(e).hidden &&
      !threadOf(e).pinned &&
      threadOf(e).autoDeleteTtl === 0,
  );
  gw.emit("status", "online");
  await cleared;
  list = (await a.request("threads.list")) as { threads: Thread[] };
  const clearedFriend = list.threads.find((t) => t.id === "friend-1")!;
  expect(clearedFriend.hidden).toBe(false);
  expect(clearedFriend.pinned).toBe(false);
  expect(clearedFriend.autoDeleteTtl).toBe(0);
  a.close();
  b.close();
});

test("a failed sync section keeps local hidden, archive and TTL", async () => {
  const { a, b } = await clients();
  await seedThread(a, "friend-9");
  gw.syncPinned = [];
  gw.syncMuted = [];
  gw.hiddenThreads = [{ threadId: "friend-9", threadType: "user" }];
  gw.archivedThreads = [{ threadId: "friend-9", threadType: "user" }];
  gw.autoDeleteConversations = [
    { threadId: "friend-9", threadType: "user", ttl: 86_400_000 },
  ];
  const seeded = a.waitEvent(
    "thread.updated",
    5000,
    (e) =>
      threadOf(e).id === "friend-9" &&
      threadOf(e).hidden &&
      threadOf(e).archived &&
      threadOf(e).autoDeleteTtl === 86_400_000,
  );
  gw.emit("status", "online");
  await seeded;

  // Hidden/archive/auto-delete endpoints fail: their sections are absent.
  // A pin change still produces an event, so the sync is known to finish.
  const realSync = gw.syncConversationState.bind(gw);
  gw.syncConversationState = async () => ({
    pinned: [{ threadId: "friend-9", threadType: "user" }],
    muted: [],
  });
  a.events.length = 0;
  const pinnedEvt = a.waitEvent(
    "thread.updated",
    5000,
    (e) =>
      threadOf(e).id === "friend-9" &&
      threadOf(e).pinned &&
      threadOf(e).hidden &&
      threadOf(e).archived &&
      threadOf(e).autoDeleteTtl === 86_400_000,
  );
  gw.emit("status", "online");
  await pinnedEvt;

  const list = (await a.request("threads.list")) as { threads: Thread[] };
  const friend = list.threads.find((t) => t.id === "friend-9")!;
  expect(friend.hidden).toBe(true);
  expect(friend.archived).toBe(true);
  expect(friend.autoDeleteTtl).toBe(86_400_000);

  gw.syncConversationState = realSync;
  gw.syncPinned = [];
  gw.hiddenThreads = [];
  gw.archivedThreads = [];
  gw.autoDeleteConversations = [];
  a.close();
  b.close();
});

test("a failed pin and mute sync keeps local pinned and muted", async () => {
  const { a, b } = await clients();
  await seedThread(a, "friend-7");
  gw.syncPinned = [{ threadId: "friend-7", threadType: "user" }];
  gw.syncMuted = [{ threadId: "friend-7", threadType: "user" }];
  gw.hiddenThreads = [];
  gw.archivedThreads = [];
  gw.autoDeleteConversations = [];
  const seeded = a.waitEvent(
    "thread.updated",
    5000,
    (e) =>
      threadOf(e).id === "friend-7" &&
      threadOf(e).pinned &&
      threadOf(e).muted,
  );
  gw.emit("status", "online");
  await seeded;

  // The pin and mute endpoints fail, so their sections are absent. A hidden
  // change still produces an event, so the sync is known to finish.
  const realSync = gw.syncConversationState.bind(gw);
  gw.syncConversationState = async () => ({
    hidden: [{ threadId: "friend-7", threadType: "user" }],
  });
  a.events.length = 0;
  const hiddenEvt = a.waitEvent(
    "thread.updated",
    5000,
    (e) =>
      threadOf(e).id === "friend-7" &&
      threadOf(e).hidden &&
      threadOf(e).pinned &&
      threadOf(e).muted,
  );
  gw.emit("status", "online");
  await hiddenEvt;

  const list = (await a.request("threads.list")) as { threads: Thread[] };
  const friend = list.threads.find((t) => t.id === "friend-7")!;
  expect(friend.pinned).toBe(true);
  expect(friend.muted).toBe(true);

  gw.syncConversationState = realSync;
  gw.syncPinned = [];
  gw.syncMuted = [];
  gw.hiddenThreads = [];
  a.close();
  b.close();
});

test("linked devices are read-only and drop opaque crypto fields", async () => {
  const { a, b } = await clients();
  gw.linkedDevicesValue = {
    masterId: gw.self.uid,
    lastUpdateTs: 1_700_000_000_000,
    companions: [
      { name: "iPhone 15", platform: "ios", current: true },
      { summary: "object(3)" },
    ],
  };
  const res = (await a.request("account.linkedDevices")) as {
    devices: unknown;
  };
  expect(res).toEqual({ devices: gw.linkedDevicesValue });
  expect(JSON.stringify(res)).not.toContain("SECRET");
  a.close();
  b.close();
});

test("manifest advertises the Phase D capabilities", async () => {
  const control = await controlClient(env, admin);
  const manifest = (await control.request("manifest.get")) as {
    accounts: { slot: string; capabilities: string[] }[];
  };
  const account = manifest.accounts.find((x) => x.slot === slot)!;
  expect(account.capabilities).toEqual(
    expect.arrayContaining([
      "archive",
      "hidden",
      "labels",
      "autoDelete",
      "zaloDevices",
    ]),
  );
  control.close();
});

test("auto-delete sweeper starts and stops with the account lifecycle", async () => {
  const tenv = await makeEnv({ autoDeleteSweepMs: 25 });
  const tAdmin = await pairDevice(tenv, { name: "admin" });
  const tControl = await controlClient(tenv, tAdmin);
  const tSlot = await loginQrAccount(tenv, tControl);
  const tgw = tenv.factory.gateways.at(-1)!;
  const tClient = await accountClient(tenv, tAdmin, tSlot);

  expect(tenv.server.accounts.hasAutoDeleteSweeper(tSlot)).toBe(true);

  // Seed a TTL directly, then let the timer find the old message.
  tenv.server.store.upsertThread({
    slot: tSlot,
    threadId: "friend-1",
    type: "user",
  });
  tenv.server.store.setThreadTtl(tSlot, "friend-1", "user", 86_400_000);
  const old = tgw.injectIncoming({
    threadId: "friend-1",
    ts: Date.now() - 2 * 86_400_000,
    text: "timer secret",
  });
  const deadline = Date.now() + 3000;
  while (
    tenv.server.store.getMessage(tSlot, old.id) !== null &&
    Date.now() < deadline
  ) {
    await Bun.sleep(20);
  }
  expect(tenv.server.store.getMessage(tSlot, old.id)).toBeNull();

  // Manual stop/start and remove/close both clear the timer.
  tenv.server.accounts.stopAutoDeleteSweeper(tSlot);
  expect(tenv.server.accounts.hasAutoDeleteSweeper(tSlot)).toBe(false);
  tenv.server.accounts.startAutoDeleteSweeper(tSlot);
  expect(tenv.server.accounts.hasAutoDeleteSweeper(tSlot)).toBe(true);
  await tenv.server.accounts.removeAccount(tSlot);
  expect(tenv.server.accounts.hasAutoDeleteSweeper(tSlot)).toBe(false);

  tenv.server.accounts.startAutoDeleteSweeper(tSlot);
  expect(tenv.server.accounts.hasAutoDeleteSweeper(tSlot)).toBe(true);
  tClient.close();
  tControl.close();
  await tenv.cleanup();
  expect(tenv.server.accounts.hasAutoDeleteSweeper(tSlot)).toBe(false);
});
