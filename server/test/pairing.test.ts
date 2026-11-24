import { test, expect, beforeAll, afterAll } from "bun:test";
import { WebSocket } from "ws";
import {
  makeEnv,
  pairDevice,
  pairDeviceWith,
  controlClient,
  noiseKeypair,
  type TestEnv,
} from "./support/helpers.ts";
import { Client, fromHex } from "./support/client.ts";

let env: TestEnv;
beforeAll(async () => {
  env = await makeEnv();
});
afterAll(() => env.cleanup());

test("pairing happy path: first device becomes admin", async () => {
  const dev = await pairDevice(env, { name: "first" });
  expect(dev.role).toBe("admin");
  const row = env.server.store.deviceById(dev.deviceId)!;
  expect(row.role).toBe("admin");
  expect(row.public_key).toBeTruthy();
});

test("second device gets the pairing role, not admin", async () => {
  const dev = await pairDevice(env, { name: "second", role: "admin" });
  expect(dev.role).toBe("admin"); // pairing asked for admin
  const dev2 = await pairDevice(env, { name: "third" });
  expect(dev2.role).toBe("member");
});

test("pairing is single use", async () => {
  const pairing = env.server.store.createPairing("member");
  await pairDeviceWith(env, pairing.id, fromHex(pairing.secret));
  const kp = noiseKeypair();
  const c = await Client.connect({
    url: `ws://127.0.0.1:${env.port}/v1/pair/${pairing.id}`,
    prologue: `zalos/1/pair/${pairing.id}`,
    devicePrivate: kp.private,
    serverPublic: fromHex(env.serverPubHex),
    psk: fromHex(pairing.secret),
    waitHandshake: false,
  });
  expect(await c.closed).toBe(4001);
});

test("expired pairing is rejected", async () => {
  const pairing = env.server.store.createPairing("member", -1000);
  const kp = noiseKeypair();
  const c = await Client.connect({
    url: `ws://127.0.0.1:${env.port}/v1/pair/${pairing.id}`,
    prologue: `zalos/1/pair/${pairing.id}`,
    devicePrivate: kp.private,
    serverPublic: fromHex(env.serverPubHex),
    psk: fromHex(pairing.secret),
    waitHandshake: false,
  });
  expect(await c.closed).toBe(4001);
});

// Same rule as unknown account slots: pre-auth rejections are 4001.
test("unknown pairing id gets close 4001", async () => {
  const kp = noiseKeypair();
  const ws = new WebSocket(`ws://127.0.0.1:${env.port}/v1/pair/${"aa".repeat(8)}`);
  const code = await new Promise<number>((r) => {
    ws.on("close", (c) => r(c));
    ws.on("error", () => r(-1));
  });
  expect(code).toBe(4001);
});

test("unknown device cannot open control channel", async () => {
  const stranger = noiseKeypair();
  const c = await Client.connect({
    url: `ws://127.0.0.1:${env.port}/v1/control`,
    prologue: "zalos/1/control",
    devicePrivate: stranger.private,
    serverPublic: fromHex(env.serverPubHex),
    psk: new Uint8Array(32),
    waitHandshake: false,
  });
  const code = await c.closed;
  expect(code).toBe(4001);
});

test("revoked device cannot reconnect; live socket is closed", async () => {
  const admin = await pairDevice(env, { name: "admin2", role: "admin" });
  const member = await pairDevice(env, { name: "member1" });
  const memberConn = await controlClient(env, member);
  const adminConn = await controlClient(env, admin);
  await adminConn.request("devices.revoke", { deviceId: member.deviceId });
  const code = await memberConn.closed;
  expect(code).toBe(4001);
  // and it cannot come back
  const again = await Client.connect({
    url: `ws://127.0.0.1:${env.port}/v1/control`,
    prologue: "zalos/1/control",
    devicePrivate: member.keypair.private,
    serverPublic: fromHex(env.serverPubHex),
    psk: member.psk,
    waitHandshake: false,
  });
  expect(await again.closed).toBe(4001);
  adminConn.close();
});

test("prologue mismatch fails the handshake", async () => {
  const dev = await pairDevice(env, { name: "prolo" });
  const c = await Client.connect({
    url: `ws://127.0.0.1:${env.port}/v1/control`,
    prologue: "zalos/1/account/whatever",
    devicePrivate: dev.keypair.private,
    serverPublic: fromHex(env.serverPubHex),
    psk: dev.psk,
    waitHandshake: false,
  });
  expect(await c.closed).toBe(4001);
});

test("non-admin gets forbidden on admin methods", async () => {
  const member = await pairDevice(env, { name: "mem-forbid" });
  const conn = await controlClient(env, member);
  const err = await conn.request("devices.list").then(
    () => null,
    (e) => e,
  );
  expect(err.code).toBe("forbidden");
  // but manifest.get is fine
  const manifest = await conn.request("manifest.get");
  expect(manifest).toHaveProperty("server");
  conn.close();
});
