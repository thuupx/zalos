// zalos server CLI: serve | pair | devices | accounts
import { createZalosServer } from "./server.ts";
import { Store, fingerprint } from "./store/db.ts";
import { b64url } from "./tunnel/framer.ts";
import { encodePairingUri } from "./methods/control.ts";

import qrcode from "qrcode-terminal";
import { renderQrTerminal } from "./qr_terminal.ts";
import { createZaloFactory } from "./gateway/zca.ts";
import { OaGateway } from "./gateway/oa.ts";
import { mockGatewayFetch } from "./gateway/mock.ts";
import { clearAccountMedia } from "./media.ts";
import type { GatewaySelf, OaCredentials } from "./gateway/types.ts";
import { runDoctor, printChecks, tailscaleIPv4, defaultDeps } from "./doctor.ts";
import { mkdirSync, writeFileSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { createInterface } from "node:readline";
import { join } from "node:path";

// Everything the CLI writes (db, wal, tmp, media cache) is owner-only.
process.umask(0o077);

const DATA_DIR = process.env.ZALOS_DATA_DIR ?? "./data";

function argFlag(args: string[], name: string): boolean {
  return args.includes(`--${name}`);
}

function argValue(args: string[], name: string, fallback: string): string {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
}

async function main() {
  const [cmd, sub, ...rest] = process.argv.slice(2);
  const args = sub === undefined ? rest : [sub, ...rest];

  switch (cmd) {
    case "serve": {
      const dev = argFlag(args, "dev");
      const fake = argFlag(args, "fake");
      const local = argFlag(args, "local");
      const port = Number(argValue(args, "port", "7443"));
      let host: string;
      if (local) {
        // Local-container development mode: binds the wildcard address so
        // a host-published port can reach it. Only ever allowed inside the
        // hardened container with the explicit env opt-in.
        if (
          process.env.ZALOS_CONTAINER !== "1" ||
          process.env.ZALOS_ALLOW_LOCAL !== "1"
        ) {
          console.error(
            "--local requires ZALOS_CONTAINER=1 and ZALOS_ALLOW_LOCAL=1",
          );
          process.exit(1);
        }
        if (dev) {
          console.error("--local and --dev are mutually exclusive");
          process.exit(1);
        }
        host = "0.0.0.0";
        console.error(
          "warning: local mode has no network-level protection beyond the host's loopback port publish",
        );
        const checks = await runDoctor({ host, port, dataDir: DATA_DIR });
        const failed = printChecks(checks);
        if (failed) {
          console.error("doctor found critical failures; refusing to start");
          process.exit(1);
        }
      } else if (dev) {
        if (process.env.INVOCATION_ID !== undefined) {
          console.error(
            "refusing --dev under systemd (INVOCATION_ID is set); run without --dev",
          );
          process.exit(1);
        }
        host = argValue(args, "host", "127.0.0.1");
        // Dev mode is for local testing: loopback only.
        if (!/^127\.|^::1$|^localhost$/i.test(host)) {
          console.error("--dev accepts only loopback hosts (127.x, ::1, localhost)");
          process.exit(1);
        }
      } else {
        host =
          argValue(args, "host", "") ||
          (await tailscaleIPv4(defaultDeps())) ||
          "";
        if (host === "") {
          console.error(
            "could not resolve this node's Tailscale IPv4 address; pass --host",
          );
          process.exit(1);
        }
        const checks = await runDoctor({ host, port, dataDir: DATA_DIR });
        const failed = printChecks(checks);
        if (failed) {
          console.error("doctor found critical failures; refusing to start");
          process.exit(1);
        }
      }
      const mockUrl = process.env.ZALOS_ZALO_MOCK_URL;
      if (mockUrl !== undefined && !dev && !local) {
        console.error(
          "refusing ZALOS_ZALO_MOCK_URL without --dev or --local",
        );
        process.exit(1);
      }
      if (fake && !dev) {
        console.error("refusing --fake without --dev");
        process.exit(1);
      }
      const server = createZalosServer({
        dataDir: DATA_DIR,
        fake,
        mockUrl,
        allowDev: dev || local,
      });
      const bound = await server.tunnel.listen(port, host);
      server.store.setMeta("listen_addr", `${host}:${bound}`);
      const pub = Buffer.from(server.tunnel.serverKey.public).toString("hex");
      console.log(`zalos listening on ws://${host}:${bound}`);
      console.log(`fingerprint: ${fingerprint(pub)}`);
      if (fake) {
        console.log("running with the fake Zalo gateway");
        // Localhost-only hook guarded by a random per-run bearer token.
        const injectToken = Buffer.from(
          crypto.getRandomValues(new Uint8Array(32)),
        ).toString("hex");
        const tokenPath = join(DATA_DIR, "fake-inject.token");
        writeFileSync(tokenPath, injectToken, { mode: 0o600 });
        const admin = Bun.serve({
          port: 0,
          hostname: "127.0.0.1",
          fetch: async (req) => {
            const url = new URL(req.url);
            if (req.method !== "POST" || url.pathname !== "/inject") {
              return new Response("not found", { status: 404 });
            }
            const supplied = req.headers.get("x-zalos-inject-token") ?? "";
            if (supplied !== injectToken) {
              return new Response("unauthorized", { status: 401 });
            }
            const body = (await req.json()) as {
              slot?: string;
              threadId?: string;
              text?: string;
              event?: string;
              [k: string]: unknown;
            };
            if (body.slot === undefined || body.threadId === undefined) {
              return new Response("slot and threadId required", {
                status: 400,
              });
            }
            const gw = server.accounts.gateway(body.slot) as unknown as {
              injectIncoming?: (m: { threadId: string; text?: string }) => void;
              injectReceipt?: (t: unknown) => void;
              injectFriend?: (t: unknown) => void;
              injectGroup?: (t: unknown) => void;
            };
            if (body.event === "receipt" && typeof gw.injectReceipt === "function") {
              gw.injectReceipt(body);
              return new Response("ok");
            }
            if (body.event === "friend" && typeof gw.injectFriend === "function") {
              gw.injectFriend(body);
              return new Response("ok");
            }
            if (body.event === "group" && typeof gw.injectGroup === "function") {
              gw.injectGroup(body);
              return new Response("ok");
            }
            if (typeof gw.injectIncoming !== "function") {
              return new Response("not a fake gateway", { status: 400 });
            }
            gw.injectIncoming({ threadId: body.threadId, text: body.text });
            return new Response("ok");
          },
        });
        server.store.setMeta("fake_admin_addr", `127.0.0.1:${admin.port}`);
        console.log(`fake admin hook on 127.0.0.1:${admin.port}`);
      }
      await new Promise(() => {});
      break;
    }
    case "doctor": {
      const localMode =
        process.env.ZALOS_CONTAINER === "1" &&
        process.env.ZALOS_ALLOW_LOCAL === "1";
      const host =
        argValue(args, "host", "") ||
        (localMode ? "0.0.0.0" : (await tailscaleIPv4(defaultDeps()))) ||
        "";
      if (host === "") {
        console.error(
          "could not resolve this node's Tailscale IPv4 address; pass --host",
        );
        process.exit(1);
      }
      const port = Number(argValue(args, "port", "7443"));
      const checks = await runDoctor({ host, port, dataDir: DATA_DIR });
      let critical: boolean;
      if (argFlag(args, "json")) {
        console.log(JSON.stringify(checks, null, 2));
        critical = checks.some(
          (c) => c.severity === "critical" && c.status === "FAIL",
        );
      } else {
        critical = printChecks(checks);
      }
      if (critical) process.exit(1);
      break;
    }
    case "pair": {
      const store = new Store(DATA_DIR);
      const role =
        argValue(args, "role", "member") === "admin" ? "admin" : "member";
      const listenAddr = store.getMeta("listen_addr");
      if (listenAddr === null) {
        console.error(
          "the server has not recorded a listen address; run `zalos serve` first",
        );
        store.close();
        process.exit(1);
      }
      const pairing = store.createPairing(role);
      const kp = store.serverKeypair();
      const secret = Buffer.from(pairing.secret, "hex").toString("base64url");
      let [host, port] = listenAddr.split(":");
      if (host === "0.0.0.0" || host === "::") {
        // Local-container mode: the wildcard bind is unreachable from
        // clients; the pairing uri carries the address the host publishes.
        host = process.env.ZALOS_PUBLIC_HOST ?? "127.0.0.1";
        port = process.env.ZALOS_PUBLIC_PORT ?? port;
      }
      const uri = encodePairingUri({
        host,
        port: Number(port),
        id: pairing.id,
        secret,
        key: b64url(kp.public),
      });
      console.log(uri);
      qrcode.generate(uri, { small: true });
      store.close();
      break;
    }
    case "health": {
      // Container HEALTHCHECK: a bare TCP connect to the recorded listen
      // address proves the tunnel accepts connections.
      const store = new Store(DATA_DIR);
      const listenAddr = store.getMeta("listen_addr");
      store.close();
      if (listenAddr === null) process.exit(1);
      const [host, portStr] = listenAddr.split(":");
      const port = Number(portStr);
      if (!host || !Number.isInteger(port)) process.exit(1);
      const { connect } = await import("node:net");
      const ok = await new Promise<boolean>((resolve) => {
        const sock = connect({ host, port }, () => {
          sock.destroy();
          resolve(true);
        });
        sock.setTimeout(5000, () => {
          sock.destroy();
          resolve(false);
        });
        sock.on("error", () => resolve(false));
      });
      process.exit(ok ? 0 : 1);
    }
    case "vault": {
      if (args[0] !== "reset") {
        console.error("usage: vault reset --yes");
        process.exit(1);
      }
      const store = new Store(DATA_DIR);
      const accounts = store.listAccounts();
      const keyed = accounts.filter((a) => a.vault_public_key !== null);
      const msgCount = store.db
        .query(`SELECT COUNT(*) AS n FROM messages WHERE body_json LIKE '%"sealed"%'`)
        .get() as { n: number };
      console.log("vault reset will:");
      console.log(`  - clear the vault claim flag`);
      console.log(`  - remove vault keys from ${keyed.length} account(s)`);
      console.log(`  - delete sealed content in ${msgCount.n} message record(s) plus related event log entries`);
      console.log("  - delete sealed media cache files and pending vault requests/grants");
      console.log("all sealed history becomes permanently unreadable");
      if (!argFlag(args, "yes")) {
        console.error("refusing without --yes");
        store.close();
        process.exit(1);
      }
      store.vaultReset();
      // Sealed media cache files: drop the .bin/.meta pairs marked sealed.
      const cacheRoot = join(DATA_DIR, "media-cache");
      let removed = 0;
      for (const slotDir of store.listAccounts().map((a) => a.slot)) {
        const dir = join(cacheRoot, slotDir);
        let names: string[] = [];
        try {
          names = readdirSync(dir);
        } catch {
          continue;
        }
        for (const name of names) {
          if (!name.endsWith(".meta")) continue;
          const metaPath = join(dir, name);
          const meta = JSON.parse(readFileSync(metaPath, "utf-8")) as {
            sealed?: boolean;
          };
          if (meta.sealed !== true) continue;
          rmSync(join(dir, name.replace(/\.meta$/, ".bin")), { force: true });
          rmSync(metaPath, { force: true });
          removed++;
        }
      }
      console.log(`removed ${removed} sealed media cache file(s)`);
      store.close();
      console.log("vault reset complete; the next device to call vault.claim starts a new vault");
      break;
    }
    case "fake": {
      const store = new Store(DATA_DIR);
      const addr = store.getMeta("fake_admin_addr");
      if (addr === null) {
        console.error(
          "no fake admin hook recorded; start the server with --fake first",
        );
        store.close();
        process.exit(1);
      }
      store.close();
      let payload: Record<string, unknown>;
      if (args[0] === "incoming" && args.length >= 4) {
        payload = { slot: args[1], threadId: args[2], text: args[3] };
      } else if (args[0] === "emit" && args.length >= 3) {
        payload = JSON.parse(args[2]) as Record<string, unknown>;
        payload.slot = args[1];
      } else {
        console.error(
          "usage: fake incoming <slot> <threadId> <text> | fake emit <slot> <json>",
        );
        process.exit(1);
      }
      const injectToken = (() => {
        try {
          return readFileSync(join(DATA_DIR, "fake-inject.token"), "utf-8").trim();
        } catch {
          return "";
        }
      })();
      const res = await fetch(`http://${addr}/inject`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-zalos-inject-token": injectToken,
        },
        body: JSON.stringify(payload),
      });
      if (!res.ok) {
        console.error(`inject failed: ${res.status} ${await res.text()}`);
        process.exit(1);
      }
      break;
    }
    case "devices": {
      const store = new Store(DATA_DIR);
      if (args[0] === "list") {
        for (const d of store.listDevices(args.includes("--all"))) {
          const revoked = d.revoked_at !== null ? " (revoked)" : "";
          console.log(`${d.id}  ${d.role}  ${d.name}${revoked}`);
        }
      } else if (args[0] === "audit-acl") {
        const accounts = store.listAccounts().map((a) => a.slot);
        let flagged = 0;
        for (const d of store.listDevices(false)) {
          if (d.role !== "member") continue;
          const acl = store.deviceAcl(d.id);
          const allSlots = accounts.length > 0 && acl.length >= accounts.length;
          if (acl.length > 0) {
            flagged++;
            const note = allSlots ? " [ALL ACCOUNTS]" : "";
            console.log(
              `${d.id}  member  ${d.name}  slots=[${acl.join(",")}]${note}`,
            );
          }
        }
        if (flagged === 0) {
          console.log("no member devices hold account ACL grants");
        }
      } else if (args[0] === "revoke" && args[1] !== undefined) {
        const target = store.deviceById(args[1]);
        if (target === null || target.revoked_at !== null) {
          console.error(`unknown device ${args[1]}`);
          store.close();
          process.exit(1);
        }
        if (
          target.role === "admin" &&
          store.adminCount() <= 1 &&
          !argFlag(args, "force")
        ) {
          console.error(
            "refusing to revoke the last admin device; pass --force to override",
          );
          store.close();
          process.exit(1);
        }
        store.revokeDevice(args[1]);
        console.log(`revoked ${args[1]}`);
      } else {
        console.error("usage: devices list [--all] | revoke [--force] <id>");
        process.exit(1);
      }
      store.close();
      break;
    }
    case "accounts": {
      const store = new Store(DATA_DIR);
      if (args[0] === "list" || args[0] === undefined) {
        for (const a of store.listAccounts()) {
          console.log(`${a.slot}  ${a.status}  ${a.display_name}`);
        }
      } else if (args[0] === "add") {
        // The seam applies here only inside an opted-in local container
        // (the mock deployment); plain `accounts add` ignores it.
        const factory = createZaloFactory({
          mockUrl:
            process.env.ZALOS_ALLOW_LOCAL === "1"
              ? process.env.ZALOS_ZALO_MOCK_URL
              : undefined,
        });
        const qrPath = join(DATA_DIR, "tmp", "login-qr.png");
        mkdirSync(join(DATA_DIR, "tmp"), { recursive: true });
        const res = await factory.loginQr({
          onQr: (png) => {
            writeFileSync(qrPath, png);
            console.log(
              `--- login QR refreshed at ${new Date().toISOString()} ---`,
            );
            try {
              process.stdout.write(renderQrTerminal(png));
            } catch (e) {
              console.error(`qr render failed: ${(e as Error).message}`);
            }
            console.log(`scan this QR with the Zalo app; png: ${qrPath}`);
            if (process.env.ZALOS_CONTAINER === "1") {
              console.log(
                `copy it out with: docker compose cp zalos:${qrPath} ./login-qr.png`,
              );
            }
          },
          onScanned: (info) => {
            console.log(`scanned by ${info.displayName}; confirm on the phone`);
          },
        });
        if (res === null) {
          console.error("login declined");
          process.exit(1);
        }
        // Same rule as AccountManager.addAccount: a Zalo account that
        // already has a slot gets that slot's session renewed, never a
        // second slot (two listeners for one account displace each other).
        const known =
          res.self.uid === ""
            ? undefined
            : store
                .listAccounts()
                .find((a) => a.kind !== "oa" && a.zalo_uid === res.self.uid);
        if (known !== undefined) {
          store.updateAccountCredentials(
            known.slot,
            JSON.stringify(res.credentials),
          );
          store.updateAccountIdentity(
            known.slot,
            res.self.uid,
            res.self.displayName,
            res.self.avatarUrl,
          );
          console.log(`renewed account ${known.slot} (${res.self.displayName})`);
        } else {
          const account = store.createAccount({
            zaloUid: res.self.uid,
            displayName: res.self.displayName,
            avatarUrl: res.self.avatarUrl,
            credentialsJson: JSON.stringify(res.credentials),
          });
          console.log(`added account ${account.slot} (${res.self.displayName})`);
        }
        console.log("restart the server so it picks up the credentials");
      } else if (args[0] === "add-oa") {
        // Official Account credentials come from env vars or interactive
        // prompts - never argv (they would land in shell history).
        const ask = async (envName: string, label: string): Promise<string> => {
          const env = process.env[envName];
          if (env !== undefined && env !== "") return env;
          const rl = createInterface({ input: process.stdin, output: process.stderr });
          const value = await new Promise<string>((resolve) =>
            rl.question(`${label}: `, resolve),
          );
          rl.close();
          return value.trim();
        };
        const creds: OaCredentials = {
          appId: await ask("ZALOS_OA_APP_ID", "OA app id"),
          appSecret: await ask("ZALOS_OA_APP_SECRET", "OA app secret"),
          accessToken: await ask("ZALOS_OA_ACCESS_TOKEN", "OA access token"),
          refreshToken: await ask("ZALOS_OA_REFRESH_TOKEN", "OA refresh token"),
        };
        if (Object.values(creds).some((v) => v === "")) {
          console.error("all four OA credential values are required");
          store.close();
          process.exit(1);
        }
        const mockFetch =
          process.env.ZALOS_ALLOW_LOCAL === "1" &&
          process.env.ZALOS_ZALO_MOCK_URL !== undefined
            ? mockGatewayFetch(process.env.ZALOS_ZALO_MOCK_URL)
            : undefined;
        const self: GatewaySelf = { uid: "", displayName: "", avatarUrl: "" };
        const gw = new OaGateway(
          creds,
          self,
          { onCredentials: () => {}, clientConnected: () => false },
          mockFetch,
        );
        await gw.start();
        await gw.stop();
        if (self.uid === "" || gw.status === "needs_login") {
          console.error("OA credentials rejected by Zalo");
          store.close();
          process.exit(1);
        }
        const account = store.createAccount({
          kind: "oa",
          zaloUid: self.uid,
          displayName: self.displayName,
          avatarUrl: self.avatarUrl,
          // Validation may have rotated the single-use refresh token;
          // storing the input pair would strand the account.
          credentialsJson: JSON.stringify(gw.oaCredentials()),
        });
        console.log(`added OA account ${account.slot} (${self.displayName})`);
        console.log("restart the server so it picks up the credentials");
      } else if (args[0] === "remove" && args[1] !== undefined) {
        if (store.accountBySlot(args[1]) === null) {
          console.error(`unknown account ${args[1]}`);
          store.close();
          process.exit(1);
        }
        await clearAccountMedia(DATA_DIR, args[1], { retire: true });
        store.removeAccount(args[1]);
        console.log(`removed ${args[1]}`);
      } else {
        console.error("usage: accounts list | add | add-oa | remove <slot>");
        process.exit(1);
      }
      store.close();
      break;
    }
    default:
      console.error("usage: zalos <serve|pair|doctor|health|devices|accounts|fake|vault> ...");
      process.exit(1);
  }
}

await main();
