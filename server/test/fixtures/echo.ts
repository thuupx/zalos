// Fixture for client/test/noise_echo_test.dart: the same late-set_psk echo
// responder the spike used, kept alive after server/spike was removed.
import { WebSocketServer, type WebSocket } from "ws";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const noise = require("../../vendor/zalos-noise/zalos_noise.js");

const PROLOGUE = new TextEncoder().encode("zalos/1/control");
const SERVER_PRIVATE =
  "66e311da9859f28fb41c85f08d949c975077cddf844cbc4460567c30514ed497";
const DEVICE_PUBLIC =
  "0d164b6e38d7848959106600ec3d677fd7584cb33917ebc08c628dbe108b5f26";
const DEVICE_PSK =
  "51d5139a58c5069b6221e7300c9c4e2d48857fe1f97e39418564732a8bd905b2";
const DEVICE_TABLE: Record<string, string> = { [DEVICE_PUBLIC]: DEVICE_PSK };

const fromHex = (hex: string) => new Uint8Array(Buffer.from(hex, "hex"));
const toHex = (b: Uint8Array) => Buffer.from(b).toString("hex");

export function startEchoServer(port: number, host = "127.0.0.1") {
  const wss = new WebSocketServer({ host, port, path: "/v1/control" });
  wss.on("connection", (ws: WebSocket) => {
    const responder = noise.Session.responder(PROLOGUE, fromHex(SERVER_PRIVATE));
    ws.on("message", (data: Buffer) => {
      try {
        if (!responder.is_handshake_finished()) {
          responder.read_handshake(new Uint8Array(data));
          if (!responder.is_handshake_finished()) {
            const psk = DEVICE_TABLE[toHex(responder.remote_static())];
            if (psk === undefined) {
              ws.close(4001, "unknown device");
              return;
            }
            responder.set_psk(fromHex(psk));
            ws.send(Buffer.from(responder.write_handshake(new Uint8Array(0))));
          }
          return;
        }
        const plain = responder.decrypt(new Uint8Array(data));
        ws.send(Buffer.from(responder.encrypt(plain)));
      } catch (err) {
        ws.close(4002, String(err));
      }
    });
  });
  return wss;
}

if (process.argv[1] && import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.argv[2] ?? 8787);
  const wss = startEchoServer(port);
  wss.on("listening", () => console.log(`listening ${port}`));
}
