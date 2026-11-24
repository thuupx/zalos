// Regression tests for the security review: SSRF guard, revocation/ACL
// enforcement, close codes, rpc table pollution, cliId idempotency,
// message delete/recall scrubbing and sync validation.
import { test, expect, beforeAll, afterAll, describe } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { assertPublicUrl } from "../src/media.ts";
import { Store } from "../src/store/db.ts";
import { makeEnv, pairDevice, pairDeviceWith, controlClient, accountClient, loginQrAccount, type TestEnv, type PairedDevice } from "./support/helpers.ts";
import { Client, noiseKeypair, fromHex } from "./support/client.ts";
import { RpcError } from "../src/tunnel/rpc.ts";

describe("ssrf guard", () => {
  const blocked = [
    "http://127.0.0.1:1/a",
    "http://localhost:1/",
    "http://[::1]:1/",
    "http://[::ffff:127.0.0.1]:1/",
    "http://[::ffff:7f00:1]:1/",
    "http://[0:0:0:0:0:ffff:7f00:1]:1/",
    "http://[::127.0.0.1]:1/",
    "http://2130706433:1/",
    "http://0x7f.1:1/",
    "http://0177.0.0.1:1/",
    "http://127.1:1/",
    "http://0:1/",
    "http://0.0.0.0:1/",
    "http://[::]:1/",
    "http://10.0.0.1/",
    "http://100.64.0.1/",
    "http://192.168.1.1/",
    "http://172.16.0.1/",
    "http://169.254.169.254/latest/meta-data/",
    "http://[::ffff:169.254.169.254]/latest/meta-data/",
    "http://[::ffff:a9fe:a9fe]/",
    "http://[::ffff:6440:1]/",
    "http://[::ffff:c0a8:101]/",
    "http://[fe80::1]/",
    "http://[febf::1]/",
    "http://[fec0::1]/",
    "http://[fd00::1]/",
    "http://[64:ff9b::7f00:1]/",
    "http://[2002:7f00:1::1]/",
    "http://192.0.0.8/",
    "http://198.18.0.1/",
    "file:///etc/passwd",
    "ftp://example.com/x",
    "data:text/plain,hi",
    "gopher://127.0.0.1/",
    "http://user:pass@127.0.0.1:1/cred",
    "http://user:pass@example.com/",
    "not a url",
    "",
  ];
  for (const url of blocked) {
    test(`blocks ${url || "(empty)"}`, async () => {
      await expect(assertPublicUrl(url)).rejects.toThrow();
    });
  }
  const allowed = [
    "http://8.8.8.8/",
    "https://1.1.1.1/x",
    "http://[2606:4700:4700::1111]/",
    "http://[2002:808:808::]/", // 6to4 to a public v4
    "http://[64:ff9b::808:808]/", // NAT64 to a public v4
    "http://[::ffff:8.8.8.8]/",
  ];
  for (const url of allowed) {
    test(`allows ${url}`, async () => {
      await assertPublicUrl(url);
    });
  }
});

describe("revocation, acl and protocol", () => {
  let env: TestEnv;
  let admin: PairedDevice;
  let control: Client;
  let slot: string;
  beforeAll(async () => {
    env = await makeEnv();
    admin = await pairDevice(env, { name: "admin", role: "admin" });
    control = await controlClient(env, admin);
    slot = await loginQrAccount(env, control);
  });
  afterAll(() => env.cleanup());

  test("unknown slot closes pre-auth with 4001, not 4004", async () => {
    const c = await Client.connect({
      url: `ws://127.0.0.1:${env.port}/v1/account/deadbeef`,
      prologue: "zalos/1/account/deadbeef",
      devicePrivate: admin.keypair.private,
      serverPublic: fromHex(env.serverPubHex),
      psk: admin.psk,
    }).then(() => "handshake ok").catch((e: Error) => e.message);
    expect(String(c)).toContain("4001");
  });

  test("revoke closes a pending channel that never sent a request", async () => {
    const victim = await pairDevice(env, { name: "victim" });
    // Handshake only: registered nowhere yet, must still be closed.
    const pending = await Client.connect({
      url: `ws://127.0.0.1:${env.port}/v1/control`,
      prologue: "zalos/1/control",
      devicePrivate: victim.keypair.private,
      serverPublic: fromHex(env.serverPubHex),
      psk: victim.psk,
    });
    await control.request("devices.revoke", { deviceId: victim.deviceId });
    const code = await pending.closed;
    expect(code).toBe(4001);
  });

  test("revoke wipes key material and re-pairing the key is a fresh device", async () => {
    const victim = await pairDevice(env, { name: "gone" });
    await control.request("devices.revoke", { deviceId: victim.deviceId });
    const row = env.server.store.deviceById(victim.deviceId)!;
    expect(row.psk).toBe("");
    expect(row.public_key.startsWith("revoked:")).toBe(true);
    const pubHex = Buffer.from(victim.keypair.public).toString("hex");
    expect(env.server.store.deviceByPublicKey(pubHex)).toBeNull();
    // Re-pairing a revoked member key creates a fresh device with no implicit
    // account access.
    const pairing = env.server.store.createPairing("member");
    const re = await pairDeviceWith(
      env,
      pairing.id,
      fromHex(pairing.secret),
      { name: "fresh" },
      victim.keypair,
    );
    expect(re.deviceId).not.toBe(victim.deviceId);
    expect(env.server.store.deviceAcl(re.deviceId)).toEqual([]);
  });

  test("acl loss on a pending account channel closes it", async () => {
    const member = await pairDevice(env, { name: "limbo" });
    env.server.store.setAcl(member.deviceId, [slot]);
    const pending = await Client.connect({
      url: `ws://127.0.0.1:${env.port}/v1/account/${slot}`,
      prologue: `zalos/1/account/${slot}`,
      devicePrivate: member.keypair.private,
      serverPublic: fromHex(env.serverPubHex),
      psk: member.psk,
    });
    await control.request("devices.setAcl", {
      deviceId: member.deviceId,
      slots: [],
    });
    const code = await pending.closed;
    expect(code).toBe(4001);
  });

  test("cli-side revoke takes effect on live channels within the sweep", async () => {
    const victim = await pairDevice(env, { name: "cli-victim" });
    const ctl = await controlClient(env, victim);
    env.server.store.revokeDevice(victim.deviceId);
    const code = await Promise.race([
      ctl.closed,
      new Promise<number>((r) => setTimeout(() => r(-1), 8000)),
    ]);
    expect(code).toBe(4001);
  }, 15000);

  test("live request is rejected once the device is revoked in the db", async () => {
    const victim = await pairDevice(env, { name: "db-only" });
    const ctl = await controlClient(env, victim);
    env.server.store.db
      .query("UPDATE devices SET revoked_at = ? WHERE id = ?")
      .run(Date.now(), victim.deviceId);
    void ctl.request("manifest.get").catch(() => {});
    const code = await Promise.race([
      ctl.closed,
      new Promise<number>((r) => setTimeout(() => r(-1), 7000)),
    ]);
    expect(code).toBe(4001);
  }, 12000);

  test("protocol-shaped methods resolve to unknown_method", async () => {
    for (const m of ["toString", "constructor", "__proto__", "hasOwnProperty"]) {
      const code = await control.request(m, {}).then(
        () => "ok",
        (e: Error & { code?: string }) => e.code,
      );
      expect(code).toBe("unknown_method");
    }
  });

  test("sync validates sinceSeq and resets beyond latest", async () => {
    const a = await accountClient(env, admin, slot);
    for (const bad of ["abc", 1.5]) {
      const code = await a.request("sync", { sinceSeq: bad }).then(
        () => "ok",
        (e: Error & { code?: string }) => e.code,
      );
      expect(code).toBe("bad_request");
    }
    const res = (await a.request("sync", { sinceSeq: Number.MAX_SAFE_INTEGER })) as {
      reset: boolean;
    };
    expect(res.reset).toBe(true);
    a.close();
  });

  test("framing error after auth closes 4002", async () => {
    const c = await Client.connect({
      url: `ws://127.0.0.1:${env.port}/v1/control`,
      prologue: "zalos/1/control",
      devicePrivate: admin.keypair.private,
      serverPublic: fromHex(env.serverPubHex),
      psk: admin.psk,
    });
    // Trigger authentication, then send a short frame.
    await c.request("manifest.get");
    const { encodeFrame } = await import("../src/tunnel/framer.ts");
    for (const f of [c.session.encrypt(new Uint8Array(3)), c.session.encrypt(encodeFrame(9, 1, 5, new Uint8Array(4)))]) {
      c.ws.send(Buffer.from(f));
    }
    const code = await c.closed;
    expect(code).toBe(4002);
  });

  test("a ninth open inbound stream closes 4002", async () => {
    const c = await Client.connect({
      url: `ws://127.0.0.1:${env.port}/v1/control`,
      prologue: "zalos/1/control",
      devicePrivate: admin.keypair.private,
      serverPublic: fromHex(env.serverPubHex),
      psk: admin.psk,
    });
    await c.request("manifest.get");
    const { encodeFrame } = await import("../src/tunnel/framer.ts");
    for (let i = 0; i < 9; i++) {
      c.ws.send(Buffer.from(c.session.encrypt(encodeFrame(1, 0, 1000 + i, new Uint8Array(10)))));
    }
    const code = await c.closed;
    expect(code).toBe(4002);
  });
});

describe("messages", () => {
  let env: TestEnv;
  let admin: PairedDevice;
  let control: Client;
  let slot: string;
  beforeAll(async () => {
    env = await makeEnv();
    admin = await pairDevice(env, { name: "admin", role: "admin" });
    control = await controlClient(env, admin);
    slot = await loginQrAccount(env, control);
  });
  afterAll(() => env.cleanup());

  test("sendText with a stored cliId does not call the gateway again", async () => {
    const a = await accountClient(env, admin, slot);
    const first = (await a.request("messages.sendText", {
      threadId: "friend-1", threadType: "user", cliId: "dup-1", text: "one",
    })) as { msgId: string };
    const gw = env.factory.gateways.at(-1)!;
    const calls = gw.calls.filter((c) => c.method === "sendText").length;
    const second = (await a.request("messages.sendText", {
      threadId: "friend-1", threadType: "user", cliId: "dup-1", text: "one",
    })) as { msgId: string };
    expect(second.msgId).toBe(first.msgId);
    expect(gw.calls.filter((c) => c.method === "sendText").length).toBe(calls);
    await expect(
      a.request("messages.sendText", {
        threadId: "friend-1", threadType: "user", cliId: "dup-1", text: "two",
      }),
    ).rejects.toMatchObject({ code: "conflict" });
    a.close();
  });

  test("messages.delete removes the row, scrubs the event log, 404s on unknown", async () => {
    const a = await accountClient(env, admin, slot);
    const sent = (await a.request("messages.sendText", {
      threadId: "friend-1", threadType: "user", cliId: "del-1", text: "gone",
    })) as { msgId: string };
    await a.request("messages.delete", {
      msgId: sent.msgId, threadId: "friend-1", threadType: "user",
    });
    const list = (await a.request("messages.list", {
      threadId: "friend-1", threadType: "user",
    })) as { messages: { id: string }[] };
    expect(list.messages.some((m) => m.id === sent.msgId)).toBe(false);
    // The deleted message's content is gone from earlier event entries too.
    const evts = env.server.store
      .eventsSince(slot, 0)
      .map((e) => e.data_json)
      .join();
    expect(evts.includes('"gone"')).toBe(false);
    const code = await a.request("messages.delete", {
      msgId: "gm-nope", threadId: "friend-1", threadType: "user",
    }).then(() => "ok", (e: Error & { code?: string }) => e.code);
    expect(code).toBe("not_found");
    a.close();
  });

  test("event seq numbers never go backwards after pruning", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zalos-seq-"));
    try {
      const store = new Store(dir);
      const a1 = store.appendEvent("s1", "message.new", {});
      const a2 = store.appendEvent("s1", "message.new", {});
      expect(a2.seq).toBe(a1.seq + 1);
      // Hard-prune the whole log, as a restart-facing test or an operator
      // would: new events must continue from the last issued seq, not
      // restart at 1, or clients holding the old cursor drop them.
      store.db.run("DELETE FROM events");
      const b = store.appendEvent("s1", "message.new", {});
      expect(b.seq).toBe(a2.seq + 1);
      // Reopen the store (server restart): the counter survives.
      store.close();
      const store2 = new Store(dir);
      const c = store2.appendEvent("s1", "message.new", {});
      expect(c.seq).toBe(b.seq + 1);
      store2.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("recall scrubs earlier event entries of the message", async () => {
    const a = await accountClient(env, admin, slot);
    const gw = env.factory.gateways.at(-1)!;
    const evt = a.waitEvent("message.new");
    const m = gw.injectIncoming({ threadId: "friend-1", text: "recall-me" });
    await evt;
    const upd = a.waitEvent("message.updated");
    gw.recall(m.id, "friend-1", "user");
    await upd;
    const hits = env.server.store
      .eventsSince(slot, 0)
      .filter((e) => e.data_json.includes("recall-me"));
    expect(hits.length).toBe(0);
    a.close();
  });

  test("unterminated blob upload is cleaned when the channel closes", async () => {
    const c = await Client.connect({
      url: `ws://127.0.0.1:${env.port}/v1/control`,
      prologue: "zalos/1/control",
      devicePrivate: admin.keypair.private,
      serverPublic: fromHex(env.serverPubHex),
      psk: admin.psk,
    });
    await c.request("manifest.get");
    const { encodeFrame } = await import("../src/tunnel/framer.ts");
    c.ws.send(Buffer.from(c.session.encrypt(encodeFrame(2, 0, 777, new Uint8Array(5000)))));
    await new Promise((r) => setTimeout(r, 300));
    const dir = join(env.dir, "tmp");
    const during = existsSync(dir) ? require("node:fs").readdirSync(dir).length : 0;
    c.close();
    await new Promise((r) => setTimeout(r, 400));
    const after = existsSync(dir) ? require("node:fs").readdirSync(dir).length : 0;
    expect(during).toBeGreaterThanOrEqual(1);
    expect(after).toBe(0);
  });
});

describe("file modes", () => {
  test("cli serve leaves wal/shm and tmp owner-only", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zalos-umask-"));
    const childEnv: Record<string, string | undefined> = {
      ...process.env,
      ZALOS_DATA_DIR: dir,
    };
    // GitHub Actions / systemd-launched runners export INVOCATION_ID, which
    // cli.ts treats as a production systemd unit and rejects --dev.
    delete childEnv.INVOCATION_ID;
    const proc = Bun.spawn(
      ["bun", "src/cli.ts", "serve", "--dev", "--fake", "--port", "0"],
      {
        cwd: `${process.cwd()}`,
        env: childEnv,
        stdout: "pipe",
        stderr: "pipe",
      },
    );
    const reader = proc.stdout.getReader();
    let out = "";
    const deadline = Date.now() + 15000;
    try {
      while (!out.includes("zalos listening") && Date.now() < deadline) {
        const { value } = await Promise.race([
          reader.read(),
          new Promise<{ value?: Uint8Array }>((_, rej) =>
            setTimeout(() => rej(new Error("read timeout")), 15000),
          ),
        ]);
        if (!value) break;
        out += new TextDecoder().decode(value);
      }
      expect(out).toContain("zalos listening");
      for (const name of ["zalos.db", "zalos.db-wal", "zalos.db-shm"]) {
        const p = join(dir, name);
        if (existsSync(p)) {
          expect(statSync(p).mode & 0o777).toBe(0o600);
        }
      }
      if (existsSync(join(dir, "tmp"))) {
        expect(statSync(join(dir, "tmp")).mode & 0o777).toBe(0o700);
      }
    } finally {
      reader.releaseLock();
      proc.kill();
      await proc.exited;
      rmSync(dir, { recursive: true, force: true });
    }
  }, 20000);
});
