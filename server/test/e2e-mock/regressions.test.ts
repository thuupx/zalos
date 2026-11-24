// Regression e2e against the offline Zalo mock (see e2e.test.ts): one
// incoming message is one event and one row across reconnects, restarts
// and re-logins; thread names; group deputies; group history on demand;
// full-size avatars; rotated cookies survive a restart.
import {
  test,
  expect,
  beforeAll,
  afterAll,
  describe,
  setDefaultTimeout,
} from "bun:test";
import {
  E2E,
  MOCK_URL,
  dockerOk,
  makeMockEnv,
  mockCtl,
  journal,
  sleep,
  mockMsg,
  type MockEnv,
} from "./support.ts";
import {
  pairDevice,
  controlClient,
  accountClient,
  setVaultKey,
  openRecord,
  type PairedDevice,
  type TestEnv,
} from "../support/helpers.ts";
import type { Client, ClientEvent } from "../support/client.ts";

setDefaultTimeout(120_000);

type Rec = {
  id: string;
  threadId: string;
  sealed?: string;
  body?: Record<string, unknown>;
};
type ThreadRec = {
  id: string;
  type: string;
  name: string;
  unread: number;
  lastMessage: Rec | null;
};

describe.skipIf(!E2E || !dockerOk)("e2e-regressions", () => {
  let env: MockEnv;
  let admin: PairedDevice;
  let second: PairedDevice;
  let ctrl: Client;
  let a: Client;
  let b: Client;
  let slot: string;
  const tenv = () => env as unknown as TestEnv;

  const textOf = (r: Rec): string => {
    try {
      return String(openRecord(tenv(), slot, r).text ?? "");
    } catch {
      return "";
    }
  };
  const newText = (e: ClientEvent, text: string) =>
    e.event === "message.new" &&
    textOf((e.data as { message: Rec }).message) === text;
  const status = (e: ClientEvent) =>
    ((e.data ?? {}) as { status?: string }).status;

  async function qrLogin(): Promise<string> {
    ctrl.events = [];
    const img = ctrl.waitEvent("loginQr.image", 15000);
    const done = ctrl.waitEvent("loginQr.done", 30000);
    ctrl.request("accounts.loginQr.start").catch(() => {});
    await img;
    await mockCtl("/qr/scan");
    await ctrl.waitEvent("loginQr.scanned", 15000);
    await mockCtl("/qr/confirm");
    return ((await done).data as { slot: string }).slot;
  }

  async function openChannels() {
    a = await accountClient(tenv(), admin, slot);
    b = await accountClient(tenv(), second, slot);
  }

  // Online in the manifest and exactly one live listener socket at Zalo.
  async function online(): Promise<void> {
    for (let i = 0; i < 160; i++) {
      const m = (await ctrl.request("manifest.get")) as {
        accounts: { slot: string; status: string }[];
      };
      const st = (await (await fetch(`${MOCK_URL}/__mock/state`)).json()) as {
        sockets: number;
      };
      if (
        m.accounts.find((x) => x.slot === slot)?.status === "online" &&
        st.sockets === 1
      ) {
        await sleep(300);
        return;
      }
      await sleep(250);
    }
    throw new Error("account never came back online");
  }

  async function storedCount(text: string): Promise<number> {
    const res = (await a.request("messages.list", {
      threadId: "777000222",
      threadType: "user",
      limit: 100,
    })) as { messages: Rec[] };
    return res.messages.filter((m) => textOf(m) === text).length;
  }

  // Injects one message from Trần Thị Hoa and asserts both devices saw
  // exactly one message.new for it and exactly one row is stored.
  async function injectOnce(text: string): Promise<Record<string, unknown>> {
    const fromA = a.events.length;
    const fromB = b.events.length;
    const res = await mockCtl("/events/message", {
      type: "user",
      uidFrom: "777000222",
      idTo: "777000111",
      dName: "Trần Thị Hoa",
      content: text,
    });
    await a.waitEvent("message.new", 10000, (e) => newText(e, text));
    await b.waitEvent("message.new", 10000, (e) => newText(e, text));
    // Late duplicates (a second listener, a replay) would land here.
    await sleep(1500);
    expect(a.events.slice(fromA).filter((e) => newText(e, text)).length).toBe(1);
    expect(b.events.slice(fromB).filter((e) => newText(e, text)).length).toBe(1);
    expect(await storedCount(text)).toBe(1);
    return res;
  }

  async function threadsList(): Promise<ThreadRec[]> {
    return ((await a.request("threads.list")) as { threads: ThreadRec[] })
      .threads;
  }

  beforeAll(async () => {
    await mockCtl("/reset");
    env = await makeMockEnv();
    admin = await pairDevice(tenv(), { name: "admin", role: "admin" });
    ctrl = await controlClient(tenv(), admin);
    slot = await qrLogin();
    await setVaultKey(tenv(), ctrl, slot);
    second = await pairDevice(tenv(), { name: "second", role: "admin" });
    await openChannels();
    await online();
  });
  afterAll(async () => {
    a?.close();
    b?.close();
    ctrl?.close();
    await env?.cleanup();
  });

  test("A1: one injected message is one message.new per device and one row", async () => {
    await injectOnce("A1 một lần thôi");
  });

  test("A1: still one after a ws kick (3000) and reconnect", async () => {
    a.events = [];
    const displaced = a.waitEvent("account.status", 15000, (e) =>
      status(e) === "displaced",
    );
    await mockCtl("/ws/kick", { reason: 3000 });
    await displaced;
    await online();
    await injectOnce("A1 sau khi bị đá");
  });

  test("A1: still one after an abnormal close and backoff reconnect", async () => {
    a.events = [];
    const down = a.waitEvent("account.status", 15000, (e) =>
      status(e) === "reconnecting",
    );
    await mockCtl("/ws/kick", { reason: "abnormal" });
    await down;
    await online();
    await injectOnce("A1 sau khi rớt mạng");
  });

  // First profile lookup of the run: the getprofiles stub answers with
  // every profile, so only the uid-keyed pick yields the right name.
  test("A2: a name resolved later arrives via thread.updated and matches users.info", async () => {
    a.events = [];
    const named = a.waitEvent("thread.updated", 10000, (e) => {
      const t = (e.data as { thread: ThreadRec }).thread;
      return t.id === "777000444" && t.name !== "";
    });
    await mockCtl("/events/message", {
      type: "user",
      uidFrom: "777000444",
      idTo: "777000111",
      dName: "Phạm Minh Đức",
      content: "A2 tên đến sau",
    });
    const t = (await named).data as { thread: ThreadRec };
    expect(t.thread.name).toBe("Phạm Minh Đức");
    const listed = (await threadsList()).find((x) => x.id === "777000444");
    expect(listed?.name).toBe("Phạm Minh Đức");
    const users = (await a.request("users.info", { uids: ["777000444"] })) as {
      users: { uid: string; displayName: string }[];
    };
    expect(users.users[0]?.displayName).toBe("Phạm Minh Đức");
  });

  test("A2: a thread whose peer is cached never goes out unnamed", async () => {
    await a.request("users.info", { uids: ["777000333"] });
    a.events = [];
    await mockCtl("/events/message", {
      type: "user",
      uidFrom: "777000333",
      idTo: "777000111",
      dName: "Lê Quốc Bảo",
      content: "A2 tên có sẵn",
    });
    await a.waitEvent("message.new", 10000, (e) => newText(e, "A2 tên có sẵn"));
    await sleep(800);
    const updates = a.events
      .filter((e) => e.event === "thread.updated")
      .map((e) => (e.data as { thread: ThreadRec }).thread)
      .filter((t) => t.id === "777000333");
    expect(updates.length).toBeGreaterThan(0);
    for (const t of updates) expect(t.name).toBe("Lê Quốc Bảo");
  });

  test("A2: group threads get their name; one name per uid across stubs", async () => {
    const memberUids = ["777000444", "777000555", "777000666"];
    // users.info first so its names come from getprofiles, not groups.info.
    const users = (await a.request("users.info", { uids: memberUids })) as {
      users: { uid: string; displayName: string }[];
    };
    const named = a.waitEvent("thread.updated", 10000, (e) => {
      const t = (e.data as { thread: ThreadRec }).thread;
      return t.id === "880000222" && t.name !== "";
    });
    await mockCtl("/events/message", {
      type: "group",
      uidFrom: "777000555",
      idTo: "880000222",
      dName: "Vũ Thu Hằng",
      content: "A2 nhóm mới",
    });
    const t = ((await named).data as { thread: ThreadRec }).thread;
    expect(t.name).toBe("Team Dự Án Mới");
    const g = (await a.request("groups.info", { groupId: "880000222" })) as {
      group: { name: string; members: { uid: string; displayName: string }[] };
    };
    expect(g.group.name).toBe(t.name);
    const contacts = (await a.request("contacts.list")) as {
      contacts: { uid: string; displayName: string }[];
    };
    for (const uid of memberUids) {
      const names = new Set([
        users.users.find((u) => u.uid === uid)?.displayName,
        g.group.members.find((m) => m.uid === uid)?.displayName,
        contacts.contacts.find((c) => c.uid === uid)?.displayName,
      ]);
      expect([...names]).toHaveLength(1);
      expect([...names][0]).not.toBe("");
    }
  });

  test("C1: groups.info maps adminIds to deputy, creator to owner", async () => {
    const g = (await a.request("groups.info", { groupId: "880000111" })) as {
      group: { members: { uid: string; role: string }[] };
    };
    const role = (uid: string) =>
      g.group.members.find((m) => m.uid === uid)?.role;
    expect(role("777000111")).toBe("owner");
    expect(role("777000222")).toBe("deputy");
    expect(role("777000333")).toBe("member");
  });

  test("C2: paging past stored group history fetches, seals and de-dupes", async () => {
    await mockCtl("/reset");
    const before = (await threadsList()).find((x) => x.id === "880000222");
    const page = { threadId: "880000222", threadType: "group", limit: 2 };
    const p1 = (await a.request("messages.list", page)) as {
      messages: Rec[];
      hasMore: boolean;
    };
    // 1 live message stored + 3 from history; newest two first.
    expect(p1.messages.map(textOf)).toEqual([
      "A2 nhóm mới",
      "Mọi người xem lại biên bản nhé",
    ]);
    expect(p1.hasMore).toBe(true);
    for (const m of p1.messages) {
      expect(m.sealed).toBeTruthy();
      expect(m.body).toBeUndefined();
    }
    const oldest = p1.messages[1] as Rec & { ts: number };
    const p2 = (await a.request("messages.list", {
      ...page,
      before: { ts: oldest.ts, id: oldest.id },
    })) as { messages: Rec[]; hasMore: boolean };
    expect(p2.messages.map(textOf)).toEqual([
      "Đính kèm tài liệu tuần trước",
      "Tin nhắn cũ từ lịch sử nhóm",
    ]);
    expect(p2.hasMore).toBe(false);
    // The first page again: same rows, no second fetch, no duplicates.
    const again = (await a.request("messages.list", {
      ...page,
      limit: 10,
    })) as { messages: Rec[] };
    expect(new Set(again.messages.map((m) => m.id)).size).toBe(4);
    const fetches = (await journal()).filter((e) =>
      e.request.url.includes("/api/group/history"),
    );
    expect(fetches.length).toBe(1);
    expect(JSON.stringify(fetches[0]?.request.headers)).toContain("880000222");
    // Old history is not unread and does not become the last message.
    const after = (await threadsList()).find((x) => x.id === "880000222");
    expect(before).toBeDefined();
    expect(after?.unread).toBe(before?.unread ?? -1);
    expect(after?.lastMessage?.id).toBe(before?.lastMessage?.id ?? "");
  });

  test("C4: users.avatar returns the full-size url, cached", async () => {
    await mockCtl("/reset");
    const r1 = (await a.request("users.avatar", { uid: "777000222" })) as {
      url: string;
    };
    expect(r1.url).toBe("https://avatar-mock.zdn.vn/full/u777000222.jpg");
    const r2 = (await a.request("users.avatar", { uid: "777000222" })) as {
      url: string;
    };
    expect(r2.url).toBe(r1.url);
    const hits = (await journal()).filter((e) =>
      e.request.url.includes("/api/social/profile/avatar"),
    );
    expect(hits.length).toBe(1);
    // No full-size copy at Zalo: falls back to the 240 px profile avatar.
    const r3 = (await a.request("users.avatar", { uid: "777000666" })) as {
      url: string;
    };
    expect(r3.url).toBe("https://avatar-mock.zdn.vn/240/u777000666.jpg");
    await expect(a.request("users.avatar", {})).rejects.toThrow();
  });

  test("C3 + A1: rotated cookie is persisted and used after a restart; replayed history is not re-counted", async () => {
    await mockCtl("/reset");
    await mockCtl("/cookie/rotate", { name: "zpw_sek", value: "rotated-e2e-1" });
    // Any Zalo call carries the Set-Cookie back.
    await a.request("users.avatar", { uid: "777000333" });
    await sleep(300);
    const creds = env.server.store.accountBySlot(slot)?.credentials_json ?? "";
    expect(creds).toContain("rotated-e2e-1");
    await mockCtl("/reset");

    // Zalo replays already stored messages on the next listener start.
    const live = await injectOnce("A1 trước khi khởi động lại");
    await mockCtl("/old-messages/user", {
      msgs: [
        mockMsg({
          msgId: live.msgId,
          cliMsgId: live.cliMsgId,
          content: "A1 trước khi khởi động lại",
        }),
      ],
    });
    const unreadBefore =
      (await threadsList()).find((x) => x.id === "777000222")?.unread ?? -1;

    a.close();
    b.close();
    ctrl.close();
    const root = (env as MockEnv & { __root?: Uint8Array }).__root;
    await env.cleanup();
    env = await makeMockEnv(env.dir);
    (env as MockEnv & { __root?: Uint8Array }).__root = root;
    ctrl = await controlClient(tenv(), admin);
    await openChannels();
    await online();
    await sleep(1000);

    const login = (await journal()).find((e) =>
      e.request.url.includes("getLoginInfo"),
    );
    const cookie = Object.entries(login?.request.headers ?? {}).find(
      ([k]) => k.toLowerCase() === "cookie",
    )?.[1];
    expect(String(cookie)).toContain("zpw_sek=rotated-e2e-1");

    expect(await storedCount("A1 trước khi khởi động lại")).toBe(1);
    expect(
      (await threadsList()).find((x) => x.id === "777000222")?.unread,
    ).toBe(unreadBefore);
    await injectOnce("A1 sau khi khởi động lại");
  });

  test("A1: a second QR login of the same Zalo account reuses its slot", async () => {
    await mockCtl("/reset");
    const again = await qrLogin();
    expect(again).toBe(slot);
    const m = (await ctrl.request("manifest.get")) as {
      accounts: { slot: string; uid: string }[];
    };
    expect(m.accounts.filter((x) => x.uid === "777000111").length).toBe(1);
    await online();
    await injectOnce("A1 sau khi đăng nhập lại");
  });
});
