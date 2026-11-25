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
import type { ActiveCall } from "../src/gateway/types.ts";

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
