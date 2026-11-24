import { test, expect, beforeAll, afterAll } from "bun:test";
import type { GroupInfo as ZcaGroupInfo } from "zca-js";
import {
  makeEnv,
  pairDevice,
  controlClient,
  loginQrAccount,
  type TestEnv,
  type PairedDevice,
} from "./support/helpers.ts";
import { normalizeZcaGroupInfo, ZcaGateway } from "../src/gateway/zca.ts";
import type { FakeGateway } from "../src/gateway/fake.ts";

// Real accounts return memberIds empty and only a page of currentMems, with
// the total in totalMember. This is that exact shape, plus a duplicate and a
// missing id to prove the defensive filtering.
const realShape = {
  groupId: "group-1",
  name: "Team",
  desc: "",
  type: 1,
  creatorId: "u1",
  version: "1",
  avt: "https://example.com/g.png",
  fullAvt: "",
  memberIds: [],
  adminIds: ["u2"],
  currentMems: [
    { id: "u1", dName: "Owner", zaloName: "owner", avatar: "https://example.com/u1.png", avatar_25: "", accountStatus: 0, type: 0 },
    { id: "u2", dName: "Deputy", zaloName: "deputy", avatar: "https://example.com/u2.png", avatar_25: "", accountStatus: 0, type: 0 },
    { id: "u3", dName: "", zaloName: "member", avatar: "", avatar_25: "https://example.com/u3-25.png", accountStatus: 0, type: 0 },
    { id: "u2", dName: "Deputy", zaloName: "deputy", avatar: "https://example.com/u2.png", avatar_25: "", accountStatus: 0, type: 0 },
    { id: "", dName: "Broken", zaloName: "", avatar: "", avatar_25: "", accountStatus: 0, type: 0 },
  ],
  updateMems: [],
  admins: [],
  hasMoreMember: 1,
  subType: 0,
  totalMember: 8,
  maxMember: 100,
  setting: {},
  createdTime: 0,
  visibility: 0,
  globalId: "",
  e2ee: 0,
  extraInfo: { enable_media_store: 0 },
} as unknown as ZcaGroupInfo;

test("real zca shape: currentMems fills memberIds and totalMember carries the count", () => {
  const info = normalizeZcaGroupInfo("group-1", realShape);
  expect(info.memberIds).toEqual(["u1", "u2", "u3"]);
  expect(info.memberCount).toBe(8);
  expect(info.ownerId).toBe("u1");
  expect(info.adminIds).toEqual(["u2"]);
  expect(info.members).toEqual([
    { uid: "u1", displayName: "Owner", avatarUrl: "https://example.com/u1.png", role: "owner" },
    { uid: "u2", displayName: "Deputy", avatarUrl: "https://example.com/u2.png", role: "deputy" },
    { uid: "u3", displayName: "member", avatarUrl: "https://example.com/u3-25.png", role: "member" },
  ]);
});

test("explicit memberIds win over currentMems and count falls back to the list", () => {
  const info = normalizeZcaGroupInfo("group-1", {
    ...realShape,
    memberIds: ["u3", "u1"],
    totalMember: 0,
  });
  expect(info.memberIds).toEqual(["u3", "u1"]);
  expect(info.memberCount).toBe(2);
  expect(info.members?.map((m) => m.uid)).toEqual(["u1", "u3"]);
});

test("memVerList fills memberIds when explicit memberIds and currentMems are empty", () => {
  const info = normalizeZcaGroupInfo("group-1", {
    ...realShape,
    memberIds: [],
    currentMems: [],
    memVerList: ["u1_0", "u2_0", "u3_0", "u2_0"],
    totalMember: 3,
  } as unknown as ZcaGroupInfo);
  expect(info.memberIds).toEqual(["u1", "u2", "u3"]);
  expect(info.memberCount).toBe(3);
});

test("unknown group shape falls back safely", () => {
  const info = normalizeZcaGroupInfo("group-1", {} as ZcaGroupInfo);
  expect(info.memberIds).toEqual([]);
  expect(info.memberCount).toBe(0);
  expect(info.members).toBeUndefined();
});

test("adapter normalizes listGroups and groupInfo from the real shape", async () => {
  const api = {
    jar: [],
    getCookie: () => ({ toJSON: () => ({ cookies: [] }) }),
    getAllGroups: async () => ({ gridVerMap: { "group-1": "1" } }),
    getGroupInfo: async () => ({
      removedsGroup: [],
      unchangedsGroup: [],
      gridInfoMap: { "group-1": realShape },
    }),
    listener: { on: () => {}, stop: () => {}, start: () => {} },
  };
  const gw = new ZcaGateway(
    { imei: "i", cookie: {}, userAgent: "ua" },
    { uid: "me", displayName: "me", avatarUrl: "" },
    async () => api as never,
  );
  await gw.start();
  const list = await gw.listGroups();
  expect(list[0].memberIds).toEqual(["u1", "u2", "u3"]);
  expect(list[0].memberCount).toBe(8);
  const one = await gw.groupInfo("group-1");
  expect(one.memberIds).toEqual(["u1", "u2", "u3"]);
  expect(one.memberCount).toBe(8);
  await gw.stop();
});

const linkInfoBase = {
  groupId: "group-1",
  name: "Team",
  desc: "",
  type: 1,
  creatorId: "u1",
  avt: "",
  fullAvt: "",
  adminIds: ["u2"],
  admins: [],
  subType: 0,
  setting: {},
  globalId: "",
};

function linkMem(id: string, name: string) {
  return {
    id,
    dName: name,
    zaloName: name.toLowerCase(),
    avatar: `https://example.com/${id}.png`,
    avatar_25: "",
    accountStatus: 0,
    type: 0,
  };
}

function emptyRoster(over: Record<string, unknown> = {}): ZcaGroupInfo {
  return {
    ...realShape,
    memberIds: [],
    currentMems: [],
    hasMoreMember: 0,
    ...over,
  } as unknown as ZcaGroupInfo;
}

async function gatewayWith(api: Record<string, unknown>): Promise<ZcaGateway> {
  const gateway = new ZcaGateway(
    { imei: "i", cookie: {}, userAgent: "ua" },
    { uid: "me", displayName: "me", avatarUrl: "" },
    async () => api as never,
  );
  await gateway.start();
  return gateway;
}

test("empty roster with totalMember backfills the full link roster", async () => {
  const calls: string[] = [];
  const ids = ["u1", "u2", "u3", "u4", "u5", "u6", "u7"];
  const api = {
    jar: [],
    getCookie: () => ({ toJSON: () => ({ cookies: [] }) }),
    getGroupInfo: async () => ({
      removedsGroup: [],
      unchangedsGroup: [],
      gridInfoMap: { "group-1": emptyRoster({ totalMember: 7 }) },
    }),
    getGroupLinkDetail: async (groupId: string) => {
      calls.push(`detail:${groupId}`);
      return { link: "https://zalo.me/g/abc", enabled: 1 };
    },
    getGroupLinkInfo: async ({
      link,
      memberPage,
    }: {
      link: string;
      memberPage?: number;
    }) => {
      calls.push(`info:${link}:${memberPage}`);
      return {
        ...linkInfoBase,
        currentMems: ids.map((id) => linkMem(id, id.toUpperCase())),
        hasMoreMember: 0,
        totalMember: 7,
      };
    },
    listener: { on: () => {}, stop: () => {}, start: () => {} },
  };
  const gateway = await gatewayWith(api);
  const one = await gateway.groupInfo("group-1");
  expect(calls).toEqual(["detail:group-1", "info:https://zalo.me/g/abc:1"]);
  expect(one.memberIds).toEqual(ids);
  expect(one.members?.map((m) => m.uid)).toEqual(ids);
  expect(one.memberCount).toBe(7);
  expect(one.ownerId).toBe("u1");
  expect(one.adminIds).toEqual(["u2"]);
  expect(one.members?.find((m) => m.uid === "u2")?.role).toBe("deputy");
  await gateway.stop();
});

test("link pages merge and dedupe while memberCount stays the server total", async () => {
  const pages: number[] = [];
  const api = {
    jar: [],
    getCookie: () => ({ toJSON: () => ({ cookies: [] }) }),
    getGroupInfo: async () => ({
      removedsGroup: [],
      unchangedsGroup: [],
      gridInfoMap: { "group-1": emptyRoster({ totalMember: 5 }) },
    }),
    getGroupLinkDetail: async () => ({
      link: "https://zalo.me/g/abc",
      enabled: 1,
    }),
    getGroupLinkInfo: async ({ memberPage }: { memberPage?: number }) => {
      const page = memberPage ?? 1;
      pages.push(page);
      return page === 1
        ? {
            ...linkInfoBase,
            currentMems: [
              linkMem("u1", "One"),
              linkMem("u2", "Two"),
              linkMem("u3", "Three"),
            ],
            hasMoreMember: 1,
            totalMember: 5,
          }
        : {
            ...linkInfoBase,
            currentMems: [
              linkMem("u3", "Three"),
              linkMem("u4", "Four"),
              linkMem("u5", "Five"),
            ],
            hasMoreMember: 0,
            totalMember: 5,
          };
    },
    listener: { on: () => {}, stop: () => {}, start: () => {} },
  };
  const gateway = await gatewayWith(api);
  const one = await gateway.groupInfo("group-1");
  expect(pages).toEqual([1, 2]);
  expect(one.memberIds).toEqual(["u1", "u2", "u3", "u4", "u5"]);
  expect(one.members?.map((m) => m.uid)).toEqual(["u1", "u2", "u3", "u4", "u5"]);
  expect(one.memberCount).toBe(5);
  await gateway.stop();
});

test("a complete roster with no more pages makes no link calls", async () => {
  const calls: string[] = [];
  const api = {
    jar: [],
    getCookie: () => ({ toJSON: () => ({ cookies: [] }) }),
    getGroupInfo: async () => ({
      removedsGroup: [],
      unchangedsGroup: [],
      gridInfoMap: {
        "group-1": emptyRoster({
          memberIds: ["u1", "u2"],
          hasMoreMember: 0,
          totalMember: 2,
        }),
      },
    }),
    getGroupLinkDetail: async () => {
      calls.push("detail");
      throw new Error("must not be called");
    },
    getGroupLinkInfo: async () => {
      calls.push("info");
      throw new Error("must not be called");
    },
    listener: { on: () => {}, stop: () => {}, start: () => {} },
  };
  const gateway = await gatewayWith(api);
  const one = await gateway.groupInfo("group-1");
  expect(calls).toEqual([]);
  expect(one.memberIds).toEqual(["u1", "u2"]);
  expect(one.memberCount).toBe(2);
  await gateway.stop();
});

test("disabled link and lookup failures keep the base metadata", async () => {
  const disabled = {
    jar: [],
    getCookie: () => ({ toJSON: () => ({ cookies: [] }) }),
    getGroupInfo: async () => ({
      removedsGroup: [],
      unchangedsGroup: [],
      gridInfoMap: {
        "group-1": emptyRoster({ totalMember: 7, hasMoreMember: 1 }),
      },
    }),
    getGroupLinkDetail: async () => ({
      link: "https://zalo.me/g/abc",
      enabled: 0,
    }),
    getGroupLinkInfo: async () => {
      throw new Error("must not be called");
    },
    listener: { on: () => {}, stop: () => {}, start: () => {} },
  };
  const gateway = await gatewayWith(disabled);
  const one = await gateway.groupInfo("group-1");
  expect(one).toEqual({
    id: "group-1",
    name: "Team",
    avatarUrl: "https://example.com/g.png",
    memberIds: [],
    memberCount: 7,
    ownerId: "u1",
    adminIds: ["u2"],
  });
  await gateway.stop();

  const missing = { ...disabled, getGroupLinkDetail: async () => ({ enabled: 1 }) };
  const gwMissing = await gatewayWith(missing);
  expect(await gwMissing.groupInfo("group-1")).toEqual(one);
  await gwMissing.stop();

  const failing = {
    ...disabled,
    getGroupLinkDetail: async () => {
      throw new Error("detail unavailable");
    },
  };
  const gwFailing = await gatewayWith(failing);
  expect(await gwFailing.groupInfo("group-1")).toEqual(one);
  await gwFailing.stop();
});

test("a failing link lookup does not take other groups down", async () => {
  const api = {
    jar: [],
    getCookie: () => ({ toJSON: () => ({ cookies: [] }) }),
    getAllGroups: async () => ({
      gridVerMap: { "group-1": "1", "group-2": "1" },
    }),
    getGroupInfo: async () => ({
      removedsGroup: [],
      unchangedsGroup: [],
      gridInfoMap: {
        "group-1": emptyRoster({ totalMember: 7 }),
        "group-2": emptyRoster({ totalMember: 3 }),
      },
    }),
    getGroupLinkDetail: async (groupId: string) => {
      if (groupId === "group-1") throw new Error("detail unavailable");
      return { link: "https://zalo.me/g/two", enabled: 1 };
    },
    getGroupLinkInfo: async () => ({
      ...linkInfoBase,
      groupId: "group-2",
      currentMems: [linkMem("a1", "A"), linkMem("a2", "B"), linkMem("a3", "C")],
      hasMoreMember: 0,
      totalMember: 3,
    }),
    listener: { on: () => {}, stop: () => {}, start: () => {} },
  };
  const gateway = await gatewayWith(api);
  const list = await gateway.listGroups();
  expect(list.map((g) => g.id)).toEqual(["group-1", "group-2"]);
  expect(list[0].memberIds).toEqual([]);
  expect(list[0].memberCount).toBe(7);
  expect(list[1].memberIds).toEqual(["a1", "a2", "a3"]);
  expect(list[1].memberCount).toBe(3);
  await gateway.stop();
});

let env: TestEnv;
let admin: PairedDevice;
let slot: string;
let gw: FakeGateway;

beforeAll(async () => {
  env = await makeEnv();
  admin = await pairDevice(env, { name: "admin" });
  const control = await controlClient(env, admin);
  slot = await loginQrAccount(env, control);
  gw = env.factory.gateways.at(-1)!;
  control.close();
});

afterAll(() => env.cleanup());

test("groups.info requests profiles for normalized ids and keeps the total", async () => {
  const requested: string[][] = [];
  gw.groupInfo = async () => ({
    id: "group-1",
    name: "Team",
    avatarUrl: "",
    memberIds: ["u1", "u2", "u3"],
    memberCount: 8,
    ownerId: "u1",
    adminIds: ["u2"],
    members: [
      { uid: "u1", displayName: "Owner", avatarUrl: "a1", role: "owner" },
      { uid: "u2", displayName: "Deputy", avatarUrl: "a2", role: "deputy" },
      { uid: "u3", displayName: "Member", avatarUrl: "a3", role: "member" },
    ],
  });
  gw.groupMembersInfo = async (uids) => {
    requested.push(uids);
    // The real lookup can fail while currentMems names are still valid.
    throw new Error("profiles unavailable");
  };
  const info = await env.server.accounts.groupInfoMembers(slot, "group-1");
  expect(requested).toEqual([["u1", "u2", "u3"]]);
  expect(info.memberCount).toBe(8);
  expect(info.members).toEqual([
    { uid: "u1", displayName: "Owner", avatarUrl: "a1", role: "owner" },
    { uid: "u2", displayName: "Deputy", avatarUrl: "a2", role: "deputy" },
    { uid: "u3", displayName: "Member", avatarUrl: "a3", role: "member" },
  ]);
});
