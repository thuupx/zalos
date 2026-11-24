// Regressions for the account manager gaps found in the end-to-end RE
// audit: forward attribution, empty-history thread deletion, group
// membership events and delivery state across the self echo merge.
import { test, expect } from "bun:test";
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
import type { Message } from "../src/gateway/types.ts";

type Setup = {
  env: TestEnv;
  admin: PairedDevice;
  slot: string;
  gw: FakeGateway;
};

async function setup(): Promise<Setup> {
  const env = await makeEnv({ autoDeleteSweepMs: 0 });
  const admin = await pairDevice(env, { name: "admin", role: "admin" });
  const control = await controlClient(env, admin);
  const slot = await loginQrAccount(env, control);
  control.close();
  return { env, admin, slot, gw: env.factory.gateways.at(-1)! };
}

async function waitFor(cond: () => boolean, ms = 2000) {
  const end = Date.now() + ms;
  while (!cond()) {
    if (Date.now() > end) throw new Error("timed out waiting for condition");
    await Bun.sleep(5);
  }
}

function bodyOf(env: TestEnv, slot: string, msgId: string) {
  const row = env.server.store.getMessage(slot, msgId)!;
  return JSON.parse(row.body_json) as Record<string, unknown>;
}

test("forward carries the zca-js reference built from the stored raw message", async () => {
  const { env, admin, slot, gw } = await setup();
  try {
    const a = await accountClient(env, admin, slot);
    const src: Message = {
      id: "fwd-src",
      cliId: "fwd-cli",
      threadId: "friend-1",
      threadType: "user",
      senderId: "friend-1",
      senderName: "Friend One",
      ts: 1700000000123,
      isSelf: false,
      kind: "text",
      text: "forward me",
      reactions: {},
      recalled: false,
      raw: {
        msgId: "fwd-src",
        cliMsgId: "fwd-cli",
        uidFrom: "friend-1",
        idTo: "friend-1",
        msgType: "webchat",
        ts: 1700000000123,
        logSrcType: 7,
        fwLvl: 2,
      },
    };
    const newMsg = a.waitEvent("message.new");
    gw.emit("message", src);
    await newMsg;

    await a.request("messages.forward", {
      msgId: "fwd-src",
      threadId: "friend-1",
      threadType: "user",
      to: [{ threadId: "friend-2", threadType: "user" }],
      raw: "forward me",
    });
    const call = gw.calls.filter((c) => c.method === "forward").at(-1)!;
    expect(call.args[0]).toEqual({
      message: "forward me",
      reference: {
        id: "fwd-src",
        ts: 1700000000123,
        logSrcType: 7,
        fwLvl: 2,
      },
    });
    a.close();
  } finally {
    await env.cleanup();
  }
});

test("forward falls back to the documented web-client reference defaults", async () => {
  const { env, admin, slot, gw } = await setup();
  try {
    const a = await accountClient(env, admin, slot);
    const sent = (await a.request("messages.sendText", {
      threadId: "friend-1",
      threadType: "user",
      cliId: "fwd-default",
      text: "default reference",
    })) as { msgId: string };
    const body = bodyOf(env, slot, sent.msgId);
    await a.request("messages.forward", {
      msgId: sent.msgId,
      threadId: "friend-1",
      threadType: "user",
      to: [{ threadId: "friend-2", threadType: "user" }],
      raw: "default reference",
    });
    const call = gw.calls.filter((c) => c.method === "forward").at(-1)!;
    expect(call.args[0]).toEqual({
      message: "default reference",
      reference: {
        id: sent.msgId,
        ts: Number(body.ts),
        logSrcType: 0,
        fwLvl: 1,
      },
    });
    a.close();
  } finally {
    await env.cleanup();
  }
});

test("deleting a thread without a last message never sends an empty conver", async () => {
  const { env, admin, slot, gw } = await setup();
  try {
    env.server.store.upsertThread({
      slot,
      threadId: "empty-thread",
      type: "user",
    });
    const a = await accountClient(env, admin, slot);
    const del = a.waitEvent("thread.deleted");
    await a.request("threads.delete", {
      threadId: "empty-thread",
      threadType: "user",
    });
    await del;
    expect(gw.calls.some((c) => c.method === "deleteConversation")).toBe(false);
    expect(env.server.store.getThread(slot, "empty-thread", "user")).toBeNull();
    a.close();
  } finally {
    await env.cleanup();
  }
});

test("group membership events refresh member data and fold the profile", async () => {
  const { env, admin, slot, gw } = await setup();
  try {
    const a = await accountClient(env, admin, slot);
    const newMsg = a.waitEvent("message.new");
    gw.injectIncoming({
      threadId: "group-1",
      threadType: "group",
      text: "hello group",
    });
    await newMsg;
    // The authoritative refetch reports the same rename, so it cannot
    // overwrite the folded name with the fake default.
    gw.groupInfo = async () => ({
      id: "group-1",
      name: "Renamed Group",
      avatarUrl: "https://example.com/g1.png",
      memberIds: [gw.self.uid, "friend-1"],
      ownerId: gw.self.uid,
      adminIds: [],
    });
    const before = gw.calls.filter((c) => c.method === "groupMembersInfo")
      .length;
    const updated = a.waitEvent(
      "thread.updated",
      3000,
      (e) =>
        (e.data as { thread: { name: string } }).thread.name === "Renamed Group",
    );
    gw.injectGroup({
      act: "join",
      data: {
        groupId: "group-1",
        groupName: "Renamed Group",
        updateMembers: [{ id: "friend-2", dName: "New Member" }],
        groupSetting: null,
      },
    });
    await updated;
    await waitFor(
      () =>
        gw.calls.filter((c) => c.method === "groupMembersInfo").length > before,
    );
    const thread = env.server.store.getThread(slot, "group-1", "group")!;
    expect(thread.name).toBe("Renamed Group");
    // The roster refetch refreshed the profiles cache too.
    await waitFor(
      () =>
        env.server.store.getProfile(slot, "friend-1", "user")?.name ===
        "User friend-1",
    );
    a.close();
  } finally {
    await env.cleanup();
  }
});

test("a failed member refetch does not block the listener or drop the rename", async () => {
  const { env, admin, slot, gw } = await setup();
  try {
    const a = await accountClient(env, admin, slot);
    const newMsg = a.waitEvent("message.new");
    gw.injectIncoming({
      threadId: "group-2",
      threadType: "group",
      text: "hello group",
    });
    await newMsg;
    gw.groupInfo = async () => {
      throw new Error("group unavailable");
    };
    const before = gw.calls.filter((c) => c.method === "groupMembersInfo")
      .length;
    const updated = a.waitEvent(
      "thread.updated",
      3000,
      (e) =>
        (e.data as { thread: { name: string } }).thread.name ===
        "Renamed Offline",
    );
    gw.injectGroup({
      act: "join",
      data: {
        groupId: "group-2",
        groupName: "Renamed Offline",
        updateMembers: [{ id: "friend-3", dName: "Offline Member" }],
        groupSetting: null,
      },
    });
    await updated;
    await Bun.sleep(30);
    expect(env.server.store.getThread(slot, "group-2", "group")!.name).toBe(
      "Renamed Offline",
    );
    expect(gw.calls.filter((c) => c.method === "groupMembersInfo").length).toBe(
      before,
    );
    a.close();
  } finally {
    await env.cleanup();
  }
});

test("delivery folded before the self echo survives the echo merge", async () => {
  const { env, admin, slot, gw } = await setup();
  try {
    const a = await accountClient(env, admin, slot);
    const sent = (await a.request("messages.sendText", {
      threadId: "group-1",
      threadType: "group",
      cliId: "echo-race",
      text: "seen before echo",
    })) as { msgId: string; cliId: string };
    const seen = a.waitEvent(
      "message.updated",
      3000,
      (e) =>
        (
          (e.data as { message: { delivery?: { state?: string } } }).message
            .delivery?.state ?? ""
        ) === "seen",
    );
    gw.injectReceipt({
      threadId: "group-1",
      threadType: "group",
      kind: "seen",
      userIds: ["friend-1", "friend-2"],
      msgId: sent.msgId,
    });
    await seen;

    const echoed = a.waitEvent(
      "message.updated",
      3000,
      (e) =>
        (
          (
            (e.data as { message: { body?: { attachments?: unknown[] } } })
              .message.body?.attachments ?? []
          ).length > 0
        ),
    );
    gw.emit("message", {
      id: sent.msgId,
      cliId: sent.cliId,
      threadId: "group-1",
      threadType: "group",
      senderId: gw.self.uid,
      senderName: gw.self.displayName,
      ts: Date.now(),
      isSelf: true,
      kind: "image",
      attachments: [
        {
          kind: "image",
          url: "https://example.com/echo.png",
          name: "echo.png",
        },
      ],
      reactions: {},
      recalled: false,
    });
    const ev = await echoed;
    const updated = (ev.data as { message: { delivery?: unknown } }).message;
    expect(updated.delivery).toEqual({ state: "seen", seenBy: 2 });
    expect(bodyOf(env, slot, sent.msgId).delivery).toEqual({
      state: "seen",
      seenBy: 2,
    });
    a.close();
  } finally {
    await env.cleanup();
  }
});
