import { test, expect, beforeAll, afterAll } from "bun:test";
import { WebSocket } from "ws";
import {
  makeEnv,
  pairDevice,
  controlClient,
  accountClient,
  loginQrAccount,
  type TestEnv,
  type PairedDevice,
} from "./support/helpers.ts";
import { Client, fromHex } from "./support/client.ts";

let env: TestEnv;
let admin: PairedDevice;
beforeAll(async () => {
  env = await makeEnv();
  admin = await pairDevice(env, { name: "admin" });
});
afterAll(() => env.cleanup());

test("manifest.get returns server, device, accounts", async () => {
  const c = await controlClient(env, admin);
  const m = (await c.request("manifest.get")) as {
    server: { fingerprint: string };
    device: { role: string };
    accounts: unknown[];
  };
  expect(m.server.fingerprint).toMatch(/^[0-9a-f ]+$/);
  expect(m.device.role).toBe("admin");
  expect(m.accounts).toEqual([]);
  c.close();
});

test("loginQr flow creates an account and emits events", async () => {
  const c = await controlClient(env, admin);
  const imgWait = c.waitEvent("loginQr.image");
  const doneWait = c.waitEvent("loginQr.done");
  await c.request("accounts.loginQr.start");
  const img = await imgWait;
  const done = await doneWait;
  const stream = (img.data as { stream: number }).stream;
  const png = await c.waitBlob(stream);
  expect(new TextDecoder().decode(png)).toBe("fake-qr-png");
  const slot = (done.data as { slot: string }).slot;
  const acct = env.server.store.accountBySlot(slot)!;
  expect(acct.status).toBe("online");
  c.close();
});

test("manifest.changed fires (debounced) when account appears", async () => {
  const c = await controlClient(env, admin);
  const wait = c.waitEvent("manifest.changed");
  await loginQrAccount(env, c);
  await wait;
  c.close();
});

test("ACL enforced on account channel", async () => {
  const c = await controlClient(env, admin);
  const slot = await loginQrAccount(env, c);
  const noAcl = await pairDevice(env, { name: "noacl" });
  // strip its ACL for this slot
  env.server.store.setAcl(noAcl.deviceId, []);
  const denied = await Client.connect({
    url: `ws://127.0.0.1:${env.port}/v1/account/${slot}`,
    prologue: `zalos/1/account/${slot}`,
    devicePrivate: noAcl.keypair.private,
    serverPublic: fromHex(env.serverPubHex),
    psk: noAcl.psk,
    waitHandshake: false,
  });
  expect(await denied.closed).toBe(4001);
  // grant ACL, now it works
  env.server.store.setAcl(noAcl.deviceId, [slot]);
  const ok = await accountClient(env, noAcl, slot);
  ok.close();
  c.close();
});

// Pre-authentication rejections are always 4001 so the code does not
// reveal whether a slot exists; 4004 is only for authenticated channels.
test("unknown account slot gets close 4001", async () => {
  const ws = new WebSocket(
    `ws://127.0.0.1:${env.port}/v1/account/${"ff".repeat(6)}`,
  );
  const code = await new Promise<number>((r) => {
    ws.on("close", (c) => r(c));
    ws.on("error", () => r(-1));
  });
  expect(code).toBe(4001);
});

test("devices.list / setAcl round trip", async () => {
  const member = await pairDevice(env, { name: "acl-member" });
  const c = await controlClient(env, admin);
  const res = (await c.request("devices.list")) as {
    devices: { id: string; slots: string[] }[];
  };
  expect(res.devices.some((d) => d.id === member.deviceId)).toBe(true);
  await c.request("devices.setAcl", { deviceId: member.deviceId, slots: [] });
  expect(env.server.store.deviceAcl(member.deviceId)).toEqual([]);
  c.close();
});
