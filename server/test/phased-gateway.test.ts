import { test, expect } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ThreadType, Urgency as ZcaUrgency } from "@zalos/zalo-sdk";
import { ZcaGateway } from "../src/gateway/zca.ts";
import { OaGateway } from "../src/gateway/oa.ts";
import type { Label } from "../src/gateway/types.ts";

// A zca-js API stub with the exact method names and response shapes the
// Phase D gateway code reads. No network: start() only binds the stub
// listener.
function stubApi() {
  const hiddenSets: unknown[] = [];
  const pins: string[] = [];
  let pinResets = 0;
  const archiveUpdates: unknown[] = [];
  const labelUpdates: unknown[] = [];
  const ttlUpdates: unknown[] = [];
  const sentTexts: unknown[] = [];
  const sentMedia: unknown[] = [];
  const sentVoice: unknown[] = [];
  const sentVideo: unknown[] = [];
  const quickUpdates: unknown[] = [];
  const quickCustomParams: unknown[] = [];
  const linkSends: unknown[] = [];
  const bankSends: unknown[] = [];
  const api = {
    hiddenSets,
    pins,
    pinResets: () => pinResets,
    archiveUpdates,
    labelUpdates,
    ttlUpdates,
    sentTexts,
    sentMedia,
    sentVoice,
    sentVideo,
    quickUpdates,
    quickCustomParams,
    linkSends,
    bankSends,
    zpwServiceMap: { quick_message: ["https://quick-message"] },
    // zca-js custom() hands the caller the session-bound request utils;
    // the stub records the encrypted payload and answers like Zalo.
    custom: (
      name: string,
      cb: (args: {
        ctx: unknown;
        utils: unknown;
        props: unknown;
      }) => unknown,
    ) => {
      const utils = {
        makeURL: (base: string) => base,
        encodeAES: (data: string) => {
          quickCustomParams.push(JSON.parse(data));
          return "encrypted";
        },
        request: async () => new Response("{}"),
        resolve: async () => ({
          item: {
            id: 2,
            keyword: "sua",
            type: 0,
            createdTime: 1,
            lastModified: 5,
            message: { title: "Đã sửa", params: null },
            // A sparse response must not make the gateway drop media.
            media: null,
          },
          version: 6,
        }),
      };
      Object.defineProperty(api, name, {
        value: (props: unknown) => cb({ ctx: {}, utils, props }),
      });
    },
    sendMessage: async (payload: unknown, threadId: string, type: ThreadType) => {
      const p = payload as { attachments?: unknown };
      if (Array.isArray(p.attachments)) sentMedia.push({ payload, threadId, type });
      else sentTexts.push({ payload, threadId, type });
      return { message: { msgId: 99 }, attachment: [] };
    },
    uploadAttachment: async () => [{ fileUrl: "https://up/file", fileType: "file" }],
    sendVoice: async (opts: unknown, threadId: string, type: ThreadType) => {
      sentVoice.push({ opts, threadId, type });
      return { msgId: "voice-msg-1" };
    },
    sendVideo: async (opts: unknown, threadId: string, type: ThreadType) => {
      sentVideo.push({ opts, threadId, type });
      return { msgId: 77 };
    },
    parseLink: async (link: string) => ({
      data: {
        thumb: "https://preview/thumb.jpg",
        title: "Preview title",
        desc: "Preview description",
        src: "example.com",
        href: link,
        media: {
          type: 0,
          count: 1,
          mediaTitle: "Clip",
          artist: "Artist",
          streamUrl: "https://preview/stream",
          stream_icon: "",
        },
        stream_icon: "",
      },
      error_maps: {},
    }),
    sendLink: async (opts: unknown, threadId: string, type: ThreadType) => {
      linkSends.push({ opts, threadId, type });
      return { msgId: "link-msg-1" };
    },
    sendBankCard: async (payload: unknown, threadId: string, type: ThreadType) => {
      bankSends.push({ payload, threadId, type });
      // Real Zalo answers with an empty body.
      return "";
    },
    getListBank: async () => ({
      banks: [
        {
          bin: 970436,
          logo: "https://banks/vcb.png",
          name: "Ngoại Thương",
          name_eng: "Vietcombank",
          short_name: "Vietcombank",
          search_key_word: "vcb",
        },
        { bin: 0, name: "ignored" },
        { bin: 970422 },
      ],
    }),
    getListBankAccount: async (page: number, limit: number) => ({
      hasMore: true,
      total: 3,
      myBanks: [
        {
          id: "acc-1",
          bin: 970436,
          bank_number: "0123456789",
          holder_name: "NGUYEN VAN A",
          is_default: true,
          account_id: 11,
          created_at: 1,
          updated_at: 2,
        },
        { id: "acc-bad" },
      ],
      page,
      limit,
    }),
    getQuickMessageList: async () => ({
      cursor: 2,
      version: 4,
      items: [
        {
          id: 1,
          keyword: "chao",
          type: 0,
          createdTime: 1,
          lastModified: 2,
          message: { title: "Chào bạn", params: null },
          media: null,
        },
        {
          id: 2,
          keyword: "anh",
          type: 1,
          createdTime: 1,
          lastModified: 2,
          message: { title: "Ảnh", params: null },
          media: {
            items: [
              {
                type: 0,
                photoId: 9001,
                title: "",
                width: 640,
                height: 480,
                previewThumb: "https://qm/t.jpg",
                rawUrl: "https://qm/r.jpg",
                thumbUrl: "https://qm/t.jpg",
                normalUrl: "https://qm/n.jpg",
                hdUrl: "https://qm/h.jpg",
              },
            ],
          },
        },
        { id: "bad", keyword: "ignored" },
      ],
    }),
    addQuickMessage: async (payload: { keyword: string; title: string }) => ({
      item: {
        id: 9,
        keyword: payload.keyword,
        type: 0,
        createdTime: 3,
        lastModified: 3,
        message: { title: payload.title, params: null },
        media: null,
      },
      version: 5,
    }),
    updateQuickMessage: async (
      payload: { keyword: string; title: string; media?: unknown },
      itemId: number,
    ) => {
      quickUpdates.push({ payload, itemId });
      return {
        item: {
          id: itemId,
          keyword: payload.keyword,
          type: Array.isArray(payload.media) && payload.media.length > 0 ? 1 : 0,
          createdTime: 3,
          lastModified: 4,
          message: { title: payload.title, params: null },
          media: null,
        },
        version: 6,
      };
    },
    removeQuickMessage: async (ids: number[]) => ({ itemIds: ids, version: 7 }),
    getCookie: () => ({ toJSON: () => ({ cookies: [] }) }),
    getOwnId: () => "me",
    fetchAccountInfo: async () => ({
      profile: { displayName: "Me", avatar: "" },
    }),
    listener: { on: () => {}, stop: () => {}, start: () => {} },
    getPinConversations: async () => ({
      conversations: ["u777000222"],
    }),
    // Real zca-js shape: user and group mutes arrive in separate lists.
    getMute: async () => ({
      chatEntries: [
        {
          id: "777000222",
          duration: -1,
          startTime: 1,
          systemTime: 1,
          currentTime: 1,
          muteMode: 0,
        },
      ],
      groupChatEntries: [
        {
          id: "880000111",
          duration: -1,
          startTime: 1,
          systemTime: 1,
          currentTime: 1,
          muteMode: 0,
        },
      ],
    }),
    getHiddenConversations: async () => ({
      pin: "deadbeefdeadbeefdeadbeefdeadbeef",
      threads: [
        { is_group: 0, thread_id: "777000222" },
        { is_group: 1, thread_id: "880000111" },
        { is_group: 0 },
        null,
      ],
    }),
    setHiddenConversations: async (
      hidden: boolean,
      threadIds: string[],
      type: ThreadType,
    ) => {
      hiddenSets.push({ hidden, threadIds, type });
      return "";
    },
    updateHiddenConversPin: async (pin: string) => {
      pins.push(pin);
      return "";
    },
    resetHiddenConversPin: async () => {
      pinResets++;
      return "";
    },
    getArchivedChatList: async () => ({
      items: [
        { id: "880000111", type: 1 },
        { id: "777000222", type: 0 },
        "g999",
        { threadId: "777000333", isGroup: true },
        { id: "bad" },
        { id: "x", type: 9 },
      ],
      version: 7,
    }),
    updateArchivedChatList: async (archived: boolean, convs: unknown[]) => {
      archiveUpdates.push({ archived, convs });
      return { needSync: true, version: 8 };
    },
    getLabels: async () => ({
      labelData: [
        {
          id: 1,
          text: "Gia đình",
          textKey: "",
          conversations: ["777000222", ""],
          color: "#e91e63",
          offset: 0,
          emoji: "",
          createTime: 1700000000000,
        },
        { id: "bad", text: "ignored" },
      ],
      version: 3,
      lastUpdateTime: 1700000000000,
    }),
    updateLabels: async (payload: { labelData: unknown[]; version: number }) => {
      labelUpdates.push(payload);
      return {
        labelData: payload.labelData,
        version: payload.version + 1,
        lastUpdateTime: 1700000000001,
      };
    },
    getAutoDeleteChat: async () => ({
      convers: [
        {
          destId: "777000222",
          isGroup: false,
          ttl: 86_400_000,
          createdAt: 1,
        },
        { destId: "880000111", isGroup: true, ttl: 12_345, createdAt: 2 },
        { destId: "777000333", isGroup: true, ttl: 604_800_000 },
        { isGroup: true, ttl: 1 },
      ],
    }),
    updateAutoDeleteChat: async (
      ttl: number,
      threadId: string,
      type: ThreadType,
    ) => {
      ttlUpdates.push({ ttl, threadId, type });
      return "";
    },
    getListDevice: async () => ({
      devices: {
        masterId: "777000111",
        encIdentity: "SECRET-IDENTITY",
        lastUpdateTs: 1_700_000_000_000,
        encSignature: "SECRET-SIGNATURE",
        companions: [
          {
            deviceName: "iPhone 15",
            platform: "ios",
            lastUpdateTs: 1_700_000_000_000,
            current: true,
            publicIdentityKey: "SECRET-KEY",
          },
          {
            data: {
              deviceName: "MacBook Pro",
              platform: "macos",
              lastUpdateTs: 1_699_999_999_000,
              deviceSignature: "SECRET-SIG",
            },
          },
          { opaque: "SECRET-OPAQUE" },
          "SECRET-STRING",
        ],
      },
    }),
  };
  return api;
}

async function startedGateway() {
  const api = stubApi();
  const gw = new ZcaGateway(
    { imei: "i", cookie: {}, userAgent: "ua" },
    { uid: "me", displayName: "me", avatarUrl: "" },
    async () => api as never,
  );
  await gw.start();
  return { api, gw };
}

test("hiddenConversations reports pinSet and never leaks the pin hash", async () => {
  const { gw } = await startedGateway();
  const hidden = await gw.hiddenConversations();
  expect(hidden.pinSet).toBe(true);
  expect(hidden.threads).toEqual([
    { threadId: "777000222", threadType: "user" },
    { threadId: "880000111", threadType: "group" },
  ]);
  expect(JSON.stringify(hidden)).not.toContain("deadbeef");
  await gw.stop();
});

test("setHiddenConversations groups ids by thread type", async () => {
  const { api, gw } = await startedGateway();
  await gw.setHiddenConversations(
    [
      { threadId: "777000222", threadType: "user" },
      { threadId: "880000111", threadType: "group" },
    ],
    true,
  );
  expect(api.hiddenSets).toEqual([
    { hidden: true, threadIds: ["777000222"], type: ThreadType.User },
    { hidden: true, threadIds: ["880000111"], type: ThreadType.Group },
  ]);
  await gw.stop();
});

test("hidden pin is validated, forwarded once, and never echoed", async () => {
  const { api, gw } = await startedGateway();
  const bad = gw.setHiddenPin("12a4");
  await expect(bad).rejects.toMatchObject({ code: "bad_request" });
  const err = (await bad.catch((e) => e)) as Error;
  expect(err.message).not.toContain("12a4");
  expect(api.pins).toEqual([]);

  await gw.setHiddenPin("1234");
  expect(api.pins).toEqual(["1234"]);
  await gw.resetHiddenPin();
  expect(api.pinResets()).toBe(1);
  await gw.stop();
});

test("archivedChatList parses untyped items and skips unknown shapes", async () => {
  const { gw } = await startedGateway();
  const list = await gw.archivedChatList();
  expect(list.version).toBe(7);
  expect(list.threads).toEqual([
    { threadId: "880000111", threadType: "group" },
    { threadId: "777000222", threadType: "user" },
    { threadId: "999", threadType: "group" },
    { threadId: "777000333", threadType: "group" },
  ]);
  await gw.stop();
});

test("updateArchivedChatList maps targets and reads needSync", async () => {
  const { api, gw } = await startedGateway();
  const res = await gw.updateArchivedChatList(false, [
    { threadId: "777000222", threadType: "user" },
    { threadId: "880000111", threadType: "group" },
  ]);
  expect(res).toEqual({ needResync: true, version: 8 });
  expect(api.archiveUpdates).toEqual([
    {
      archived: false,
      convs: [
        { id: "777000222", type: ThreadType.User },
        { id: "880000111", type: ThreadType.Group },
      ],
    },
  ]);
  await gw.stop();
});

test("labels parse labelData and whole-set updates keep the version", async () => {
  const { api, gw } = await startedGateway();
  const state = await gw.labels();
  expect(state.version).toBe(3);
  expect(state.lastUpdateTime).toBe(1_700_000_000_000);
  expect(state.labels).toEqual([
    {
      id: 1,
      text: "Gia đình",
      textKey: "",
      conversations: ["777000222"],
      color: "#e91e63",
      offset: 0,
      emoji: "",
      createTime: 1_700_000_000_000,
    },
  ]);

  const labels: Label[] = [
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
  const updated = await gw.updateLabels(labels, 3);
  expect(updated.version).toBe(4);
  expect(updated.labels).toEqual(labels);
  expect(api.labelUpdates).toEqual([{ labelData: labels, version: 3 }]);
  await gw.stop();
});

test("autoDeleteChat normalizes unsupported TTLs and skips bad entries", async () => {
  const { gw } = await startedGateway();
  const state = await gw.autoDeleteChat();
  expect(state.conversations).toEqual([
    {
      threadId: "777000222",
      threadType: "user",
      ttl: 86_400_000,
      createdAt: 1,
    },
    {
      threadId: "880000111",
      threadType: "group",
      ttl: 0,
      createdAt: 2,
    },
    { threadId: "777000333", threadType: "group", ttl: 604_800_000 },
  ]);
  await gw.stop();
});

test("updateAutoDeleteChat rejects unsupported TTLs and maps the type", async () => {
  const { api, gw } = await startedGateway();
  await expect(
    gw.updateAutoDeleteChat("880000111", "group", 30_000),
  ).rejects.toMatchObject({ code: "bad_request" });
  expect(api.ttlUpdates).toEqual([]);

  await gw.updateAutoDeleteChat("880000111", "group", 604_800_000);
  expect(api.ttlUpdates).toEqual([
    {
      ttl: 604_800_000,
      threadId: "880000111",
      type: ThreadType.Group,
    },
  ]);
  await gw.stop();
});

test("linkedDevices drops opaque crypto and summarizes unknown companions", async () => {
  const { gw } = await startedGateway();
  const devices = await gw.linkedDevices();
  expect(devices.masterId).toBe("777000111");
  expect(devices.lastUpdateTs).toBe(1_700_000_000_000);
  expect(devices.companions).toEqual([
    {
      name: "iPhone 15",
      platform: "ios",
      lastUpdateTs: 1_700_000_000_000,
      current: true,
    },
    {
      name: "MacBook Pro",
      platform: "macos",
      lastUpdateTs: 1_699_999_999_000,
    },
    { summary: "object(opaque)" },
    { summary: "string(13)" },
  ]);
  const wire = JSON.stringify(devices);
  expect(wire).not.toContain("SECRET");
  expect(wire).not.toContain("publicIdentityKey");
  await gw.stop();
});

test("syncConversationState carries hidden, archived and auto-delete", async () => {
  const { gw } = await startedGateway();
  const state = await gw.syncConversationState();
  expect(state.pinned).toEqual([{ threadId: "777000222", threadType: "user" }]);
  expect(state.muted).toEqual([
    { threadId: "777000222", threadType: "user" },
    { threadId: "880000111", threadType: "group" },
  ]);
  expect(state.hidden).toEqual([
    { threadId: "777000222", threadType: "user" },
    { threadId: "880000111", threadType: "group" },
  ]);
  expect(state.archived).toHaveLength(4);
  expect(state.autoDelete).toHaveLength(3);
  await gw.stop();
});

test("getMute reads the real user and group entry lists", async () => {
  const { api, gw } = await startedGateway();
  const entry = (id: string) => ({
    id,
    duration: -1,
    startTime: 1,
    systemTime: 1,
    currentTime: 1,
    muteMode: 0,
  });
  api.getMute = async () => ({
    chatEntries: [entry("777000222"), entry("")],
    groupChatEntries: [entry("880000111")],
  });
  const state = await gw.syncConversationState();
  expect(state.muted).toEqual([
    { threadId: "777000222", threadType: "user" },
    { threadId: "880000111", threadType: "group" },
  ]);
  await gw.stop();
});

test("a failed sync section is omitted instead of reported empty", async () => {
  const { api, gw } = await startedGateway();
  api.getHiddenConversations = async () => {
    throw new Error("hidden endpoint offline");
  };
  api.getArchivedChatList = async () => {
    throw new Error("archive endpoint offline");
  };
  api.getAutoDeleteChat = async () => {
    throw new Error("auto-delete endpoint offline");
  };
  const state = await gw.syncConversationState();
  // Absent means "unknown": the manager keeps the local flags rather than
  // clearing them from an empty list.
  expect(state.hidden).toBeUndefined();
  expect(state.archived).toBeUndefined();
  expect(state.autoDelete).toBeUndefined();
  // The other sections still converge.
  expect(state.pinned).toHaveLength(1);
  expect(state.muted).toHaveLength(2);
  await gw.stop();
});

test("failed pin and mute endpoints are omitted instead of reported empty", async () => {
  const { api, gw } = await startedGateway();
  api.getPinConversations = async () => {
    throw new Error("pin endpoint offline");
  };
  api.getMute = async () => {
    throw new Error("mute endpoint offline");
  };
  const state = await gw.syncConversationState();
  // Absent means "unknown": an empty list would clear every local flag.
  expect(state.pinned).toBeUndefined();
  expect(state.muted).toBeUndefined();
  // The independent sections still converge.
  expect(state.hidden).toHaveLength(2);
  expect(state.archived).toHaveLength(4);
  expect(state.autoDelete).toHaveLength(3);
  await gw.stop();
});

test("empty pin and mute responses report empty sections", async () => {
  const { api, gw } = await startedGateway();
  api.getPinConversations = async () => ({ conversations: [] });
  api.getMute = async () => ({ chatEntries: [], groupChatEntries: [] });
  const state = await gw.syncConversationState();
  // An empty list is Zalo's answer: stale local flags are cleared.
  expect(state.pinned).toEqual([]);
  expect(state.muted).toEqual([]);
  await gw.stop();
});

test("OA keeps the Phase D surface unsupported", async () => {
  const oa = new OaGateway(
    { appId: "a", appSecret: "s", accessToken: "t", refreshToken: "r" },
    { uid: "oa-1", displayName: "OA", avatarUrl: "" },
    { onCredentials: () => {}, clientConnected: () => false },
  );
  expect(oa.capabilities()).toEqual([]);
  const calls = [
    () => oa.hiddenConversations(),
    () => oa.setHiddenConversations(),
    () => oa.setHiddenPin(),
    () => oa.resetHiddenPin(),
    () => oa.archivedChatList(),
    () => oa.updateArchivedChatList(),
    () => oa.labels(),
    () => oa.updateLabels(),
    () => oa.autoDeleteChat(),
    () => oa.updateAutoDeleteChat(),
    () => oa.linkedDevices(),
  ];
  for (const call of calls) {
    await expect((async () => call())()).rejects.toMatchObject({
      code: "not_supported",
    });
  }
});

test("sendText maps styles, urgency and ttl to zca-js", async () => {
  const { api, gw } = await startedGateway();
  await gw.sendText("u1", "user", "hello", {
    styles: [
      { start: 0, len: 5, st: "b" },
      { start: 0, len: 5, st: "ind_$", indentSize: 2 },
    ],
    urgency: "urgent",
    ttl: 60_000,
  });
  const sent = (api.sentTexts as { payload: Record<string, unknown> }[])[0];
  expect(sent.payload.styles).toEqual([
    { start: 0, len: 5, st: "b" },
    { start: 0, len: 5, st: "ind_$", indentSize: 2 },
  ]);
  expect(sent.payload.urgency).toBe(ZcaUrgency.Urgent);
  expect(sent.payload.ttl).toBe(60_000);
  await gw.stop();
});

test("gif sends keep a real .gif filename for the dedicated upload", async () => {
  const dir = mkdtempSync(join(tmpdir(), "zalos-gif-"));
  const path = join(dir, "upload.bin");
  writeFileSync(path, Buffer.from("GIF89a"));
  const { api, gw } = await startedGateway();

  await gw.sendMedia("u1", "user", "gif", { name: "party.gif", path });
  await gw.sendMedia("u1", "user", "gif", { name: "no-ext", path });
  await gw.sendMedia("u1", "user", "image", { name: "already.gif", path });

  const sends = api.sentMedia as {
    payload: { attachments: string[] };
  }[];
  expect(sends).toHaveLength(3);
  for (const send of sends) {
    expect(send.payload.attachments[0].endsWith(".gif")).toBe(true);
  }
  expect(sends[1].payload.attachments[0].endsWith("no-ext.gif")).toBe(true);
  await gw.stop();
});

test("an explicit file send with a .gif name is not uploaded as a gif", async () => {
  const dir = mkdtempSync(join(tmpdir(), "zalos-gif-file-"));
  const path = join(dir, "upload.bin");
  writeFileSync(path, Buffer.from("GIF89a"));
  const { api, gw } = await startedGateway();

  const file = { name: "report.gif", path };
  await gw.sendMedia("u1", "user", "file", file);

  const sends = api.sentMedia as { payload: { attachments: string[] } }[];
  expect(sends).toHaveLength(1);
  // zca-js would route a `.gif` name to the gif upload; staging under a
  // neutral extension keeps the file pipeline.
  expect(sends[0].payload.attachments[0].endsWith(".gif")).toBe(false);
  expect(sends[0].payload.attachments[0].endsWith("report.bin")).toBe(true);
  // The caller's name is untouched: the local record keeps it.
  expect(file.name).toBe("report.gif");
  await gw.stop();
  rmSync(dir, { recursive: true, force: true });
});

test("parseLink, sendLink and sendBankCard map the real payloads", async () => {
  const { api, gw } = await startedGateway();
  const preview = await gw.parseLink("https://example.com/a");
  expect(preview).toEqual({
    title: "Preview title",
    description: "Preview description",
    srcUrl: "example.com",
    href: "https://example.com/a",
    thumbUrl: "https://preview/thumb.jpg",
    mediaType: 0,
    mediaCount: 1,
    mediaTitle: "Clip",
    mediaArtist: "Artist",
    streamUrl: "https://preview/stream",
  });

  const link = await gw.sendLink("u1", "user", {
    link: "https://example.com/a",
    msg: "look",
    ttl: 60_000,
  });
  expect(link).toEqual({ msgId: "link-msg-1" });
  expect(api.linkSends).toEqual([
    {
      opts: { link: "https://example.com/a", msg: "look", ttl: 60_000 },
      threadId: "u1",
      type: ThreadType.User,
    },
  ]);

  // An empty response is honest: no invented msgId.
  const bank = await gw.sendBankCard("u1", "user", {
    bin: 970436,
    accountNumber: "0123456789",
    holderName: "Nguyen Van A",
  });
  expect(bank).toEqual({ msgId: "" });
  expect(api.bankSends).toEqual([
    {
      payload: {
        binBank: 970436,
        numAccBank: "0123456789",
        nameAccBank: "Nguyen Van A",
      },
      threadId: "u1",
      type: ThreadType.User,
    },
  ]);
  await gw.stop();
});

test("bank list and accounts normalize typed rows", async () => {
  const { gw } = await startedGateway();
  const banks = await gw.bankList();
  expect(banks).toEqual([
    {
      bin: 970436,
      logo: "https://banks/vcb.png",
      name: "Ngoại Thương",
      nameEn: "Vietcombank",
      shortName: "Vietcombank",
      searchKeyword: "vcb",
    },
  ]);
  const accounts = await gw.bankAccounts(1, 10);
  expect(accounts.total).toBe(3);
  expect(accounts.hasMore).toBe(true);
  expect(accounts.accounts).toEqual([
    {
      id: "acc-1",
      bin: 970436,
      accountNumber: "0123456789",
      holderName: "NGUYEN VAN A",
      isDefault: true,
      accountId: 11,
      createdAt: 1,
      updatedAt: 2,
    },
  ]);
  await gw.stop();
});

test("quick messages keep cursor, version and typed media", async () => {
  const { api, gw } = await startedGateway();
  const list = await gw.quickMessages();
  expect(list.cursor).toBe(2);
  expect(list.version).toBe(4);
  expect(list.items).toHaveLength(2);
  expect(list.items[0]).toEqual({
    id: 1,
    keyword: "chao",
    title: "Chào bạn",
    type: 0,
    createdTime: 1,
    lastModified: 2,
    media: [],
  });
  expect(list.items[1].media).toEqual([
    {
      type: 0,
      photoId: 9001,
      title: "",
      width: 640,
      height: 480,
      previewThumb: "https://qm/t.jpg",
      rawUrl: "https://qm/r.jpg",
      thumbUrl: "https://qm/t.jpg",
      normalUrl: "https://qm/n.jpg",
      hdUrl: "https://qm/h.jpg",
    },
  ]);

  const added = await gw.addQuickMessage({ keyword: "moi", title: "Mới" });
  expect(added.version).toBe(5);
  expect(added.item).toMatchObject({ id: 9, keyword: "moi", title: "Mới" });
  const updated = await gw.updateQuickMessage(9, {
    keyword: "sua",
    title: "Đã sửa",
  });
  expect(updated.version).toBe(6);
  expect(updated.item).toMatchObject({ id: 9, keyword: "sua" });
  const removed = await gw.removeQuickMessages([9]);
  expect(removed).toEqual({ itemIds: [9], version: 7 });
  expect((api.removeQuickMessage as unknown)).toBeDefined();
  await gw.stop();
});

test("quick message text edits keep the stored photoId", async () => {
  const { api, gw } = await startedGateway();
  const updated = await gw.updateQuickMessage(2, {
    keyword: "sua",
    title: "Đã sửa",
  });
  expect(updated.version).toBe(6);
  // Direct SDK updateQuickMessage carries the existing media item array.
  expect(api.quickUpdates).toHaveLength(1);
  expect(api.quickUpdates[0]).toMatchObject({
    itemId: 2,
    payload: {
      keyword: "sua",
      title: "Đã sửa",
      media: [{ photoId: 9001, normalUrl: "https://qm/n.jpg" }],
    },
  });
  // A sparse Zalo response must not hand the client an item without media.
  expect(updated.item.media).toEqual([
    {
      type: 0,
      photoId: 9001,
      title: "",
      width: 640,
      height: 480,
      previewThumb: "https://qm/t.jpg",
      rawUrl: "https://qm/r.jpg",
      thumbUrl: "https://qm/t.jpg",
      normalUrl: "https://qm/n.jpg",
      hdUrl: "https://qm/h.jpg",
    },
  ]);
  expect(updated.item.type).toBe(1);
  await gw.stop();
});

test("quick message replacement upload goes through the public payload", async () => {
  const { api, gw } = await startedGateway();
  const updated = await gw.updateQuickMessage(2, {
    keyword: "anh",
    title: "Ảnh mới",
    media: { name: "new.jpg", path: "/tmp/new.jpg" },
  });
  expect(updated.version).toBe(6);
  expect(api.quickUpdates).toEqual([
    { payload: { keyword: "anh", title: "Ảnh mới", media: "/tmp/new.jpg" }, itemId: 2 },
  ]);
  expect(api.quickCustomParams).toHaveLength(0);
  await gw.stop();
});

test("sendMedia passes ttl and urgency to zca-js where supported", async () => {
  const { api, gw } = await startedGateway();
  const dir = mkdtempSync(join(tmpdir(), "zalos-send-"));
  const image = join(dir, "photo.jpg");
  const voice = join(dir, "clip.aac");
  const video = join(dir, "clip.mp4");
  writeFileSync(image, "img");
  writeFileSync(voice, "voice");
  writeFileSync(video, "video");
  try {
    await gw.sendMedia(
      "u1",
      "user",
      "image",
      { name: "photo.jpg", path: image },
      "cap",
      "cli-image",
      { ttl: 60_000, urgency: "urgent" },
    );
    expect(api.sentMedia.at(-1)).toMatchObject({
      payload: { ttl: 60_000, urgency: ZcaUrgency.Urgent },
    });

    await gw.sendMedia(
      "u1",
      "user",
      "voice",
      { name: "clip.aac", path: voice },
      undefined,
      "cli-voice",
      { ttl: 30_000 },
    );
    expect(api.sentVoice.at(-1)).toMatchObject({
      opts: { voiceUrl: "https://up/file", ttl: 30_000 },
    });

    await gw.sendMedia(
      "u1",
      "user",
      "video",
      { name: "clip.mp4", path: video },
      undefined,
      "cli-video",
      { ttl: 30_000 },
    );
    expect(api.sentVideo.at(-1)).toMatchObject({
      opts: { videoUrl: "https://up/file", ttl: 30_000 },
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
    await gw.stop();
  }
});

test("OA keeps the Phase D messaging surface unsupported", async () => {
  const oa = new OaGateway(
    { appId: "a", appSecret: "s", accessToken: "t", refreshToken: "r" },
    { uid: "oa-1", displayName: "OA", avatarUrl: "" },
    { onCredentials: () => {}, clientConnected: () => false },
  );
  const calls = [
    () => oa.parseLink(),
    () => oa.sendLink(),
    () => oa.sendBankCard(),
    () => oa.bankList(),
    () => oa.bankAccounts(),
    () => oa.quickMessages(),
    () => oa.addQuickMessage(),
    () => oa.updateQuickMessage(),
    () => oa.removeQuickMessages(),
  ];
  for (const call of calls) {
    await expect((async () => call())()).rejects.toMatchObject({
      code: "not_supported",
    });
  }
});
