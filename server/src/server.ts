// Composition root: store + gateways + tunnel + method tables.
import { Store } from "./store/db.ts";
import { mkdirSync, rmSync } from "node:fs";
import { AccountManager } from "./accounts/manager.ts";
import { TunnelServer, type TunnelLimits } from "./tunnel/server.ts";
import { registerPairMethods } from "./methods/pair.ts";
import { registerControlMethods } from "./methods/control.ts";
import { registerAccountMethods } from "./methods/account.ts";
import type { GatewayFactory } from "./gateway/types.ts";
import { FakeGatewayFactory } from "./gateway/fake.ts";
import { createZaloFactory } from "./gateway/zca.ts";
import type { ChannelContext } from "./tunnel/server.ts";

export type ZalosServer = {
  store: Store;
  accounts: AccountManager;
  tunnel: TunnelServer;
  port: () => number;
  ready: Promise<void>;
  close(): Promise<void>;
};

export function createZalosServer(opts: {
  dataDir: string;
  fake: boolean;
  factory?: GatewayFactory;
  name?: string;
  // ZALOS_ZALO_MOCK_URL value, already gated to --dev/--local by the
  // caller; forwards every Zalo host to the offline mock gateway.
  mockUrl?: string;
  // Auto-delete sweeper interval; tests use a short value. 0 disables it.
  autoDeleteSweepMs?: number;
  // Per-message TTL sweeper interval; defaults to autoDeleteSweepMs.
  messageTtlSweepMs?: number;
  // Optional resource governance overrides (used in tests).
  limits?: TunnelLimits;
  // Explicitly gate fake/mock gateways at the composition root.
  allowDev?: boolean;
}): ZalosServer {
  const allowDev = opts.allowDev ?? opts.factory !== undefined;
  if (!allowDev && (opts.fake || opts.mockUrl !== undefined)) {
    throw new Error("fake/mock gateways are forbidden outside dev/local mode");
  }
  const store = new Store(opts.dataDir);
  let port = 0;
  const tunnel = new TunnelServer({
    store,
    name: opts.name,
    limits: opts.limits,
  });
  const factory =
    opts.factory ??
    (opts.fake
      ? new FakeGatewayFactory()
      : createZaloFactory({ mockUrl: opts.mockUrl }));
  rmSync(`${opts.dataDir}/tmp`, { recursive: true, force: true });
  mkdirSync(`${opts.dataDir}/tmp`, { recursive: true });
  const accounts = new AccountManager(store, factory, tunnel, {
    autoDeleteSweepMs: opts.autoDeleteSweepMs,
    messageTtlSweepMs: opts.messageTtlSweepMs,
  });
  tunnel.accounts = accounts;

  registerPairMethods(tunnel);
  registerAccountMethods(tunnel, { fake: opts.fake });
  registerControlMethods(tunnel, {
    loginQr: async (ctx: ChannelContext) => {
      const channel = ctx.channel;
      // Serialize outbound event sends: loginQr.image (blob) must be fully
      // flushed before scanned/done are sent.
      let chain: Promise<unknown> = Promise.resolve();
      const enqueue = (f: () => Promise<unknown> | void) => {
        chain = chain.then(f);
      };
      try {
        const res = await factory.loginQr({
          onQr: (png) => {
            enqueue(async () => {
              const stream = await channel.sendBlob(png);
              channel.sendEvent("loginQr.image", {
                stream,
                size: png.length,
                contentType: "image/png",
              });
            });
          },
          onScanned: (info) => {
            enqueue(() => channel.sendEvent("loginQr.scanned", info));
          },
        });
        if (res === null) {
          enqueue(() =>
            channel.sendEvent("loginQr.failed", { reason: "cancelled" }),
          );
          await chain;
          return;
        }
        const { slot } = await ctx.accounts.addAccount(res);
        enqueue(() => channel.sendEvent("loginQr.done", { slot }));
        await chain;
      } catch (e) {
        enqueue(() =>
          channel.sendEvent("loginQr.failed", { reason: String(e) }),
        );
        await chain;
      }
    },
  });

  // Start gateways for accounts already in the store; callers that need
  // deterministic startup (tests, `accounts` commands) await `ready`.
  const ready = accounts.restoreAccounts();
  const server: ZalosServer = {
    store,
    accounts,
    tunnel,
    port: () => port,
    ready,
    // Gateways own sockets, poll timers and retry timers; closing only
    // the tunnel leaked them and let dead sessions keep reconnecting.
    close: async () => {
      await accounts.close();
      await tunnel.close();
    },
  };

  const origListen = tunnel.listen.bind(tunnel);
  tunnel.listen = async (p: number, host: string) => {
    port = await origListen(p, host);
    return port;
  };
  return server;
}
