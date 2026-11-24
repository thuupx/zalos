import { test, expect } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Store } from "../src/store/db.ts";
import {
  createPhaseDState,
  phaseDResponse,
  phaseDStateSnapshot,
} from "../../mock/gateway/src/phased.ts";

function tempDir(): string {
  return mkdtempSync(join(tmpdir(), "zalos-phased-"));
}

test("threads created before Phase D gain hidden/archived/ttl columns", () => {
  const dir = tempDir();
  const old = new Database(join(dir, "zalos.db"));
  old.exec(`CREATE TABLE threads (
    slot TEXT NOT NULL,
    thread_id TEXT NOT NULL,
    type TEXT NOT NULL,
    name TEXT NOT NULL DEFAULT '',
    avatar_url TEXT NOT NULL DEFAULT '',
    last_msg_id TEXT,
    last_ts INTEGER NOT NULL DEFAULT 0,
    unread INTEGER NOT NULL DEFAULT 0,
    pinned INTEGER NOT NULL DEFAULT 0,
    muted INTEGER NOT NULL DEFAULT 0,
    marked_unread INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (slot, thread_id, type)
  )`);
  old
    .query("INSERT INTO threads (slot, thread_id, type) VALUES (?, ?, ?)")
    .run("slot", "friend-1", "user");
  old.close();

  const store = new Store(dir);
  const columns = store.db
    .query("PRAGMA table_info(threads)")
    .all() as { name: string }[];
  const names = columns.map((c) => c.name);
  expect(names).toContain("hidden");
  expect(names).toContain("archived");
  expect(names).toContain("auto_delete_ttl");

  const row = store.getThread("slot", "friend-1", "user")!;
  expect(row.hidden).toBe(0);
  expect(row.archived).toBe(0);
  expect(row.auto_delete_ttl).toBe(0);
  store.close();
});

test("labels are replaced as a clear whole set with a version", () => {
  const store = new Store(tempDir());
  const labels = [
    {
      id: 2,
      text: "Công việc",
      textKey: "",
      conversations: ["880000111"],
      color: "#2196f3",
      offset: 1,
      emoji: "",
      createTime: 1_700_000_000_000,
    },
    {
      id: 1,
      text: "Gia đình",
      textKey: "",
      conversations: ["777000222", "880000111"],
      color: "#e91e63",
      offset: 0,
      emoji: "",
      createTime: 1_700_000_000_000,
    },
  ];
  store.replaceLabels("slot", labels, 4, 1_700_000_000_500);
  expect(store.listLabels("slot")).toEqual([labels[1], labels[0]]);
  expect(store.labelState("slot")).toEqual({
    version: 4,
    lastUpdateTime: 1_700_000_000_500,
  });

  store.replaceLabels("slot", [], 5, 1_700_000_000_600);
  expect(store.listLabels("slot")).toEqual([]);
  expect(store.labelState("slot")).toEqual({
    version: 5,
    lastUpdateTime: 1_700_000_000_600,
  });
  store.close();
});

test("bulk delete scrubs every message from the event log in one pass", () => {
  const store = new Store(tempDir());
  for (const id of ["m1", "m2"]) {
    store.upsertMessage({
      slot: "slot",
      msgId: id,
      cliId: null,
      threadId: "friend-1",
      threadType: "user",
      senderId: "friend-1",
      ts: 1,
      isSelf: false,
      kind: "text",
      bodyJson: JSON.stringify({ id, body: { text: `secret-${id}` } }),
    });
    store.appendEvent("slot", "message.new", {
      message: { id, body: { text: `secret-${id}` } },
    });
  }
  store.deleteMessages("slot", ["m1", "m2"]);
  expect(store.getMessage("slot", "m1")).toBeNull();
  expect(store.getMessage("slot", "m2")).toBeNull();
  const events = store.allEventRows("slot");
  expect(events).toHaveLength(2);
  for (const ev of events) {
    const data = JSON.parse(ev.data_json) as {
      message: { id: string; body?: unknown };
    };
    expect(data.message.body).toBeUndefined();
  }
  store.close();
});

test("phase D mock seeds realistic fixtures for every endpoint", () => {
  const state = createPhaseDState();

  const hidden = phaseDResponse(
    state,
    "GET",
    "/api/hiddenconvers/get-all",
    {},
  );
  expect(hidden).toMatchObject({ ok: true });
  if (!hidden?.ok) throw new Error("unreachable");
  const hiddenData = hidden.data as { pin: string; threads: unknown[] };
  expect(hiddenData.pin).not.toBe("");
  expect(hiddenData.threads).toHaveLength(2);

  const archived = phaseDResponse(
    state,
    "GET",
    "/api/archivedchat/list",
    { version: 1 },
  );
  expect(archived?.ok).toBe(true);
  if (!archived?.ok) throw new Error("unreachable");
  expect((archived.data as { items: unknown[] }).items).toHaveLength(2);

  const labels = phaseDResponse(state, "GET", "/api/convlabel/get", {});
  if (!labels?.ok) throw new Error("unreachable");
  const labelData = labels.data as {
    labelData: string;
    version: number;
    lastUpdateTime: number;
  };
  expect(labelData.version).toBe(3);
  expect(JSON.parse(labelData.labelData)).toHaveLength(3);

  const ttl = phaseDResponse(
    state,
    "GET",
    "/api/conv/autodelete/getConvers",
    {},
  );
  if (!ttl?.ok) throw new Error("unreachable");
  expect((ttl.data as { convers: unknown[] }).convers).toHaveLength(2);

  const devices = phaseDResponse(state, "GET", "/api/devices/linked", {});
  if (!devices?.ok) throw new Error("unreachable");
  expect(
    (devices.data as { devices: { masterId: string } }).devices.masterId,
  ).toBe("777000111");

  expect(phaseDResponse(state, "GET", "/api/not/phased", {})).toBeNull();
});

test("phase D mock hidden state mutates and the PIN resets", () => {
  const state = createPhaseDState();
  phaseDResponse(state, "POST", "/api/hiddenconvers/add-remove", {
    add_threads: JSON.stringify([{ thread_id: "777000444", is_group: 0 }]),
    del_threads: JSON.stringify([{ thread_id: "880000111", is_group: 1 }]),
  });
  expect(state.hidden.threads).toEqual([
    { is_group: 0, thread_id: "777000222" },
    { is_group: 0, thread_id: "777000444" },
  ]);

  phaseDResponse(state, "GET", "/api/hiddenconvers/update-pin", {
    new_pin: "abcdefabcdefabcdefabcdefabcdefab",
  });
  expect(state.hidden.pin).toBe("abcdefabcdefabcdefabcdefabcdefab");
  phaseDResponse(state, "GET", "/api/hiddenconvers/reset", {});
  expect(state.hidden.pin).toBe("");

  const snapshot = phaseDStateSnapshot(state);
  expect(snapshot.hidden.pinSet).toBe(false);
  expect(JSON.stringify(snapshot)).not.toContain("abcdef");
});

test("phase D mock archive updates the list and advances the version", () => {
  const state = createPhaseDState();
  const before = state.archived.version;
  const res = phaseDResponse(state, "POST", "/api/archivedchat/update", {
    ids: [{ id: "777000444", type: 0 }],
    version: before,
    actionType: 0,
  });
  if (!res?.ok) throw new Error("unreachable");
  const data = res.data as { version: number; needSync: boolean };
  expect(data.needSync).toBe(false);
  expect(data.version).toBe(before + 1);
  expect(state.archived.items).toContainEqual({ id: "777000444", type: 0 });

  const removed = phaseDResponse(state, "POST", "/api/archivedchat/update", {
    ids: [{ id: "777000444", type: 0 }],
    version: data.version,
    actionType: 1,
  });
  if (!removed?.ok) throw new Error("unreachable");
  expect(state.archived.items).not.toContainEqual({
    id: "777000444",
    type: 0,
  });
});

test("phase D mock labels reject stale versions and advance on success", () => {
  const state = createPhaseDState();
  const stale = phaseDResponse(state, "POST", "/api/convlabel/update", {
    version: 1,
    labelData: JSON.stringify([]),
  });
  expect(stale).toMatchObject({ ok: false, code: 1005 });

  const labels = [
    {
      id: 9,
      text: "Du lịch",
      textKey: "",
      conversations: ["777000222"],
      color: "#ff9800",
      offset: 0,
      emoji: "",
      createTime: 1,
    },
  ];
  const ok = phaseDResponse(state, "POST", "/api/convlabel/update", {
    version: state.labels.version,
    labelData: JSON.stringify(labels),
  });
  if (!ok?.ok) throw new Error("unreachable");
  expect(state.labels.labelData).toEqual(labels);
  expect(state.labels.version).toBe(4);
  expect(
    (ok.data as { labelData: string }).labelData,
  ).toBe(JSON.stringify(labels));
});

test("phase D mock auto-delete updates the per-thread map", () => {
  const state = createPhaseDState();
  phaseDResponse(state, "POST", "/api/conv/autodelete/updateConvers", {
    threadId: "777000222",
    isGroup: 0,
    ttl: 0,
  });
  expect(
    state.autoDelete.convers.some((c) => c.destId === "777000222"),
  ).toBe(false);

  phaseDResponse(state, "POST", "/api/conv/autodelete/updateConvers", {
    threadId: "777000333",
    isGroup: 0,
    ttl: 1_209_600_000,
  });
  expect(state.autoDelete.convers).toContainEqual({
    destId: "777000333",
    isGroup: false,
    ttl: 1_209_600_000,
    createdAt: expect.any(Number),
  });
});

test("phase D mock device snapshot hides opaque crypto fields", () => {
  const state = createPhaseDState();
  const snapshot = phaseDStateSnapshot(state);
  const wire = JSON.stringify(snapshot);
  expect(wire).not.toContain("mock-enc-identity-opaque");
  expect(wire).not.toContain("mock-enc-signature-opaque");
  expect(wire).toContain("777000111");
});

test("messages created before per-message TTL gain expires_at", () => {
  const dir = tempDir();
  const old = new Database(join(dir, "zalos.db"));
  old.exec(`CREATE TABLE messages (
    slot TEXT NOT NULL,
    msg_id TEXT NOT NULL,
    cli_id TEXT,
    ref_json TEXT,
    thread_id TEXT NOT NULL,
    thread_type TEXT NOT NULL,
    sender_id TEXT NOT NULL,
    ts INTEGER NOT NULL,
    is_self INTEGER NOT NULL DEFAULT 0,
    kind TEXT NOT NULL,
    body_json TEXT NOT NULL,
    recalled INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (slot, msg_id)
  )`);
  old
    .query(
      `INSERT INTO messages (slot, msg_id, thread_id, thread_type, sender_id, ts, kind, body_json)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .run("slot", "m1", "friend-1", "user", "u1", 1, "text", "{}");
  old.close();

  const store = new Store(dir);
  const columns = store.db
    .query("PRAGMA table_info(messages)")
    .all() as { name: string }[];
  expect(columns.map((c) => c.name)).toContain("expires_at");
  const row = store.getMessage("slot", "m1")!;
  expect(row.expires_at).toBe(0);
  store.close();
});

test("per-message TTL expiry is separate from conversation auto-delete", () => {
  const store = new Store(tempDir());
  store.upsertThread({ slot: "slot", threadId: "friend-1", type: "user" });
  const base = {
    slot: "slot",
    cliId: null,
    threadId: "friend-1",
    threadType: "user",
    senderId: "me",
    ts: 1_000,
    isSelf: true,
    kind: "text",
    bodyJson: "{}",
  };
  store.upsertMessage({ ...base, msgId: "past", expiresAt: 1_500 });
  store.upsertMessage({ ...base, msgId: "future", expiresAt: 5_000 });
  store.upsertMessage({ ...base, msgId: "none", expiresAt: 0 });

  expect(
    store.expiredTtlMessages("slot", 2_000).map((m) => m.msg_id),
  ).toEqual(["past"]);
  // Conversation auto-delete is off, so nothing is auto-deleted yet.
  expect(store.expiredMessages("slot", 2_000)).toEqual([]);

  store.setThreadTtl("slot", "friend-1", "user", 500);
  const auto = store.expiredMessages("slot", 2_000).map((m) => m.msg_id);
  expect(auto.sort()).toEqual(["future", "none", "past"]);
  // The TTL query still only reports the row with its own deadline.
  expect(
    store.expiredTtlMessages("slot", 2_000).map((m) => m.msg_id),
  ).toEqual(["past"]);
  store.close();
});

test("phase D mock serves bank, link and quick-message fixtures", () => {
  const state = createPhaseDState();

  const banks = phaseDResponse(state, "GET", "/api/transfer/conf", {});
  expect(banks?.ok).toBe(true);
  expect(
    (banks as { data: { banks: unknown[] } }).data.banks,
  ).toHaveLength(3);

  const accounts = phaseDResponse(state, "GET", "/api/transfer/list", {
    page: 0,
    limit: 1,
  });
  expect(accounts?.ok).toBe(true);
  expect(
    (accounts as { data: { hasMore: boolean; myBanks: unknown[] } }).data,
  ).toMatchObject({ hasMore: true, total: 2 });
  expect(
    (accounts as { data: { myBanks: unknown[] } }).data.myBanks,
  ).toHaveLength(1);

  const link = phaseDResponse(state, "GET", "/api/message/parselink", {
    link: "https://example.com/a",
  });
  expect(link?.ok).toBe(true);
  const preview = (link as { data: { data: { href: string; thumb: string } } })
    .data.data;
  expect(preview.href).toBe("https://example.com/a");
  expect(preview.thumb).toContain("mock-media");

  const list = phaseDResponse(state, "GET", "/api/quickmessage/list", {});
  const listed = (
    list as { data: { cursor: number; version: number; items: unknown[] } }
  ).data;
  expect(listed).toMatchObject({ cursor: 2, version: 4 });
  expect(listed.items).toHaveLength(2);

  const created = phaseDResponse(state, "GET", "/api/quickmessage/create", {
    keyword: "moi",
    message: { title: "Mới", params: "" },
    type: 0,
  });
  expect(created?.ok).toBe(true);
  const createdData = (
    created as { data: { item: { id: number; keyword: string }; version: number } }
  ).data;
  expect(createdData.item.keyword).toBe("moi");
  expect(createdData.version).toBe(5);
  expect(state.quickMessages.items).toHaveLength(3);

  const updated = phaseDResponse(state, "GET", "/api/quickmessage/update", {
    itemId: createdData.item.id,
    keyword: "sua",
    message: { title: "Đã sửa", params: "" },
  });
  expect(updated?.ok).toBe(true);
  expect(state.quickMessages.items.at(-1)?.keyword).toBe("sua");

  const missing = phaseDResponse(state, "GET", "/api/quickmessage/update", {
    itemId: 9999,
    keyword: "x",
    message: { title: "x", params: "" },
  });
  expect(missing).toMatchObject({ ok: false, code: 212 });

  const removed = phaseDResponse(state, "GET", "/api/quickmessage/delete", {
    itemIds: [createdData.item.id],
  });
  expect(removed?.ok).toBe(true);
  expect(state.quickMessages.items).toHaveLength(2);
});
