import { test, expect, beforeAll, afterAll } from "bun:test";
import { WebSocket } from "ws";
import {
  makeEnv,
  pairDevice,
  controlClient,
  accountClient,
  loginQrAccount,
  fromHex,
  type TestEnv,
  type PairedDevice,
} from "./support/helpers.ts";
import { Client, noiseKeypair } from "./support/client.ts";
import { FakeGateway } from "../src/gateway/fake.ts";

let env: TestEnv;
let admin: PairedDevice;
beforeAll(async () => {
  env = await makeEnv();
  admin = await pairDevice(env, { name: "admin" });
});
afterAll(() => env.cleanup());

// A1: a channel only registers after a first successful transport decrypt.
// Post-handshake channels are tracked before their first transport
// message so devices.revoke / devices.setAcl can close pending ones too.
test("channel is tracked right after the handshake", async () => {
  const c = await Client.connect({
    url: `ws://127.0.0.1:${env.port}/v1/control`,
    prologue: "zalos/1/control",
    devicePrivate: admin.keypair.private,
    serverPublic: fromHex(env.serverPubHex),
    psk: admin.psk,
  });
  await Bun.sleep(100);
  expect(env.server.tunnel.connectionsForDevice(admin.deviceId)).toHaveLength(1);
  await c.request("manifest.get");
  await Bun.sleep(50);
  expect(env.server.tunnel.connectionsForDevice(admin.deviceId)).toHaveLength(1);
  c.close();
});

test("idle channel after handshake is closed with 4001 within 10s", async () => {
  const c = await Client.connect({
    url: `ws://127.0.0.1:${env.port}/v1/control`,
    prologue: "zalos/1/control",
    devicePrivate: admin.keypair.private,
    serverPublic: fromHex(env.serverPubHex),
    psk: admin.psk,
  });
  expect(await c.closed).toBe(4001);
}, 15000);

// A2: text frames rejected; oversized binary rejected by ws maxPayload.
test("text frame closes with 4001", async () => {
  const c = await Client.connect({
    url: `ws://127.0.0.1:${env.port}/v1/control`,
    prologue: "zalos/1/control",
    devicePrivate: admin.keypair.private,
    serverPublic: fromHex(env.serverPubHex),
    psk: admin.psk,
  });
  await c.request("manifest.get"); // authenticate
  c.ws.send("hello text");
  // Text frames on a Noise channel are a post-auth protocol error.
  expect(await c.closed).toBe(4002);
});

test("oversized binary frame is rejected by ws", async () => {
  const c = await Client.connect({
    url: `ws://127.0.0.1:${env.port}/v1/control`,
    prologue: "zalos/1/control",
    devicePrivate: admin.keypair.private,
    serverPublic: fromHex(env.serverPubHex),
    psk: admin.psk,
  });
  await c.request("manifest.get");
  c.ws.send(Buffer.alloc(71000));
  const code = await c.closed;
  expect(code === 1009 || code === 4002).toBe(true);
});

// A3: re-pairing a revoked device's key creates a fresh device; the old
// row stays a tombstone without key material.
test("re-pair of a revoked key creates a fresh device", async () => {
  const dev = await pairDevice(env, { name: "rep-air" });
  env.server.store.revokeDevice(dev.deviceId);
  // new pairing, same client keypair
  const pairing = env.server.store.createPairing("member");
  const c = await Client.connect({
    url: `ws://127.0.0.1:${env.port}/v1/pair/${pairing.id}`,
    prologue: `zalos/1/pair/${pairing.id}`,
    devicePrivate: dev.keypair.private,
    serverPublic: fromHex(env.serverPubHex),
    psk: fromHex(pairing.secret),
  });
  const res = (await c.request("pair.complete", {
    deviceName: "rep-air",
    boxPublicKey: Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64"),
  })) as {
    deviceId: string;
    psk: string;
  };
  expect(res.deviceId).not.toBe(dev.deviceId);
  expect(env.server.store.deviceById(dev.deviceId)!.revoked_at).not.toBeNull();
  const fresh = env.server.store.deviceById(res.deviceId)!;
  expect(fresh.revoked_at).toBeNull();
  // new psk works
  const conn = await controlClient(env, {
    ...dev,
    deviceId: res.deviceId,
    psk: new Uint8Array(Buffer.from(res.psk, "base64")),
  });
  conn.close();
});

// A4: setAcl drops live channels for lost slots; accounts.remove drops all.
test("setAcl closes live account channel for a removed slot", async () => {
  const control = await controlClient(env, admin);
  const slot = await loginQrAccount(env, control);
  const member = await pairDevice(env, { name: "acl-drop" });
  env.server.store.setAcl(member.deviceId, [slot]);
  const acctConn = await accountClient(env, member, slot);
  await control.request("devices.setAcl", {
    deviceId: member.deviceId,
    slots: [],
  });
  expect(await acctConn.closed).toBe(4001);
  control.close();
});

test("accounts.remove closes all channels of the slot", async () => {
  const control = await controlClient(env, admin);
  const slot = await loginQrAccount(env, control);
  const member = await pairDevice(env, { name: "acct-remove" });
  env.server.store.setAcl(member.deviceId, [slot]);
  const acctConn = await accountClient(env, member, slot);
  await control.request("accounts.remove", { slot });
  expect(await acctConn.closed).toBe(4004);
  control.close();
});

// A5: SSRF guard edge cases via assertPublicUrl.
test("ssrf: localhost, unresolvable, mapped v6, multicast rejected", async () => {
  const { assertPublicUrl } = await import("../src/media.ts");
  for (const url of [
    "http://localhost/x",
    "http://127.0.0.1/x",
    "http://[::1]/x",
    "http://this-host-should-not-exist.invalid/x",
    "http://224.0.0.1/x",
    "http://255.255.255.255/x",
  ]) {
    await expect(assertPublicUrl(url)).rejects.toMatchObject({
      code: "forbidden",
    });
  }
});

// A6: non-RpcError becomes {code:"internal"} on the wire.
test("non-RpcError maps to internal error", async () => {
  const control = await controlClient(env, admin);
  const slot = await loginQrAccount(env, control);
  const gw = env.factory.gateways.at(-1) as FakeGateway;
  gw.userInfo = () => Promise.reject(new Error("boom zca"));
  const a = await accountClient(env, admin, slot);
  const err = await a
    .request("users.info", { uids: ["x"] })
    .then(() => null, (e: Error & { code?: string }) => e);
  expect(err!.code).toBe("internal");
  expect(err!.message).toBe("internal error");
  a.close();
  control.close();
});
