import { RpcError } from "../tunnel/rpc.ts";
import { fingerprint } from "../vault.ts";
import { b64, b64url } from "../tunnel/framer.ts";
import { auditEvent } from "../security/audit.ts";
import type { ChannelContext, TunnelServer } from "../tunnel/server.ts";

function deviceOf(ctx: ChannelContext) {
  const device = ctx.store.deviceById(ctx.channel.deviceId ?? "");
  if (device === null) throw new RpcError("unauthorized", "no device");
  return device;
}

function requireAdmin(ctx: ChannelContext) {
  if (deviceOf(ctx).role !== "admin") {
    throw new RpcError("forbidden", "admin only");
  }
}

export function encodePairingUri(params: {
  host: string;
  port: number;
  id: string;
  secret: string;
  key: string;
  vault?: string;
}): string {
  const payload = Buffer.from(JSON.stringify(params), "utf8").toString(
    "base64url",
  );
  return `zalos://pair?d=${payload}`;
}

export function pairingUri(
  server: TunnelServer,
  pairing: { id: string; secret: string },
  host: string,
  port: number,
): string {
  const pub = b64url(server.serverKey.public);
  const secret = Buffer.from(pairing.secret, "hex").toString("base64url");
  return encodePairingUri({ host, port, id: pairing.id, secret, key: pub });
}

export function registerControlMethods(
  server: TunnelServer,
  opts: { loginQr: (ctx: ChannelContext) => Promise<void> },
) {
  server.registerMethods("control", {
    "manifest.get": async (ctx: ChannelContext) => {
      const device = deviceOf(ctx);
      const slots = new Set(ctx.store.deviceAcl(device.id));
      const accounts = ctx.store
        .listAccounts()
        .filter((a) => slots.has(a.slot))
        .map((a) => {
          let capabilities: string[] = [];
          try {
            capabilities = ctx.accounts.gateway(a.slot).capabilities();
          } catch {
            // Gateway not running; an empty set hides nothing critical.
          }
          return {
            slot: a.slot,
            uid: a.zalo_uid,
            kind: a.kind,
            capabilities,
            displayName: a.display_name,
            avatarUrl: a.avatar_url,
            status: a.status,
            unread: ctx.store.unreadForSlot(a.slot),
            vaultKey: a.vault_public_key,
            vaultKeyVersion: a.vault_key_version ?? 1,
          };
        });
      return {
        server: {
          name: ctx.server.name,
          version: ctx.server.version,
          fingerprint: ctx.server.fingerprint(),
        },
        device: { id: device.id, name: device.name, role: device.role },
        accounts,
      };
    },

    "devices.list": async (ctx: ChannelContext) => {
      requireAdmin(ctx);
      return {
        devices: ctx.store.listDevices().map((d) => ({
          id: d.id,
          name: d.name,
          publicKey: d.public_key,
          boxPublicKey: d.box_public_key === "" ? null : d.box_public_key,
          boxFingerprint:
            d.box_public_key === ""
              ? null
              : fingerprint(Buffer.from(d.box_public_key, "base64")),
          role: d.role,
          createdAt: d.created_at,
          lastSeenAt: d.last_seen_at,
          slots: ctx.store.deviceAcl(d.id),
        })),
      };
    },

    "devices.revoke": async (ctx: ChannelContext, params) => {
      requireAdmin(ctx);
      const deviceId = String(params.deviceId ?? "");
      if (ctx.store.deviceById(deviceId) === null) {
        throw new RpcError("not_found", deviceId);
      }
      ctx.store.revokeDevice(deviceId);
      for (const ch of ctx.server.connectionsForDevice(deviceId)) {
        ch.close(4001);
      }
      ctx.server.notifyManifestChanged();
      auditEvent({
        event: "device.revoke",
        outcome: "ok",
        deviceId: ctx.channel.deviceId,
        method: "devices.revoke",
        reason: deviceId,
      });
      return { ok: true };
    },

    "devices.setAcl": async (ctx: ChannelContext, params) => {
      requireAdmin(ctx);
      const deviceId = String(params.deviceId ?? "");
      if (ctx.store.deviceById(deviceId) === null) {
        throw new RpcError("not_found", deviceId);
      }
      if (
        params.slots !== undefined &&
        (!Array.isArray(params.slots) ||
          params.slots.some((v) => typeof v !== "string"))
      ) {
        throw new RpcError("bad_request", "slots must be a string array");
      }
      const slots = (params.slots as string[] | undefined) ?? [];
      for (const slot of slots) {
        if (ctx.store.accountBySlot(slot) === null) {
          throw new RpcError("not_found", `slot ${slot}`);
        }
      }
      const before = new Set(ctx.store.deviceAcl(deviceId));
      ctx.store.setAcl(deviceId, slots);
      // Drop live account channels for slots this device just lost.
      for (const lost of before) {
        if (!slots.includes(lost)) {
          for (const ch of ctx.server.accountChannels(lost, deviceId)) {
            ch.close(4001);
          }
        }
      }
      ctx.server.notifyManifestChanged();
      auditEvent({
        event: "acl.update",
        outcome: "ok",
        deviceId: ctx.channel.deviceId,
        method: "devices.setAcl",
        reason: `${deviceId}:${slots.join(",")}`,
      });
      return { ok: true };
    },

    "pairing.create": async (ctx: ChannelContext, params) => {
      requireAdmin(ctx);
      const role = params.role === "admin" ? "admin" : "member";
      const pairing = ctx.store.createPairing(role);
      let host = ctx.server.listenHost ?? "127.0.0.1";
      let port = ctx.server.boundPort;
      if (host === "0.0.0.0" || host === "::") {
        host = process.env.ZALOS_PUBLIC_HOST || "127.0.0.1";
        const pubPort = Number(process.env.ZALOS_PUBLIC_PORT);
        if (Number.isInteger(pubPort) && pubPort > 0) port = pubPort;
      }
      return {
        pairingId: pairing.id,
        secret: b64(Buffer.from(pairing.secret, "hex")),
        expiresAt: pairing.expires_at,
        uri: pairingUri(ctx.server, pairing, host, port),
      };
    },

    "vault.setKey": async (ctx: ChannelContext, params) => {
      requireAdmin(ctx);
      const slot = String(params.slot ?? "");
      const account = ctx.store.accountBySlot(slot);
      if (account === null) throw new RpcError("not_found", slot);
      if (typeof params.publicKey !== "string") {
        throw new RpcError("bad_request", "publicKey required");
      }
      const pk = Buffer.from(params.publicKey, "base64");
      if (pk.length !== 32) {
        throw new RpcError("bad_request", "publicKey must be 32 bytes");
      }
      await ctx.accounts.setVaultKey(
        slot,
        params.publicKey,
        new Uint8Array(pk),
      );
      ctx.server.notifyManifestChanged();
      auditEvent({
        event: "vault.setKey",
        outcome: "ok",
        deviceId: ctx.channel.deviceId,
        slot,
        method: "vault.setKey",
      });
      return { ok: true, fingerprint: fingerprint(pk) };
    },

    "vault.rotate": async (ctx: ChannelContext, params) => {
      requireAdmin(ctx);
      const slot = String(params.slot ?? "");
      const expectedVersion = Number(params.expectedVersion);
      if (!Number.isInteger(expectedVersion) || expectedVersion < 1) {
        throw new RpcError("bad_request", "expectedVersion must be >= 1");
      }
      if (typeof params.publicKey !== "string") {
        throw new RpcError("bad_request", "publicKey required");
      }
      const pk = Buffer.from(params.publicKey, "base64");
      if (pk.length !== 32) {
        throw new RpcError("bad_request", "publicKey must be 32 bytes");
      }
      const version = await ctx.accounts.rotateVaultKey(
        slot,
        expectedVersion,
        params.publicKey,
      );
      ctx.server.notifyManifestChanged();
      auditEvent({
        event: "vault.rotate",
        outcome: "ok",
        deviceId: ctx.channel.deviceId,
        slot,
        method: "vault.rotate",
        reason: `kv=${version}`,
      });
      return { ok: true, version, fingerprint: fingerprint(pk) };
    },

    "vault.request": async (ctx: ChannelContext) => {
      const device = deviceOf(ctx);
      ctx.store.setVaultRequest(device.id);
      ctx.server.broadcastToAdmins("vault.requested", {
        deviceId: device.id,
        name: device.name,
        boxPublicKey: device.box_public_key,
        fingerprint: fingerprint(Buffer.from(device.box_public_key, "base64")),
      });
      return { ok: true };
    },

    "vault.requests.list": async (ctx: ChannelContext) => {
      requireAdmin(ctx);
      return {
        requests: ctx.store.vaultRequesters().map((d) => ({
          deviceId: d.id,
          name: d.name,
          boxPublicKey: d.box_public_key,
          fingerprint: fingerprint(
            Buffer.from(d.box_public_key, "base64"),
          ),
          requestedAt: d.vault_requested_at,
        })),
      };
    },

    "vault.grant": async (ctx: ChannelContext, params) => {
      requireAdmin(ctx);
      const deviceId = String(params.deviceId ?? "");
      const wrapped = String(params.wrapped ?? "");
      const target = ctx.store.deviceById(deviceId);
      if (target === null || target.revoked_at !== null) {
        throw new RpcError("not_found", deviceId);
      }
      ctx.store.grantVault(deviceId, wrapped);
      for (const ch of ctx.server.controlChannels(deviceId)) {
        ch.sendEvent("vault.granted", {});
      }
      auditEvent({
        event: "vault.grant",
        outcome: "ok",
        deviceId: ctx.channel.deviceId,
        method: "vault.grant",
        reason: deviceId,
      });
      return { ok: true };
    },

    "vault.claim": async (ctx: ChannelContext) => {
      requireAdmin(ctx);
      const claimed = ctx.store.claimVault();
      auditEvent({
        event: "vault.claim",
        outcome: claimed ? "ok" : "denied",
        deviceId: ctx.channel.deviceId,
        method: "vault.claim",
      });
      return { claimed };
    },

    "vault.reject": async (ctx: ChannelContext, params) => {
      requireAdmin(ctx);
      const deviceId = String(params.deviceId ?? "");
      const target = ctx.store.deviceById(deviceId);
      if (target === null || target.revoked_at !== null) {
        throw new RpcError("not_found", deviceId);
      }
      ctx.store.rejectVault(deviceId);
      for (const ch of ctx.server.controlChannels(deviceId)) {
        ch.sendEvent("vault.rejected", {});
      }
      return { ok: true };
    },

    "vault.fetch": async (ctx: ChannelContext) => {
      const device = deviceOf(ctx);
      const wrapped = ctx.store.vaultWrapped(device.id);
      if (wrapped !== null) ctx.store.clearVaultWrapped(device.id);
      return { wrapped };
    },

    "accounts.loginQr.start": async (ctx: ChannelContext) => {
      requireAdmin(ctx);
      await opts.loginQr(ctx);
      return { ok: true };
    },

    // Adds an Official Account from console credentials. The secret and
    // tokens are stored server-side only and never returned.
    "accounts.addOa": async (ctx: ChannelContext, params) => {
      requireAdmin(ctx);
      for (const k of ["appId", "appSecret", "accessToken", "refreshToken"]) {
        if (typeof params[k] !== "string" || params[k] === "") {
          throw new RpcError("bad_request", `${k} is required`);
        }
      }
      const { slot } = await ctx.accounts.addOaAccount({
        appId: params.appId as string,
        appSecret: params.appSecret as string,
        accessToken: params.accessToken as string,
        refreshToken: params.refreshToken as string,
      });
      return { slot };
    },

    "accounts.updateOaTokens": async (ctx: ChannelContext, params) => {
      requireAdmin(ctx);
      const slot = String(params.slot ?? "");
      if (
        typeof params.accessToken !== "string" ||
        params.accessToken === "" ||
        typeof params.refreshToken !== "string" ||
        params.refreshToken === ""
      ) {
        throw new RpcError(
          "bad_request",
          "accessToken and refreshToken are required",
        );
      }
      await ctx.accounts.updateOaTokens(
        slot,
        params.accessToken,
        params.refreshToken,
      );
      return { ok: true };
    },

    "accounts.logout": async (ctx: ChannelContext, params) => {
      requireAdmin(ctx);
      const slot = String(params.slot ?? "");
      await ctx.accounts.logoutAccount(slot);
      auditEvent({
        event: "account.logout",
        outcome: "ok",
        deviceId: ctx.channel.deviceId,
        slot,
        method: "accounts.logout",
      });
      return { ok: true };
    },

    "accounts.remove": async (ctx: ChannelContext, params) => {
      requireAdmin(ctx);
      const slot = String(params.slot ?? "");
      if (ctx.store.accountBySlot(slot) === null) {
        throw new RpcError("not_found", slot);
      }
      await ctx.accounts.removeAccount(slot);
      for (const ch of ctx.server.accountChannels(slot)) {
        ch.close(4004);
      }
      return { ok: true };
    },
  });
}
