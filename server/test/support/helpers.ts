import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";
import { createZalosServer, type ZalosServer } from "../../src/server.ts";
import type { TunnelLimits } from "../../src/tunnel/server.ts";
import { FakeGatewayFactory } from "../../src/gateway/fake.ts";
import { Client, noiseKeypair, fromHex } from "./client.ts";

export type TestEnv = {
  server: ZalosServer;
  factory: FakeGatewayFactory;
  port: number;
  dir: string;
  serverPubHex: string;
  cleanup(): Promise<void>;
};

export async function makeEnv(
  opts: {
    fake?: boolean;
    autoDeleteSweepMs?: number;
    messageTtlSweepMs?: number;
    limits?: TunnelLimits;
  } = {},
): Promise<TestEnv> {
  const dir = mkdtempSync(join(tmpdir(), "zalos-test-"));
  const factory = new FakeGatewayFactory();
  const server = createZalosServer({
    dataDir: dir,
    fake: opts.fake ?? true,
    factory,
    autoDeleteSweepMs: opts.autoDeleteSweepMs,
    messageTtlSweepMs: opts.messageTtlSweepMs,
    limits: opts.limits,
  });
  const port = await server.tunnel.listen(0, "127.0.0.1");
  return {
    server,
    factory,
    port,
    dir,
    serverPubHex: Buffer.from(server.tunnel.serverKey.public).toString("hex"),
    async cleanup() {
      await server.close();
    },
  };
}

export function deviceKeypair() {
  return noiseKeypair();
}

export type PairedDevice = {
  deviceId: string;
  psk: Uint8Array;
  role: string;
  keypair: { public: Uint8Array; private: Uint8Array };
  boxPublicKey: Uint8Array;
};

export async function pairDevice(
  env: TestEnv,
  opts: { name?: string; role?: string } = {},
): Promise<PairedDevice> {
  const pairing = env.server.store.createPairing(
    (opts.role as "admin" | "member") ?? "member",
  );
  return pairDeviceWith(env, pairing.id, fromHex(pairing.secret), opts);
}

export async function pairDeviceWith(
  env: TestEnv,
  pairingId: string,
  secret: Uint8Array,
  opts: { name?: string } = {},
  keypair = noiseKeypair(),
): Promise<PairedDevice> {
  const c = await Client.connect({
    url: `ws://127.0.0.1:${env.port}/v1/pair/${pairingId}`,
    prologue: `zalos/1/pair/${pairingId}`,
    devicePrivate: keypair.private,
    serverPublic: fromHex(env.serverPubHex),
    psk: secret,
  });
  const boxPublicKey = crypto.getRandomValues(new Uint8Array(32));
  const res = (await c.request("pair.complete", {
    deviceName: opts.name ?? "test-device",
    boxPublicKey: Buffer.from(boxPublicKey).toString("base64"),
  })) as { deviceId: string; psk: string; role: string };
  await c.closed;
  return {
    deviceId: res.deviceId,
    psk: new Uint8Array(Buffer.from(res.psk, "base64")),
    role: res.role,
    keypair,
    boxPublicKey,
  };
}

// ---- vault test support ----

// One vault root per test env; the server never sees it.
const require = createRequire(import.meta.url);
const vault = require("../../vendor/zalos-vault/zalos_vault.js") as {
  generate_root(): Uint8Array;
  derive_public_key(root: Uint8Array, slot: string): Uint8Array;
  open_with_root(
    root: Uint8Array,
    slot: string,
    aad: Uint8Array,
    sealed: Uint8Array,
  ): Uint8Array;
  file_opener_with_root(
    root: Uint8Array,
    slot: string,
    aad: Uint8Array,
    header: Uint8Array,
  ): { open_chunk(c: Uint8Array): Uint8Array };
};

export function vaultRoot(env: TestEnv): Uint8Array {
  const anyEnv = env as TestEnv & { __root?: Uint8Array };
  if (anyEnv.__root === undefined) {
    anyEnv.__root = vault.generate_root();
  }
  return anyEnv.__root;
}

// Give the account a vault key through the control channel and return the
// derived public key.
export async function setVaultKey(
  env: TestEnv,
  control: Client,
  slot: string,
): Promise<Uint8Array> {
  const pk = vault.derive_public_key(vaultRoot(env), slot);
  await control.request("vault.setKey", {
    slot,
    publicKey: Buffer.from(pk).toString("base64"),
  });
  return pk;
}

const te = new TextEncoder();

// Open the `sealed` field of a wire record and return the body object.
export function openRecord(
  env: TestEnv,
  slot: string,
  rec: { id: string; sealed?: string; body?: Record<string, unknown> },
): Record<string, unknown> {
  if (rec.body !== undefined) return rec.body;
  const aad = te.encode(`zalos/1/msg/${slot}/${rec.id}`);
  const pt = vault.open_with_root(
    vaultRoot(env),
    slot,
    aad,
    Buffer.from(rec.sealed!, "base64"),
  );
  return JSON.parse(new TextDecoder().decode(pt));
}

// Open a sealed media blob (header || chunks).
export function openMedia(
  env: TestEnv,
  slot: string,
  url: string,
  size: number,
  blob: Uint8Array,
): Uint8Array {
  const hash = Buffer.from(
    require("node:crypto").createHash("sha256").update(url).digest(),
  );
  const aad = te.encode(`zalos/1/media/${slot}/${hash.toString("hex")}/${size}`);
  const opener = vault.file_opener_with_root(
    vaultRoot(env),
    slot,
    aad,
    blob.subarray(0, 32),
  );
  const out: Uint8Array[] = [];
  const CHUNK = 1024 * 1024 + 16;
  for (let off = 32; off < blob.length; off += CHUNK) {
    out.push(opener.open_chunk(blob.subarray(off, off + CHUNK)));
  }
  const total = out.reduce((n, c) => n + c.length, 0);
  const res = new Uint8Array(total);
  let at = 0;
  for (const c of out) {
    res.set(c, at);
    at += c.length;
  }
  return res;
}

export async function controlClient(
  env: TestEnv,
  device: PairedDevice,
): Promise<Client> {
  const c = await Client.connect({
    url: `ws://127.0.0.1:${env.port}/v1/control`,
    prologue: "zalos/1/control",
    devicePrivate: device.keypair.private,
    serverPublic: fromHex(env.serverPubHex),
    psk: device.psk,
  });
  // First transport message proves psk knowledge; the server only registers
  // (broadcasts, device registry) after it, so send a benign request now.
  await c.request("manifest.get");
  return c;
}

export async function accountClient(
  env: TestEnv,
  device: PairedDevice,
  slot: string,
): Promise<Client> {
  const c = await Client.connect({
    url: `ws://127.0.0.1:${env.port}/v1/account/${slot}`,
    prologue: `zalos/1/account/${slot}`,
    devicePrivate: device.keypair.private,
    serverPublic: fromHex(env.serverPubHex),
    psk: device.psk,
  });
  await c.request("sync", { sinceSeq: Number.MAX_SAFE_INTEGER });
  return c;
}

export async function loginQrAccount(
  env: TestEnv,
  admin: Client,
): Promise<string> {
  const waiter = admin.waitEvent("loginQr.done", 10000);
  await admin.request("accounts.loginQr.start");
  const evt = await waiter;
  return (evt.data as { slot: string }).slot;
}

export { fromHex, toHex, noiseKeypair } from "./client.ts";
