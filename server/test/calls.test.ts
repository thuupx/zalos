import { afterAll, beforeAll, expect, test } from "bun:test";
import {
  accountClient,
  controlClient,
  loginQrAccount,
  makeEnv,
  pairDevice,
  type PairedDevice,
  type TestEnv,
} from "./support/helpers.ts";
import type { FakeGateway } from "../src/gateway/fake.ts";
import type { ActiveCall, ZaloGateway } from "../src/gateway/types.ts";
import { CallManager } from "../src/accounts/call_manager.ts";
import { CallMediaGateway } from "../src/accounts/call_media_gateway.ts";
import type { ZrtcRelaySession } from "../src/accounts/zrtc_session.ts";
import type { Store } from "../src/store/db.ts";
import type { TunnelServer } from "../src/tunnel/server.ts";

let env: TestEnv;
let devA: PairedDevice;
let devB: PairedDevice;
let slot: string;
let gw: FakeGateway;

beforeAll(async () => {
  env = await makeEnv({ autoDeleteSweepMs: 0 });
  devA = await pairDevice(env, { name: "phone-A" });
  devB = await pairDevice(env, { name: "desktop-B" });
  const control = await controlClient(env, devA);
  slot = await loginQrAccount(env, control);
  gw = env.factory.gateways.at(-1)!;
  // Share account slot ACL with devB too.
  await control.request("devices.setAcl", {
    deviceId: devB.deviceId,
    slots: [slot],
  });
  control.close();
});

afterAll(() => env.cleanup());

test("capabilities include voiceCall and videoCall", () => {
  expect(gw.capabilities()).toContain("voiceCall");
  expect(gw.capabilities()).toContain("videoCall");
});

test("incoming call broadcasts ephemerally with zero SQLite event rows and atomic accept pickup", async () => {
  const clientA = await accountClient(env, devA, slot);
  const clientB = await accountClient(env, devB, slot);
  try {
    const beforeEvents = env.server.store.eventsSince(slot, 0).length;

    const incomingA = clientA.waitEvent("call.incoming", 5000);
    const incomingB = clientB.waitEvent("call.incoming", 5000);

    gw.simulateIncomingCall({
      callId: "call-in-1",
      callerId: "friend-call-1",
      callerName: "Nguyễn Văn Call",
      media: "video",
    });

    const [evtA, evtB] = await Promise.all([incomingA, incomingB]);
    expect(evtA.seq).toBeUndefined();
    expect(evtB.seq).toBeUndefined();
    const callA = (evtA.data as { call: ActiveCall }).call;
    expect(callA.callId).toBe("call-in-1");
    expect(callA.media).toBe("video");
    expect(callA.status).toBe("ringing");
    expect(callA.direction).toBe("incoming");

    // Verify 0 SQLite durable event rows were written for ephemeral call signaling.
    const afterIncomingEvents = env.server.store.eventsSince(slot, 0).length;
    expect(afterIncomingEvents).toBe(beforeEvents);

    // devA accepts first; devB must receive call.answeredElsewhere, NOT devA.
    const elsewhereB = clientB.waitEvent("call.answeredElsewhere", 5000);
    const accepted = (await clientA.request("calls.accept", {
      callId: "call-in-1",
    })) as { call: ActiveCall };
    expect(accepted.call.status).toBe("active");
    expect(accepted.call.answeredByDeviceId).toBe(devA.deviceId);

    const els = await elsewhereB;
    expect(els.data).toMatchObject({
      callId: "call-in-1",
      answeredByDeviceId: devA.deviceId,
    });
    expect(clientA.events.some((e) => e.event === "call.answeredElsewhere")).toBe(false);

    // Racing accept from devB must fail with conflict.
    let conflictErr: unknown;
    try {
      await clientB.request("calls.accept", { callId: "call-in-1" });
    } catch (e) {
      conflictErr = e;
    }
    expect(conflictErr).toMatchObject({ code: "conflict" });

    // Clean hangup removes active call and broadcasts ephemeral call.ended.
    const endedA = clientA.waitEvent("call.ended", 5000);
    const endedB = clientB.waitEvent("call.ended", 5000);
    await clientA.request("calls.hangup", { callId: "call-in-1" });
    await Promise.all([endedA, endedB]);

    const active = (await clientA.request("calls.active")) as { calls: ActiveCall[] };
    expect(active.calls).toEqual([]);
  } finally {
    clientA.close();
    clientB.close();
  }
});

test("reject local silences only requester while global rejects for all devices", async () => {
  const clientA = await accountClient(env, devA, slot);
  const clientB = await accountClient(env, devB, slot);
  try {
    const incomingB = clientB.waitEvent("call.incoming", 5000);
    gw.simulateIncomingCall({
      callId: "call-in-2",
      callerId: "friend-call-2",
      media: "voice",
    });
    await incomingB;

    const endedA = clientA.waitEvent("call.ended", 5000);
    await clientA.request("calls.reject", {
      callId: "call-in-2",
      scope: "local",
    });
    const localEnd = await endedA;
    expect(localEnd.data).toMatchObject({
      callId: "call-in-2",
      reason: "silenced_locally",
    });

    // Call must still be active on devB.
    const activeB = (await clientB.request("calls.active")) as { calls: ActiveCall[] };
    expect(activeB.calls.some((c) => c.callId === "call-in-2")).toBe(true);

    // Global reject from devB terminates for everyone.
    const globalEndB = clientB.waitEvent("call.ended", 5000);
    await clientB.request("calls.reject", {
      callId: "call-in-2",
      scope: "global",
    });
    const ge = await globalEndB;
    expect(ge.data).toMatchObject({ callId: "call-in-2", reason: "rejected" });
  } finally {
    clientA.close();
    clientB.close();
  }
});

test("outgoing start, groupState, and zaloSignal RPCs", async () => {
  const client = await accountClient(env, devA, slot);
  try {
    const started = (await client.request("calls.start", {
      threadId: "group-call-1",
      threadType: "group",
      media: "video",
    })) as { call: ActiveCall };
    expect(started.call.direction).toBe("outgoing");
    expect(started.call.isGroup).toBe(true);
    expect(started.call.media).toBe("video");

    gw.groupCallStates.set("group-call-1", {
      groupId: "group-call-1",
      active: true,
      members: ["u1", "u2"],
    });
    const gs = (await client.request("calls.groupState", {
      groupId: "group-call-1",
    })) as { active: boolean; members: string[] };
    expect(gs.active).toBe(true);
    expect(gs.members).toEqual(["u1", "u2"]);

    const sig = (await client.request("calls.zaloSignal", {
      callId: started.call.callId,
      action: "conf",
      payload: { isOnCam: true, isOnMic: true },
    })) as { ok: boolean };
    expect(sig.ok).toBe(true);

    await client.request("calls.hangup", { callId: started.call.callId });
  } finally {
    client.close();
  }
});

test("calls.media.config RPC returns configured iceServers", async () => {
  const client = await accountClient(env, devA, slot);
  try {
    const cfg = (await client.request("calls.media.config", {})) as {
      iceServers: Array<{ urls: string | string[] }>;
    };
    expect(Array.isArray(cfg.iceServers)).toBe(true);
    expect(cfg.iceServers.length).toBeGreaterThan(0);
  } finally {
    client.close();
  }
});

test("CallManager cleans up and broadcasts relay_failed when outgoing ZRTC connect fails", async () => {
  const broadcasts: Array<{ event: string; data: unknown }> = [];
  const invites: unknown[] = [];
  const cancels: unknown[] = [];
  let attempts = 0;

  const mockGw = {
    self: { uid: "1001", displayName: "Me", avatarUrl: "" },
    startCall: async () => ({
      callId: "9001",
      serverConfig: {
        sessId: "s-9001",
        servers: [{ rtpaddr: "171.244.25.89:4200", rtcpaddr: "171.244.25.89:4004" }],
      },
    }),
    sendCallInvite: async (_callId: string, opts: unknown) => {
      invites.push(opts);
    },
    cancelCall: async (callId: string, opts: unknown) => {
      cancels.push({ callId, opts });
    },
  } as unknown as ZaloGateway;

  let endedResolve!: () => void;
  const endedPromise = new Promise<void>((r) => {
    endedResolve = r;
  });

  const tunnel = {
    broadcastAccount: (_slot: string, event: string, data: unknown) => {
      broadcasts.push({ event, data });
      if (event === "call.ended") endedResolve();
    },
    accountChannels: () => [],
  } as unknown as TunnelServer;

  const store = {
    getProfile: () => null,
  } as unknown as Store;

  const mediaGateway = new CallMediaGateway();
  const mgr = new CallManager(() => mockGw, tunnel, store, mediaGateway, {
    maxAttempts: 2,
    timeoutMs: 20,
    factory: () =>
      ({
        connect: async () => {
          attempts++;
          throw new Error("relay timeout");
        },
        close: () => {},
      }) as unknown as ZrtcRelaySession,
  });

  await mgr.start("main", "2002", "user", "voice", "dev-1");
  await endedPromise;

  expect(attempts).toBe(2);
  expect(invites).toHaveLength(0);
  expect(cancels).toHaveLength(1);
  expect(mgr.activeCalls("main")).toHaveLength(0);
  expect(mediaGateway.getBridge("main", "9001")).toBeUndefined();
  expect(broadcasts.some((b) => b.event === "call.ended")).toBe(true);
  const ended = broadcasts.find((b) => b.event === "call.ended")!.data as {
    callId: string;
    reason: string;
  };
  expect(ended).toEqual({ callId: "9001", reason: "relay_failed" });
});

test("CallManager retries outgoing ZRTC connect and attaches relay when retry succeeds", async () => {
  const invites: Array<{ rtpAddress: string; rtcpAddress: string; extendData?: string }> = [];
  let attempts = 0;
  let inviteResolve!: () => void;
  const invitePromise = new Promise<void>((r) => {
    inviteResolve = r;
  });

  const mockGw = {
    self: { uid: "1001", displayName: "Me", avatarUrl: "" },
    startCall: async () => ({
      callId: "9002",
      serverConfig: {
        sessId: "s-9002",
        servers: [{ rtpaddr: "171.244.25.89:4200", rtcpaddr: "171.244.25.89:4004" }],
      },
    }),
    sendCallInvite: async (
      _callId: string,
      opts: { rtpAddress: string; rtcpAddress: string; extendData?: string },
    ) => {
      invites.push(opts);
      inviteResolve();
    },
  } as unknown as ZaloGateway;

  const tunnel = {
    broadcastAccount: () => {},
    accountChannels: () => [],
  } as unknown as TunnelServer;
  const store = { getProfile: () => null } as unknown as Store;
  const mediaGateway = new CallMediaGateway();
  const mgr = new CallManager(() => mockGw, tunnel, store, mediaGateway, {
    maxAttempts: 2,
    timeoutMs: 20,
    factory: () =>
      ({
        connect: async () => {
          attempts++;
          if (attempts === 1) throw new Error("transient timeout");
          return {
            token: 555,
            rtpAddress: "171.244.25.89:4200",
            rtcpAddress: "171.244.25.89:4004",
            transport: "udp" as const,
          };
        },
        close: () => {},
      }) as unknown as ZrtcRelaySession,
  });

  await mgr.start("main-slot", "2002", "user", "voice", "dev-1");
  await invitePromise;

  expect(attempts).toBe(2);
  expect(invites).toHaveLength(1);
  expect(invites[0]!.rtpAddress).toBe("171.244.25.89:4200");
  const extendData = JSON.parse(invites[0]!.extendData ?? "{}") as Record<string, unknown>;
  expect(extendData).toEqual({
    callType: 0,
    fecTP: 0,
    gccAudio: 0,
    gccEarlyCall: 0,
    gccMode: 0,
    gccSVLR: 0,
    maxFT: 120,
    newZrtc: 1,
    packetMode: 2,
    platform: 2,
    sP2P: 0,
    serverAddr: [
      {
        rtcp: "171.244.25.89:4004",
        rtcpIPv6: "::FFFF:171.244.25.89:4004",
        rtp: "171.244.25.89:4200",
        rtpIPv6: "::FFFF:171.244.25.89:4200",
        tpType: 0,
      },
    ],
    spTcp: 0,
    srtcp: 0,
    srtpMode: 0,
    supportCallBusy: 0,
    supportHevcDecode: 0,
    tpType: 0,
    video: { codec: [{ name: "h264", payload: 97 }] },
    rtcpDiff: 0,
    rtcp: [{ ip: "171.244.25.89", port: 4004 }],
    rtp: [{ ip: "171.244.25.89", port: 4200 }],
    status: 0,
  });
  expect(mediaGateway.getBridge("main-slot", "9002")?.zrtc).toBeDefined();
  await mediaGateway.closeCall("main-slot", "9002");
});

test("CallManager.accept rejects with relay_failed and does not enter active without ZRTC", async () => {
  const answers: unknown[] = [];
  const mockGw = {
    self: { uid: "2002", displayName: "Callee", avatarUrl: "" },
    answerCall: async (_callId: string, opts: unknown) => {
      answers.push(opts);
      return {};
    },
    sendRingRing: async () => {},
  } as unknown as ZaloGateway;

  const tunnel = {
    broadcastAccount: () => {},
    accountChannels: () => [],
  } as unknown as TunnelServer;
  const store = { getProfile: () => null } as unknown as Store;

  let shouldFail = true;
  const mediaGateway = new CallMediaGateway();
  const mgr = new CallManager(() => mockGw, tunnel, store, mediaGateway, {
    maxAttempts: 2,
    timeoutMs: 20,
    factory: () =>
      ({
        connect: async () => {
          if (shouldFail) throw new Error("callee relay timeout");
          return {
            token: 777,
            rtpAddress: "171.244.25.89:4200",
            rtcpAddress: "171.244.25.89:4004",
            transport: "udp" as const,
          };
        },
        close: () => {},
      }) as unknown as ZrtcRelaySession,
  });

  mgr.onVoipEvent("s1", {
    act: "request",
    ts: Date.now(),
    callerId: "1001",
    inCallStatus: null,
    data: {
      callId: "9003",
      session: "sess-9003",
      rtpAddress: "171.244.25.89:4200",
      rtcpAddress: "171.244.25.89:4004",
    },
  });

  let caught: unknown;
  try {
    await mgr.accept("s1", "9003", "dev-1");
  } catch (e) {
    caught = e;
  }
  expect(caught).toMatchObject({ code: "relay_failed" });
  expect(answers).toHaveLength(0);
  const afterFail = mgr.activeCalls("s1")[0]!;
  expect(afterFail.status).toBe("ringing");
  expect(afterFail.answeredByDeviceId).toBeUndefined();
  expect(mediaGateway.getBridge("s1", "9003")).toBeUndefined();

  shouldFail = false;
  const accepted = await mgr.accept("s1", "9003", "dev-1");
  expect(accepted.call.status).toBe("active");
  expect(answers).toHaveLength(1);
  expect(mediaGateway.getBridge("s1", "9003")?.zrtc).toBeDefined();
  await mediaGateway.closeCall("s1", "9003");
});
