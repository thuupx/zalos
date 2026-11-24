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
import type { ContactCard, Message } from "../src/gateway/types.ts";

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

async function clients() {
  const a = await accountClient(env, admin, slot);
  const b = await accountClient(env, deviceB, slot);
  a.events.length = 0;
  b.events.length = 0;
  return { a, b };
}

test("contacts.findPhone and findUsername validate and return typed users", async () => {
  const { a, b } = await clients();
  await expect(a.request("contacts.findPhone", { phone: "  " })).rejects.toMatchObject(
    { code: "bad_request" },
  );
  gw.foundUsers.set("0900000000", {
    uid: "777000222",
    displayName: "Trần Thị Hoa",
    avatarUrl: "https://a/hoa.jpg",
  });
  const found = (await a.request("contacts.findPhone", {
    phone: "0900000000",
  })) as { user: { uid: string; displayName: string } };
  expect(found.user.uid).toBe("777000222");
  expect(found.user.displayName).toBe("Trần Thị Hoa");
  const spaced = (await a.request("contacts.findPhone", {
    phone: "0900 000-000",
  })) as { user: { uid: string } | null };
  expect(spaced.user?.uid).toBe("777000222");
  expect(
    (await a.request("contacts.findPhone", { phone: "0999999999" })) as {
      user: unknown;
    },
  ).toEqual({ user: null });

  const missing = a.request("contacts.findUsername", {});
  await expect(missing).rejects.toMatchObject({ code: "bad_request" });
  a.close();
  b.close();
});

test("contacts.requests splits received and sent, accept and cancel clear them", async () => {
  const { a, b } = await clients();
  gw.receivedRequests = [
    {
      uid: "777000444",
      displayName: "Phạm Minh Đức",
      avatarUrl: "https://a/duc.jpg",
      message: "Xin chào",
      ts: 1700000000000,
    },
  ];
  gw.sentRequests = [
    {
      uid: "777000666",
      displayName: "Đỗ Anh Tuấn",
      avatarUrl: "https://a/tuan.jpg",
      ts: 1700000000001,
    },
  ];
  const inbox = (await a.request("contacts.requests")) as {
    received: { uid: string }[];
    sent: { uid: string }[];
  };
  expect(inbox.received.map((r) => r.uid)).toEqual(["777000444"]);
  expect(inbox.sent.map((r) => r.uid)).toEqual(["777000666"]);

  const aChanged = a.waitEvent("contacts.changed");
  const bChanged = b.waitEvent("contacts.changed");
  await a.request("contacts.request.accept", { uid: "777000444" });
  expect((await aChanged).seq).toBeUndefined();
  await bChanged;
  expect(gw.receivedRequests).toEqual([]);

  await a.request("contacts.request.cancel", { uid: "777000666" });
  expect(gw.sentRequests).toEqual([]);
  a.close();
  b.close();
});

test("alias set and remove fan out contacts.changed and merge into contacts.list", async () => {
  const { a, b } = await clients();
  const aChanged = a.waitEvent("contacts.changed");
  const bChanged = b.waitEvent("contacts.changed");
  await a.request("contacts.setAlias", { uid: "friend-1", alias: "Bestie" });
  await aChanged;
  await bChanged;
  const list = (await a.request("contacts.list")) as {
    contacts: { uid: string; alias?: string }[];
  };
  expect(list.contacts.find((c) => c.uid === "friend-1")?.alias).toBe("Bestie");

  await a.request("contacts.removeAlias", { uid: "friend-1" });
  const again = (await a.request("contacts.list")) as {
    contacts: { uid: string; alias?: string }[];
  };
  expect(again.contacts.find((c) => c.uid === "friend-1")?.alias).toBeUndefined();
  a.close();
  b.close();
});

test("block, unblock and unfriend call the gateway and invalidate contacts", async () => {
  const { a, b } = await clients();
  const wait = a.waitEvent("contacts.changed");
  await a.request("contacts.block", { uid: "friend-1" });
  await wait;
  await a.request("contacts.unblock", { uid: "friend-1" });
  await a.request("contacts.remove", { uid: "friend-1" });
  const methods = gw.calls.map((c) => c.method);
  expect(methods).toContain("blockUser");
  expect(methods).toContain("unblockUser");
  expect(methods).toContain("removeFriend");
  a.close();
  b.close();
});

test("presence is read on demand from the gateway", async () => {
  const { a, b } = await clients();
  gw.presence = [
    { uid: "friend-1", status: "online", online: true },
    { uid: "friend-2", status: "offline", online: false },
  ];
  gw.lastSeen = { showOnlineStatus: true, lastOnline: 1700000000000 };
  const online = (await a.request("contacts.online")) as {
    presence: { uid: string; online: boolean }[];
  };
  expect(online.presence).toEqual(gw.presence);
  const last = (await a.request("contacts.lastOnline", { uid: "friend-1" })) as {
    showOnlineStatus: boolean;
    lastOnline: number;
  };
  expect(last).toEqual({ showOnlineStatus: true, lastOnline: 1700000000000 });
  await expect(a.request("contacts.lastOnline", {})).rejects.toMatchObject({
    code: "bad_request",
  });
  a.close();
  b.close();
});

test("messages.sendCard is idempotent by cliId and persists a typed card", async () => {
  const { a, b } = await clients();
  env.server.store.upsertProfile({
    slot,
    uid: "777000222",
    kind: "user",
    name: "Trần Thị Hoa",
    avatarUrl: "https://a/hoa.jpg",
  });
  const first = (await a.request("messages.sendCard", {
    threadId: "friend-1",
    threadType: "user",
    cliId: "cli-card",
    userId: "777000222",
    phoneNumber: "0900000000",
  })) as { msgId: string; cliId: string };
  const second = (await a.request("messages.sendCard", {
    threadId: "friend-1",
    threadType: "user",
    cliId: "cli-card",
    userId: "777000222",
    phoneNumber: "0900000000",
  })) as { msgId: string; cliId: string };
  expect(second).toEqual(first);
  expect(gw.calls.filter((c) => c.method === "sendCard").length).toBe(1);

  const evt = await a.waitEvent("message.new");
  // message.new carries the wire record: clear fields plus body/sealed.
  const msg = (evt.data as { message: Message & { body?: { card?: ContactCard } } })
    .message;
  expect(msg.kind).toBe("card");
  expect(msg.body?.card).toEqual({
    uid: "777000222",
    displayName: "Trần Thị Hoa",
    avatarUrl: "https://a/hoa.jpg",
    phone: "0900000000",
  } satisfies ContactCard);

  const page = (await a.request("messages.list", {
    threadId: "friend-1",
    threadType: "user",
  })) as { messages: (Message & { body?: { card?: ContactCard } })[] };
  const stored = page.messages.find((m) => m.id === first.msgId)!;
  expect(stored.kind).toBe("card");
  expect(stored.body?.card?.phone).toBe("0900000000");
  a.close();
  b.close();
});

test("threads.report validates reason and only sends content for other", async () => {
  const { a, b } = await clients();
  await expect(
    a.request("threads.report", {
      threadId: "friend-1",
      threadType: "user",
      reason: "spam",
    }),
  ).rejects.toMatchObject({ code: "bad_request" });
  await expect(
    a.request("threads.report", {
      threadId: "friend-1",
      threadType: "user",
      reason: "other",
    }),
  ).rejects.toMatchObject({ code: "bad_request" });

  const res = (await a.request("threads.report", {
    threadId: "friend-1",
    threadType: "user",
    reason: "sensitive",
  })) as { reportId: string };
  expect(res.reportId.startsWith("report-")).toBe(true);
  const call = gw.calls.findLast((c) => c.method === "sendReport")!;
  expect(call.args[2]).toEqual({ reason: "sensitive" });

  await a.request("threads.report", {
    threadId: "group-1",
    threadType: "group",
    reason: "other",
    content: "spam links",
  });
  const other = gw.calls.findLast((c) => c.method === "sendReport")!;
  expect(other.args[2]).toEqual({ reason: "other", content: "spam links" });
  a.close();
  b.close();
});

test("messages.deleteForAll enforces group, other-author and admin rules", async () => {
  const { a, b } = await clients();
  const incoming = gw.injectIncoming({
    threadId: "group-1",
    threadType: "group",
    senderId: "friend-1",
    text: "delete me",
  });

  // A plain member cannot delete someone else's message.
  gw.groupOwnerId = "someone-else";
  gw.groupAdminIds = [];
  await expect(
    a.request("messages.deleteForAll", {
      msgId: incoming.id,
      threadId: "group-1",
      threadType: "group",
    }),
  ).rejects.toMatchObject({ code: "forbidden" });
  expect(gw.calls.some((c) => c.method === "deleteMessageForAll")).toBe(false);

  // The owner can.
  gw.groupOwnerId = null;
  const ownerWait = a.waitEvent(
    "message.deleted",
    5000,
    (e) => (e.data as { msgId: string }).msgId === incoming.id,
  );
  await a.request("messages.deleteForAll", {
    msgId: incoming.id,
    threadId: "group-1",
    threadType: "group",
  });
  const ownerEvt = await ownerWait;
  expect(ownerEvt.seq).toBeGreaterThan(0);
  expect(env.server.store.getMessage(slot, incoming.id)).toBeNull();

  // A deputy can.
  const deputyMsg = gw.injectIncoming({
    threadId: "group-1",
    threadType: "group",
    senderId: "friend-1",
    text: "delete me too",
  });
  gw.groupOwnerId = "someone-else";
  gw.groupAdminIds = [gw.self.uid];
  const wait = a.waitEvent(
    "message.deleted",
    5000,
    (e) => (e.data as { msgId: string }).msgId === deputyMsg.id,
  );
  await a.request("messages.deleteForAll", {
    msgId: deputyMsg.id,
    threadId: "group-1",
    threadType: "group",
  });
  await wait;
  expect(env.server.store.getMessage(slot, deputyMsg.id)).toBeNull();
  expect(gw.calls.filter((c) => c.method === "deleteMessageForAll").length).toBe(
    2,
  );

  // One-to-one threads are rejected by the RPC.
  const direct = gw.injectIncoming({
    threadId: "friend-1",
    threadType: "user",
    senderId: "friend-1",
  });
  await expect(
    a.request("messages.deleteForAll", {
      msgId: direct.id,
      threadId: "friend-1",
      threadType: "user",
    }),
  ).rejects.toMatchObject({ code: "bad_request" });

  // Own messages are rejected: recall is the path for those.
  gw.groupOwnerId = null;
  gw.groupAdminIds = [];
  const own = (await a.request("messages.sendText", {
    threadId: "group-1",
    threadType: "group",
    cliId: "cli-own-group",
    text: "mine",
  })) as { msgId: string };
  await expect(
    a.request("messages.deleteForAll", {
      msgId: own.msgId,
      threadId: "group-1",
      threadType: "group",
    }),
  ).rejects.toMatchObject({ code: "bad_request" });

  // A message from another thread cannot be smuggled in by id.
  const other = gw.injectIncoming({
    threadId: "group-2",
    threadType: "group",
    senderId: "friend-1",
  });
  await expect(
    a.request("messages.deleteForAll", {
      msgId: other.id,
      threadId: "group-1",
      threadType: "group",
    }),
  ).rejects.toMatchObject({ code: "not_found" });
  a.close();
  b.close();
});
