import { describe, expect, test } from "bun:test";
import { randomBytes } from "node:crypto";
import { ZaloClient } from "../src/client.ts";
import type { FetchLike } from "../src/core/context.ts";
import { decodeAES, encodeAES, ParamsEncryptor } from "../src/core/crypto.ts";
import {
  BinBankCard,
  Gender,
  LoginQRCallbackEventType,
  Reactions,
  ReportReason,
  ThreadType,
} from "../src/models/enums.ts";

function buildMockSessionFetch(secretKey: string) {
  const calls: Array<{
    url: string;
    pathname: string;
    method: string;
    params: Record<string, unknown>;
    isMultipart: boolean;
    cookieHeader: string;
  }> = [];

  const serviceMap = {
    aext: ["https://aext.zalo.me"],
    alias: ["https://alias.zalo.me"],
    auto_reply: ["https://autoreply.zalo.me"],
    catalog: ["https://catalog.zalo.me"],
    chat: ["https://chat.zalo.me", "https://chat2.zalo.me"],
    chat_e2e: ["https://e2ee.zalo.me"],
    conversation: ["https://conv.zalo.me"],
    emoji_stt: ["https://emoji.zalo.me"],
    file: ["https://file.zalo.me"],
    friend: ["https://friend.zalo.me"],
    friend_board: ["https://fboard.zalo.me"],
    group: ["https://group.zalo.me"],
    group_board: ["https://gboard.zalo.me"],
    group_cloud_message: ["https://gcm.zalo.me"],
    group_e2e: ["https://ge2ee.zalo.me"],
    group_poll: ["https://poll.zalo.me"],
    label: ["https://label.zalo.me"],
    media_store: ["https://mstore.zalo.me"],
    media_store_send2me: ["https://mstore2me.zalo.me"],
    profile: ["https://profile.zalo.me"],
    quick_message: ["https://quick.zalo.me"],
    reaction: ["https://react.zalo.me"],
    recent_search: ["https://search.zalo.me"],
    sticker: ["https://sticker.zalo.me"],
    voice_call: ["https://voicecall.zalo.me"],
    zcloud: ["https://zcld.chat.zalo.me"],
    zimsg: ["https://zimsg.chat.zalo.me"],
  };

  let qrScanPolls = 0;
  let qrConfirmPolls = 0;

  const fetchMock: FetchLike = async (input, init) => {
    const urlStr = typeof input === "string" ? input : input.toString();
    const u = new URL(urlStr);
    const method = (init?.method ?? "GET").toUpperCase();
    const headers = new Headers(init?.headers);
    const cookieHeader = headers.get("cookie") ?? "";

    // QR Login Web flow
    if (u.hostname === "id.zalo.me") {
      if (u.pathname === "/account") {
        return new Response('<script src="https://stc-zlogin.zdn.vn/main-5.2.1.js"></script>', {
          status: 200,
          headers: { "set-cookie": "zlogin_sid=s1; Domain=id.zalo.me; Path=/" },
        });
      }
      if (u.pathname === "/account/logininfo" || u.pathname === "/account/verify-client") {
        return new Response(JSON.stringify({ error_code: 0, data: {} }), { status: 200 });
      }
      if (u.pathname === "/account/authen/qr/generate") {
        return new Response(
          JSON.stringify({
            error_code: 0,
            data: { code: "qr-code-1", image: "data:image/png;base64,iVBORw0KGgo=" },
          }),
          { status: 200 },
        );
      }
      if (u.pathname === "/account/authen/qr/waiting-scan") {
        qrScanPolls += 1;
        if (qrScanPolls === 1) {
          return new Response(JSON.stringify({ error_code: 8, data: {} }), { status: 200 });
        }
        return new Response(
          JSON.stringify({ error_code: 0, data: { avatar: "ava.jpg", display_name: "Tester" } }),
          { status: 200 },
        );
      }
      if (u.pathname === "/account/authen/qr/waiting-confirm") {
        qrConfirmPolls += 1;
        if (qrConfirmPolls === 1) {
          return new Response(JSON.stringify({ error_code: 8, data: {} }), { status: 200 });
        }
        return new Response(JSON.stringify({ error_code: 0, data: {} }), { status: 200 });
      }
      if (u.pathname === "/account/checksession") {
        return new Response("", {
          status: 302,
          headers: {
            location: "https://id.zalo.me/account/setsid",
            "set-cookie": "zpw_sek=initial-sek; Domain=.zalo.me; Path=/; HttpOnly; Secure",
          },
        });
      }
      if (u.pathname === "/account/setsid") {
        return new Response("", { status: 200 });
      }
    }
    if (u.hostname === "jr.chat.zalo.me" && u.pathname === "/jr/userinfo") {
      return new Response(JSON.stringify({ data: { logged: true } }), { status: 200 });
    }

    // Login bootstrap
    if (u.pathname === "/api/login/getLoginInfo") {
      const zcid = u.searchParams.get("zcid")!;
      const zcidExt = u.searchParams.get("zcid_ext")!;
      const enk = ParamsEncryptor.deriveKey(zcid, zcidExt);
      const inner = encodeAES(
        enk,
        JSON.stringify({
          error_code: 0,
          data: {
            uid: "10001",
            zpw_enk: secretKey,
            zpw_ws: ["wss://ws1.zalo.me"],
            zpw_service_map_v3: serviceMap,
          },
        }),
        "base64",
        true,
      );
      return new Response(JSON.stringify({ error_code: 0, data: inner }), { status: 200 });
    }
    if (u.pathname === "/api/login/getServerInfo") {
      return new Response(
        JSON.stringify({
          error_code: 0,
          data: {
            setttings: {
              features: {
                sharefile: {
                  max_file: 9,
                  max_size_share_file_v3: 100,
                  chunk_size_file: 1024 * 1024,
                  restricted_ext_file: ["exe"],
                },
              },
            },
          },
        }),
        { status: 200 },
      );
    }

    const isMultipart = init?.body instanceof FormData;
    let encParams = u.searchParams.get("params");
    if (!encParams && init?.body instanceof URLSearchParams) {
      encParams = init.body.get("params");
    }
    const params = encParams ? (JSON.parse(decodeAES(secretKey, encParams)) as Record<string, unknown>) : {};
    calls.push({ url: urlStr, pathname: u.pathname, method, params, isMultipart, cookieHeader });

    // Special endpoint responses
    let payload: unknown = { ok: true, pathname: u.pathname };
    if (u.pathname.endsWith("photo_original/upload")) {
      payload = { finished: 1, photoId: "p-1", normalUrl: "n.jpg", hdUrl: "h.jpg", thumbUrl: "t.jpg", clientFileId: 1 };
    } else if (u.pathname.endsWith("upthumb")) {
      payload = { url: "thumb.png" };
    } else if (u.pathname === "/api/convlabel/get") {
      payload = { labelData: JSON.stringify([{ id: 1, text: "VIP", textKey: "vip", conversations: [], color: "#f00", offset: 0, emoji: "", createTime: 1 }]), version: 3 };
    } else if (u.pathname === "/api/conv/getUnreadMark") {
      payload = { data: JSON.stringify({ convsUser: [], convsGroup: [] }), status: 1 };
    } else if (u.pathname === "/api/friend/profile/get") {
      return new Response(JSON.stringify({ error_code: 216, error_message: "Not found" }), { status: 200 });
    } else if (u.pathname === "/api/group/create/v2") {
      expect(u.searchParams.get("params")).toBeTruthy();
      expect(init?.body).toBeUndefined();
      payload = { groupId: "99901" };
    } else if (u.pathname === "/keepalive") {
      return new Response(JSON.stringify({ error_code: 0, data: { alive: true } }), { status: 200 });
    }

    const inner = encodeAES(secretKey, JSON.stringify({ error_code: 0, error_message: "", data: payload }));
    return new Response(JSON.stringify({ error_code: 0, error_message: "", data: inner }), {
      status: 200,
      headers: { "set-cookie": "zpw_sek=rotated-sek; Domain=.zalo.me; Path=/; Secure" },
    });
  };

  return { fetchMock, calls };
}

describe("Full SDK Domains & Auth Flows", () => {
  test("QR login flow rotates cookies, initializes all 12 API namespaces, and exercises every domain cleanly", async () => {
    const secretKey = randomBytes(16).toString("base64");
    const { fetchMock, calls } = buildMockSessionFetch(secretKey);

    const client = new ZaloClient({ profile: "web", polyfill: fetchMock });
    const qrEvents: LoginQRCallbackEventType[] = [];
    const api = await client.loginQR({}, (evt) => qrEvents.push(evt.type));

    expect(qrEvents).toEqual([
      LoginQRCallbackEventType.QRCodeGenerated,
      LoginQRCallbackEventType.QRCodeScanned,
      LoginQRCallbackEventType.GotLoginInfo,
    ]);
    expect(api).not.toBeNull();
    if (!api) throw new Error("Expected loginQR to return ZaloApi");
    expect(api.getOwnId()).toBe("10001");

    // 1. Messaging + GIF + Image + Stickers + Reactions + Bank card
    await api.sendMessage({ msg: "Hi", urgency: 1 }, "u2", ThreadType.User);
    await api.sendMessage(
      { msg: "Look", attachments: { data: Buffer.from("GIF89a..."), filename: "anim.gif" } },
      "g1",
      ThreadType.Group,
    );
    await api.addReaction(Reactions.HEART, { data: { msgId: "1", cliMsgId: "2" }, threadId: "u2", type: ThreadType.User });
    await api.sendBankCard({ binBank: BinBankCard.MBBank, numAccBank: "1234", nameAccBank: "nguyen a" }, "u2");
    await api.stickers.getEmojiStatusFriends();

    // Cookie rotation must have updated zpw_sek to rotated-sek
    expect(api.getCookie().getCookieStringSync("https://chat.zalo.me")).toContain("zpw_sek=rotated-sek");

    // 2. Groups (including createGroup query-param quirk + unencrypted getAllGroups)
    await api.getAllGroups();
    const grp = await api.createGroup({ name: "Engineering", members: ["u2", "u3"] });
    expect(grp.groupId).toBe("99901");

    // 3. Board, Polls & 1:1 / Group Pins (first-class SDK methods replacing api.custom)
    await api.createPoll({ question: "Lunch?", options: ["Pho", "Bun"] }, "g1");
    await api.board.createFriendPin("u2", { msgId: "101", title: "Pin me" });
    await api.board.reorderFriendPins("u2", ["101", "102"], 2);
    await api.board.pinGroupMessage("g1", { client_msg_id: "5", global_msg_id: "6", title: "Group pin" });
    await api.board.reorderGroupPins("g1", [{ topicId: "6", topicType: 2 }], 4);

    // 4. Friends (phone 0xxx -> 84xxx & 216 null mapping + blocklist + close friend + znoise)
    expect(await api.findUser("0909123456")).toBeNull();
    const findCall = calls.find((c) => c.pathname === "/api/friend/profile/get");
    expect(findCall?.params.phone).toBe("84909123456");
    await api.friends.getBlockList();
    await api.friends.updateCloseFriend("u2", true);
    await api.sendReport({ reason: ReportReason.Fraud }, "u2", ThreadType.User);

    // 5. Conversations, Profile, Business, E2EE HTTP, Extras HTTP
    const labels = await api.getLabels();
    expect(labels.labelData[0]!.text).toBe("VIP");
    await api.getUnreadMark();
    await api.profile.updateProfile({ name: "Thu", dob: "1995-01-01", gender: Gender.Male });
    await api.business.updateQuickMessage(7, { keyword: "/hi", title: "Hello", media: [{ photoId: "p1" }] });
    await api.e2ee.sendE2eeMessage("sms", { toid: "u2", message: "ciphertext" }, false);
    await api.extras.previewMediaStore("g1");
    await api.extras.listOneOneMedia("image");
    await api.extras.getCloudViewerKey();
    await api.extras.updateRecentSearch([], 1, ["zalos"]);
    await api.extras.encryptGroupId(["u2"]);
    await api.keepAlive();

    // Service domain failover switches from index 0 to index 1 and keeps working
    expect(api.http.serviceBase("chat")).toBe("https://chat.zalo.me");
    expect(api.http.rotateServiceDomain("chat")).toBe(true);
    expect(api.http.serviceBase("chat")).toBe("https://chat2.zalo.me");
  });
});
