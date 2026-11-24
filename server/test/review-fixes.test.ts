// Regressions for the server review: cliId defaults and in-flight
// idempotency, delete thread checks, label version conflicts, archive
// resync, revocation secure deletion and sweep/account lifecycle races.
import { test, expect } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Store } from "../src/store/db.ts";
import { RpcError } from "../src/tunnel/rpc.ts";
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

type Setup = {
  env: TestEnv;
  admin: PairedDevice;
  member: PairedDevice;
  slot: string;
  gw: FakeGateway;
};

async function setup(): Promise<Setup> {
  const env = await makeEnv({ autoDeleteSweepMs: 0 });
  const admin = await pairDevice(env, { name: "admin", role: "admin" });
  const member = await pairDevice(env, { name: "member" });
  const control = await controlClient(env, admin);
  const slot = await loginQrAccount(env, control);
  env.server.store.setAcl(member.deviceId, [slot]);
  control.close();
  return { env, admin, member, slot, gw: env.factory.gateways.at(-1)! };
}

async function waitFor(cond: () => boolean, ms = 2000) {
  const end = Date.now() + ms;
  while (!cond()) {
    if (Date.now() > end) throw new Error("timed out waiting for condition");
    await Bun.sleep(5);
  }
}

test("omitted cliId is empty, never the literal undefined", async () => {
  const { env, admin, slot, gw } = await setup();
  try {
    const a = await accountClient(env, admin, slot);
    const first = (await a.request("messages.sendText", {
      threadId: "no-cli",
      threadType: "user",
      text: "one",
    })) as { msgId: string };
    const second = (await a.request("messages.sendText", {
      threadId: "no-cli",
      threadType: "user",
      text: "two",
    })) as { msgId: string };
    expect(second.msgId).not.toBe(first.msgId);

    const mediaCliIds: (string | undefined)[] = [];
    const origMedia = gw.sendMedia.bind(gw);
    gw.sendMedia = async (...args) => {
      mediaCliIds.push(args[5]);
      return origMedia(...args);
    };
    const stream = a.sendBlob(new Uint8Array([1, 2, 3, 4]));
    await a.request("messages.sendMedia", {
      threadId: "no-cli",
      threadType: "user",
      kind: "file",
      name: "no-cli.bin",
      stream,
    });
    await a.request("messages.sendSticker", {
      threadId: "no-cli",
      threadType: "user",
      sticker: { id: 1, cateId: 2, type: 1, url: "" },
    });

    // The gateway receives an empty key, and no row stores the literal.
    expect(mediaCliIds).toEqual([""]);
    expect(env.server.store.getMessageByCliId(slot, "undefined")).toBeNull();
    const rows = env.server.store.listMessages(slot, "no-cli", "user", 10);
    expect(rows).toHaveLength(4);
    expect(rows.some((r) => r.cli_id === "undefined")).toBe(false);
    a.close();
  } finally {
    await env.cleanup();
  }
});

test("concurrent duplicate sends share one gateway call", async () => {
  const { env, admin, member, slot, gw } = await setup();
  try {
    const a = await accountClient(env, admin, slot);
    const b = await accountClient(env, member, slot);
    const orig = gw.sendText.bind(gw);
    let release: () => void = () => {};
    const gate = new Promise<void>((r) => {
      release = r;
    });
    let calls = 0;
    gw.sendText = async (...args) => {
      calls++;
      await gate;
      return orig(...args);
    };

    const send = (c: typeof a, text: string) =>
      c.request("messages.sendText", {
        threadId: "race-thread",
        threadType: "user",
        cliId: "cli-race",
        text,
      });
    const p1 = send(a, "one");
    await waitFor(() => calls === 1);
    const p2 = send(b, "one");
    // Generous wait so the second request has surely reached the manager
    // before the first is allowed to finish.
    await Bun.sleep(200);
    expect(calls).toBe(1);
    release();
    const [r1, r2] = (await Promise.all([p1, p2])) as {
      msgId: string;
      cliId: string;
    }[];
    expect(r2).toEqual(r1);
    expect(gw.calls.filter((c) => c.method === "sendText")).toHaveLength(1);
    expect(env.server.store.listMessages(slot, "race-thread", "user", 10))
      .toHaveLength(1);
    a.close();
    b.close();
  } finally {
    await env.cleanup();
  }
});

test("concurrent duplicate sends with different method reject as conflict", async () => {
  const { env, admin, member, slot, gw } = await setup();
  try {
    const a = await accountClient(env, admin, slot);
    const b = await accountClient(env, member, slot);
    const orig = gw.sendText.bind(gw);
    let release: () => void = () => {};
    const gate = new Promise<void>((r) => {
      release = r;
    });
    let calls = 0;
    gw.sendText = async (...args) => {
      calls++;
      await gate;
      return orig(...args);
    };

    const p1 = a.request("messages.sendText", {
      threadId: "race-cross",
      threadType: "user",
      cliId: "cli-cross",
      text: "text first",
    });
    await waitFor(() => calls === 1);
    const p2 = b.request("messages.sendSticker", {
      threadId: "race-cross",
      threadType: "user",
      cliId: "cli-cross",
      sticker: { id: 1, cateId: 2, type: 1, url: "" },
    });
    await expect(p2).rejects.toMatchObject({ code: "conflict" });
    expect(gw.calls.filter((c) => c.method === "sendSticker")).toHaveLength(0);
    release();
    const r1 = (await p1) as { msgId: string; cliId: string };
    expect(r1.cliId).toBe("cli-cross");
    a.close();
    b.close();
  } finally {
    await env.cleanup();
  }
});

test("a failed send drops the in-flight marker so a retry sends", async () => {
  const { env, admin, slot, gw } = await setup();
  try {
    const a = await accountClient(env, admin, slot);
    const orig = gw.sendText.bind(gw);
    let attempts = 0;
    gw.sendText = async (...args) => {
      attempts++;
      if (attempts === 1) throw new RpcError("error", "zalo down");
      return orig(...args);
    };
    const params = {
      threadId: "retry-thread",
      threadType: "user",
      cliId: "cli-retry",
      text: "again",
    };
    await expect(a.request("messages.sendText", params)).rejects.toMatchObject({
      code: "error",
    });
    const ok = (await a.request("messages.sendText", params)) as {
      msgId: string;
    };
    expect(ok.msgId).not.toBe("");
    expect(attempts).toBe(2);
    expect(env.server.store.listMessages(slot, "retry-thread", "user", 10))
      .toHaveLength(1);
    a.close();
  } finally {
    await env.cleanup();
  }
});

test("messages.delete refuses a mismatched thread", async () => {
  const { env, admin, slot, gw } = await setup();
  try {
    const a = await accountClient(env, admin, slot);
    const sent = (await a.request("messages.sendText", {
      threadId: "del-a",
      threadType: "user",
      cliId: "cli-del-mismatch",
      text: "keep me",
    })) as { msgId: string };
    await expect(
      a.request("messages.delete", {
        msgId: sent.msgId,
        threadId: "del-b",
        threadType: "user",
      }),
    ).rejects.toMatchObject({ code: "not_found" });
    await expect(
      a.request("messages.delete", {
        msgId: sent.msgId,
        threadId: "del-a",
        threadType: "group",
      }),
    ).rejects.toMatchObject({ code: "not_found" });
    expect(gw.calls.filter((c) => c.method === "deleteMessage")).toHaveLength(0);
    expect(env.server.store.getMessage(slot, sent.msgId)).not.toBeNull();
    a.close();
  } finally {
    await env.cleanup();
  }
});

test("Zalo label version conflict 1005 maps to conflict", async () => {
  const { ZcaGateway } = await import("../src/gateway/zca.ts");
  const api = {
    updateLabels: async () => {
      throw Object.assign(new Error("label version mismatch"), { code: 1005 });
    },
    listener: { on: () => {}, stop: () => {}, start: () => {} },
    getCookie: () => ({ toJSON: () => ({ cookies: [] }) }),
  };
  const gw = new ZcaGateway(
    { imei: "i", cookie: {}, userAgent: "ua" },
    { uid: "me", displayName: "me", avatarUrl: "" },
    async () => api as never,
  );
  await gw.start();
  await expect(gw.updateLabels([], 1)).rejects.toMatchObject({
    code: "conflict",
  });
  await gw.stop();
});

test("archive needResync triggers a conversation-state sync", async () => {
  const { env, admin, slot, gw } = await setup();
  try {
    const a = await accountClient(env, admin, slot);
    await a.request("messages.sendText", {
      threadId: "arc-1",
      threadType: "group",
      cliId: "cli-arc-seed",
      text: "seed",
    });
    gw.archivedThreads = [{ threadId: "arc-1", threadType: "group" }];
    const orig = gw.updateArchivedChatList.bind(gw);
    gw.updateArchivedChatList = async (archived, threads) => {
      await orig(archived, threads);
      return { needResync: true, version: gw.archiveVersion };
    };
    const before = gw.calls.filter(
      (c) => c.method === "syncConversationState",
    ).length;
    const res = (await a.request("threads.setArchived", {
      threadId: "arc-1",
      threadType: "group",
      archived: true,
    })) as { needResync: boolean };
    expect(res.needResync).toBe(true);
    expect(
      gw.calls.filter((c) => c.method === "syncConversationState").length,
    ).toBe(before + 1);
    const list = (await a.request("threads.list")) as {
      threads: { id: string; archived: boolean }[];
    };
    expect(list.threads.find((t) => t.id === "arc-1")?.archived).toBe(true);
    a.close();
  } finally {
    await env.cleanup();
  }
});

test("device revocation clears old key bytes from the database file", () => {
  const dir = mkdtempSync(join(tmpdir(), "zalos-revoke-"));
  const store = new Store(dir);
  try {
    const psk = "ab".repeat(32);
    const publicKey = "cd".repeat(32);
    const device = store.createDevice({
      name: "gone",
      publicKey,
      psk,
      role: "member",
    });
    // Force the key material onto disk before revocation.
    store.checkpoint();
    expect(readFileSync(join(dir, "zalos.db")).includes(psk)).toBe(true);

    // Secure deletion is a SQL-level effect: the overwrite must happen with
    // secure_delete on, then VACUUM rebuilds the file so freed pages cannot
    // still hold the old key material.
    const execs: string[] = [];
    const origExec = store.db.exec.bind(store.db);
    store.db.exec = (sql: string) => {
      execs.push(sql);
      return origExec(sql);
    };

    store.revokeDevice(device.id);
    expect(execs).toContain("PRAGMA secure_delete=ON");
    expect(execs).toContain("VACUUM");
    expect(store.deviceById(device.id)!.psk).toBe("");
    for (const f of ["zalos.db", "zalos.db-wal"]) {
      const path = join(dir, f);
      if (!existsSync(path)) continue;
      const bytes = readFileSync(path);
      expect(bytes.includes(psk)).toBe(false);
      expect(bytes.includes(publicKey)).toBe(false);
    }
  } finally {
    store.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

type SweepInternals = {
  runTtlSweep(slot: string): Promise<number>;
  deleteExpired(
    slot: string,
    expired: { msg_id: string; thread_id: string; thread_type: string }[],
  ): Promise<number>;
};

// Gate the TTL sweep after it has captured its expired rows: a lifecycle
// call that deletes account rows meanwhile would let the sweep write
// orphan events for a slot that is gone.
function gateTtlSweep(env: TestEnv, slot: string) {
  const internals = env.server.accounts as unknown as SweepInternals;
  let release: () => void = () => {};
  const gate = new Promise<void>((r) => {
    release = r;
  });
  internals.runTtlSweep = async (s) => {
    const expired = env.server.store.expiredTtlMessages(s, Date.now());
    await gate;
    return internals.deleteExpired(s, expired);
  };
  const seed = (msgId: string) => {
    env.server.store.upsertThread({
      slot,
      threadId: "ttl-race",
      type: "user",
    });
    env.server.store.upsertMessage({
      slot,
      msgId,
      cliId: null,
      threadId: "ttl-race",
      threadType: "user",
      senderId: "me",
      ts: 1,
      isSelf: true,
      kind: "text",
      bodyJson: JSON.stringify({ senderName: "me", text: "expire" }),
      expiresAt: 1,
    });
  };
  return { release, seed };
}

test("removeAccount waits for an in-flight sweep and clears its counters", async () => {
  const { env, slot } = await setup();
  const sweepGate = gateTtlSweep(env, slot);
  try {
    sweepGate.seed("expired-remove");
    const sweep = env.server.accounts.sweepTtl(slot);
    const removed = env.server.accounts.removeAccount(slot);
    await Bun.sleep(30);
    // Rows are still there while the sweep holds the account open.
    expect(env.server.store.accountBySlot(slot)).not.toBeNull();
    sweepGate.release();
    await removed;
    await sweep;
    expect(env.server.store.accountBySlot(slot)).toBeNull();
    expect(env.server.store.eventsSince(slot, 0)).toHaveLength(0);
    expect(
      env.server.store.db
        .query("SELECT 1 x FROM event_counters WHERE slot = ?")
        .get(slot),
    ).toBeNull();
  } finally {
    sweepGate.release();
    await env.cleanup();
  }
});

test("logoutAccount waits for an in-flight sweep", async () => {
  const { env, slot } = await setup();
  const sweepGate = gateTtlSweep(env, slot);
  try {
    sweepGate.seed("expired-logout");
    const sweep = env.server.accounts.sweepTtl(slot);
    const loggingOut = env.server.accounts.logoutAccount(slot);
    await Bun.sleep(30);
    expect(env.server.store.accountBySlot(slot)?.status).not.toBe(
      "needs_login",
    );
    sweepGate.release();
    await loggingOut;
    await sweep;
    expect(env.server.store.accountBySlot(slot)?.status).toBe("needs_login");
  } finally {
    sweepGate.release();
    await env.cleanup();
  }
});

test("close waits for an in-flight sweep", async () => {
  const { env, slot } = await setup();
  const sweepGate = gateTtlSweep(env, slot);
  sweepGate.seed("expired-close");
  const sweep = env.server.accounts.sweepTtl(slot);
  let closed = false;
  const closing = env.server.accounts.close().then(() => {
    closed = true;
  });
  try {
    await Bun.sleep(30);
    expect(closed).toBe(false);
    sweepGate.release();
    await closing;
    await sweep;
    expect(closed).toBe(true);
  } finally {
    sweepGate.release();
    await env.cleanup();
  }
});
