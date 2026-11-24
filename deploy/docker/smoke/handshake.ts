// Host-side check for the local variant: completes a Noise pairing
// handshake through the published loopback port.
// Usage: bun deploy/docker/smoke/handshake.ts <zalos://pair?...>
import { Client, noiseKeypair, fromHex } from "../../../server/test/support/client.ts";

const uri = process.argv[2];
if (uri === undefined) {
  console.error("usage: handshake.ts <pairing uri>");
  process.exit(1);
}
const u = new URL(uri.replace("zalos://pair", "http://x/"));
const host = u.searchParams.get("host")!;
const port = Number(u.searchParams.get("port"));
const pairingId = u.searchParams.get("id")!;
const secret = new Uint8Array(
  Buffer.from(u.searchParams.get("secret")!, "base64url"),
);
const keyParam = u.searchParams.get("key")!;
const serverKey = fromHex(
  keyParam.length === 64
    ? keyParam
    : Buffer.from(keyParam, "base64url").toString("hex"),
);

const kp = noiseKeypair();
const pc = await Client.connect({
  url: `ws://${host}:${port}/v1/pair/${pairingId}`,
  prologue: `zalos/1/pair/${pairingId}`,
  devicePrivate: kp.private,
  serverPublic: serverKey,
  psk: secret,
});
const paired = (await pc.request("pair.complete", {
  deviceName: "smoke-host",
  boxPublicKey: Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64"),
})) as { deviceId: string };
pc.close();
console.log(`HANDSHAKE OK device=${paired.deviceId}`);
process.exit(0);
