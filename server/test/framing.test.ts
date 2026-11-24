import { test, expect, beforeAll, afterAll } from "bun:test";
import {
  makeEnv,
  pairDevice,
  controlClient,
  type TestEnv,
  type PairedDevice,
} from "./support/helpers.ts";
import { encodeFrame, TYPE_JSON, TYPE_BLOB } from "../src/tunnel/framer.ts";

let env: TestEnv;
let admin: PairedDevice;
beforeAll(async () => {
  env = await makeEnv();
  admin = await pairDevice(env, { name: "framer" });
});
afterAll(() => env.cleanup());

test("JSON message over 1 MiB is rejected", async () => {
  const c = await controlClient(env, admin);
  const huge = new Uint8Array(1024 * 1024 + 10);
  for (let off = 0; off < huge.length; off += 60000) {
    const chunk = huge.subarray(off, off + 60000);
    const fin = off + 60000 >= huge.length ? 1 : 0;
    c.ws.send(
      Buffer.from(
        c.session.encrypt(encodeFrame(TYPE_JSON, fin, 901, chunk)),
      ),
    );
  }
  const code = await c.closed;
  // Oversized post-auth protocol error.
  expect(code).toBe(4002);
});

test("media.fetch SSRF guard rejects private hosts (non-fake)", async () => {
  const env2 = await makeEnv({ fake: false });
  try {
    const admin2 = await pairDevice(env2, { name: "ssrf" });
    const c = await controlClient(env2, admin2);
    // create an account directly so an account channel exists
    const { slot } = await env2.server.accounts.addAccount({
      credentials: { imei: "x", cookie: {}, userAgent: "x" },
      self: { uid: "u", displayName: "n", avatarUrl: "" },
    });
    const a = await (await import("./support/helpers.ts")).accountClient(
      env2,
      admin2,
      slot,
    );
    const err = await a
      .request("media.fetch", { url: "http://127.0.0.1:1/x" })
      .then(() => null, (e: Error & { code?: string }) => e);
    expect(err!.code).toBe("forbidden");
    a.close();
    c.close();
  } finally {
    await env2.cleanup();
  }
});
