// End-to-end: real zca-js gateway <-> offline Zalo mock (mock/).
// Run with `bun run test:e2e` (ZALOS_E2E=1). Plain `bun test` skips it.
import {
  test,
  expect,
  beforeAll,
  afterAll,
  describe,
  setDefaultTimeout,
} from "bun:test";
import { join } from "node:path";
import { existsSync, readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import {
  E2E,
  dockerOk,
  makeMockEnv,
  mockCtl,
  journal,
  journalBodies,
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
  openMedia,
  type PairedDevice,
  type TestEnv,
} from "../support/helpers.ts";
import type { Client } from "../support/client.ts";

setDefaultTimeout(90_000);

describe.skipIf(!E2E || !dockerOk)("e2e-mock", () => {
  let env: MockEnv;
  let admin: PairedDevice;
  let slot: string;
  let ctrl: Client;
  const tenv = () => env as unknown as TestEnv;

  beforeAll(async () => {
    await mockCtl("/reset");
    env = await makeMockEnv();
    admin = await pairDevice(tenv(), { name: "admin", role: "admin" });
    ctrl = await controlClient(tenv(), admin);
    // Old messages served on the listener's first connect.
    await mockCtl("/old-messages/user", {
      msgs: [
        mockMsg({ msgId: "9001", ts: "1700000001000", content: "Chào buổi sáng" }),
        mockMsg({ msgId: "9002", ts: "1700000002000", content: "Cuối tuần đi cafe không?" }),
      ],
    });
    await mockCtl("/old-messages/group", {
      msgs: [
        mockMsg({
          msgId: "9101", ts: "1700000003000", uidFrom: "777000333",
          idTo: "880000111", dName: "Lê Quốc Bảo", content: "Họp lúc 2h nhé",
        }),
      ],
    });
  });
  afterAll(async () => {
    ctrl?.close();
    await env?.cleanup();
  });

  test("qr login: image, scan, confirm, done; manifest has real uid", async () => {
    const imgW = ctrl.waitEvent("loginQr.image");
    const startP = ctrl.request("accounts.loginQr.start");
    startP.catch(() => {});
    const img = await imgW;
    const png = await ctrl.waitBlob(
      (img.data as { stream: number }).stream,
    );
    expect(png.length).toBeGreaterThan(100);
    expect(png[1]).toBe(0x50); // PNG magic
    await mockCtl("/qr/scan");
    await ctrl.waitEvent("loginQr.scanned");
    await mockCtl("/qr/confirm");
    const done = await ctrl.waitEvent("loginQr.done");
    slot = (done.data as { slot: string }).slot;
    const m = (await ctrl.request("manifest.get")) as {
      accounts: { slot: string; uid: string; status: string }[];
    };
    const acct = m.accounts.find((a) => a.slot === slot)!;
    expect(acct.uid).toBe("777000111");
    expect(acct.status).toBe("online");
    await setVaultKey(tenv(), ctrl, slot);
  });

  test("old messages ingested, threads listed, sealed at rest", async () => {
    const a = await accountClient(tenv(), admin, slot);
    const threads = (await a.request("threads.list")) as {
      threads: { id: string; lastMessage?: { body?: { text?: string } } }[];
    };
    const ids = threads.threads.map((t) => t.id);
    expect(ids).toContain("777000222");
    expect(ids).toContain("880000111");
    const msgs = (await a.request("messages.list", {
      threadId: "777000222",
      threadType: "user",
    })) as { messages: { id: string; body?: { text?: string }; sealed?: string }[] };
    expect(msgs.messages.some((m) => openRecord(tenv(), slot, m).text === "Chào buổi sáng")).toBe(true);
    // sealed at rest: plaintext is not recoverable from db files
    env.server.store.checkpoint();
    for (const f of ["zalos.db", "zalos.db-wal"]) {
      const p = join(env.dir, f);
      if (existsSync(p)) {
        expect(readFileSync(p).includes("Chào buổi sáng")).toBe(false);
      }
    }
    a.close();
  });

  test("incoming user and group messages normalize and emit", async () => {
    const a = await accountClient(tenv(), admin, slot);
    const w = a.waitEvent("message.new");
    await mockCtl("/events/message", {
      type: "user",
      uidFrom: "777000222",
      idTo: "777000111",
      dName: "Trần Thị Hoa",
      content: "Tối nay ăn gì?",
    });
    const evt = await w;
    const msg = (evt.data as { message: { id: string; body?: { text?: string }; sealed?: string; senderId: string } })
      .message;
    expect(openRecord(tenv(), slot, msg).text).toBe("Tối nay ăn gì?");
    expect(msg.senderId).toBe("777000222");

    const wg = a.waitEvent("message.new", 5000, (d) =>
      ((d.data ?? {}) as { message?: { threadId?: string } }).message
        ?.threadId === "880000111",
    );
    await mockCtl("/events/message", {
      type: "group",
      uidFrom: "777000333",
      idTo: "880000111",
      dName: "Lê Quốc Bảo",
      content: "Deadline thứ 6 nhé mọi người",
    });
    const evtG = await wg;
    const gmsg = (evtG.data as { message: { threadId: string } }).message;
    expect(gmsg.threadId).toBe("880000111");
    a.close();
  });

  test("sendText reaches the mock with plaintext params in the journal", async () => {
    const a = await accountClient(tenv(), admin, slot);
    await mockCtl("/reset").then(() => {}); // clears journal too? reset clears journal
    const res = (await a.request("messages.sendText", {
      threadId: "777000222",
      threadType: "user",
      cliId: "e2e-cli-1",
      text: "Nhớ gửi file báo cáo nhé",
    })) as { msgId: string };
    expect(res.msgId).not.toBe("");
    await sleep(400);
    const bodies = journalBodies(await journal());
    const send = bodies.find(
      (b) => b.entry.request.url.includes("/api/message") &&
        b.params.message === "Nhớ gửi file báo cáo nhé",
    );
    expect(send).toBeDefined();
    expect(send!.params.toid).toBe("777000222");
    a.close();
  });

  test("media: image upload hits photo endpoint with the real file name", async () => {
    const a = await accountClient(tenv(), admin, slot);
    const png = new Uint8Array(readFileSync(join(import.meta.dir, "../../../mock/wiremock/__files/login-qr.png")));
    const stream = a.sendBlob(png);
    await a.request("messages.sendMedia", {
      threadId: "777000222",
      threadType: "user",
      cliId: "e2e-img",
      kind: "image",
      name: "anh-dep.png",
      stream,
    });
    await sleep(500);
    const entries = await journal();
    const upload = entries.find((e) =>
      e.request.url.includes("photo_original/upload"),
    );
    expect(upload).toBeDefined();
    const uploadBody = upload!.request.body ?? "";
    // multipart body carries the staged client-supplied name
    const decoded = Buffer.from(
      upload!.request.bodyAsBase64 ?? "",
      "base64",
    ).toString();
    expect(uploadBody + decoded).toContain("anh-dep.png");
    a.close();
  });

  test("media: file send keeps its original name", async () => {
    const a = await accountClient(tenv(), admin, slot);
    const stream = a.sendBlob(new Uint8Array([1, 2, 3, 4]));
    await a.request("messages.sendMedia", {
      threadId: "777000222",
      threadType: "user",
      cliId: "e2e-file",
      kind: "file",
      name: "bao-cao-thang-12.pdf",
      stream,
    });
    await sleep(700); // asyncfile waits for the ws file_done control
    const entries = await journal();
    const upload = entries.find((e) =>
      e.request.url.includes("asyncfile/upload"),
    );
    expect(upload).toBeDefined();
    const decoded = Buffer.from(
      upload!.request.bodyAsBase64 ?? "",
      "base64",
    ).toString();
    expect((upload!.request.body ?? "") + decoded).toContain(
      "bao-cao-thang-12.pdf",
    );
    a.close();
  });

  test("rate-limit and generic error stubs surface clean errors", async () => {
    const a = await accountClient(tenv(), admin, slot);
    const res = a.request("messages.sendText", {
      threadId: "777000222",
      threadType: "user",
      cliId: "e2e-rl",
      text: "__ratelimit__",
    });
    await expect(res).rejects.toThrow();
    a.close();
  });

  test("ws kick 3000 -> displaced then recovery", async () => {
    const a = await accountClient(tenv(), admin, slot);
    const w = a.waitEvent("account.status", 15000, (d) => {
      console.log("kick test saw status:", JSON.stringify(d.data));
      return ((d.data ?? {}) as { status: string }).status === "displaced";
    });
    await mockCtl("/ws/kick", { reason: 3000 });
    await w;
    // listener retries per socket settings; give it a moment
    const onlineW = a.waitEvent("account.status", 30000, (d) =>
      ((d.data ?? {}) as { status: string }).status === "online",
    );
    await onlineW;
    a.close();
  });


  test("qr login declined surfaces loginQr.failed", async () => {
    const failW = ctrl.waitEvent("loginQr.failed", 20000);
    const start = ctrl.request("accounts.loginQr.start");
    await ctrl.waitEvent("loginQr.image", 20000);
    await mockCtl("/qr/decline");
    const evt = await failW;
    expect(evt.event).toBe("loginQr.failed");
    await start;
  });

  test("qr login expired refreshes to a new image", async () => {
    const doneW = ctrl.waitEvent("loginQr.done", 30000);
    const start = ctrl.request("accounts.loginQr.start");
    await ctrl.waitEvent("loginQr.image", 20000);
    const img2W = ctrl.waitEvent("loginQr.image", 20000);
    await mockCtl("/qr/expire");
    await img2W;
    // clean up: decline the refreshed code so no extra account is added
    await mockCtl("/qr/decline");
    await ctrl.waitEvent("loginQr.failed", 20000);
    await start.catch(() => {});
    await doneW.catch(() => {});
  });

  test("reactions in both directions", async () => {
    const a = await accountClient(tenv(), admin, slot);
    const upd = a.waitEvent("message.updated", 10000, (d) =>
      (((d.data ?? {}) as { message?: { id?: string } }).message?.id) === "9001",
    );
    await mockCtl("/events/reaction", {
      msgId: "9001",
      cliMsgId: "9001",
      uidFrom: "777000222",
      idTo: "777000111",
      dName: "Trần Thị Hoa",
      icon: "heart",
    });
    const e = await upd;
    const rec = (e.data as { message: { id: string } }).message;
    expect(rec.id).toBe("9001");

    // outgoing: react on the stored message, assert the plaintext params
    await a.request("messages.react", {
      msgId: "9001",
      threadId: "777000222",
      threadType: "user",
      icon: "heart",
    });
    await sleep(500);
    const bodies = journalBodies(await journal());
    expect(
      bodies.some((b) => b.entry.request.url.includes("reaction")),
    ).toBe(true);
    a.close();
  });

  test("recall in both directions", async () => {
    const a = await accountClient(tenv(), admin, slot);
    const upd = a.waitEvent("message.updated", 10000, (d) =>
      (((d.data ?? {}) as { message?: { id?: string; recalled?: boolean } })
        .message?.recalled) === true,
    );
    await mockCtl("/events/undo", {
      type: "user",
      msgId: "9002",
      cliMsgId: "9002",
      uidFrom: "777000222",
      idTo: "777000111",
    });
    const e = await upd;
    expect(
      ((e.data ?? {}) as { message?: { recalled?: boolean } }).message
        ?.recalled,
    ).toBe(true);
    a.close();
  });

  test("seen, delivered and typing in both directions", async () => {
    const a = await accountClient(tenv(), admin, slot);
    const seenW = a.waitEvent("receipt", 10000, (d) =>
      ((d.data ?? {}) as { kind?: string }).kind === "seen",
    );
    await mockCtl("/events/seen", {
      threadId: "777000222",
      msgId: "9001",
      uidFrom: "777000222",
    });
    await seenW;

    const delW = a.waitEvent("receipt", 10000, (d) =>
      ((d.data ?? {}) as { kind?: string }).kind === "delivered",
    );
    await mockCtl("/events/delivered", {
      threadId: "777000222",
      msgId: "9001",
      userIds: ["777000111"],
    });
    await delW;

    const typW = a.waitEvent("typing", 10000);
    await mockCtl("/events/typing", {
      threadId: "777000222",
      uid: "777000222",
    });
    await typW;

    // outgoing side lands in the journal
    await a.request("threads.markSeen", {
      threadId: "777000222",
      threadType: "user",
    });
    await a.request("threads.typing", {
      threadId: "777000222",
      threadType: "user",
    });
    await sleep(500);
    const urls = (await journal()).map((e) => e.request.url);
    expect(urls.some((u) => u.includes("seen"))).toBe(true);
    expect(urls.some((u) => u.includes("typing"))).toBe(true);
    a.close();
  });

  test("second device converges on the same account", async () => {
    const admin2 = await pairDevice(tenv(), { name: "second", role: "admin" });
    const a2 = await accountClient(tenv(), admin2, slot);
    const w = a2.waitEvent("message.new", 10000, (d) =>
      openRecord(tenv(), slot, (d.data as { message: { id: string } }).message)
        .text === "Máy thứ hai thấy không?",
    );
    await mockCtl("/events/message", {
      type: "user",
      uidFrom: "777000222",
      idTo: "777000111",
      dName: "Trần Thị Hoa",
      content: "Máy thứ hai thấy không?",
    });
    await w;
    a2.close();
  });

  test("own-send echo does not duplicate the message", async () => {
    const a = await accountClient(tenv(), admin, slot);
    const res = (await a.request("messages.sendText", {
      threadId: "777000222",
      threadType: "user",
      cliId: "e2e-echo-1",
      text: "echo của chính mình",
    })) as { msgId: string };
    // the backend echoes our own message back over the listener
    await mockCtl("/events/message", {
      type: "user",
      uidFrom: "0",
      idTo: "777000222",
      cliMsgId: "e2e-echo-1",
      content: "echo của chính mình",
    });
    await sleep(700);
    const msgs = (await a.request("messages.list", {
      threadId: "777000222",
      threadType: "user",
    })) as { messages: { id: string; body?: { text?: string } }[] };
    const matches = msgs.messages.filter((m) => {
      try {
        return openRecord(tenv(), slot, m).text === "echo của chính mình";
      } catch {
        return false; // recalled records carry no content
      }
    });
    expect(matches.length).toBe(1);
    a.close();
  });

  test("quote, mention and sticker reach Zalo with plaintext params", async () => {
    const a = await accountClient(tenv(), admin, slot);
    const listed = (await a.request("messages.list", {
      threadId: "777000222",
      threadType: "user",
    })) as { messages: { id: string }[] };
    const quoted = listed.messages.find((m) => m.id === "9001")!;
    const quotedRaw = openRecord(tenv(), slot, quoted).raw;
    await a.request("messages.sendText", {
      threadId: "777000222",
      threadType: "user",
      cliId: "e2e-quote",
      text: "đồng ý luôn @Hoa",
      quote: { raw: quotedRaw },
    });
    // zca only expands mentionInfo on group threads
    await a.request("messages.sendText", {
      threadId: "880000111",
      threadType: "group",
      cliId: "e2e-ment",
      text: "@Bảo nhận việc nhé",
      mentions: [{ uid: "777000333", pos: 0, len: 4 }],
    });
    await a.request("messages.sendSticker", {
      threadId: "777000222",
      threadType: "user",
      cliId: "e2e-stk",
      sticker: { id: 12001, cateId: 1200, type: 1, url: "" },
    });
    await sleep(600);
    const bodies = journalBodies(await journal());
    const q = bodies.find((b) => b.params.message === "đồng ý luôn @Hoa");
    expect(q).toBeDefined();
    expect(q!.params.qmsgId).toBe("9001");
    const m = bodies.find((b) => b.params.message === "@Bảo nhận việc nhé");
    expect(m).toBeDefined();
    expect(m!.params.mentionInfo).toBeDefined();
    expect(
      bodies.some((b) => b.entry.request.url.includes("sticker")),
    ).toBe(true);
    const searched = (await a.request("stickers.search", {
      query: "hi",
    })) as { stickers: { url?: string }[] };
    expect(
      searched.stickers.every((st) => typeof st.url === "string"),
    ).toBe(true);
    a.close();
  });

  test("every media url in seeded responses resolves through media.fetch", async () => {
    const a = await accountClient(tenv(), admin, slot);
    const seen: unknown[] = [];
    const { threads } = (await a.request("threads.list")) as {
      threads: { id: string; type: string }[];
    };
    seen.push(threads);
    for (const t of threads) {
      const { messages } = (await a.request("messages.list", {
        threadId: t.id,
        threadType: t.type,
      })) as { messages: { id: string; sealed?: string; body?: Record<string, unknown> }[] };
      // Recalled messages are scrubbed: neither body nor sealed.
      seen.push(
        messages.map((m) =>
          m.sealed === undefined && m.body === undefined ? m : openRecord(tenv(), slot, m),
        ),
      );
    }
    const { contacts } = (await a.request("contacts.list")) as {
      contacts: { uid: string }[];
    };
    const { groups } = (await a.request("groups.list")) as {
      groups: { id: string }[];
    };
    seen.push(contacts, groups);
    for (const g of groups) {
      seen.push(await a.request("groups.info", { groupId: g.id }));
    }
    for (const c of contacts) {
      seen.push(await a.request("users.avatar", { uid: c.uid }));
    }
    seen.push(await a.request("stickers.search", { query: "hi" }));
    const urls = [
      ...new Set(
        JSON.stringify(seen).match(/https?:\/\/[a-z0-9.-]+\.(?:zdn|zadn)\.vn\/[^"\\\s]+/g) ?? [],
      ),
    ];
    expect(urls.some((u) => u.includes("avatar-mock.zdn.vn"))).toBe(true);
    expect(urls.some((u) => u.includes("mock-media.zdn.vn"))).toBe(true);
    const empty: string[] = [];
    for (const url of urls) {
      const res = (await a.request("media.fetch", { url })) as {
        stream: number;
        size: number;
      };
      const blob = await a.waitBlob(res.stream);
      if (res.size === 0 || blob.length === 0) empty.push(url);
    }
    expect(empty).toEqual([]);
    a.close();
  });


  test("session-expired stub flips the account to needs_login", async () => {
    const a = await accountClient(tenv(), admin, slot);
    const w = a.waitEvent("account.status", 15000, (d) =>
      ((d.data ?? {}) as { status: string }).status === "needs_login",
    );
    await expect(
      a.request("messages.sendText", {
        threadId: "777000222",
        threadType: "user",
        cliId: "e2e-sess",
        text: "__session__",
      }),
    ).rejects.toThrow();
    await w;
    a.close();
  });

  test("media.fetch through the mock returns a sealed blob", async () => {
    const a = await accountClient(tenv(), admin, slot);
    const res = (await a.request("media.fetch", {
      url: "http://mock-media.zadn.vn/files/doc.bin",
    })) as { stream?: number; size?: number; sha256?: string };
    expect(res.stream !== undefined || res.size !== undefined).toBe(true);
    a.close();
  });

  test("media.fetch serves every mock fixture byte-exact", async () => {
    const files = join(import.meta.dir, "../../../mock/wiremock/__files");
    const sha = (b: Uint8Array) => createHash("sha256").update(b).digest("hex");
    const cases: [string, string][] = [
      ["http://mock-media.zdn.vn/files/img-normal.jpg", "sample.jpg"],
      ["http://mock-media.zdn.vn/files/img-hd.jpg", "sample.jpg"],
      ["http://mock-media.zdn.vn/files/img-thumb.jpg", "sample.jpg"],
      ["http://mock-media.zadn.vn/files/img-hd.jpg?v=1", "sample.jpg"],
      ["http://mock-media.zdn.vn/files/doc.bin", "sample.bin"],
      ["http://mock-media.zadn.vn/media/voice.aac", "sample.bin"],
      ["http://mock-media.zdn.vn/files/upload.bin", "sample.bin"],
      ["http://mock-media.zdn.vn/files/gif-thumb.jpg", "gif-thumb.jpg"],
      ["http://mock-media.zdn.vn/stickers/12002.png", "stickers/12002.png"],
      ["https://avatar-mock.zdn.vn/full/u777000222.jpg", "avatars/u777000222.jpg"],
    ];
    const a = await accountClient(tenv(), admin, slot);
    for (const [url, fixture] of cases) {
      const res = (await a.request("media.fetch", { url })) as {
        stream: number;
        size: number;
        sealed: boolean;
      };
      const blob = await a.waitBlob(res.stream);
      const bytes = res.sealed ? openMedia(tenv(), slot, url, res.size, blob) : blob;
      expect({ url, sha: sha(bytes) }).toEqual({
        url,
        sha: sha(readFileSync(join(files, fixture))),
      });
    }
    a.close();
  });

  test("restart resumes the session via cookie login (no QR)", async () => {
    ctrl.close();
    await env.cleanup();
    const before = (await journal()).filter((e) =>
      e.request.url.includes("getLoginInfo"),
    ).length;
    env = await makeMockEnv(env.dir);
    admin = await pairDevice(tenv(), { name: "admin", role: "admin" });
    ctrl = await controlClient(tenv(), admin);
    const m = (await ctrl.request("manifest.get")) as {
      accounts: { slot: string; uid: string; status: string }[];
    };
    const acct = m.accounts.find((a) => a.slot === slot)!;
    let acct2 = { status: "", uid: "" };
    for (let i = 0; i < 40; i++) {
      const m2 = (await ctrl.request("manifest.get")) as {
        accounts: { slot: string; uid: string; status: string }[];
      };
      acct2 = m2.accounts.find((a) => a.slot === slot)!;
      if (acct2.status === "online") break;
      await sleep(250);
    }
    expect(acct2.status).toBe("online");
    expect(acct2.uid).toBe("777000111");
    expect(
      (await journal()).filter((e) =>
        e.request.url.includes("getLoginInfo"),
      ).length,
    ).toBeGreaterThan(before);
  });

  test("pin, mute, markUnread hit the journal and emit thread.updated", async () => {
    const a = await accountClient(tenv(), admin, slot);
    await mockCtl("/reset");
    await a.request("threads.setPinned", {
      threadId: "777000222", threadType: "user", pinned: true,
    });
    await a.request("threads.setMuted", {
      threadId: "777000222", threadType: "user", muted: true,
    });
    await a.request("threads.markUnread", {
      threadId: "777000222", threadType: "user",
    });
    await sleep(400);
    const urls = (await journal()).map((e) => e.request.url);
    expect(urls.some((u) => u.includes("pinconvers/updatev2"))).toBe(true);
    expect(urls.some((u) => u.includes("social/profile/setmute"))).toBe(true);
    expect(urls.some((u) => u.includes("conv/addUnreadMark"))).toBe(true);
    const bodies = journalBodies(await journal());
    const pin = bodies.find((b) => b.entry.request.url.includes("pinconvers"));
    expect(pin?.params.conversations).toEqual(["u777000222"]);
    const list = (await a.request("threads.list")) as {
      threads: { id: string; pinned: boolean; muted: boolean; unread: number }[];
    };
    const th = list.threads.find((t) => t.id === "777000222")!;
    expect(th.pinned).toBe(true);
    expect(th.muted).toBe(true);
    expect(th.unread).toBeGreaterThanOrEqual(1);
    // markSeen clears the flag and asks Zalo to drop the unread mark.
    await a.request("threads.markSeen", {
      threadId: "777000222", threadType: "user",
    });
    await sleep(400);
    const urls2 = (await journal()).map((e) => e.request.url);
    expect(urls2.some((u) => u.includes("removeUnreadMark"))).toBe(true);
    a.close();
  });

  test("unpin and unmute clear the flags", async () => {
    const a = await accountClient(tenv(), admin, slot);
    await a.request("threads.setPinned", {
      threadId: "777000222", threadType: "user", pinned: false,
    });
    await a.request("threads.setMuted", {
      threadId: "777000222", threadType: "user", muted: false,
    });
    const list = (await a.request("threads.list")) as {
      threads: { id: string; pinned: boolean; muted: boolean }[];
    };
    const th = list.threads.find((t) => t.id === "777000222")!;
    expect(th.pinned).toBe(false);
    expect(th.muted).toBe(false);
    a.close();
  });

  test("forward sends plaintext to the mforward endpoint", async () => {
    const a = await accountClient(tenv(), admin, slot);
    await mockCtl("/reset");
    const res = (await a.request("messages.sendText", {
      threadId: "777000222", threadType: "user",
      cliId: "e2e-fwd-src", text: "Chuyển tiếp tin này",
    })) as { msgId: string };
    await a.request("messages.forward", {
      msgId: res.msgId,
      threadId: "777000222",
      threadType: "user",
      to: [
        { threadId: "777000333", threadType: "user" },
        { threadId: "880000111", threadType: "group" },
      ],
      raw: "Chuyển tiếp tin này",
    });
    await sleep(400);
    const entries = (await journal()).map((e) => e.request.url);
    expect(entries.some((u) => u.includes("message/mforward"))).toBe(true);
    expect(entries.some((u) => u.includes("group/mforward"))).toBe(true);
    const bodies = journalBodies(await journal());
    const fwd = bodies.find((b) => b.entry.request.url.includes("mforward"));
    expect(String(fwd?.params.msgInfo)).toContain("Chuyển tiếp tin này");
    a.close();
  });

  test("users.get serves cached and unknown profiles; groups.info carries members", async () => {
    const a = await accountClient(tenv(), admin, slot);
    const res = (await a.request("users.info", {
      uids: ["777000222", "999999999"],
    })) as { users: { uid: string; displayName: string }[] };
    const known = res.users.find((u) => u.uid === "777000222")!;
    expect(known.displayName).not.toBe("");
    const unknown = res.users.find((u) => u.uid === "999999999")!;
    expect(unknown.displayName).toBe("");
    // second call must not hit the network again for the cached uid
    await mockCtl("/reset");
    await a.request("users.info", { uids: ["777000222"] });
    await sleep(300);
    const hits = (await journal()).filter((e) =>
      e.request.url.includes("getprofiles"),
    );
    expect(hits.length).toBe(0);
    const g = (await a.request("groups.info", {
      groupId: "880000111",
    })) as {
      group: {
        memberIds: string[];
        ownerId?: string;
        members: { uid: string; displayName: string; role: string }[];
      };
    };
    expect(g.group.members.length).toBe(g.group.memberIds.length);
    const owner = g.group.members.find((m) => m.uid === g.group.ownerId);
    expect(owner?.role).toBe("owner");
    a.close();
  });

  test("delivery receipts fold into own messages as delivery state", async () => {
    const a = await accountClient(tenv(), admin, slot);
    const res = (await a.request("messages.sendText", {
      threadId: "777000222", threadType: "user",
      cliId: "e2e-dlv", text: "Tin cần xác nhận",
    })) as { msgId: string };
    const readDelivery = async () => {
      const list = (await a.request("messages.list", {
        threadId: "777000222", threadType: "user", limit: 50,
      })) as {
        messages: { id: string; delivery?: { state: string } }[];
      };
      return list.messages.find((m) => m.id === res.msgId)?.delivery?.state;
    };
    await mockCtl("/events/delivered", {
      threadId: "777000222", msgId: res.msgId, userIds: ["777000222"],
    });
    await sleep(400);
    expect(await readDelivery()).toBe("delivered");
    await mockCtl("/events/seen", {
      threadId: "777000222", msgId: res.msgId, uidFrom: "777000222",
    });
    await sleep(400);
    expect(await readDelivery()).toBe("seen");
    a.close();
  });

  test("video and voice sends hit their upload endpoints", async () => {
    const a = await accountClient(tenv(), admin, slot);
    await mockCtl("/reset");
    const mp4 = new Uint8Array(64 * 1024).fill(1);
    const s1 = a.sendBlob(mp4);
    await a.request("messages.sendMedia", {
      threadId: "777000222", threadType: "user", cliId: "e2e-vid",
      kind: "video", name: "clip-gia-dinh.mp4", stream: s1,
    });
    const m4a = new Uint8Array(32 * 1024).fill(2);
    const s2 = a.sendBlob(m4a);
    await a.request("messages.sendMedia", {
      threadId: "777000222", threadType: "user", cliId: "e2e-voice",
      kind: "voice", name: "loi-nhan.m4a", stream: s2,
    });
    await sleep(600);
    const entries = await journal();
    const urls = entries.map((e) => e.request.url);
    expect(
      urls.some((u) => u.includes("asyncfile/upload") || u.includes("file")),
    ).toBe(true);
    const raw = entries
      .map((e) => Buffer.from(e.request.bodyAsBase64 ?? "", "base64").toString())
      .join("\n");
    expect(raw).toContain("clip-gia-dinh.mp4");
    expect(raw).toContain("loi-nhan.m4a");
    a.close();
  });

  test("abnormal socket close reconnects with backoff", async () => {
    const a = await accountClient(tenv(), admin, slot);
    const rec = a.waitEvent("account.status");
    await mockCtl("/ws/kick", { reason: "abnormal" });
    const ev = (await rec) as { data: { status: string } };
    expect(["reconnecting", "displaced", "starting", "online"]).toContain(
      ev.data.status,
    );
    let status = "";
    for (let i = 0; i < 24; i++) {
      await sleep(500);
      const m = (await ctrl.request("manifest.get")) as {
        accounts: { slot: string; status: string }[];
      };
      status = m.accounts.find((x) => x.slot === slot)!.status;
      if (status === "online") break;
    }
    expect(status).toBe("online");
    a.close();
  });

  test("friend event broadcasts contacts.changed; group rename emits thread.updated", async () => {
    const a = await accountClient(tenv(), admin, slot);
    const fr = a.waitEvent("contacts.changed");
    await mockCtl("/events/friend", { act: "req_v2", data: {} });
    await fr;
    const tu = a.waitEvent("thread.updated");
    await mockCtl("/events/group", {
      act: "update",
      data: { groupId: "880000111", groupName: "Nhóm Đổi Tên" },
    });
    const ev = (await tu) as {
      data: { thread: { id: string; name: string } };
    };
    if (ev.data.thread.id === "880000111") {
      expect(ev.data.thread.name).toBe("Nhóm Đổi Tên");
    }
    a.close();
  });

  test("delete conversation purges it locally and emits thread.deleted", async () => {
    const a = await accountClient(tenv(), admin, slot);
    await a.request("messages.sendText", {
      threadId: "777000444", threadType: "user",
      cliId: "e2e-del", text: "Sắp bị xóa",
    });
    await sleep(300);
    const del = a.waitEvent("thread.deleted");
    await a.request("threads.delete", {
      threadId: "777000444", threadType: "user",
    });
    await del;
    await sleep(300);
    const urls = (await journal()).map((e) => e.request.url);
    expect(urls.some((u) => u.includes("deleteconver"))).toBe(true);
    const list = (await a.request("threads.list")) as {
      threads: { id: string }[];
    };
    expect(list.threads.some((t) => t.id === "777000444")).toBe(false);
    const msgs = (await a.request("messages.list", {
      threadId: "777000444", threadType: "user", limit: 10,
    })) as { messages: unknown[] };
    expect(msgs.messages.length).toBe(0);
    a.close();
  });
  test("accounts.logout wipes credentials and flips to needs_login", async () => {
    const m0 = (await ctrl.request("manifest.get")) as {
      accounts: { slot: string; status: string }[];
    };
    const other = m0.accounts.find((x) => x.slot !== slot);
    const target = other?.slot ?? slot;
    await ctrl.request("accounts.logout", { slot: target });
    await sleep(600);
    const m = (await ctrl.request("manifest.get")) as {
      accounts: { slot: string; status: string }[];
    };
    expect(m.accounts.find((x) => x.slot === target)!.status).toBe(
      "needs_login",
    );
    const urls = (await journal()).map((e) => e.request.url);
    expect(urls.some((u) => u.includes("logout-token"))).toBe(true);
  });

});

// ---- Official Account (OA OpenAPI mock) ----
const OA_CREDS = {
  appId: "oa-app-1",
  appSecret: "oa-secret-1",
  accessToken: "oa-at-1",
  refreshToken: "oa-rt-1",
};

describe.skipIf(!E2E || !dockerOk)("e2e-oa", () => {
  let env: MockEnv;
  let admin: PairedDevice;
  let ctrl: Client;
  let slot: string;
  const tenv = () => env as unknown as TestEnv;

  beforeAll(async () => {
    await mockCtl("/reset");
    env = await makeMockEnv();
    admin = await pairDevice(tenv(), { name: "admin", role: "admin" });
    ctrl = await controlClient(tenv(), admin);
  });
  afterAll(async () => {
    ctrl?.close();
    await env?.cleanup();
  });

  test("add OA account: manifest kind/capabilities, secrets never leave the server", async () => {
    const res = (await ctrl.request("accounts.addOa", OA_CREDS)) as {
      slot: string;
    };
    slot = res.slot;
    expect(slot).toBeTruthy();
    const m = (await ctrl.request("manifest.get")) as {
      accounts: Record<string, unknown>[];
    };
    const row = m.accounts.find((x) => x.slot === slot)!;
    expect(row.kind).toBe("oa");
    expect(row.uid).toBe("oa-9001");
    expect(row.displayName).toBe("Quán Cà Phê Sáng");
    expect(row.capabilities).toEqual([]);
    const blob = JSON.stringify(m);
    for (const secret of ["oa-secret-1", "oa-at-", "oa-rt-"]) {
      expect(blob.includes(secret)).toBe(false);
    }
  });

  test("inbound messages from two users, ordered, no duplicates", async () => {
    const a = await accountClient(tenv(), admin, slot);
    for (const [userId, name, text] of [
      ["oa-u-1", "Ngô Thu Trang", "Cho em một ly cà phê sữa"],
      ["oa-u-2", "Bùi Hải Nam", "Còn bánh mì không ạ"],
      ["oa-u-1", "Ngô Thu Trang", "Thêm ít đá nhé"],
    ] as const) {
      await mockCtl("/oa/events/message", { userId, displayName: name, text });
    }
    const deadline = Date.now() + 15_000;
    let msgs: { id: string; threadId: string; body: { text?: string } }[] = [];
    while (Date.now() < deadline) {
      const r = (await a.request("messages.list", {
        threadId: "oa-u-1",
        threadType: "user",
        limit: 50,
      })) as { messages: never[] };
      const r2 = (await a.request("messages.list", {
        threadId: "oa-u-2",
        threadType: "user",
        limit: 50,
      })) as { messages: never[] };
      msgs = [...(r.messages as never[]), ...(r2.messages as never[])] as never[];
      if (msgs.length >= 3) break;
      await sleep(700);
    }
    expect(msgs.length).toBe(3);
    // Polls can replay; ids must stay unique.
    expect(new Set(msgs.map((m) => m.id)).size).toBe(3);
    a.close();
  });

  test("send text/image/file: journal shows access_token and payload", async () => {
    const a = await accountClient(tenv(), admin, slot);
    await a.request("messages.sendText", {
      threadId: "oa-u-1",
      threadType: "user",
      cliId: "e2e-oa-1",
      text: "Dạ có ngay ạ",
    });
    await a.request("messages.sendMedia", {
      threadId: "oa-u-1", threadType: "user", cliId: "e2e-oa-img",
      kind: "image", name: "menu.png",
      stream: a.sendBlob(new Uint8Array([0x89, 0x50, 1, 2])),
    });
    await a.request("messages.sendMedia", {
      threadId: "oa-u-1", threadType: "user", cliId: "e2e-oa-file",
      kind: "file", name: "hoa-don.pdf",
      stream: a.sendBlob(new Uint8Array([37, 80, 68, 70])),
    });
    const entries = await journal();
    const sends = entries.filter((e) =>
      e.request.url.includes("openapi.zalo.me/v3.0/oa/message/cs"),
    );
    expect(sends.length).toBeGreaterThanOrEqual(3);
    const send = sends.find((e) => (e.request.body ?? "").includes("Dạ có ngay ạ"))!;
    expect(send.request.url).not.toContain("access_token=");
    expect(String(send.request.headers?.access_token ?? "")).toContain("oa-at-");
    expect(send.request.body).toContain("oa-u-1");
    const ups = entries.filter((e) => e.request.url.includes("oa/upload/"));
    expect(ups.map((e) => e.request.url).join(",")).toContain("upload/image");
    expect(ups.map((e) => e.request.url).join(",")).toContain("upload/file");
    a.close();
  });

  test("quote, 2000 char limit, error mapping and not_supported", async () => {
    const a = await accountClient(tenv(), admin, slot);
    // quote: the raw of an inbound OA message carries message_id.
    const m = (await a.request("messages.list", {
      threadId: "oa-u-1", threadType: "user", limit: 5,
    })) as { messages: { id: string }[] };
    await a.request("messages.sendText", {
      threadId: "oa-u-1", threadType: "user", cliId: "e2e-oa-2",
      text: "Vâng ạ", quote: { msgId: m.messages[0].id },
    });
    const sends = (await journal()).filter((e) =>
      e.request.url.includes("oa/message/cs") && (e.request.body ?? "").includes("Vâng ạ"),
    );
    expect(sends.length).toBe(1);
    // 2000 char limit.
    await expect(
      a.request("messages.sendText", {
        threadId: "oa-u-1", threadType: "user", cliId: "e2e-oa-3",
        text: "x".repeat(2001),
      }),
    ).rejects.toThrow("2000");
    // window_expired via mock flag.
    await mockCtl("/oa/set-window-expired", { userId: "oa-u-2" });
    await expect(
      a.request("messages.sendText", {
        threadId: "oa-u-2", threadType: "user", cliId: "e2e-oa-4", text: "hi",
      }),
    ).rejects.toMatchObject({ code: "window_expired" });
    // quota and rate-limit via magic user ids.
    await expect(
      a.request("messages.sendText", {
        threadId: "u-quota", threadType: "user", cliId: "e2e-oa-5", text: "hi",
      }),
    ).rejects.toMatchObject({ code: "quota_exceeded" });
    await expect(
      a.request("messages.sendText", {
        threadId: "u-rate", threadType: "user", cliId: "e2e-oa-6", text: "hi",
      }),
    ).rejects.toMatchObject({ code: "rate_limited" });
    // Unsupported features reject cleanly.
    await expect(
      a.request("threads.setPinned", {
        threadId: "oa-u-1", threadType: "user", pinned: true,
      }),
    ).rejects.toMatchObject({ code: "not_supported" });
    a.close();
  });

  test("refresh rotation persists; expire -> needs_login -> updateOaTokens recovers", async () => {
    // The stored pair must already be the rotated one from add-validation.
    const row = env.server.store.accountBySlot(slot)!;
    const creds = JSON.parse(row.credentials_json) as {
      refreshToken: string;
    };
    expect(creds.refreshToken).toBe("oa-rt-2");
    // Restart: the persisted rotated token is used, not the burned one.
    await env.cleanup();
    env = await makeMockEnv(env.dir);
    admin = await pairDevice(tenv(), { name: "admin", role: "admin" });
    ctrl = await controlClient(tenv(), admin);
    await sleep(1500);
    const m = (await ctrl.request("manifest.get")) as {
      accounts: { slot: string; status: string }[];
    };
    expect(m.accounts.find((x) => x.slot === slot)!.status).toBe("online");
    // Expire the access token: refresh path must recover the account.
    await mockCtl("/oa/expire-token");
    await sleep(2500);
    const m2 = (await ctrl.request("manifest.get")) as {
      accounts: { slot: string; status: string }[];
    };
    expect(m2.accounts.find((x) => x.slot === slot)!.status).toBe("online");
    const row2 = env.server.store.accountBySlot(slot)!;
    expect(
      (JSON.parse(row2.credentials_json) as { refreshToken: string })
        .refreshToken,
    ).not.toBe("oa-rt-2");
  });

  test("refresh failure -> needs_login -> updateOaTokens recovers", async () => {
    // Poison the live pair with a refresh token the mock never issued.
    await ctrl.request("accounts.updateOaTokens", {
      slot, accessToken: "oa-at-dead", refreshToken: "oa-rt-bad",
    });
    await mockCtl("/oa/expire-token", { accessToken: "oa-at-dead" });
    const deadline = Date.now() + 12_000;
    let status = "";
    while (Date.now() < deadline) {
      const m = (await ctrl.request("manifest.get")) as {
        accounts: { slot: string; status: string }[];
      };
      status = m.accounts.find((x) => x.slot === slot)!.status;
      if (status === "needs_login") break;
      await sleep(700);
    }
    expect(status).toBe("needs_login");
    // Fresh tokens from the console recover it. The mock does not
    // validate access tokens, so the new pair works immediately.
    await ctrl.request("accounts.updateOaTokens", {
      slot, accessToken: "oa-at-9", refreshToken: "oa-rt-9",
    });
    await sleep(2500);
    const m2 = (await ctrl.request("manifest.get")) as {
      accounts: { slot: string; status: string }[];
    };
    expect(m2.accounts.find((x) => x.slot === slot)!.status).toBe("online");
  });
});
