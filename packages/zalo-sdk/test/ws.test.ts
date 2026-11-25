import { describe, expect, test } from "bun:test";
import { randomBytes } from "node:crypto";
import { WebSocketServer } from "ws";
import { CLIENT_PROFILES, WS_CMD, WS_SUB_CMD } from "../src/core/constants.ts";
import type { ZaloContext } from "../src/core/context.ts";
import { ZaloCookieJar } from "../src/core/cookies.ts";
import { encodeWsPayload } from "../src/core/crypto.ts";
import { ThreadType } from "../src/models/enums.ts";
import { decodeWsFrame, encodeWsFrame } from "../src/ws/framing.ts";
import { ZaloListener } from "../src/ws/listener.ts";

function makeContext(wsUrl: string): ZaloContext {
  return {
    uid: "10001",
    imei: "test-imei",
    userAgent: "TestAgent",
    language: "vi",
    secretKey: randomBytes(16).toString("base64"),
    cookie: new ZaloCookieJar("zpw_sek=abc"),
    profile: CLIENT_PROFILES.pc_macos,
    apiType: 23,
    apiVersion: 694,
    computerName: "Mac",
    settings: {},
    extraVer: {},
    zpwServiceMap: {},
    wsUrls: [wsUrl],
    uploadCallbacks: new Map(),
    options: { selfListen: true, checkUpdate: false, logging: false },
  };
}

describe("WebSocket binary framing & listener", () => {
  test("handles cmd=1 cipherKey handshake, encrypt=2 GCM+zlib messages, brace-less typing, voip staleness, file_done, and E2EE req/resp", async () => {
    const cipherKey = randomBytes(32).toString("base64");
    const wss = new WebSocketServer({ port: 0, host: "127.0.0.1" });
    await new Promise<void>((resolve) => wss.once("listening", () => resolve()));
    const addr = wss.address() as { port: number };
    const wsUrl = `ws://127.0.0.1:${addr.port}/ws`;

    let inCall = true;
    const listener = new ZaloListener(makeContext(wsUrl), {
      pingIntervalMs: 60_000,
      isInCall: () => inCall,
    });

    const receivedFrames: Array<{ cmd: number; subCmd: number; body: Record<string, unknown> }> = [];
    wss.on("connection", (sock) => {
      // 1. Send AUTHEN handshake (cmd=1, subCmd=1) with AES-GCM cipherKey
      sock.send(
        encodeWsFrame(1, WS_CMD.AUTHEN, WS_SUB_CMD.AUTHEN, {
          error_code: 0,
          key: cipherKey,
          encrypt: 2,
          data: encodeWsPayload({ error_code: 0, data: { qCmds: [], ctrl_qCmds: [] } }, 2, cipherKey),
        }),
      );

      sock.on("message", (buf: Buffer) => {
        const parsed = decodeWsFrame(buf);
        const body = JSON.parse(parsed.bodyText) as Record<string, unknown>;
        receivedFrames.push({ cmd: parsed.cmd, subCmd: parsed.subCmd, body });
        if (parsed.cmd === WS_CMD.E2EE_GET_BUNDLE) {
          sock.send(
            encodeWsFrame(1, WS_CMD.E2EE_GET_BUNDLE, 0, {
              error_code: 0,
              encrypt: 2,
              data: encodeWsPayload(
                { error_code: 0, data: { reqId: body.reqId, bundles: [{ uid: "20002", identityKey: "IK" }] } },
                2,
                cipherKey,
              ),
            }),
          );
        }
      });

      // 2. Push encrypted 1:1 message (encrypt=2 AES-256-GCM + zlib) with >53-bit msgId
      sock.send(
        encodeWsFrame(1, WS_CMD.PUSH_MSG_1_1, 0, {
          encrypt: 2,
          data: encodeWsPayload(
            {
              error_code: 0,
              data: {
                msgs: [
                  {
                    msgId: 9007199254740999888n.toString(),
                    cliMsgId: "111",
                    msgType: "webchat",
                    uidFrom: "20002",
                    idTo: "0",
                    ts: String(Date.now()),
                    content: "Hello encrypted WS",
                  },
                ],
              },
            },
            2,
            cipherKey,
          ),
        }),
      );

      // 3. Push cmd=602 brace-less typing quirk
      sock.send(
        encodeWsFrame(1, WS_CMD.CTRL_ACTION, 0, {
          encrypt: 0,
          data: JSON.stringify({
            actions: [{ act_type: "typing", act: "typing", data: '"uid":"20002","ts":"1732400"' }],
          }),
        }),
      );

      // 4. Push fresh VoIP request + stale VoIP request (>60s) + async file_done
      const now = Date.now();
      sock.send(
        encodeWsFrame(1, WS_CMD.CTRL_PUSH_CTRL, 0, {
          encrypt: 0,
          data: JSON.stringify({
            controls: [
              {
                content: {
                  act_type: "voip",
                  act: "request",
                  data: JSON.stringify({ callerId: "20002", callId: "c-fresh", ts: now }),
                },
              },
              {
                content: {
                  act_type: "voip",
                  act: "request",
                  data: JSON.stringify({ callerId: "20002", callId: "c-stale", ts: now - 120_000 }),
                },
              },
              {
                content: {
                  act_type: "file_done",
                  fileId: "file-77",
                  data: JSON.stringify({ url: "https://cdn.example/f77.pdf" }),
                },
              },
            ],
          }),
        }),
      );
    });

    const events = {
      connected: false,
      msgs: [] as unknown[],
      typings: [] as unknown[],
      voips: [] as unknown[],
      droppedStale: [] as unknown[],
      uploadDone: null as unknown,
    };

    const donePromise = new Promise<void>((resolve) => {
      listener.ctx.uploadCallbacks.set("file-77", (d) => {
        events.uploadDone = d;
        if (events.msgs.length && events.typings.length && events.voips.length) resolve();
      });
      listener.on("connected", () => {
        events.connected = true;
      });
      listener.on("message", (m) => {
        events.msgs.push(m);
        if (events.uploadDone && events.typings.length && events.voips.length) resolve();
      });
      listener.on("typing", (t) => {
        events.typings.push(t);
        if (events.uploadDone && events.msgs.length && events.voips.length) resolve();
      });
      listener.on("voip_control", (v) => {
        events.voips.push(v);
        if (events.uploadDone && events.msgs.length && events.typings.length) resolve();
      });
      listener.on("voip_dropped_stale", (s) => events.droppedStale.push(s));
    });

    listener.start({ retryOnClose: false });
    await donePromise;

    expect(events.connected).toBe(true);
    expect(events.msgs).toHaveLength(1);
    const msg = events.msgs[0] as { threadId: string; data: { msgId: string; idTo: string } };
    expect(msg.threadId).toBe("20002");
    expect(msg.data.idTo).toBe("10001");
    expect(msg.data.msgId).toBe("9007199254740999888");

    expect(events.typings).toHaveLength(1);
    expect((events.typings[0] as { type: ThreadType; threadId: string }).threadId).toBe("20002");

    // Stale >60s invite was dropped; fresh invite carries inCallStatus="zalo"
    expect(events.voips).toHaveLength(1);
    expect((events.voips[0] as { inCallStatus: string; data: { callId: string } }).data.callId).toBe("c-fresh");
    expect((events.voips[0] as { inCallStatus: string }).inCallStatus).toBe("zalo");
    expect(events.droppedStale).toHaveLength(1);

    expect(events.uploadDone).toEqual({ url: "https://cdn.example/f77.pdf" });

    // Test E2EE correlated requestCommand
    const bundleRes = (await listener.requestCommand(WS_CMD.E2EE_GET_BUNDLE, WS_SUB_CMD.E2EE_REQUEST, {
      uids: [{ uid: "20002", deviceId: 2 }],
    })) as { bundles: Array<{ uid: string }> };
    expect(bundleRes.bundles[0]!.uid).toBe("20002");

    // Test history request framing
    listener.requestOldMessages(ThreadType.Group, "999");
    await new Promise((r) => setTimeout(r, 30));
    expect(receivedFrames.some((f) => f.cmd === WS_CMD.OFFLINE_MSG_GROUP && f.subCmd === 1)).toBe(true);

    inCall = false;
    listener.stop();
    await new Promise<void>((r) => wss.close(() => r()));
  });
});
