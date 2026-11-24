import { RpcError } from "../tunnel/rpc.ts";
import { b64 } from "../tunnel/framer.ts";
import { auditEvent } from "../security/audit.ts";
import type { ChannelContext } from "../tunnel/server.ts";
import type { TunnelServer } from "../tunnel/server.ts";

export function registerPairMethods(server: TunnelServer) {
  server.registerMethods("pair", {
    "pair.complete": async (
      ctx: ChannelContext,
      params: Record<string, unknown>,
    ) => {
      const kind = ctx.channel.kind;
      if (kind.kind !== "pair") throw new RpcError("error", "wrong channel");
      const pairing = ctx.store.pairingById(kind.pairingId);
      if (
        pairing === null ||
        pairing.used_at !== null ||
        pairing.expires_at < Date.now()
      ) {
        throw new RpcError("unauthorized", "pairing invalid");
      }
      const remote = ctx.channel.session.remote_static();
      if (remote === null) throw new RpcError("error", "no remote static");
      if (typeof params.boxPublicKey !== "string") {
        throw new RpcError("bad_request", "boxPublicKey required");
      }
      const boxKey = Buffer.from(params.boxPublicKey, "base64");
      if (boxKey.length !== 32) {
        throw new RpcError("bad_request", "boxPublicKey must be 32 bytes");
      }
      const devicePsk = crypto.getRandomValues(new Uint8Array(32));
      const device = ctx.store.completePairing({
        pairingId: pairing.id,
        role: pairing.role,
        publicKey: Buffer.from(remote).toString("hex"),
        psk: Buffer.from(devicePsk).toString("hex"),
        name: String(params.deviceName ?? "device"),
        boxPublicKey: params.boxPublicKey,
      });
      if (device === null) {
        throw new RpcError("unauthorized", "pairing invalid");
      }
      ctx.channel.deviceId = device.id;
      ctx.server.notifyManifestChanged();
      auditEvent({
        event: "pair.complete",
        outcome: "ok",
        deviceId: device.id,
        role: device.role,
        method: "pair.complete",
      });
      const result = {
        deviceId: device.id,
        psk: b64(devicePsk),
        role: device.role,
        server: {
          name: ctx.server.name,
          version: ctx.server.version,
          fingerprint: ctx.server.fingerprint(),
        },
      };
      // Let the response flush before tearing the socket down.
      setTimeout(() => ctx.channel.close(1000), 100).unref?.();
      return result;
    },
  });
}
