// Regressions for the final review: a seen send without a stored message
// reference must fail instead of clearing local unread state, fetchMedia
// must bound redirects and body size, and receipt listeners must survive
// payloads with missing uid arrays.
import { test, expect } from "bun:test";
import { ThreadType } from "@zalos/zalo-sdk";
import { ZcaGateway } from "../src/gateway/zca.ts";
import { RpcError } from "../src/tunnel/rpc.ts";
import {
  accountClient,
  controlClient,
  loginQrAccount,
  makeEnv,
  pairDevice,
} from "./support/helpers.ts";

const MiB = 1024 * 1024;

type StubFetch = (url: URL | string, init?: RequestInit) => Promise<Response>;

function stubGateway(api: Record<string, unknown>, http?: StubFetch) {
  return new ZcaGateway(
    { imei: "i", cookie: {}, userAgent: "ua" },
    { uid: "me", displayName: "me", avatarUrl: "" },
    async () =>
      ({
        listener: { on: () => {}, stop: () => {}, start: () => {} },
        getCookie: () => ({ toJSON: () => ({ cookies: [] }) }),
        getOwnId: () => "me",
        fetchAccountInfo: async () => ({ profile: {} }),
        ...api,
      }) as never,
    http as unknown as typeof fetch | undefined,
  );
}

test("markSeen without a stored reference rejects and sends nothing", async () => {
  const seen: unknown[] = [];
  const gw = stubGateway({
    sendSeenEvent: async (params: unknown) => {
      seen.push(params);
    },
  });
  await gw.start();

  for (const raw of [undefined, null, {}, { msgId: "9" }]) {
    await expect(gw.markSeen("u1", "user", raw)).rejects.toMatchObject({
      code: "not_found",
    });
  }
  expect(seen).toHaveLength(0);

  // The successful path is unchanged.
  await gw.markSeen("u1", "user", { msgId: "9", cliMsgId: "8" });
  expect(seen).toHaveLength(1);
  await gw.stop();
});

test("a failed seen send leaves local unread state untouched", async () => {
  const env = await makeEnv();
  const admin = await pairDevice(env, { name: "admin", role: "admin" });
  const control = await controlClient(env, admin);
  const slot = await loginQrAccount(env, control);
  control.close();
  try {
    const gw = env.factory.gateways.at(-1)!;
    env.server.store.upsertThread({
      slot,
      threadId: "seen-noref",
      type: "user",
    });
    env.server.store.markUnread(slot, "seen-noref", "user");
    // The real gateway rejects a missing reference; the fake one succeeds.
    gw.markSeen = async () => {
      throw new RpcError(
        "not_found",
        "mark seen: no incoming message reference",
      );
    };

    const a = await accountClient(env, admin, slot);
    await expect(
      a.request("threads.markSeen", {
        threadId: "seen-noref",
        threadType: "user",
      }),
    ).rejects.toMatchObject({ code: "not_found" });

    const row = env.server.store.getThread(slot, "seen-noref", "user")!;
    expect(row.unread).toBe(1);
    expect(row.marked_unread).toBe(1);
    expect(gw.calls.some((c) => c.method === "removeUnreadMark")).toBe(false);
    a.close();
  } finally {
    await env.cleanup();
  }
});

test("fetchMedia follows a bounded redirect and validates each hop", async () => {
  const requested: string[] = [];
  const gw = stubGateway(
    {},
    async (url) => {
      const u = String(url);
      requested.push(u);
      if (u === "https://8.8.8.8/a.png") {
        return new Response(null, {
          status: 302,
          headers: { location: "https://1.1.1.1/b.png" },
        });
      }
      return new Response(new TextEncoder().encode("media-bytes"), {
        status: 200,
        headers: { "content-type": "image/png" },
      });
    },
  );
  await gw.start();

  const out = await gw.fetchMedia("https://8.8.8.8/a.png");
  expect(requested).toEqual(["https://8.8.8.8/a.png", "https://1.1.1.1/b.png"]);
  expect(new TextDecoder().decode(out.data)).toBe("media-bytes");
  expect(out.contentType).toBe("image/png");
  await gw.stop();
});

test("fetchMedia rejects private hosts and invalid schemes before requesting", async () => {
  for (const [location, code] of [
    ["http://127.0.0.1/secret", "forbidden"],
    ["file:///etc/passwd", "bad_request"],
  ] as const) {
    const requested: string[] = [];
    const gw = stubGateway(
      {},
      async (url) => {
        requested.push(String(url));
        return new Response(null, {
          status: 307,
          headers: { location },
        });
      },
    );
    await gw.start();
    await expect(gw.fetchMedia("https://8.8.8.8/a.png")).rejects.toMatchObject({
      code,
    });
    // Only the original hop was fetched; the redirect target never was.
    expect(requested).toEqual(["https://8.8.8.8/a.png"]);
    await gw.stop();
  }
});

test("fetchMedia rejects a chunked body over the 100 MB cap", async () => {
  const chunk = new Uint8Array(MiB);
  let sent = 0;
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (sent === 101) {
        controller.close();
        return;
      }
      sent++;
      controller.enqueue(chunk);
    },
  });
  const gw = stubGateway(
    {},
    async () =>
      new Response(body, {
        status: 200,
        headers: { "content-type": "image/png" },
      }),
  );
  await gw.start();

  await expect(gw.fetchMedia("https://8.8.8.8/a.png")).rejects.toMatchObject({
    code: "error",
    message: "too large",
  });
  // Reading stopped at the cap: the whole body was never buffered.
  expect(sent).toBe(101);
  await gw.stop();
});

test("fetchMedia rejects a declared Content-Length over the cap", async () => {
  const gw = stubGateway(
    {},
    async () =>
      ({
        status: 200,
        ok: true,
        headers: new Headers({
          "content-length": String(200 * MiB),
          "content-type": "image/png",
        }),
        body: null,
      }) as unknown as Response,
  );
  await gw.start();

  await expect(gw.fetchMedia("https://8.8.8.8/a.png")).rejects.toMatchObject({
    code: "error",
    message: "too large",
  });
  await gw.stop();
});

test("fetchMedia keeps the live Zalo cookie retry on 401/403", async () => {
  const prior = process.env.ZALOS_ZALO_MOCK_URL;
  // assertPublicUrl skips DNS for Zalo hosts while a mock url is set; the
  // fetch below is stubbed, so this only keeps the host check offline-safe.
  process.env.ZALOS_ZALO_MOCK_URL = "http://127.0.0.1:1";
  try {
    const requests: { url: string; cookie?: string }[] = [];
    const gw = stubGateway(
      {
        getCookie: () => ({
          toJSON: () => ({ cookies: [] }),
          getCookieStringSync: () => "zpw_sek=s1",
        }),
      },
      async (url, init) => {
        const headers = init?.headers as Record<string, string> | undefined;
        requests.push({ url: String(url), cookie: headers?.cookie });
        if (headers?.cookie === undefined) {
          return new Response(null, { status: 401 });
        }
        return new Response(new TextEncoder().encode("ok"), { status: 200 });
      },
    );
    await gw.start();

    const out = await gw.fetchMedia("https://zalo.me/media/x.png");
    expect(new TextDecoder().decode(out.data)).toBe("ok");
    expect(requests).toEqual([
      { url: "https://zalo.me/media/x.png", cookie: undefined },
      { url: "https://zalo.me/media/x.png", cookie: "zpw_sek=s1" },
    ]);

    // A non-Zalo host never receives the cookie: no retry, the 401 stands.
    requests.length = 0;
    await expect(
      gw.fetchMedia("https://8.8.8.8/a.png"),
    ).rejects.toMatchObject({ code: "error", message: "fetch failed: 401" });
    expect(requests).toEqual([{ url: "https://8.8.8.8/a.png", cookie: undefined }]);
    await gw.stop();
  } finally {
    if (prior === undefined) delete process.env.ZALOS_ZALO_MOCK_URL;
    else process.env.ZALOS_ZALO_MOCK_URL = prior;
  }
});

test("receipt listeners tolerate missing uid arrays", async () => {
  const handlers = new Map<string, (...args: never[]) => void>();
  const gw = stubGateway({
    listener: {
      on: (event: string, cb: (...args: never[]) => void) =>
        handlers.set(event, cb),
      stop: () => {},
      start: () => {},
    },
    sendDeliveredEvent: async () => {},
  });
  await gw.start();
  const receipts: unknown[] = [];
  gw.on("receipt", (r) => receipts.push(r));

  handlers.get("seen_messages")!([
    // Malformed: a group seen event without seenUids.
    {
      type: ThreadType.Group,
      threadId: "g1",
      isSelf: false,
      data: { msgId: "s1", groupId: "g1" },
    },
    {
      type: ThreadType.Group,
      threadId: "g2",
      isSelf: false,
      data: { msgId: "s2", groupId: "g2", seenUids: ["u2"] },
    },
  ] as never);
  handlers.get("delivered_messages")!([
    // Malformed: no deliveredUids and no seenUids.
    { type: ThreadType.User, threadId: "777", isSelf: false, data: { msgId: "d1" } },
    {
      type: ThreadType.Group,
      threadId: "g3",
      isSelf: false,
      data: { msgId: "d2" },
    },
    {
      type: ThreadType.User,
      threadId: "888",
      isSelf: false,
      data: { msgId: "d3", deliveredUids: ["888"], seenUids: [] },
    },
  ] as never);

  expect(receipts).toEqual([
    { threadId: "g1", threadType: "group", kind: "seen", userIds: [], msgId: "s1" },
    {
      threadId: "g2",
      threadType: "group",
      kind: "seen",
      userIds: ["u2"],
      msgId: "s2",
    },
    {
      threadId: "777",
      threadType: "user",
      kind: "delivered",
      userIds: ["777"],
      msgId: "d1",
    },
    {
      threadId: "g3",
      threadType: "group",
      kind: "delivered",
      userIds: [],
      msgId: "d2",
    },
    {
      threadId: "888",
      threadType: "user",
      kind: "delivered",
      userIds: ["888"],
      msgId: "d3",
    },
  ]);
  await gw.stop();
});
