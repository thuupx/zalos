// In-container smoke check: pair, log in the fake account, claim the
// vault, send and receive a message, and verify the data dir holds no
// plaintext of the marker. Exits 0 on success.
// Usage: bun /opt/zalos/smoke/smoke.ts <zalos://pair?...> <data-dir>
import { createRequire } from "node:module";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { Client, noiseKeypair, fromHex } from "./support/client.ts";
import { Store } from "../src/store/db.ts";

const require = createRequire(import.meta.url);
const vault = require("../vendor/zalos-vault/zalos_vault.js");

const [uri, dataDir] = process.argv.slice(2);
if (uri === undefined || dataDir === undefined) {
  console.error("usage: smoke.ts <pairing uri> <data dir>");
  process.exit(1);
}

function out(name: string, value: unknown) {
  console.log(`[${name}]`, typeof value === "string" ? value : JSON.stringify(value));
}

const u = new URL(uri.replace("zalos://pair", "http://x/"));
const host = u.searchParams.get("host")!;
const port = Number(u.searchParams.get("port"));
const pairingId = u.searchParams.get("id")!;
const secret = new Uint8Array(Buffer.from(u.searchParams.get("secret")!, "base64url"));
const serverKey = fromHex(u.searchParams.get("key")!.length === 64 ? u.searchParams.get("key")! : Buffer.from(u.searchParams.get("key")!, "base64url").toString("hex"));

const kp = noiseKeypair();
const box = vault.box_keypair();
const pc = await Client.connect({
  url: `ws://${host}:${port}/v1/pair/${pairingId}`,
  prologue: `zalos/1/pair/${pairingId}`,
  devicePrivate: kp.private,
  serverPublic: serverKey,
  psk: secret,
});
const paired = (await pc.request("pair.complete", {
  deviceName: "smoke",
  boxPublicKey: Buffer.from(box.subarray(0, 32)).toString("base64"),
})) as { deviceId: string; psk: string };
pc.close();
out("paired", paired.deviceId);

const psk = new Uint8Array(Buffer.from(paired.psk, "base64"));
const ctl = await Client.connect({
  url: `ws://${host}:${port}/v1/control`,
  prologue: "zalos/1/control",
  devicePrivate: kp.private,
  serverPublic: serverKey,
  psk,
});
const done = ctl.waitEvent("loginQr.done", 15000);
await ctl.request("accounts.loginQr.start");
const slot = ((await done) as { data?: { slot?: string } }).data?.slot;
if (typeof slot !== "string") {
  const manifest = (await ctl.request("manifest.get")) as {
    accounts: { slot: string }[];
  };
  if (manifest.accounts.length === 0) throw new Error("loginQr produced no account");
  out("slot", manifest.accounts[0].slot);
} else {
  out("slot", slot);
}
const slotId =
  slot ??
  (((await ctl.request("manifest.get")) as { accounts: { slot: string }[] })
    .accounts[0]?.slot ?? "");
if (slotId === "") throw new Error("no slot");

const claim = (await ctl.request("vault.claim", {})) as { claimed: boolean };
if (!claim.claimed) throw new Error("vault.claim returned false");
const root = vault.generate_root();
const pubRaw = vault.derive_public_key(root, slotId);
const pub = typeof pubRaw === "string" ? pubRaw : Buffer.from(pubRaw).toString("base64");
await ctl.request("vault.setKey", { slot: slotId, publicKey: pub });
out("vault key set", true);

const acc = await Client.connect({
  url: `ws://${host}:${port}/v1/account/${slotId}`,
  prologue: `zalos/1/account/${slotId}`,
  devicePrivate: kp.private,
  serverPublic: serverKey,
  psk,
});

const marker = `SMK-${Math.random().toString(36).slice(2, 12)}`;
const sent = (await acc.request("messages.sendText", {
  threadId: "friend-1",
  threadType: "user",
  cliId: "smoke-1",
  text: marker,
})) as { msgId: string };
out("sent", sent.msgId);

// Inbound via the fake admin hook.
const store = new Store(dataDir);
const adminAddr = store.getMeta("fake_admin_addr");
store.close();
if (adminAddr !== null) {
  const marker2 = `${marker}-in`;
  const r = await fetch(`http://${adminAddr}/inject`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ slot: slotId, threadId: "friend-1", text: marker2 }),
  });
  out("inject status", r.status);
  const evt = acc.waitEvent("message.new", 10000);
  await evt;
  out("received inbound event", true);
}

const list = (await acc.request("messages.list", {
  threadId: "friend-1",
  threadType: "user",
})) as { messages: { id: string; sealed?: string }[] };
if (!list.messages.some((m) => m.id === sent.msgId)) {
  throw new Error("sent message missing from messages.list");
}
if (!list.messages.every((m) => typeof m.sealed === "string")) {
  throw new Error("a record is not sealed");
}
out("records sealed", list.messages.length);

// The marker plaintext must not appear anywhere in the data dir.
const needles = [Buffer.from(marker)];
function* walk(d: string): Generator<string> {
  for (const e of readdirSync(d)) {
    const p = join(d, e);
    if (statSync(p).isDirectory()) yield* walk(p);
    else yield p;
  }
}
let leaks = 0;
for (const f of walk(dataDir)) {
  try {
    const buf = readFileSync(f);
    if (needles.some((n) => buf.includes(n))) {
      console.log(`LEAK: ${f}`);
      leaks++;
    }
  } catch {}
}
if (leaks > 0) throw new Error(`${leaks} plaintext leaks`);
out("no plaintext leaks", true);

acc.close();
ctl.close();
console.log("SMOKE OK");
process.exit(0);
