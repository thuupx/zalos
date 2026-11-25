// Regressions from real-account testing: received-request parsing shapes,
// sticker detail urls and lookups, Zalo-hosted media auth, delivered
// receipts, and one reaction per user.
import { test, expect } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ThreadType } from "@zalos/zalo-sdk";
import {
  ZcaGateway,
  enrichStickerUrl,
  normalizeZcaMessage,
} from "../src/gateway/zca.ts";
import { applyReaction } from "../src/accounts/manager.ts";
import { fetchAndCache } from "../src/media.ts";
import type { Message } from "../src/gateway/types.ts";
import {
  accountClient,
  makeEnv,
  pairDevice,
} from "./support/helpers.ts";

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

const wrap = (
  data: Record<string, unknown>,
  type = ThreadType.User,
  isSelf = false,
) => ({ type, threadId: "u1", isSelf, data }) as never;

const sticker = (content: Record<string, unknown>) =>
  normalizeZcaMessage(wrap({ ...base, msgType: "chat.sticker", content }));

test("sticker detail object carries its renderable url", () => {
  const m = sticker({
    detail: { id: 7, catId: 2, type: 3, stickerUrl: "https://s/7.png" },
  });
  expect(m.kind).toBe("sticker");
  expect(m.sticker).toEqual({
    id: 7,
    cateId: 2,
    type: 3,
    url: "https://s/7.png",
  });
});

test("sticker detail as a JSON string is parsed", () => {
  const m = sticker({
    detail: JSON.stringify({
      id: 8,
      cateId: 4,
      type: 1,
      stickerWebpUrl: "https://s/8.webp",
    }),
  });
  expect(m.sticker).toEqual({
    id: 8,
    cateId: 4,
    type: 1,
    url: "https://s/8.webp",
  });

  const uri = sticker({
    detail: JSON.stringify({ id: 9, cateId: 5, type: 2, uri: "https://s/9" }),
  });
  expect(uri.sticker?.url).toBe("https://s/9");

  const broken = sticker({
    detail: "not json",
    href: "https://fallback/10",
  });
  expect(broken.kind).toBe("sticker");
  expect(broken.sticker?.url).toBe("https://fallback/10");
});

test("sticker without a url falls back to the generic media url", () => {
  const m = sticker({
    href: "https://generic/sticker.png",
    detail: { id: 11, catId: 1, type: 1 },
  });
  expect(m.sticker).toEqual({
    id: 11,
    cateId: 1,
    type: 1,
    url: "https://generic/sticker.png",
  });
});

test("missing sticker url is filled by a detail lookup", async () => {
  const m = sticker({ detail: { id: 12, catId: 1, type: 1 } });
  expect(m.sticker?.url).toBeUndefined();
  const asked: number[][] = [];
  const out = await enrichStickerUrl(
    {
      getStickersDetail: async (ids: number[]) => {
        asked.push(ids);
        return [{ id: 12, stickerUrl: "https://looked/12.png" }];
      },
    },
    m,
  );
  expect(asked).toEqual([[12]]);
  expect(out).toBe(m);
  expect(out.sticker?.url).toBe("https://looked/12.png");
});

test("a failed sticker lookup keeps the original sticker", async () => {
  const m = sticker({ detail: { id: 13, catId: 1, type: 1 } });
  const out = await enrichStickerUrl(
    {
      getStickersDetail: async () => {
        throw new Error("sticker service down");
      },
    },
    m,
  );
  expect(out.kind).toBe("sticker");
  expect(out.sticker).toEqual({ id: 13, cateId: 1, type: 1, url: undefined });
});

test("listener still emits a sticker message when enrichment fails", async () => {
  const handlers = new Map<string, (...args: never[]) => void>();
  const api = {
    listener: {
      on: (event: string, cb: (...args: never[]) => void) =>
        handlers.set(event, cb),
      stop: () => {},
      start: () => {},
    },
    getCookie: () => ({ toJSON: () => ({ cookies: [] }) }),
    getOwnId: () => "me",
    fetchAccountInfo: async () => ({ profile: {} }),
    sendDeliveredEvent: async () => {},
    getStickersDetail: async () => {
      throw new Error("sticker service down");
    },
  };
  const gw = new ZcaGateway(
    { imei: "i", cookie: {}, userAgent: "ua" },
    { uid: "me", displayName: "me", avatarUrl: "" },
    async () => api as never,
  );
  await gw.start();
  const seen: Message[] = [];
  gw.on("message", (m) => seen.push(m));
  handlers.get("message")!({
    type: ThreadType.User,
    threadId: "u1",
    isSelf: false,
    data: {
      ...base,
      msgType: "chat.sticker",
      content: { detail: { id: 14, catId: 1, type: 1 } },
    },
  } as never);
  await Bun.sleep(10);
  expect(seen).toHaveLength(1);
  expect(seen[0].kind).toBe("sticker");
  expect(seen[0].sticker?.url).toBeUndefined();
  await gw.stop();
});

function receiptGateway() {
  const handlers = new Map<string, (...args: never[]) => void>();
  const api = {
    listener: {
      on: (event: string, cb: (...args: never[]) => void) =>
        handlers.set(event, cb),
      stop: () => {},
      start: () => {},
    },
    getCookie: () => ({ toJSON: () => ({ cookies: [] }) }),
    getOwnId: () => "me",
    fetchAccountInfo: async () => ({ profile: {} }),
    sendDeliveredEvent: async () => {},
  };
  const gw = new ZcaGateway(
    { imei: "i", cookie: {}, userAgent: "ua" },
    { uid: "me", displayName: "me", avatarUrl: "" },
    async () => api as never,
  );
  return { gw, handlers };
}

const delivered = (
  type: ThreadType,
  threadId: string,
  data: Record<string, unknown>,
) => ({ type, threadId, isSelf: false, data }) as never;

test("a user delivered event with seen=1 is a seen receipt", async () => {
  const { gw, handlers } = receiptGateway();
  await gw.start();
  const receipts: unknown[] = [];
  gw.on("receipt", (r) => receipts.push(r));

  handlers.get("delivered_messages")!([
    delivered(ThreadType.User, "777000222", {
      msgId: "m1",
      seen: 1,
      deliveredUids: ["777000222"],
      seenUids: [],
      realMsgId: "m1",
      mSTs: 1,
    }),
    delivered(ThreadType.User, "777000333", {
      msgId: "m2",
      seen: 0,
      deliveredUids: ["777000333"],
      seenUids: [],
      realMsgId: "m2",
      mSTs: 1,
    }),
    // A group event keeps delivered semantics even with seen=1.
    delivered(ThreadType.Group, "880000111", {
      msgId: "m3",
      seen: 1,
      deliveredUids: ["777000222", "777000333"],
      seenUids: ["777000222", "777000333"],
      realMsgId: "m3",
      mSTs: 1,
    }),
  ] as never);

  expect(receipts).toEqual([
    {
      threadId: "777000222",
      threadType: "user",
      kind: "seen",
      userIds: ["777000222"],
      msgId: "m1",
    },
    {
      threadId: "777000333",
      threadType: "user",
      kind: "delivered",
      userIds: ["777000333"],
      msgId: "m2",
    },
    {
      threadId: "880000111",
      threadType: "group",
      kind: "delivered",
      userIds: ["777000222", "777000333"],
      msgId: "m3",
    },
  ]);
  await gw.stop();
});

test("fetchAndCache uses a supplied gateway fetch even when fake is false", async () => {
  const dir = mkdtempSync(join(tmpdir(), "zalos-media-"));
  const calls: string[] = [];
  const gatewayFetch = async (url: string) => {
    calls.push(url);
    return {
      data: new TextEncoder().encode("auth-bytes"),
      contentType: "image/png",
    };
  };
  try {
    const url = "https://zalo.me/media/x.png";
    const hit = await fetchAndCache(dir, url, {
      slot: "s1",
      fake: false,
      gatewayFetch,
    });
    expect(calls).toEqual([url]);
    expect(hit.size).toBe(10);
    expect(hit.contentType).toBe("image/png");
    expect(
      new TextDecoder().decode(await Bun.file(hit.path).arrayBuffer()),
    ).toBe("auth-bytes");

    // Cached: a second call does not go through the gateway again.
    await fetchAndCache(dir, url, { slot: "s1", fake: false, gatewayFetch });
    expect(calls).toEqual([url]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

function gatewayWith(api: Record<string, unknown>) {
  const gw = new ZcaGateway(
    { imei: "i", cookie: {}, userAgent: "ua" },
    { uid: "me", displayName: "me", avatarUrl: "" },
    async () => api as never,
  );
  return gw;
}

test("received requests accept number and string recommType shapes", async () => {
  const calls: string[] = [];
  const api = {
    listener: { on: () => {}, stop: () => {}, start: () => {} },
    getCookie: () => ({ toJSON: () => ({ cookies: [] }) }),
    getOwnId: () => "me",
    fetchAccountInfo: async () => ({ profile: {} }),
    getFriendRecommendations: async () => ({
      recommItems: [
        {
          dataInfo: {
            userId: 111,
            displayName: "An",
            avatar: "https://a/an.jpg",
            recommType: "2",
            recommInfo: JSON.stringify({ message: "Xin chào" }),
            recommTime: "1700000000000",
          },
        },
        {
          dataInfo: {
            userId: "222",
            displayName: "Bình",
            avatar: "https://a/binh.jpg",
            recommType: 2,
            recommInfo: { customText: "Kết bạn nhé" },
            recommTime: 1700000000001,
          },
        },
        {
          dataInfo: {
            userId: "333",
            displayName: "Chi",
            avatar: "",
            recommType: 1,
            recommInfo: { message: "gợi ý" },
          },
        },
      ],
    }),
    acceptFriendRequest: async (uid: string) => {
      calls.push(`accept:${uid}`);
    },
    rejectFriendRequest: async (uid: string) => {
      calls.push(`reject:${uid}`);
    },
  };
  const gw = gatewayWith(api);
  await gw.start();
  const received = await gw.receivedFriendRequests();
  expect(received).toEqual([
    {
      uid: "111",
      displayName: "An",
      avatarUrl: "https://a/an.jpg",
      message: "Xin chào",
      ts: 1700000000000,
    },
    {
      uid: "222",
      displayName: "Bình",
      avatarUrl: "https://a/binh.jpg",
      message: "Kết bạn nhé",
      ts: 1700000000001,
    },
  ]);
  const recommended = await gw.friendRecommendations();
  expect(recommended.map((r) => r.uid)).toEqual(["333"]);

  await gw.acceptFriendRequest("111");
  await gw.rejectFriendRequest("222");
  expect(calls).toEqual(["accept:111", "reject:222"]);
  await gw.stop();
});

test("changing a reaction keeps exactly one icon per user", () => {
  const rec: { reactions: Record<string, string[]> } = {
    reactions: { "/-heart": ["u1", "u2"] },
  };
  expect(applyReaction(rec, "/-laughing", "u1")).toBe(true);
  expect(rec.reactions).toEqual({
    "/-heart": ["u2"],
    "/-laughing": ["u1"],
  });

  // Repeating the same icon is idempotent.
  expect(applyReaction(rec, "/-laughing", "u1")).toBe(false);
  expect(rec.reactions).toEqual({
    "/-heart": ["u2"],
    "/-laughing": ["u1"],
  });

  // An empty icon clears the user from every icon and prunes empty lists.
  expect(applyReaction(rec, "", "u1")).toBe(true);
  expect(rec.reactions).toEqual({ "/-heart": ["u2"] });
  expect(applyReaction(rec, "", "u2")).toBe(true);
  expect(rec.reactions).toEqual({});
});

async function accountEnv(fake: boolean) {
  const env = await makeEnv({ fake });
  const admin = await pairDevice(env, { name: "admin", role: "admin" });
  const { slot } = await env.server.accounts.addAccount({
    credentials: { imei: "i", cookie: [], userAgent: "ua" },
    self: { uid: "me", displayName: "me", avatarUrl: "" },
  });
  const a = await accountClient(env, admin, slot);
  const gw = env.factory.gateways.at(-1)!;
  return { env, a, gw };
}

test("real Zalo media uses the gateway fetch, non-Zalo hosts do not", async () => {
  const { env, a, gw } = await accountEnv(false);
  try {
    const url = "https://zalo.me/media/sticker.png";
    const res = (await a.request("media.fetch", { url })) as {
      stream: number;
    };
    const bytes = await a.waitBlob(res.stream);
    expect(new TextDecoder().decode(bytes)).toContain("fake media bytes");
    expect(
      gw.calls.some((c) => c.method === "fetchMedia" && c.args[0] === url),
    ).toBe(true);

    const before = gw.calls.filter((c) => c.method === "fetchMedia").length;
    // Non-Zalo urls keep download(), whose SSRF guard rejects this host
    // before any network call.
    await expect(
      a.request("media.fetch", { url: "http://127.0.0.1:1/x.png" }),
    ).rejects.toMatchObject({ code: "forbidden" });
    expect(
      gw.calls.filter((c) => c.method === "fetchMedia").length,
    ).toBe(before);
  } finally {
    a.close();
    await env.cleanup();
  }
});

test("fake mode keeps fetching media through the gateway", async () => {
  const { env, a, gw } = await accountEnv(true);
  try {
    const url = "https://cdn.example.com/pic.png";
    const res = (await a.request("media.fetch", { url })) as {
      stream: number;
    };
    const bytes = await a.waitBlob(res.stream);
    expect(new TextDecoder().decode(bytes)).toContain("fake media bytes");
    expect(
      gw.calls.some((c) => c.method === "fetchMedia" && c.args[0] === url),
    ).toBe(true);
  } finally {
    a.close();
    await env.cleanup();
  }
});
