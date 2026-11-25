import { test, expect } from "bun:test";
import { ThreadType } from "@zalos/zalo-sdk";
import { ZcaGateway } from "../src/gateway/zca.ts";
import { OaGateway } from "../src/gateway/oa.ts";

// A zca-js API stub with the exact method names and response shapes the
// gateway reads. No network: ZcaGateway.start only binds the stub listener.
function stubApi() {
  const sentReports: unknown[] = [];
  const deleted: unknown[] = [];
  const cards: unknown[] = [];
  const api = {
    reports: sentReports,
    deletes: deleted,
    cards,
    getCookie: () => ({ toJSON: () => ({ cookies: [] }) }),
    getOwnId: () => "me",
    fetchAccountInfo: async () => ({
      profile: { displayName: "Me", avatar: "" },
    }),
    listener: { on: () => {}, stop: () => {}, start: () => {} },
    getAllFriends: async () => [
      {
        userId: "777000222",
        displayName: "Trần Thị Hoa",
        avatar: "https://a/hoa.jpg",
      },
    ],
    getAliasList: async (_count: number, page: number) =>
      page === 1
        ? {
            items: [
              { userId: "777000222", alias: "Hoa" },
              { userId: "777000999", alias: "" },
            ],
            updateTime: "1700000000000",
          }
        : { items: [], updateTime: "1700000000000" },
    getCloseFriends: async () => [{ userId: "777000222" }],
    getFriendRecommendations: async () => ({
      expiredDuration: 0,
      collapseMsgListConfig: {
        collapseId: 0,
        collapseXItem: 0,
        collapseYItem: 0,
      },
      recommItems: [
        {
          recommItemType: 1,
          dataInfo: {
            userId: "777000444",
            zaloName: "Phạm Minh Đức",
            displayName: "Phạm Minh Đức",
            avatar: "https://a/duc.jpg",
            phoneNumber: "0912000003",
            status: "",
            gender: 0,
            dob: 0,
            type: 1,
            recommType: 2,
            recommSrc: 0,
            recommTime: 1700000000000,
            recommInfo: {
              suggestWay: 0,
              source: 0,
              message: "Xin chào",
              customText: null,
            },
            bizPkg: { pkgId: 0 },
            isSeenFriendReq: false,
          },
        },
        {
          recommItemType: 1,
          dataInfo: {
            userId: "777000555",
            zaloName: "Vũ Thu Hằng",
            displayName: "Vũ Thu Hằng",
            avatar: "https://a/hang.jpg",
            phoneNumber: "0912000004",
            status: "",
            gender: 1,
            dob: 0,
            type: 1,
            recommType: 1,
            recommSrc: 0,
            recommTime: 1700000000000,
            recommInfo: {
              suggestWay: 0,
              source: 0,
              message: "Có 5 bạn chung",
              customText: null,
            },
            bizPkg: { pkgId: 0 },
            isSeenFriendReq: false,
          },
        },
      ],
    }),
    getSentFriendRequest: async () => ({
      "777000666": {
        userId: "777000666",
        zaloName: "Đỗ Anh Tuấn",
        displayName: "Đỗ Anh Tuấn",
        avatar: "https://a/tuan.jpg",
        globalId: "777000666",
        bizPkg: { pkgId: 0 },
        fReqInfo: { message: "Kết bạn nhé", src: 30, time: 1700000000000 },
      },
    }),
    getFriendOnlines: async () => ({
      predefine: [],
      ownerStatus: "online",
      onlines: [
        { userId: "777000222", status: "online" },
        { userId: "777000333", status: "offline" },
        { userId: "777000444", status: "hidden" },
        { userId: "777000555", status: "active" },
        { userId: "777000666", status: "1712345678901" },
        { userId: "777000777", status: "away" },
        { userId: "777000888", status: "" },
      ],
    }),
    lastOnline: async (_uid: string) => ({
      settings: { show_online_status: true },
      lastOnline: 1700000000000,
    }),
    findUser: async (phone: string) =>
      phone === "0900000000"
        ? {
            uid: "777000222",
            display_name: "Trần Thị Hoa",
            zalo_name: "Hoa",
            avatar: "https://a/hoa.jpg",
            gender: 1,
          }
        : {},
    findUserByUsername: async (_username: string) => ({
      data: {
        uid: "777000333",
        display_name: "Lê Quốc Bảo",
        avatar: "https://a/bao.jpg",
        gender: 0,
      },
    }),
    getFriendRequestStatus: async (_uid: string) => ({
      addFriendPrivacy: 0,
      isSeenFriendReq: true,
      is_friend: 0,
      is_requested: 1,
      is_requesting: 0,
    }),
    sendReport: async (options: unknown, threadId: string, type: ThreadType) => {
      sentReports.push({ options, threadId, type });
      return { reportId: "report-1" };
    },
    deleteMessage: async (dest: unknown, onlyMe: boolean) => {
      deleted.push({ dest, onlyMe });
      return { status: 0 };
    },
    sendCard: async (
      options: unknown,
      threadId: string,
      type: ThreadType,
    ) => {
      cards.push({ options, threadId, type });
      return { msgId: 123 };
    },
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

test("listFriends merges aliases and the close-friend flag", async () => {
  const { gw } = await startedGateway();
  const contacts = await gw.listFriends();
  expect(contacts).toHaveLength(1);
  expect(contacts[0]).toEqual({
    uid: "777000222",
    displayName: "Trần Thị Hoa",
    avatarUrl: "https://a/hoa.jpg",
    alias: "Hoa",
    closeFriend: true,
  });
  await gw.stop();
});

test("received requests and recommendations split by recommType", async () => {
  const { gw } = await startedGateway();
  const received = await gw.receivedFriendRequests();
  expect(received).toEqual([
    {
      uid: "777000444",
      displayName: "Phạm Minh Đức",
      avatarUrl: "https://a/duc.jpg",
      message: "Xin chào",
      ts: 1700000000000,
    },
  ]);
  const recommended = await gw.friendRecommendations();
  expect(recommended).toEqual([
    {
      uid: "777000555",
      displayName: "Vũ Thu Hằng",
      avatarUrl: "https://a/hang.jpg",
      phoneNumber: "0912000004",
      gender: "female",
      message: "Có 5 bạn chung",
    },
  ]);
  await gw.stop();
});

test("sent requests map fReqInfo and drop empty fields", async () => {
  const { gw } = await startedGateway();
  const sent = await gw.sentFriendRequests();
  expect(sent).toEqual([
    {
      uid: "777000666",
      displayName: "Đỗ Anh Tuấn",
      avatarUrl: "https://a/tuan.jpg",
      message: "Kết bạn nhé",
      ts: 1700000000000,
    },
  ]);
  await gw.stop();
});

test("presence maps status strings and lastOnline settings", async () => {
  const { gw } = await startedGateway();
  const presence = await gw.friendOnlines();
  // Only explicit online/active values light the dot; timestamps and
  // unknown opaque strings must not be treated as online.
  expect(presence).toEqual([
    { uid: "777000222", status: "online", online: true },
    { uid: "777000333", status: "offline", online: false },
    { uid: "777000444", status: "hidden", online: false },
    { uid: "777000555", status: "active", online: true },
    { uid: "777000666", status: "1712345678901", online: false },
    { uid: "777000777", status: "away", online: false },
    { uid: "777000888", status: "", online: false },
  ]);
  const seen = await gw.lastOnline("777000222");
  expect(seen).toEqual({
    showOnlineStatus: true,
    lastOnline: 1700000000000,
  });
  await gw.stop();
});

test("findUser maps UserBasic, wrapped data, and a missing user", async () => {
  const { gw } = await startedGateway();
  const found = await gw.findUserByPhone("0900000000");
  expect(found).toEqual({
    uid: "777000222",
    displayName: "Trần Thị Hoa",
    avatarUrl: "https://a/hoa.jpg",
    zaloName: "Hoa",
    gender: "female",
  });
  expect(await gw.findUserByPhone("0999999999")).toBeNull();
  const byName = await gw.findUserByUsername("lequocbao");
  expect(byName?.uid).toBe("777000333");
  expect(byName?.gender).toBe("male");
  await gw.stop();
});

test("friend request status maps numeric flags", async () => {
  const { gw } = await startedGateway();
  const status = await gw.friendRequestStatus("777000444");
  expect(status).toEqual({
    isFriend: false,
    isRequested: true,
    isRequesting: false,
    addFriendPrivacy: 0,
    isSeen: true,
  });
  await gw.stop();
});

test("sendReport maps reasons and only sends content for other", async () => {
  const { api, gw } = await startedGateway();
  await gw.sendReport("777000222", "user", { reason: "sensitive" });
  await gw.sendReport("777000222", "user", {
    reason: "other",
    content: "spam links",
  });
  expect(api.reports).toEqual([
    {
      options: { reason: 1 },
      threadId: "777000222",
      type: ThreadType.User,
    },
    {
      options: { reason: 0, content: "spam links" },
      threadId: "777000222",
      type: ThreadType.User,
    },
  ]);
  await gw.stop();
});

test("sendCard forwards the zca options and returns the msgId", async () => {
  const { api, gw } = await startedGateway();
  const res = await gw.sendCard("880000111", "group", {
    userId: "777000222",
    phoneNumber: "0900000000",
    ttl: 0,
  });
  expect(res.msgId).toBe("123");
  expect(api.cards).toEqual([
    {
      options: { userId: "777000222", phoneNumber: "0900000000", ttl: 0 },
      threadId: "880000111",
      type: ThreadType.Group,
    },
  ]);
  await gw.stop();
});

test("deleteMessageForAll calls deleteMessage with onlyMe false", async () => {
  const { api, gw } = await startedGateway();
  await gw.deleteMessageForAll(
    "msg-9",
    "880000111",
    "group",
    { msgId: "msg-9", cliMsgId: "cli-9", uidFrom: "777000444" },
  );
  expect(api.deletes).toEqual([
    {
      dest: {
        data: { msgId: "msg-9", cliMsgId: "cli-9", uidFrom: "777000444" },
        threadId: "880000111",
        type: ThreadType.Group,
      },
      onlyMe: false,
    },
  ]);
  await gw.stop();
});

test("OA keeps the Phase C surface unsupported and capability-gated", async () => {
  const oa = new OaGateway(
    { appId: "a", appSecret: "s", accessToken: "t", refreshToken: "r" },
    { uid: "oa-1", displayName: "OA", avatarUrl: "" },
    { onCredentials: () => {}, clientConnected: () => false },
  );
  expect(oa.capabilities()).toEqual([]);
  const calls = [
    () => oa.findUserByPhone(),
    () => oa.friendRequestStatus(),
    () => oa.setFriendAlias(),
    () => oa.friendOnlines(),
    () => oa.lastOnline(),
    () => oa.sendCard(),
    () => oa.sendReport(),
    () => oa.deleteMessageForAll(),
  ];
  for (const call of calls) {
    // The stubs throw synchronously; wrap so the rejection is awaited.
    await expect((async () => call())()).rejects.toMatchObject({
      code: "not_supported",
    });
  }
});
