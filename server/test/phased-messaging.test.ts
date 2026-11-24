import { test, expect, beforeAll, afterAll } from "bun:test";
import {
  makeEnv,
  pairDevice,
  controlClient,
  accountClient,
  loginQrAccount,
  openRecord,
  setVaultKey,
  type TestEnv,
  type PairedDevice,
} from "./support/helpers.ts";
import type { FakeGateway } from "../src/gateway/fake.ts";
import type {
  BankCard,
  LinkPreview,
  Message,
  Poll,
} from "../src/gateway/types.ts";

let env: TestEnv;
let admin: PairedDevice;
let deviceB: PairedDevice;
let slot: string;
let gw: FakeGateway;

beforeAll(async () => {
  // Both expiry timers are off; the TTL test drives the sweep by hand.
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

type WireMessage = Message & {
  body?: Record<string, unknown>;
  sealed?: string;
};

function messageOf(evt: { data?: unknown }): WireMessage {
  return (evt.data as { message: WireMessage }).message;
}

async function sendText(
  a: Awaited<ReturnType<typeof clients>>["a"],
  threadId: string,
  cliId: string,
  extra: Record<string, unknown> = {},
) {
  return (await a.request("messages.sendText", {
    threadId,
    threadType: "user",
    cliId,
    text: "hello",
    ...extra,
  })) as { msgId: string; cliId: string };
}

test("sendText passes styles, urgency and ttl and stays idempotent", async () => {
  const { a, b } = await clients();
  const cliId = "cli-styled";
  const before = gw.calls.filter((c) => c.method === "sendText").length;
  const res = await sendText(a, "styled-thread", cliId, {
    styles: [{ start: 0, len: 5, st: "b" }],
    urgency: "important",
    ttl: 60_000,
  });
  const again = await sendText(a, "styled-thread", cliId, {
    styles: [{ start: 0, len: 5, st: "b" }],
    urgency: "important",
    ttl: 60_000,
  });
  expect(again).toEqual(res);
  expect(gw.calls.filter((c) => c.method === "sendText").length).toBe(
    before + 1,
  );

  const evt = await a.waitEvent(
    "message.new",
    5000,
    (e) => messageOf(e).id === res.msgId,
  );
  const msg = messageOf(evt);
  expect(msg.body?.styles).toEqual([{ start: 0, len: 5, st: "b" }]);
  expect(msg.body?.urgency).toBe("important");
  expect(msg.body?.ttl).toBe(60_000);
  expect(typeof msg.body?.expiresAt).toBe("number");

  const page = (await a.request("messages.list", {
    threadId: "styled-thread",
    threadType: "user",
  })) as { messages: WireMessage[] };
  const stored = page.messages.find((m) => m.id === res.msgId)!;
  expect(stored.body?.ttl).toBe(60_000);

  await expect(
    a.request("messages.sendText", {
      threadId: "styled-thread",
      threadType: "user",
      cliId: "bad-style",
      text: "hello",
      styles: [{ start: 0, len: 1, st: "nope" }],
    }),
  ).rejects.toMatchObject({ code: "bad_request" });
  await expect(
    a.request("messages.sendText", {
      threadId: "styled-thread",
      threadType: "user",
      cliId: "bad-urgency",
      text: "hello",
      urgency: "now",
    }),
  ).rejects.toMatchObject({ code: "bad_request" });
  await expect(
    a.request("messages.sendText", {
      threadId: "styled-thread",
      threadType: "user",
      cliId: "bad-ttl",
      text: "hello",
      ttl: 8 * 86_400_000,
    }),
  ).rejects.toMatchObject({ code: "bad_request" });
  a.close();
  b.close();
});

test("gif uploads keep the gif kind and a real filename", async () => {
  const { a, b } = await clients();
  const bytes = new TextEncoder().encode("GIF89a");
  const stream = a.sendBlob(bytes);
  const gif = (await a.request("messages.sendMedia", {
    threadId: "gif-thread",
    threadType: "user",
    cliId: "cli-gif",
    kind: "gif",
    name: "party.gif",
    stream,
  })) as { msgId: string; cliId: string };

  const evt = await a.waitEvent(
    "message.new",
    5000,
    (e) => messageOf(e).id === gif.msgId,
  );
  expect(messageOf(evt).kind).toBe("gif");
  const call = gw.calls.find(
    (c) => c.method === "sendMedia" && c.args[2] === "gif",
  );
  expect(call).toBeDefined();

  // An image kind with a `.gif` name is routed by zca-js to the gif upload
  // too; the local record mirrors that.
  const stream2 = a.sendBlob(bytes);
  const byName = (await a.request("messages.sendMedia", {
    threadId: "gif-thread",
    threadType: "user",
    cliId: "cli-gif-name",
    kind: "image",
    name: "dance.gif",
    stream: stream2,
  })) as { msgId: string; cliId: string };
  const evt2 = await a.waitEvent(
    "message.new",
    5000,
    (e) => messageOf(e).id === byName.msgId,
  );
  expect(messageOf(evt2).kind).toBe("gif");
  a.close();
  b.close();
});

test("an explicit file send with a .gif name stays a file with its name", async () => {
  const { a, b } = await clients();
  const bytes = new TextEncoder().encode("GIF89a");
  const stream = a.sendBlob(bytes);
  const file = (await a.request("messages.sendMedia", {
    threadId: "file-gif-thread",
    threadType: "user",
    cliId: "cli-file-gif",
    kind: "file",
    name: "report.gif",
    stream,
  })) as { msgId: string; cliId: string };

  const evt = await a.waitEvent(
    "message.new",
    5000,
    (e) => messageOf(e).id === file.msgId,
  );
  const msg = messageOf(evt);
  expect(msg.kind).toBe("file");
  expect(msg.body?.attachments).toEqual([
    expect.objectContaining({ kind: "file", name: "report.gif" }),
  ]);
  a.close();
  b.close();
});

test("parseLink and sendLink carry the preview and stay idempotent", async () => {
  const { a, b } = await clients();
  const url = "https://example.com/article";
  const preview: LinkPreview = {
    title: "Article",
    description: "A read",
    srcUrl: "example.com",
    href: url,
    thumbUrl: "https://example.com/thumb.jpg",
  };
  gw.linkPreviews.set(url, preview);

  const parsed = (await a.request("messages.parseLink", { link: url })) as {
    preview: LinkPreview;
  };
  expect(parsed.preview).toEqual(preview);

  const cliId = "cli-link";
  const first = (await a.request("messages.sendLink", {
    threadId: "link-thread",
    threadType: "user",
    cliId,
    link: url,
    msg: "read this",
    ttl: 60_000,
  })) as { msgId: string; cliId: string };
  const second = (await a.request("messages.sendLink", {
    threadId: "link-thread",
    threadType: "user",
    cliId,
    link: url,
    msg: "read this",
    ttl: 60_000,
  })) as { msgId: string; cliId: string };
  expect(second).toEqual(first);
  expect(gw.calls.filter((c) => c.method === "sendLink").length).toBe(1);

  const evt = await a.waitEvent(
    "message.new",
    5000,
    (e) => messageOf(e).id === first.msgId,
  );
  const msg = messageOf(evt);
  expect(msg.kind).toBe("link");
  expect(msg.body?.attachments).toEqual([
    {
      kind: "link",
      url,
      thumbUrl: "https://example.com/thumb.jpg",
      name: "Article",
    },
  ]);
  expect(msg.body?.ttl).toBe(60_000);

  await expect(
    a.request("messages.parseLink", { link: "not a url" }),
  ).rejects.toMatchObject({ code: "bad_request" });
  await expect(
    a.request("messages.sendLink", {
      threadId: "link-thread",
      threadType: "user",
      cliId: "bad-link",
      link: "ftp://example.com/a",
    }),
  ).rejects.toMatchObject({ code: "bad_request" });
  a.close();
  b.close();
});

test("banks.list and banks.accounts return typed data with validation", async () => {
  const { a, b } = await clients();
  const banks = (await a.request("banks.list")) as {
    banks: { bin: number; shortName: string }[];
  };
  expect(banks.banks).toHaveLength(2);
  expect(banks.banks[0]).toMatchObject({ bin: 970436, shortName: "Vietcombank" });

  const accounts = (await a.request("banks.accounts", {
    page: 0,
    limit: 10,
  })) as {
    accounts: { accountNumber: string; isDefault: boolean }[];
    total: number;
    hasMore: boolean;
  };
  expect(accounts.total).toBe(1);
  expect(accounts.hasMore).toBe(false);
  expect(accounts.accounts[0]).toMatchObject({
    accountNumber: "0123456789",
    isDefault: true,
  });

  await expect(
    a.request("banks.accounts", { page: -1 }),
  ).rejects.toMatchObject({ code: "bad_request" });
  await expect(
    a.request("banks.accounts", { limit: 51 }),
  ).rejects.toMatchObject({ code: "bad_request" });
  a.close();
  b.close();
});

test("sendBankCard never invents a msgId and relies on the echo", async () => {
  const { a, b } = await clients();
  const cliId = "cli-bank";
  const first = (await a.request("messages.sendBankCard", {
    threadId: "bank-thread",
    threadType: "user",
    cliId,
    bin: 970436,
    accountNumber: "0123456789",
    holderName: "NGUYEN VAN A",
  })) as { msgId: string; cliId: string };
  expect(first).toEqual({ msgId: "", cliId });
  const second = (await a.request("messages.sendBankCard", {
    threadId: "bank-thread",
    threadType: "user",
    cliId,
    bin: 970436,
    accountNumber: "0123456789",
    holderName: "NGUYEN VAN A",
  })) as { msgId: string; cliId: string };
  expect(second).toEqual(first);
  expect(gw.calls.filter((c) => c.method === "sendBankCard").length).toBe(1);

  // The listener echo is what persists the real message.
  const evt = await a.waitEvent(
    "message.new",
    5000,
    (e) => messageOf(e).kind === "bank",
  );
  const msg = messageOf(evt);
  expect(msg.body?.bankCard).toEqual({
    bin: 970436,
    accountNumber: "0123456789",
    holderName: "NGUYEN VAN A",
    bankName: "Vietcombank",
  } satisfies BankCard);

  const page = (await a.request("messages.list", {
    threadId: "bank-thread",
    threadType: "user",
  })) as { messages: WireMessage[] };
  expect(page.messages.some((m) => m.id === msg.id)).toBe(true);

  await expect(
    a.request("messages.sendBankCard", {
      threadId: "bank-thread",
      threadType: "user",
      cliId: "bad-bin",
      bin: 0,
      accountNumber: "1",
    }),
  ).rejects.toMatchObject({ code: "bad_request" });
  a.close();
  b.close();
});

test("quick messages list, add, update and remove keep the version", async () => {
  const { a, b } = await clients();
  const list = (await a.request("quickMessages.list")) as {
    items: { id: number; title: string; media: unknown[] }[];
    version: number;
    cursor: number;
  };
  expect(list.version).toBe(4);
  expect(list.cursor).toBe(2);
  expect(list.items).toHaveLength(2);
  expect(list.items[1].media).toHaveLength(1);

  const added = (await a.request("quickMessages.add", {
    keyword: "moi",
    title: "Mới",
  })) as { item: { id: number; keyword: string }; version: number };
  expect(added.version).toBe(5);
  expect(added.item.keyword).toBe("moi");

  const updated = (await a.request("quickMessages.update", {
    id: added.item.id,
    keyword: "sua",
    title: "Đã sửa",
  })) as { item: { id: number; keyword: string; title: string }; version: number };
  expect(updated.version).toBe(6);
  expect(updated.item).toMatchObject({ id: added.item.id, keyword: "sua" });

  // Optional media rides the same blob-upload path as messages.
  const stream = a.sendBlob(new TextEncoder().encode("img"));
  const withMedia = (await a.request("quickMessages.add", {
    keyword: "anh",
    title: "Ảnh",
    mediaStream: stream,
    mediaName: "quick.jpg",
  })) as { item: { id: number } };
  const addCall = gw.calls
    .filter((c) => c.method === "addQuickMessage")
    .at(-1)!;
  expect((addCall.args[0] as { media?: { name: string } }).media?.name).toBe(
    "quick.jpg",
  );

  const removed = (await a.request("quickMessages.remove", {
    ids: [added.item.id, withMedia.item.id],
  })) as { itemIds: number[]; version: number };
  expect(removed.itemIds.sort()).toEqual(
    [added.item.id, withMedia.item.id].sort(),
  );
  expect(removed.version).toBe(8);

  await expect(
    a.request("quickMessages.add", { keyword: "", title: "x" }),
  ).rejects.toMatchObject({ code: "bad_request" });
  await expect(
    a.request("quickMessages.update", { id: 0, keyword: "x", title: "y" }),
  ).rejects.toMatchObject({ code: "bad_request" });
  await expect(
    a.request("quickMessages.remove", { ids: [] }),
  ).rejects.toMatchObject({ code: "bad_request" });
  a.close();
  b.close();
});

test("quick message text edits keep stored media, uploads replace it", async () => {
  const { a, b } = await clients();
  const kept = (await a.request("quickMessages.update", {
    id: 2,
    keyword: "banggia",
    title: "Bảng giá tháng này (mới)",
  })) as { item: { type: number; media: { photoId: number }[] } };
  expect(kept.item.type).toBe(1);
  expect(kept.item.media).toHaveLength(1);
  expect(kept.item.media[0].photoId).toBe(9001);

  const stream = a.sendBlob(new TextEncoder().encode("img"));
  const replaced = (await a.request("quickMessages.update", {
    id: 2,
    keyword: "banggia",
    title: "Bảng giá",
    mediaStream: stream,
    mediaName: "new.jpg",
  })) as { item: { type: number; media: { photoId: number }[] } };
  expect(replaced.item.type).toBe(1);
  expect(replaced.item.media).toHaveLength(1);
  expect(replaced.item.media[0].photoId).not.toBe(9001);
  a.close();
  b.close();
});

test("sendMedia carries ttl and urgency and records local expiry", async () => {
  const { a, b } = await clients();
  const before = gw.calls.filter((c) => c.method === "sendMedia").length;
  const bytes = new TextEncoder().encode("img");
  const params = {
    threadId: "media-ttl-thread",
    threadType: "user",
    cliId: "cli-media-ttl",
    kind: "image",
    name: "photo.jpg",
    ttl: 60_000,
    urgency: "urgent",
  };
  const res = (await a.request("messages.sendMedia", {
    ...params,
    stream: a.sendBlob(bytes),
  })) as { msgId: string; cliId: string };

  const call = gw.calls.filter((c) => c.method === "sendMedia").at(-1)!;
  expect(call.args[7]).toEqual({ ttl: 60_000, urgency: "urgent" });

  const evt = await a.waitEvent(
    "message.new",
    5000,
    (e) => messageOf(e).id === res.msgId,
  );
  const msg = messageOf(evt);
  expect(msg.body?.urgency).toBe("urgent");
  expect(msg.body?.ttl).toBe(60_000);
  expect(msg.body?.expiresAt).toBe(msg.ts + 60_000);

  const page = (await a.request("messages.list", {
    threadId: "media-ttl-thread",
    threadType: "user",
  })) as { messages: WireMessage[] };
  const stored = page.messages.find((m) => m.id === res.msgId)!;
  expect(stored.body?.ttl).toBe(60_000);
  expect(stored.body?.expiresAt).toBe(stored.ts + 60_000);

  // The cliId idempotency key still short-circuits a duplicate send.
  const again = (await a.request("messages.sendMedia", {
    ...params,
    stream: a.sendBlob(bytes),
  })) as { msgId: string };
  expect(again.msgId).toBe(res.msgId);
  expect(gw.calls.filter((c) => c.method === "sendMedia").length).toBe(
    before + 1,
  );
  a.close();
  b.close();
});

test("sendMedia rejects urgency for voice/video and an invalid ttl", async () => {
  const { a, b } = await clients();
  for (const [kind, name] of [
    ["voice", "clip.aac"],
    ["video", "clip.mp4"],
  ] as const) {
    await expect(
      a.request("messages.sendMedia", {
        threadId: "media-urgent-thread",
        threadType: "user",
        cliId: `cli-${kind}-urgent`,
        kind,
        name,
        stream: a.sendBlob(new TextEncoder().encode("x")),
        urgency: "urgent",
      }),
    ).rejects.toMatchObject({ code: "not_supported" });
  }
  await expect(
    a.request("messages.sendMedia", {
      threadId: "media-ttl-thread",
      threadType: "user",
      cliId: "cli-media-bad-ttl",
      kind: "image",
      name: "photo.jpg",
      stream: a.sendBlob(new TextEncoder().encode("x")),
      ttl: 8 * 86_400_000,
    }),
  ).rejects.toMatchObject({ code: "bad_request" });
  a.close();
  b.close();
});

test("per-message ttl scrubs the record and its event content", async () => {
  const { a, b } = await clients();
  const text = "self destruct payload";
  const res = (await a.request("messages.sendText", {
    threadId: "ttl-thread",
    threadType: "user",
    cliId: "cli-ttl",
    text,
    ttl: 1,
  })) as { msgId: string };
  await a.waitEvent(
    "message.new",
    5000,
    (e) => messageOf(e).id === res.msgId,
  );

  await Bun.sleep(5);
  const originalCheckpoint = env.server.store.checkpoint;
  const realCheckpoint = originalCheckpoint.bind(env.server.store);
  let checkpoints = 0;
  env.server.store.checkpoint = () => {
    checkpoints++;
    realCheckpoint();
  };
  let deleted = 0;
  try {
    deleted = await env.server.accounts.sweepTtl(slot);
  } finally {
    env.server.store.checkpoint = originalCheckpoint;
  }
  expect(deleted).toBeGreaterThanOrEqual(1);
  // The WAL is flushed so the scrubbed content is gone from disk.
  expect(checkpoints).toBeGreaterThan(0);
  await a.waitEvent(
    "message.deleted",
    5000,
    (e) => (e.data as { msgId: string }).msgId === res.msgId,
  );

  expect(env.server.store.getMessage(slot, res.msgId)).toBeNull();
  const page = (await a.request("messages.list", {
    threadId: "ttl-thread",
    threadType: "user",
  })) as { messages: WireMessage[] };
  expect(page.messages.some((m) => m.id === res.msgId)).toBe(false);

  const events = env.server.store.eventsSince(slot, 0);
  const created = events.find((e) => {
    const data = JSON.parse(e.data_json) as {
      message?: { id?: string };
    };
    return data.message?.id === res.msgId;
  });
  expect(created).toBeDefined();
  expect(created!.data_json).not.toContain(text);
  expect(created!.data_json).not.toContain("body");
  a.close();
  b.close();
});

test("structured payloads stay inside the sealed body allowlist", async () => {
  const vaultEnv = await makeEnv({ autoDeleteSweepMs: 0 });
  try {
    const vaultAdmin = await pairDevice(vaultEnv, { name: "vault-admin" });
    const control = await controlClient(vaultEnv, vaultAdmin);
    const vaultSlot = await loginQrAccount(vaultEnv, control);
    await setVaultKey(vaultEnv, control, vaultSlot);
    const a = await accountClient(vaultEnv, vaultAdmin, vaultSlot);
    const vaultGw = vaultEnv.factory.gateways.at(-1)!;
    a.events.length = 0;

    const poll: Poll = {
      id: 7,
      question: "Tối nay ăn gì?",
      options: [
        { id: 1, text: "Phở", votes: 2, voted: true },
        { id: 2, text: "Bún", votes: 1 },
      ],
    };
    const incoming = vaultGw.injectIncoming({
      threadId: "vault-thread",
      kind: "poll",
      text: poll.question,
      poll,
    });
    const evt = await a.waitEvent(
      "message.new",
      5000,
      (e) => messageOf(e).id === incoming.id,
    );
    const rec = messageOf(evt);
    expect(typeof rec.sealed).toBe("string");
    expect(rec.body).toBeUndefined();
    expect(rec.sealed).not.toContain(poll.question);

    const opened = openRecord(vaultEnv, vaultSlot, rec);
    expect(opened.poll).toEqual(poll);
    expect(opened.text).toBe(poll.question);
    expect(opened.raw).toBeDefined();
    a.close();
    control.close();
  } finally {
    await vaultEnv.cleanup();
  }
});

test("ttl sweeper follows the account lifecycle", async () => {
  const ttlEnv = await makeEnv({
    autoDeleteSweepMs: 0,
    messageTtlSweepMs: 20,
  });
  try {
    const ttlAdmin = await pairDevice(ttlEnv, { name: "ttl-admin" });
    const control = await controlClient(ttlEnv, ttlAdmin);
    const ttlSlot = await loginQrAccount(ttlEnv, control);
    expect(ttlEnv.server.accounts.hasTtlSweeper(ttlSlot)).toBe(true);
    const a = await accountClient(ttlEnv, ttlAdmin, ttlSlot);
    a.events.length = 0;

    const res = (await a.request("messages.sendText", {
      threadId: "ttl-timer-thread",
      threadType: "user",
      cliId: "cli-ttl-timer",
      text: "expire on the timer",
      ttl: 1,
    })) as { msgId: string };

    await a.waitEvent(
      "message.deleted",
      5000,
      (e) => (e.data as { msgId: string }).msgId === res.msgId,
    );
    expect(ttlEnv.server.store.getMessage(ttlSlot, res.msgId)).toBeNull();
    a.close();
    control.close();
  } finally {
    await ttlEnv.cleanup();
  }
});
