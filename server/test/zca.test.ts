import { test, expect } from "bun:test";
import { ThreadType } from "@zalos/zalo-sdk";
import { normalizeZcaMessage, ZcaGateway } from "../src/gateway/zca.ts";

const base = {
  msgId: "101",
  cliMsgId: "55",
  msgType: "webchat",
  uidFrom: "u1",
  idTo: "me",
  dName: "Alice",
  ts: "1700000000000",
  notify: "",
  ttl: 0,
};

const wrap = (data: Record<string, unknown>, type = ThreadType.User, isSelf = false) =>
  ({ type, threadId: "u1", isSelf, data }) as never;

test("normalize text", () => {
  const m = normalizeZcaMessage(wrap({ ...base, content: "hi there" }));
  expect(m.kind).toBe("text");
  expect(m.text).toBe("hi there");
  expect(m.cliId).toBe("55");
  expect(m.threadType).toBe("user");
});

test("normalize photo", () => {
  const m = normalizeZcaMessage(
    wrap({
      ...base,
      msgType: "chat.photo",
      content: { title: "", params: JSON.stringify({ hdUrl: "https://x/p.jpg", width: 100, height: 50 }) },
    }),
  );
  expect(m.kind).toBe("image");
  expect(m.attachments![0].url).toBe("https://x/p.jpg");
  expect(m.attachments![0].width).toBe(100);
});

test("normalize video/file/voice/sticker/link/gif/system/other", () => {
  const cases: [string, unknown, import("../src/gateway/types.ts").Message["kind"]][] = [
    ["chat.video.msg", { params: JSON.stringify({ url: "https://v" }) }, "video"],
    ["chat.file", { title: "a.pdf", params: JSON.stringify({ url: "https://f" }) }, "file"],
    ["chat.voice", { params: JSON.stringify({ url: "https://au" }) }, "voice"],
    ["chat.sticker", { detail: { id: 7, catId: 2, type: 3 } }, "sticker"],
    ["chat.link", { title: "t", href: "https://l" }, "link"],
    ["chat.gif", { params: JSON.stringify({ url: "https://g" }) }, "gif"],
    ["group.join", { title: "x joined" }, "system"],
    ["chat.todo", { foo: 1 }, "other"],
  ];
  for (const [msgType, content, kind] of cases) {
    const m = normalizeZcaMessage(wrap({ ...base, msgType, content }));
    expect(m.kind).toBe(kind);
    expect(m.raw).not.toBeUndefined();
  }
});

test("group message maps thread type and mentions", () => {
  const m = normalizeZcaMessage(
    wrap(
      { ...base, content: "hi", mentions: [{ uid: "u2", pos: 0, len: 2 }] },
      ThreadType.Group,
      true,
    ),
  );
  expect(m.threadType).toBe("group");
  expect(m.isSelf).toBe(true);
  expect(m.mentions![0].uid).toBe("u2");
});

test("normalize contact card from chat.recommended", () => {
  const m = normalizeZcaMessage(
    wrap({
      ...base,
      msgType: "chat.recommended",
      content: {
        title: "Trần Thị Hoa",
        thumb: "https://x/hoa.jpg",
        href: "https://zalo.me/777000222",
        description: JSON.stringify({
          phone: "0900000000",
          caption: "Hoa",
          qrCodeUrl: "https://qr/x.png",
        }),
      },
    }),
  );
  expect(m.kind).toBe("card");
  expect(m.text).toBe("Trần Thị Hoa");
  expect(m.card).toEqual({
    uid: "777000222",
    displayName: "Trần Thị Hoa",
    avatarUrl: "https://x/hoa.jpg",
    phone: "0900000000",
    qrCodeUrl: "https://qr/x.png",
  });
});

test("chat.recommended without a card payload degrades to a link", () => {
  const plain = normalizeZcaMessage(
    wrap({
      ...base,
      msgType: "chat.recommended",
      content: { title: "t", href: "https://l", description: "not json" },
    }),
  );
  expect(plain.kind).toBe("link");
  const noCardFields = normalizeZcaMessage(
    wrap({
      ...base,
      msgType: "chat.recommended",
      content: {
        title: "t",
        href: "https://l",
        description: JSON.stringify({ caption: "just text" }),
      },
    }),
  );
  expect(noCardFields.kind).toBe("link");
});

function stubApi(): Record<string, unknown> & { jar: { key: string; value: string }[] } {
  const calls: string[] = [];
  const api = {
    calls,
    // The live cookie jar; tests rotate it like a Set-Cookie would.
    jar: [{ key: "zpw_sek", value: "s1" }],
    getCookie: () => ({ toJSON: () => ({ cookies: api.jar }) }),
    sendMessage: async () => ({ message: { msgId: 42 }, attachment: [] }),
    sendSeenEvent: async (p: unknown) => {
      calls.push(`seen:${JSON.stringify(p)}`);
    },
    keepAlive: async () => {
      api.jar = [{ key: "zpw_sek", value: "s2" }];
    },
    listener: { on: () => {}, stop: () => {}, start: () => {} },
  };
  return api;
}

test("adapter serializes calls through the queue and passes raw", async () => {
  const api = stubApi();
  const gw = new ZcaGateway(
    { imei: "i", cookie: {}, userAgent: "ua" },
    { uid: "me", displayName: "me", avatarUrl: "" },
    async () => api as never,
  );
  // start() binds the stub listener (no real connect happens)
  await gw.start();
  expect(gw.status).toBe("online");
  const res = await gw.sendText("u1", "user", "hi");
  expect(res.msgId).toBe("42");
  await gw.markSeen("u1", "user", { msgId: "9", cliMsgId: "8" });
  expect((api.calls as string[]).some((c) => c.includes("cliMsgId"))).toBe(true);
  await gw.stop();
  expect(gw.status).toBe("offline");
});

test("adapter hands rotated cookies to the manager once per change", async () => {
  const api = stubApi();
  const gw = new ZcaGateway(
    { imei: "i", cookie: [{ key: "zpw_sek", value: "s0" }], userAgent: "ua" },
    { uid: "me", displayName: "me", avatarUrl: "" },
    async () => api as never,
  );
  const seen: unknown[] = [];
  gw.on("credentials", (c) => seen.push(c.cookie));
  await gw.start();
  // after login: the live jar replaces the QR-time cookie
  expect(seen).toEqual([[{ key: "zpw_sek", value: "s1" }]]);
  await gw.sendText("u1", "user", "hi");
  expect(seen.length).toBe(1);
  await gw.keepAlive();
  expect(seen).toEqual([
    [{ key: "zpw_sek", value: "s1" }],
    [{ key: "zpw_sek", value: "s2" }],
  ]);
  await gw.stop();
});

test("normalize carries per-message ttl and expiry", () => {
  const m = normalizeZcaMessage(
    wrap({ ...base, content: "secret", ttl: 60_000 }),
  );
  expect(m.ttl).toBe(60_000);
  expect(m.expiresAt).toBe(1_700_000_000_000 + 60_000);
  const none = normalizeZcaMessage(wrap({ ...base, content: "plain", ttl: 0 }));
  expect(none.ttl).toBeUndefined();
  expect(none.expiresAt).toBeUndefined();
});

test("normalize structured kinds into typed payloads", () => {
  const bank = normalizeZcaMessage(
    wrap({
      ...base,
      msgType: "chat.bankcard",
      content: {
        params: JSON.stringify({
          binBank: 970436,
          numAccBank: "0123456789",
          nameAccBank: "NGUYEN VAN A",
          bankName: "Vietcombank",
        }),
      },
    }),
  );
  expect(bank.kind).toBe("bank");
  expect(bank.bankCard).toEqual({
    bin: 970436,
    accountNumber: "0123456789",
    holderName: "NGUYEN VAN A",
    bankName: "Vietcombank",
  });
  expect(bank.text).toBe("Vietcombank");

  const location = normalizeZcaMessage(
    wrap({
      ...base,
      msgType: "chat.location.new",
      content: {
        title: "Quán cà phê",
        params: JSON.stringify({ lat: 10.5, lng: 106.7, address: "Quận 1" }),
      },
    }),
  );
  expect(location.kind).toBe("location");
  expect(location.location).toEqual({
    lat: 10.5,
    lng: 106.7,
    name: "Quán cà phê",
    address: "Quận 1",
  });

  const poll = normalizeZcaMessage(
    wrap({
      ...base,
      msgType: "group.poll",
      content: {
        params: JSON.stringify({
          poll_id: 7,
          question: "Tối nay ăn gì?",
          options: [
            { option_id: 1, content: "Phở", votes: 2, voted: true },
            { option_id: 2, content: "Bún", votes: 1 },
          ],
          allow_multi_choices: false,
          num_vote: 3,
        }),
      },
    }),
  );
  expect(poll.kind).toBe("poll");
  expect(poll.poll?.question).toBe("Tối nay ăn gì?");
  expect(poll.poll?.options).toEqual([
    { id: 1, text: "Phở", votes: 2, voted: true },
    { id: 2, text: "Bún", votes: 1 },
  ]);
  expect(poll.poll?.totalVotes).toBe(3);

  const note = normalizeZcaMessage(
    wrap({
      ...base,
      msgType: "group.note",
      content: {
        params: JSON.stringify({
          noteId: "n1",
          title: "Ghi chú",
          extra: "Mang laptop",
          pinAct: 1,
        }),
      },
    }),
  );
  expect(note.kind).toBe("note");
  expect(note.note).toEqual({
    title: "Ghi chú",
    id: "n1",
    text: "Mang laptop",
    pinned: true,
  });

  const reminder = normalizeZcaMessage(
    wrap({
      ...base,
      msgType: "group.reminder",
      content: {
        params: JSON.stringify({
          reminderId: "r1",
          title: "Họp nhóm",
          startTime: 1_700_000_100_000,
          repeat: 1,
          emoji: "⏰",
        }),
      },
    }),
  );
  expect(reminder.kind).toBe("reminder");
  expect(reminder.reminder).toEqual({
    title: "Họp nhóm",
    id: "r1",
    startTime: 1_700_000_100_000,
    repeat: 1,
    emoji: "⏰",
  });

  const call = normalizeZcaMessage(
    wrap({
      ...base,
      msgType: "chat.call",
      content: {
        params: JSON.stringify({ callType: "video", callStatus: "missed" }),
      },
    }),
  );
  expect(call.kind).toBe("call");
  expect(call.callLog).toEqual({
    callType: "video",
    missed: true,
    state: "missed",
  });
  expect(call.text).toBe("Missed video call");

  const doodle = normalizeZcaMessage(
    wrap({
      ...base,
      msgType: "chat.doodle",
      content: {
        params: JSON.stringify({
          hdUrl: "https://d/hd.png",
          thumbUrl: "https://d/t.png",
          width: 800,
          height: 600,
        }),
      },
    }),
  );
  expect(doodle.kind).toBe("doodle");
  expect(doodle.doodle).toEqual({
    url: "https://d/hd.png",
    thumbUrl: "https://d/t.png",
    width: 800,
    height: 600,
  });

  const album = normalizeZcaMessage(
    wrap({
      ...base,
      msgType: "chat.album",
      content: {
        params: JSON.stringify({
          albumId: "a1",
          items: [
            { hdUrl: "https://a/1.jpg", thumbUrl: "https://a/1t.jpg" },
            { normalUrl: "https://a/2.jpg" },
          ],
        }),
      },
    }),
  );
  expect(album.kind).toBe("album");
  expect(album.album?.items).toHaveLength(2);
  expect(album.album?.items[0]).toEqual({
    kind: "image",
    url: "https://a/1.jpg",
    thumbUrl: "https://a/1t.jpg",
  });
  expect(album.album?.items[1].url).toBe("https://a/2.jpg");
  expect(album.text).toBe("2 photos");

  const todo = normalizeZcaMessage(
    wrap({
      ...base,
      msgType: "chat.todo",
      content: {
        params: JSON.stringify({
          todoId: "t1",
          item: {
            content: "Mua sữa",
            items: [
              { text: "Mua sữa", done: false },
              { text: "Mua bánh", done: true },
            ],
          },
        }),
      },
    }),
  );
  expect(todo.kind).toBe("todo");
  expect(todo.todo).toEqual({
    title: "Mua sữa",
    id: "t1",
    items: [
      { text: "Mua sữa", done: false },
      { text: "Mua bánh", done: true },
    ],
  });
});

test("unknown and malformed structured payloads degrade without losing raw", () => {
  const unknown = normalizeZcaMessage(
    wrap({ ...base, msgType: "chat.mystery", content: { foo: "bar" } }),
  );
  expect(unknown.kind).toBe("other");
  expect(unknown.text).toBe("[chat.mystery]");
  expect((unknown.raw as Record<string, unknown>).content).toEqual({
    foo: "bar",
  });

  // Missing the account number: not a bank card, so it stays other.
  const malformedBank = normalizeZcaMessage(
    wrap({
      ...base,
      msgType: "chat.bankcard",
      content: { params: JSON.stringify({ binBank: 970436 }) },
    }),
  );
  expect(malformedBank.kind).toBe("other");
  expect(malformedBank.raw).not.toBeUndefined();

  // Half a coordinate pair is not a location.
  const malformedLocation = normalizeZcaMessage(
    wrap({
      ...base,
      msgType: "chat.location.new",
      content: { params: JSON.stringify({ lat: 10.5 }) },
    }),
  );
  expect(malformedLocation.kind).toBe("other");
});
