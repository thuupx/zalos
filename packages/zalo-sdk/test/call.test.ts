import { describe, expect, test } from "bun:test";
import { randomBytes } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ZCallV2Bridge, buildZCallChunkMessages } from "../src/apis/zcall-bridge.ts";
import { CALL_SIGNAL_CMD, CLIENT_PROFILES } from "../src/core/constants.ts";
import type { FetchLike, ZaloContext } from "../src/core/context.ts";
import { ZaloCookieJar } from "../src/core/cookies.ts";
import { decodeAES, decodeZCallIpc, encodeAES, encodeZCallIpc } from "../src/core/crypto.ts";
import { ZaloHttpClient } from "../src/core/http.ts";
import { CallMakeType } from "../src/models/enums.ts";
import { CallApi, buildZrtcExtendData } from "../src/apis/call.ts";

interface RecordedCall {
  path: string;
  params: Record<string, unknown>;
}

function makeCallTestHarness(secretKey: string) {
  const recorded: RecordedCall[] = [];
  let logAttempts = 0;

  const mockFetch: FetchLike = async (input, init) => {
    const u = new URL(typeof input === "string" ? input : input.toString());
    if (u.hostname === "qos.talk.zing.vn") {
      recorded.push({ path: u.pathname, params: { method: init?.method ?? "GET" } });
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    }
    const encParam = u.searchParams.get("params");
    const params = encParam ? (JSON.parse(decodeAES(secretKey, encParam)) as Record<string, unknown>) : {};
    recorded.push({ path: u.pathname, params });

    if (u.pathname === "/api/voicecall/logendcall" && logAttempts === 0) {
      logAttempts += 1;
      return new Response(JSON.stringify({ error_code: 112, error_message: "retry me" }), { status: 200 });
    }

    const inner = encodeAES(
      secretKey,
      JSON.stringify({ error_code: 0, error_message: "", data: { ok: true, path: u.pathname } }),
    );
    return new Response(JSON.stringify({ error_code: 0, error_message: "", data: inner }), {
      status: 200,
    });
  };

  const ctx: ZaloContext = {
    uid: "10001",
    imei: "call-imei",
    userAgent: CLIENT_PROFILES.pc_macos.userAgent,
    language: "vi",
    secretKey,
    cookie: new ZaloCookieJar(),
    profile: CLIENT_PROFILES.pc_macos,
    apiType: 23,
    apiVersion: 694,
    computerName: "Mac",
    settings: {},
    extraVer: {},
    zpwServiceMap: {
      voice_call: ["https://voicecall-wpa.zaloapp.com"],
      profile: ["https://profile-wpa.zaloapp.com"],
    },
    wsUrls: [],
    uploadCallbacks: new Map(),
    options: { selfListen: true, checkUpdate: false, logging: false },
  };
  const http = new ZaloHttpClient(ctx, mockFetch);
  const callApi = new CallApi(http, ctx);
  return { callApi, recorded };
}

describe("Voice, Video & Group Call REST + ZCallV2Bridge", () => {
  test("dispatches all 28 1:1 & group /api/voicecall/* signals with AES encryption, /api/znoise, and logendcall retry", async () => {
    const secretKey = randomBytes(16).toString("base64");
    const { callApi, recorded } = makeCallTestHarness(secretKey);

    const expectedPaths: Array<[number, Record<string, unknown>, string]> = [
      [CALL_SIGNAL_CMD.REQUEST_CALL, { calleeId: "u2", callId: "1", typeRequest: 1 }, "/api/voicecall/requestcall"],
      [CALL_SIGNAL_CMD.REQUEST_INVITE, { calleeId: "u2", rtpAddress: "1.2.3.4:8020", rtcpAddress: "1.2.3.4:4004", codec: "[]", session: "s", callId: "1", extendData: "v1" }, "/api/voicecall/request"],
      [CALL_SIGNAL_CMD.RING_RING, { callerId: "u2", callId: "1", status: 0 }, "/api/voicecall/ringring"],
      [CALL_SIGNAL_CMD.ANSWER, { callerId: "u2", callId: "1", status: 1, rtpAddress: "r", rtcpAddress: "rt", session_id: "s" }, "/api/voicecall/answer"],
      [CALL_SIGNAL_CMD.ANSWER_ACK, { calleeId: "u2", callId: "1", status: 0 }, "/api/voicecall/answerack"],
      [CALL_SIGNAL_CMD.CANCEL, { callerId: "u2", callId: "1", callType: 1, status: 0 }, "/api/voicecall/cancel"],
      [CALL_SIGNAL_CMD.END_CALL, { uidTo: "u2", callId: "1", status: 3 }, "/api/voicecall/endcall"],
      [CALL_SIGNAL_CMD.HOLD_REQ, { toId: "u2" }, "/api/voicecall/holdreq"],
      [CALL_SIGNAL_CMD.HOLD_RESP, { toId: "u2" }, "/api/voicecall/holdresp"],
      [CALL_SIGNAL_CMD.UNHOLD_REQ, { toId: "u2" }, "/api/voicecall/unholdreq"],
      [CALL_SIGNAL_CMD.UNHOLD_RESP, { toId: "u2" }, "/api/voicecall/unholdresp"],
      [CALL_SIGNAL_CMD.CONF, { calleeId: "u2", callId: "1", isOnCam: 1, isOnMic: 1, data: {} }, "/api/voicecall/conf"],
      [CALL_SIGNAL_CMD.REQUEST_SHARE_SCREEN, { uidTo: "u2", callId: "1", status: 1 }, "/api/voicecall/requestsharescreen"],
      [CALL_SIGNAL_CMD.REQUEST_AUDIO_TO_VIDEO, { toId: "u2" }, "/api/voicecall/requestaudio2video"],
      [CALL_SIGNAL_CMD.GROUP_REQUEST_CALL, { groupId: "g1", callId: "2", typeRequest: 6 }, "/api/voicecall/group/requestcall"],
      [CALL_SIGNAL_CMD.GROUP_REQUEST_INVITE, { groupId: "g1", callId: "2", callType: 6 }, "/api/voicecall/group/request"],
      [CALL_SIGNAL_CMD.GROUP_ADD_USER, { callId: "2", callType: 6, hostCall: "u1" }, "/api/voicecall/group/adduser"],
      [CALL_SIGNAL_CMD.GROUP_ANSWER, { callId: "2", callType: 6, hostCall: "u1" }, "/api/voicecall/group/answer"],
      [CALL_SIGNAL_CMD.GROUP_CANCEL, { callId: "2", callType: 6, hostCall: "u1" }, "/api/voicecall/group/cancel"],
      [CALL_SIGNAL_CMD.GROUP_END_CALL, { callId: "2", callType: 6, hostCall: "u1" }, "/api/voicecall/group/endcall"],
      [CALL_SIGNAL_CMD.GROUP_RING_RING, { callId: "2", callType: 6, hostCall: "u1" }, "/api/voicecall/group/ringring"],
      [CALL_SIGNAL_CMD.GROUP_STATE, { callId: "2", callType: 6, hostCall: "u1" }, "/api/voicecall/group/state"],
      [CALL_SIGNAL_CMD.GROUP_FINISH, { callId: "2", callType: 6, hostCall: "u1", duration: 10, status: 1 }, "/api/voicecall/group/finish"],
      [CALL_SIGNAL_CMD.GROUP_NOTIFY, { callId: "2", callType: 6, hostCall: "u1", status: 1 }, "/api/voicecall/group/notify"],
      [CALL_SIGNAL_CMD.GROUP_PING, { callId: "2", hostCall: "u1", userId: "u2", callstate: 1, audiostate: 1, videostate: 1 }, "/api/voicecall/group/ping"],
      [CALL_SIGNAL_CMD.GROUP_BROADCAST, { callId: "2", hostCall: "u1", userId: "u2", callstate: 1, audiostate: 1, videostate: 1 }, "/api/voicecall/group/broadcast"],
      [CALL_SIGNAL_CMD.GROUP_JOIN, { userId: "u2", callId: "2", hostCall: "u1", status: 1 }, "/api/voicecall/group/join"],
      [CALL_SIGNAL_CMD.GROUP_SHARE_SCREEN, { userId: "u2", callId: "2", hostCall: "u1", status: 1 }, "/api/voicecall/group/sharescreen"],
    ];

    for (const [cmd, payload, expectedPath] of expectedPaths) {
      const res = (await callApi.dispatchNativeSignal(cmd, payload)) as { path: string };
      expect(res.path).toBe(expectedPath);
    }

    // Command 406 retries automatically on error_code === 112
    const logRes = (await callApi.logEndCall(
      { call_id: "1", partner_id: "u2", status: 3, logdata: {}, duration: 42, role: 1 },
      [5, 5],
    )) as { path: string };
    expect(logRes.path).toBe("/api/voicecall/logendcall");
    expect(recorded.filter((r) => r.path === "/api/voicecall/logendcall")).toHaveLength(2);

    // /api/znoise & QoS upload
    await callApi.resolveZNoise(["u2"], ["g1"]);
    expect(recorded.some((r) => r.path === "/api/znoise")).toBe(true);

    await callApi.uploadCallLog({
      callId: "1",
      ownerId: "10001",
      partnerId: "u2",
      timestamp: 1732400000,
      duration: 42,
      logBytes: Buffer.from("zrtc debug log line\n"),
    });
    expect(recorded.some((r) => r.path === "/api/qos/uploadcalllog")).toBe(true);
  });

  test("ZCallV2Bridge chunks messages >4000 chars over UNIX domain sockets with ack flow control", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zalos-zcall-"));
    const paths = {
      recvPath: join(dir, "recv.sock"),
      sendPath: join(dir, "send.sock"),
    };
    const bridge = new ZCallV2Bridge(paths);
    await bridge.start();

    let recvClient: net.Socket | null = null;
    let sendClient: net.Socket | null = null;
    try {
      recvClient = net.createConnection(paths.recvPath);
      sendClient = net.createConnection(paths.sendPath);
      await Promise.all([
        new Promise<void>((r) => recvClient!.once("connect", () => r())),
        new Promise<void>((r) => sendClient!.once("connect", () => r())),
      ]);

      const receivedChunks: string[] = [];
      let assembledHex = "";
      let streamBuf = "";
      const doneChunks = new Promise<void>((resolve) => {
        sendClient!.on("data", (buf) => {
          streamBuf += buf.toString("utf8");
          let delimIdx: number;
          while ((delimIdx = streamBuf.indexOf("$")) >= 0) {
            const packet = streamBuf.slice(0, delimIdx);
            streamBuf = streamBuf.slice(delimIdx + 1);
            if (!packet) continue;
            receivedChunks.push(`${packet}$`);
            const fields = packet.split("#");
            if (fields.length >= 4 && packet.endsWith("#")) {
              const [slice, , totalStr, idxStr] = fields;
              assembledHex += slice;
              sendClient!.write("\x01");
              if (Number(idxStr) + 1 === Number(totalStr)) resolve();
            } else {
              assembledHex += packet;
              resolve();
            }
          }
        });
      });

      // Emit native-ready from helper -> flushes queued makeCall + oversized init payload
      const longName = "A".repeat(2600);
      const sendP = bridge.makeCall([{ id: "u2", name: longName }], CallMakeType.VideoOneOne);
      recvClient.write(`${encodeZCallIpc({ type: "update", command: "native-ready", data: null })}$`);

      await sendP;
      await doneChunks;

      expect(receivedChunks.length).toBeGreaterThan(1);
      const decoded = decodeZCallIpc<{ command: string; data: { type: number; partner: Array<{ name: string }> } }>(
        assembledHex,
      );
      expect(decoded.command).toBe("makeCall");
      expect(decoded.data.type).toBe(CallMakeType.VideoOneOne);
      expect(decoded.data.partner[0]!.name).toBe(longName);

      // Test small helper sendSignal roundtrip
      const signalP = new Promise<{ command: number; data: Record<string, unknown> }>((resolve) => {
        bridge.once("send_signal", (evt) => resolve(evt));
      });
      recvClient.write(`${encodeZCallIpc({ type: "sendSignal", command: 401, data: { calleeId: "u2" } })}$`);
      const sig = await signalP;
      expect(sig).toEqual({ command: 401, data: { calleeId: "u2" } });

    // Test chunk helper directly
    const split = buildZCallChunkMessages("f".repeat(8500), 100, 5000);
    expect(split.chunks).toHaveLength(3);
    expect(split.chunks[0]).toMatch(/#5000#3#0#\$$/);
    expect(split.chunks[2]).toMatch(/#5002#3#2#\$$/);
  } finally {
    recvClient?.destroy();
    sendClient?.destroy();
    await bridge.stop();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("buildZrtcExtendData explicitly disables SRTP/SRTCP for voice and video calls", () => {
  const voice = JSON.parse(
    buildZrtcExtendData({
      isVideo: false,
      rtpAddress: "171.244.25.89:4200",
      rtcpAddress: "171.244.25.89:4004",
    }),
  ) as Record<string, unknown>;
  expect(voice).toMatchObject({
    p2p: 0,
    video: 0,
    callType: 1,
    newZrtc: 1,
    supportCallBusy: 1,
    srtpMode: 0,
    srtcp: 0,
    serverAddr: {
      rtp: "171.244.25.89:4200",
      rtcp: "171.244.25.89:4004",
    },
  });
  expect(voice.codec).toBeUndefined();

  const video = JSON.parse(buildZrtcExtendData({ isVideo: true })) as Record<string, unknown>;
  expect(video).toMatchObject({
    video: 1,
    callType: 3,
    srtpMode: 0,
    srtcp: 0,
    codec: [{ name: "H264", payload: 102 }],
  });
  expect(video.serverAddr).toBeUndefined();
});
});
