import { afterAll, beforeAll, expect, test } from "bun:test";
import { EventEmitter } from "node:events";
import type { API } from "@zalos/zalo-sdk";
import type { FakeGateway } from "../src/gateway/fake.ts";
import { ZcaGateway } from "../src/gateway/zca.ts";
import type { ZaloExtendedGateway } from "../src/gateway/types.ts";
import {
  accountClient,
  controlClient,
  loginQrAccount,
  makeEnv,
  pairDevice,
  type PairedDevice,
  type TestEnv,
} from "./support/helpers.ts";

let env: TestEnv;
let dev: PairedDevice;
let slot: string;
let gw: FakeGateway;
let oaSlot: string;

beforeAll(async () => {
  env = await makeEnv({ autoDeleteSweepMs: 0 });
  dev = await pairDevice(env, { name: "test-dev" });
  const control = await controlClient(env, dev);
  slot = await loginQrAccount(env, control);
  gw = env.factory.gateways.at(-1)!;
  const addedOa = (await control.request("accounts.addOa", {
    appId: "oa-app-ext",
    appSecret: "oa-secret-ext",
    accessToken: "at-1",
    refreshToken: "rt-1",
  })) as { slot: string };
  oaSlot = addedOa.slot;
  control.close();
});

afterAll(() => env.cleanup());

test("capabilities include extended SDK features for personal accounts only", () => {
  const caps = gw.capabilities();
  expect(caps).toContain("groupManage");
  expect(caps).toContain("profileSettings");
  expect(caps).toContain("businessTools");
  expect(caps).toContain("mediaStore");
  expect(caps).toContain("e2ee");
});

test("extended group management RPCs round-trip cleanly", async () => {
  const client = await accountClient(env, dev, slot);
  try {
    const created = (await client.request("groups.create", {
      name: "Team Dev",
      members: ["u1", "u2"],
    })) as { groupId: string };
    expect(created.groupId).toBeTruthy();

    await client.request("groups.rename", {
      groupId: created.groupId,
      name: "Team Zalos",
    });
    await client.request("groups.addMembers", {
      groupId: created.groupId,
      memberIds: ["u3"],
    });
    await client.request("groups.inviteToGroups", {
      userId: "u4",
      groupIds: [created.groupId],
    });
    await client.request("groups.removeMembers", {
      groupId: created.groupId,
      memberIds: ["u3"],
    });
    await client.request("groups.addDeputy", {
      groupId: created.groupId,
      memberIds: ["u2"],
    });
    await client.request("groups.removeDeputy", {
      groupId: created.groupId,
      memberIds: ["u2"],
    });
    await client.request("groups.changeOwner", {
      groupId: created.groupId,
      newOwnerId: "u2",
    });
    await client.request("groups.updateSettings", {
      groupId: created.groupId,
      settings: { lockSendMsg: true, joinAppr: true },
    });
    await client.request("groups.pendingMembers", {
      groupId: created.groupId,
    });
    await client.request("groups.reviewPending", {
      groupId: created.groupId,
      members: ["u5"],
      isApprove: true,
    });
    await client.request("groups.blockMembers", {
      groupId: created.groupId,
      memberIds: ["u6"],
    });
    const blocked = (await client.request("groups.blockedMembers", {
      groupId: created.groupId,
    })) as { blocked_members: Array<{ id: string }> };
    expect(blocked.blocked_members.some((b) => b.id === "u6")).toBe(true);
    await client.request("groups.unblockMembers", {
      groupId: created.groupId,
      memberIds: ["u6"],
    });

    await client.request("groups.enableLink", { groupId: created.groupId });
    const linkDetail = (await client.request("groups.linkDetail", {
      groupId: created.groupId,
    })) as { enabled: boolean; link?: string };
    expect(linkDetail.enabled).toBe(true);
    expect(linkDetail.link).toContain(created.groupId);

    await client.request("groups.linkInfo", { link: linkDetail.link! });
    await client.request("groups.joinLink", { link: linkDetail.link! });
    await client.request("groups.disableLink", { groupId: created.groupId });

    const inv = (await client.request("groups.inviteBoxList", {})) as {
      invitations: Array<{ groupId: string }>;
    };
    expect(inv.invitations.length).toBeGreaterThan(0);
    await client.request("groups.inviteBoxInfo", {
      groupId: inv.invitations[0]!.groupId,
    });
    await client.request("groups.inviteBoxJoin", {
      groupId: inv.invitations[0]!.groupId,
    });
    await client.request("groups.inviteBoxDelete", {
      groupIds: ["inv-none"],
    });
    await client.request("groups.upgradeCommunity", {
      groupId: created.groupId,
    });
    await client.request("groups.relatedFriendGroups", {
      friendIds: ["u1"],
    });
    await client.request("groups.leave", {
      groupId: created.groupId,
      silent: true,
    });
    await client.request("groups.disperse", {
      groupId: created.groupId,
    });
  } finally {
    client.close();
  }
});

test("profile, settings, friends extras, and board extras RPCs work", async () => {
  const client = await accountClient(env, dev, slot);
  try {
    await client.request("profile.update", {
      name: "Minh Thư",
      dob: "1998-08-08",
      gender: 1,
    });
    await client.request("profile.updateBio", { bio: "Bio mới" });
    const me = (await client.request("profile.me", {})) as {
      profile: { displayName: string; bio: string };
    };
    expect(me.profile.displayName).toBe("Minh Thư");
    expect(me.profile.bio).toBe("Bio mới");

    const avatars = (await client.request("profile.avatarList", {})) as {
      photos: Array<{ photoId: string }>;
    };
    expect(avatars.photos.length).toBeGreaterThan(0);
    await client.request("profile.reuseAvatar", {
      photoId: avatars.photos[0]!.photoId,
    });
    await client.request("profile.deleteAvatar", {
      photoIds: ["av-nonexistent"],
    });

    await client.request("profile.updateSettings", {
      type: "allow_find_phone",
      value: 0,
    });
    const settings = (await client.request("profile.settings", {})) as Record<
      string,
      unknown
    >;
    expect(settings.allow_find_phone).toBe(0);
    await client.request("profile.updateActiveStatus", { active: false });
    await client.request("profile.updateLang", { language: "en" });
    await client.request("profile.lostFocus", {});

    await client.request("contacts.setCloseFriend", {
      uids: ["u1"],
      add: true,
    });
    expect(gw.closeFriendIds.has("u1")).toBe(true);
    await client.request("contacts.findPhones", { phones: ["0901234567"] });
    const blocked = (await client.request("contacts.blockList", {})) as {
      users: Array<{ userId: string }>;
    };
    expect(blocked.users.length).toBeGreaterThan(0);
    await client.request("contacts.blockFeed", { uid: "u1", blocked: true });
    const qr = (await client.request("contacts.qr", { uids: ["u1"] })) as {
      qr: Record<string, string>;
    };
    expect(qr.qr.u1).toContain("u1");

    const boardEvt = client.waitEvent("board.updated", 5000);
    await client.request("notes.remove", { groupId: "g1", topicId: "n1" });
    await boardEvt;
    await client.request("reminders.detail", { reminderId: "r1" });
    await client.request("reminders.responses", { reminderId: "r1" });
    await client.request("pins.reorder", {
      threadId: "g1",
      threadType: "group",
      topics: [],
      version: 1,
    });
    await client.request("pins.multiUnpin", {
      groupId: "g1",
      topics: [],
      version: 1,
    });
  } finally {
    client.close();
  }
});

test("business, media store, search, sync/backup, e2ee, and call signal RPCs work", async () => {
  const client = await accountClient(env, dev, slot);
  try {
    await client.request("business.info", {});
    const cat = (await client.request("catalogs.create", {
      catalogName: "Giỏ quà",
    })) as { catalog: { catalogId: string } };
    await client.request("catalogs.update", {
      catalogId: cat.catalog.catalogId,
      catalogName: "Giỏ quà VIP",
    });
    await client.request("catalogs.register", { enable: true });
    const prod = (await client.request("catalogs.products.create", {
      catalogId: cat.catalog.catalogId,
      productName: "Lan hồ điệp",
      price: 500000,
      description: "Chậu 3 cành",
    })) as { product: { productId: string } };
    await client.request("catalogs.products.update", {
      catalogId: cat.catalog.catalogId,
      productId: prod.product.productId,
      productName: "Lan hồ điệp V2",
      price: 550000,
      description: "Chậu 5 cành",
    });
    const prodList = (await client.request("catalogs.products.list", {
      catalogId: cat.catalog.catalogId,
    })) as { products: Array<{ productName: string }> };
    expect(prodList.products[0]?.productName).toBe("Lan hồ điệp V2");
    await client.request("catalogs.products.delete", {
      catalogId: cat.catalog.catalogId,
      productIds: [prod.product.productId],
    });
    await client.request("catalogs.delete", {
      catalogId: cat.catalog.catalogId,
    });

    const ar = (await client.request("autoReply.create", {
      isEnable: true,
      content: "Tự động trả lời",
      startTime: 100,
      endTime: 200,
      scope: 0,
    })) as { item: { id: number } };
    await client.request("autoReply.update", {
      id: ar.item.id,
      isEnable: false,
      content: "Tắt",
      startTime: 100,
      endTime: 200,
      scope: 0,
    });
    await client.request("autoReply.delete", { id: ar.item.id });

    const ba = (await client.request("banks.createAccount", {
      binBank: 970436,
      numAccBank: "999888777",
      nameAccBank: "Pham Minh Thu",
    })) as { account: { id: string } };
    await client.request("banks.updateAccount", {
      accountId: ba.account.id,
      binBank: 970436,
      numAccBank: "999888777",
      nameAccBank: "PHAM MINH THU 2",
    });
    await client.request("banks.deleteAccount", {
      accountId: ba.account.id,
      isDefault: false,
    });

    await client.request("threads.unreadMarks", {});
    await client.request("messages.scanUrl", { url: "https://zalo.me" });
    await client.request("messages.cloudHistory", { groupId: "g1" });
    await client.request("messages.preloadLast", { threadIdLocalMsgId: {} });
    await client.request("messages.preloadLastSeen", {});
    await client.request("messages.lastDeliverSeen", {});
    await client.request("stickers.emojiStatusFriends", {});
    await client.request("stickers.emojiStatusConfig", {});

    await client.request("mediaStore.list", {
      groupId: "g1",
      mediaType: "image",
    });
    await client.request("mediaStore.preview", { groupId: "g1" });
    await client.request("mediaStore.remove", {
      groupId: "g1",
      mediaType: "image",
      mediaId: "gm-media-1",
    });
    await client.request("mediaStore.oneOneList", { mediaType: "image" });
    await client.request("mediaStore.oneOnePreview", {});
    await client.request("mediaStore.oneOneRemove", {
      mediaType: "image",
      mediaId: "m-oneone-1",
    });

    await client.request("cloud.viewerKey", {});
    await client.request("cloud.familyViewerKey", {});
    await client.request("search.recent", {});
    await client.request("search.updateRecent", {
      listRecent: [],
      version: 1,
      listKeyword: ["test"],
    });
    await client.request("groups.encryptId", { noiseUids: ["n1"] });
    await client.request("groups.decryptId", { globalUids: ["enc-n1"] });

    await client.request("sync.mobileRequest", {});
    await client.request("sync.ackDelete", {});
    await client.request("sync.wakeMobile", {});
    await client.request("backup.init", {});
    await client.request("backup.createSession", {});
    await client.request("backup.metadata", {});
    await client.request("backup.signalRestore", {});
    await client.request("backup.configs", {});
    await client.request("interactiveFiles.submit", { payload: { a: 1 } });
    await client.request("interactiveFiles.pull", {});
    await client.request("payment.inAppLink", { domain: "pay.zalo.me" });
    await client.request("media.uploadUrl", {});

    await client.request("e2ee.users", {});
    await client.request("e2ee.keyId", {});
    await client.request("e2ee.checkCompatible", { uids: ["u1"] });
    await client.request("e2ee.checkGroupCompatible", {
      uids: ["u1"],
      groupId: "g1",
    });
    await client.request("e2ee.enable", { threadId: "u1" });
    await client.request("e2ee.disable", { threadId: "u1" });
    await client.request("e2ee.downgradeGroup", { destId: "g1", id: "1" });
    await client.request("e2ee.command", { command: "getKeyId", payload: {} });

    await client.request("calls.hold", {
      callId: "c1",
      peerId: "u1",
      hold: true,
    });
    await client.request("calls.switchMedia", {
      callId: "c1",
      peerId: "u1",
    });
    await client.request("calls.shareScreen", {
      callId: "c1",
      uidTo: "u1",
    });
    await client.request("calls.groupAddUser", {
      callId: "c1",
      groupId: "g1",
    });
    await client.request("calls.groupJoin", {
      callId: "c1",
      groupId: "g1",
    });
    await client.request("calls.resolveZNoise", { fids: ["u1"], gids: ["g1"] });
  } finally {
    client.close();
  }
});

test("OA accounts refuse extended personal RPCs with not_supported", async () => {
  const oaClient = await accountClient(env, dev, oaSlot);
  try {
    let errCode = "";
    try {
      await oaClient.request("groups.create", { members: ["u1"] });
    } catch (e) {
      errCode = (e as { code?: string }).code ?? "";
    }
    expect(errCode).toBe("not_supported");
  } finally {
    oaClient.close();
  }
});

test("ZcaGateway delegates extended methods and call signals to @zalos/zalo-sdk API", async () => {
  const invoked: string[] = [];
  const recorder = (prefix: string) =>
    new Proxy(
      {},
      {
        get(_t, prop: string) {
          return async (...args: unknown[]) => {
            invoked.push(`${prefix}.${prop}`);
            if (prefix === "friends" && prop === "getQR") {
              return { u1: "https://zalo.me/qr/u1" };
            }
            if (prefix === "groups" && prop === "getGroupLinkDetail") {
              return { enabled: 1, link: "https://zalo.me/g/test" };
            }
            if (prefix === "groups" && prop === "createGroup") {
              return { groupId: "g-mock-1" };
            }
            return { ok: true, argsCount: args.length };
          };
        },
      },
    );

  const listener = new EventEmitter() as EventEmitter & {
    start: () => void;
    stop: () => void;
    requestOldMessages: () => void;
  };
  listener.start = () => {};
  listener.stop = () => {};
  listener.requestOldMessages = () => {};

  const fakeApi = {
    listener,
    getOwnId: () => "uid-mock",
    getCookie: () => ({ toJSON: () => ({ cookies: [] }) }),
    groups: recorder("groups"),
    profile: recorder("profile"),
    friends: recorder("friends"),
    board: recorder("board"),
    business: recorder("business"),
    conversations: recorder("conversations"),
    messaging: recorder("messaging"),
    stickers: recorder("stickers"),
    extras: recorder("extras"),
    e2ee: recorder("e2ee"),
    call: recorder("call"),
    fetchAccountInfo: async () => ({ profile: { displayName: "Z", avatar: "" } }),
  } as unknown as API;

  const zca = new ZcaGateway(
    { imei: "i", cookie: { cookies: [] }, userAgent: "ua" },
    { uid: "uid-mock", displayName: "Z", avatarUrl: "" },
    async () => fakeApi,
  );
  await zca.start();

  const ext = zca as unknown as ZaloExtendedGateway;
  await ext.createGroup({ name: "G", members: ["u1"] });
  await ext.updateProfile({ name: "N", dob: "2000-01-01", gender: 0 });
  await ext.setCloseFriend(["u1"], true);
  await ext.removeNote("g1", "n1");
  await ext.createCatalog("C");
  await ext.unreadMarks();
  await ext.scanUrl("https://zalo.me");
  await ext.emojiStatusConfig();
  await ext.mediaStoreList("g1", "image");
  await ext.extrasCommand("backupGetConfigs", {});
  await ext.e2eeCommand("getKeyId", {});
  await zca.sendCallSignal("holdRequest", { peerId: "u1" });
  await zca.sendCallSignal("requestAudioToVideo", { callId: "c1" });
  await zca.sendCallSignal("resolveZNoise", { fids: ["u1"] });
  await zca.sendCallSignal("uploadCallLog", {
    callId: "c1",
    ownerId: "u1",
    timestamp: 1,
    duration: 2,
    logText: "ok",
  });

  expect(invoked).toContain("groups.createGroup");
  expect(invoked).toContain("profile.updateProfile");
  expect(invoked).toContain("friends.updateCloseFriend");
  expect(invoked).toContain("board.removeGroupNote");
  expect(invoked).toContain("business.createCatalog");
  expect(invoked).toContain("conversations.getUnreadMark");
  expect(invoked).toContain("messaging.scanURL");
  expect(invoked).toContain("stickers.getEmojiStatusConfig");
  expect(invoked).toContain("extras.listMediaStore");
  expect(invoked).toContain("extras.backupGetConfigs");
  expect(invoked).toContain("e2ee.getKeyId");
  expect(invoked).toContain("call.holdRequest");
  expect(invoked).toContain("call.requestAudioToVideo");
  expect(invoked).toContain("call.resolveZNoise");
  expect(invoked).toContain("call.uploadCallLog");
  await zca.stop();
});
