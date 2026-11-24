// WebSocket tunnel: route dispatch, Noise responder flow, frame plumbing.
import { WebSocketServer, type WebSocket } from "ws";
import { createRequire } from "node:module";
import { createServer, type Server } from "node:http";
import { join } from "node:path";
import { unlinkSync } from "node:fs";
import {
  Assembler,
  encodeFrame,
  encodeMessage,
  FLAG_FIN,
  FRAME_CHUNK,
  TYPE_BLOB,
  TYPE_JSON,
} from "./framer.ts";
import { fromHex, fingerprint } from "../store/db.ts";
import { RpcError, decode, encode, type JsonRequest } from "./rpc.ts";
import { assertDiskHeadroom } from "../media.ts";
import { auditEvent, logSafeError } from "../security/audit.ts";
import type { Store } from "../store/db.ts";
import type { AccountManager } from "../accounts/manager.ts";

const require = createRequire(import.meta.url);
const noise = require("../../vendor/zalos-noise/zalos_noise.js");

export const CLOSE_AUTH = 4001;
export const CLOSE_PROTOCOL = 4002;
export const CLOSE_NOT_FOUND = 4004;
export const CLOSE_TRY_AGAIN = 1013;

const UPLOAD_TIMEOUT_MS = 60_000;
// ws backpressure: above this, the peer is stalled and we drop it; it
// resyncs on reconnect.
const MAX_BUFFERED = 8 * 1024 * 1024;

export type TunnelLimits = {
  maxConnections?: number;
  maxConnectionsPerDevice?: number;
  maxInflightRpcsPerChannel?: number;
  maxInflightRpcsPerDevice?: number;
  maxUnclaimedUploadsPerChannel?: number;
  maxUploadBytesPerDevice?: number;
  uploadTimeoutMs?: number;
  rateLimitMedia?: { burst: number; refillPerSec: number };
  rateLimitSend?: { burst: number; refillPerSec: number };
};

const DEFAULT_LIMITS: Required<TunnelLimits> = {
  maxConnections: 128,
  maxConnectionsPerDevice: 16,
  maxInflightRpcsPerChannel: 32,
  maxInflightRpcsPerDevice: 64,
  maxUnclaimedUploadsPerChannel: 8,
  maxUploadBytesPerDevice: 250 * 1024 * 1024,
  uploadTimeoutMs: UPLOAD_TIMEOUT_MS,
  rateLimitMedia: { burst: 160, refillPerSec: 60 },
  rateLimitSend: { burst: 60, refillPerSec: 20 },
};

class TokenBucket {
  private tokens: number;
  private lastMs: number;
  constructor(
    private readonly burst: number,
    private readonly refillPerSec: number,
  ) {
    this.tokens = burst;
    this.lastMs = Date.now();
  }
  take(cost = 1): boolean {
    const now = Date.now();
    const elapsed = Math.max(0, (now - this.lastMs) / 1000);
    this.lastMs = now;
    this.tokens = Math.min(this.burst, this.tokens + elapsed * this.refillPerSec);
    if (this.tokens < cost) return false;
    this.tokens -= cost;
    return true;
  }
}

export type ChannelKind =
  | { kind: "pair"; pairingId: string }
  | { kind: "control" }
  | { kind: "account"; slot: string };

export type ChannelContext = {
  channel: Channel;
  store: Store;
  accounts: AccountManager;
  server: TunnelServer;
};

type MethodTable = Record<
  string,
  (ctx: ChannelContext, params: Record<string, unknown>) => Promise<unknown> | unknown
>;

export class Channel {
  readonly ws: WebSocket;
  readonly session: typeof noise.Session.prototype;
  readonly kind: ChannelKind;
  readonly server: TunnelServer;
  deviceId: string | null = null;
  authenticated = false;
  authTimer: Timer | null = null;
  private assembler: Assembler;
  private outStream = 1;
  uploads = new Map<number, { filePath: string; size: number; timer: Timer }>();
  private uploadWaiters = new Map<
    number,
    { resolve: (u: { filePath: string; size: number }) => void; timer: Timer }
  >();
  inflightRpcs = 0;
  closed = false;
  onJson: ((msg: JsonRequest) => void) | null = null;
  onDispose: (() => void) | null = null;

  constructor(
    ws: WebSocket,
    session: typeof noise.Session.prototype,
    kind: ChannelKind,
    server: TunnelServer,
  ) {
    this.ws = ws;
    this.session = session;
    this.kind = kind;
    this.server = server;
    const uploadDir =
      process.env.ZALOS_UPLOAD_TMP_DIR && process.env.ZALOS_UPLOAD_TMP_DIR !== ""
        ? process.env.ZALOS_UPLOAD_TMP_DIR
        : join(server.store.dir, "tmp");
    this.assembler = new Assembler(uploadDir);
  }

  sendRaw(noiseMsg: Uint8Array) {
    if (this.closed) return;
    if (this.ws.bufferedAmount > MAX_BUFFERED) {
      this.close(CLOSE_TRY_AGAIN);
      return;
    }
    this.ws.send(Buffer.from(noiseMsg));
  }

  sendPlain(frames: Iterable<Uint8Array>) {
    for (const f of frames) {
      this.sendRaw(this.session.encrypt(f));
    }
  }

  sendJson(obj: object) {
    const stream = this.outStream++;
    this.sendPlain(encodeMessage(TYPE_JSON, stream, encode(obj)));
  }

  sendEvent(event: string, data?: unknown, seq?: number) {
    const obj: Record<string, unknown> = { event };
    if (seq !== undefined) obj.seq = seq;
    if (data !== undefined) obj.data = data;
    this.sendJson(obj);
  }

  async sendBlob(data: Uint8Array | { filePath: string }): Promise<number> {
    const stream = this.outStream++;
    if (typeof data === "object" && "filePath" in data) {
      // Stream the file in chunks and respect ws backpressure. FIN goes on
      // the last chunk, which is only known once the reader reports done.
      const reader = Bun.file(data.filePath).stream().getReader();
      const sendChunk = async (chunk: Uint8Array, fin: boolean) => {
        while (this.ws.bufferedAmount > 4 * 1024 * 1024) {
          if (this.closed) return;
          await Bun.sleep(5);
        }
        this.sendRaw(
          this.session.encrypt(
            encodeFrame(TYPE_BLOB, fin ? FLAG_FIN : 0, stream, chunk),
          ),
        );
      };
      let prev: Uint8Array | null = null;
      let done = false;
      while (!done) {
        const r = await reader.read();
        done = r.done;
        if (prev !== null) {
          for (let off = 0; off < prev.length; off += FRAME_CHUNK) {
            const isLast = done && off + FRAME_CHUNK >= prev.length;
            await sendChunk(prev.subarray(off, off + FRAME_CHUNK), isLast);
          }
        }
        if (!done && r.value !== undefined) prev = r.value;
      }
      if (prev === null) {
        await sendChunk(new Uint8Array(0), true); // empty file
      }
      reader.releaseLock();
      return stream;
    }
    const bytes = data as Uint8Array;
    this.sendPlain(encodeMessage(TYPE_BLOB, stream, bytes));
    return stream;
  }

  close(code = 1000) {
    if (this.closed) return;
    this.closed = true;
    if (this.authTimer !== null) clearTimeout(this.authTimer);
    try {
      this.ws.close(code);
    } catch {}
    this.server.unregister(this);
    this.dispose();
  }

  // Free upload temp files, half-finished inbound blob files and buffers.
  dispose() {
    for (const u of this.uploads.values()) {
      clearTimeout(u.timer);
      this.server.releaseUploadBytes(this.deviceId, u.size);
      try {
        unlinkSync(u.filePath);
      } catch {}
    }
    this.uploads.clear();
    for (const w of this.uploadWaiters.values()) clearTimeout(w.timer);
    this.uploadWaiters.clear();
    this.assembler.dispose();
    this.onDispose?.();
  }

  fail(code: number) {
    this.close(code);
  }

  feedTransport(frame: Uint8Array) {
    if (!this.authenticated) {
      this.authenticated = true;
      if (this.authTimer !== null) {
        clearTimeout(this.authTimer);
        this.authTimer = null;
      }
      this.server.register(this);
      auditEvent({
        event: "auth.ok",
        outcome: "ok",
        deviceId: this.deviceId,
        slot: this.kind.kind === "account" ? this.kind.slot : null,
        method: this.kind.kind,
      });
    }
    if (frame.length >= 6 && frame[0] === TYPE_BLOB) {
      const uploadDir =
        process.env.ZALOS_UPLOAD_TMP_DIR && process.env.ZALOS_UPLOAD_TMP_DIR !== ""
          ? process.env.ZALOS_UPLOAD_TMP_DIR
          : join(this.server.store.dir, "tmp");
      assertDiskHeadroom(uploadDir);
    }
    const msg = this.assembler.feed(frame);
    if (msg === null) return;
    if (msg.type === TYPE_JSON) {
      const parsed = decode(msg.data) as JsonRequest;
      this.onJson?.(parsed);
    } else {
      this.completeUpload(msg.stream, {
        filePath: msg.filePath,
        size: msg.size,
      });
    }
  }

  private completeUpload(
    stream: number,
    u: { filePath: string; size: number },
  ) {
    if (!this.server.reserveUploadBytes(this.deviceId, u.size)) {
      this.server.discardUpload(u);
      this.close(CLOSE_TRY_AGAIN);
      return;
    }
    const waiter = this.uploadWaiters.get(stream);
    if (waiter !== undefined) {
      this.uploadWaiters.delete(stream);
      clearTimeout(waiter.timer);
      this.server.releaseUploadBytes(this.deviceId, u.size);
      waiter.resolve(u);
      return;
    }
    // Bound completed unclaimed uploads per channel and delete evicted files.
    while (this.uploads.size >= this.server.limits.maxUnclaimedUploadsPerChannel) {
      const oldestKey = this.uploads.keys().next().value;
      if (oldestKey === undefined) break;
      const oldest = this.uploads.get(oldestKey)!;
      this.uploads.delete(oldestKey);
      clearTimeout(oldest.timer);
      this.server.releaseUploadBytes(this.deviceId, oldest.size);
      this.server.discardUpload(oldest);
    }
    // Drop stale uploads and unlink their staging file on expiry.
    const timer = setTimeout(() => {
      const stale = this.uploads.get(stream);
      if (stale === undefined) return;
      this.uploads.delete(stream);
      this.server.releaseUploadBytes(this.deviceId, stale.size);
      this.server.discardUpload(stale);
    }, this.server.limits.uploadTimeoutMs);
    timer.unref?.();
    this.uploads.set(stream, { ...u, timer });
  }

  takeUpload(stream: number): Promise<{ filePath: string; size: number }> {
    const existing = this.uploads.get(stream);
    if (existing !== undefined) {
      this.uploads.delete(stream);
      clearTimeout(existing.timer);
      this.server.releaseUploadBytes(this.deviceId, existing.size);
      return Promise.resolve({ filePath: existing.filePath, size: existing.size });
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.uploadWaiters.delete(stream);
        reject(new RpcError("timeout", "upload stream did not finish"));
      }, this.server.limits.uploadTimeoutMs);
      timer.unref?.();
      this.uploadWaiters.set(stream, { resolve, timer });
    });
  }
}

export type RouteResult =
  | { ok: true; kind: ChannelKind }
  | { ok: false; closeCode: number };

export function routePath(pathname: string): RouteResult {
  if (pathname === "/v1/control") return { ok: true, kind: { kind: "control" } };
  const pair = /^\/v1\/pair\/([0-9a-f]+)$/.exec(pathname);
  if (pair) {
    return { ok: true, kind: { kind: "pair", pairingId: pair[1] } };
  }
  const acct = /^\/v1\/account\/([0-9a-zA-Z_-]+)$/.exec(pathname);
  if (acct) {
    return { ok: true, kind: { kind: "account", slot: acct[1] } };
  }
  return { ok: false, closeCode: CLOSE_NOT_FOUND };
}

export class TunnelServer {
  readonly store: Store;
  accounts!: AccountManager;
  readonly serverKey: { public: Uint8Array; private: Uint8Array };
  readonly name: string;
  readonly version: string;
  readonly limits: Required<TunnelLimits>;
  private wss: WebSocketServer;
  private http: Server;
  private methods: Record<"pair" | "control" | "account", Map<string, MethodTable[string]>> = {
    pair: new Map(),
    control: new Map(),
    account: new Map(),
  };
  private deviceConns = new Map<string, Set<Channel>>();
  private controlConns = new Set<Channel>();
  private accountConns = new Map<string, Set<Channel>>();
  // Handshaken but not yet authenticated by a transport message, plus
  // sockets that have not sent handshake message 1 yet.
  private pendingConns = new Set<Channel>();
  private deviceInflightRpcs = new Map<string, number>();
  private deviceUploadBytes = new Map<string, number>();
  private rateBuckets = new Map<string, TokenBucket>();
  private sweepTimer: Timer | null = null;
  private manifestTimer: Timer | null = null;
  private manifestListeners = new Set<() => void>();

  constructor(opts: {
    store: Store;
    name?: string;
    version?: string;
    limits?: TunnelLimits;
  }) {
    this.store = opts.store;
    this.name = opts.name ?? "zalos";
    this.version = opts.version ?? "0.1.0";
    this.limits = { ...DEFAULT_LIMITS, ...(opts.limits ?? {}) };
    this.serverKey = this.store.serverKeypair();
    this.http = createServer();
    this.wss = new WebSocketServer({ noServer: true, maxPayload: 70000 });
    this.http.on("upgrade", (req, socket, head) => {
      const url = new URL(req.url ?? "/", "http://localhost");
      const routed = routePath(url.pathname);
      if (!routed.ok) {
        socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
        socket.destroy();
        return;
      }
      this.wss.handleUpgrade(req, socket, head, (ws: WebSocket) => {
        this.accept(ws, routed.kind);
      });
    });
    this.wss.on("error", () => {});
    // Plain HTTP requests get a bare 404 instead of hanging.
    this.http.on("request", (_req, res) => {
      res.writeHead(404);
      res.end();
    });
  }

  onManifestChanged(cb: () => void) {
    this.manifestListeners.add(cb);
  }

  fingerprint(): string {
    return fingerprint(Buffer.from(this.serverKey.public).toString("hex"));
  }

  registerMethods(kind: "pair" | "control" | "account", table: MethodTable) {
    for (const [name, fn] of Object.entries(table)) {
      this.methods[kind].set(name, fn);
    }
  }

  listenHost: string | null = null;
  boundPort = 0;

  listen(port: number, host: string): Promise<number> {
    return new Promise((resolve, reject) => {
      this.http.once("error", reject);
      this.http.listen(port, host, () => {
        this.listenHost = host;
        this.boundPort = (this.http.address() as { port: number }).port;
        // Periodic re-check of live channels against the db so CLI-side
        // revocations and ACL edits take effect within a few seconds.
        this.sweepTimer = setInterval(() => this.sweep(), 5_000);
        this.sweepTimer.unref?.();
        resolve(this.boundPort);
      });
    });
  }

  // All control channels belonging to non-revoked admin devices.
  broadcastToAdmins(event: string, data?: unknown) {
    for (const ch of this.controlConns) {
      const d = ch.deviceId === null ? null : this.store.deviceById(ch.deviceId);
      if (d !== null && d.role === "admin" && d.revoked_at === null) {
        ch.sendEvent(event, data);
      }
    }
  }

  // Control channels of one specific device.
  controlChannels(deviceId: string): Channel[] {
    return [...this.controlConns].filter((ch) => ch.deviceId === deviceId);
  }

  private sweep() {
    for (const ch of this.allChannels()) {
      if (!this.stillAllowed(ch)) ch.close(CLOSE_AUTH);
    }
  }

  // Re-check a channel's device against the db: not revoked, and for
  // account channels still holding the slot ACL.
  private stillAllowed(channel: Channel): boolean {
    if (channel.kind.kind === "pair") return true;
    if (channel.deviceId === null) return true;
    const device = this.store.deviceById(channel.deviceId);
    if (device === null || device.revoked_at !== null) return false;
    if (channel.kind.kind === "account") {
      return this.store.hasAcl(device.id, channel.kind.slot);
    }
    return true;
  }

  async close() {
    if (this.sweepTimer !== null) clearInterval(this.sweepTimer);
    for (const ws of this.wss.clients) ws.terminate();
    await new Promise<void>((r) => this.wss.close(() => r()));
    this.http.close();
  }

  private allChannels(): Channel[] {
    const out = new Set<Channel>(this.pendingConns);
    for (const set of this.deviceConns.values()) for (const c of set) out.add(c);
    for (const c of this.controlConns) out.add(c);
    for (const set of this.accountConns.values()) for (const c of set) out.add(c);
    return [...out];
  }

  connectionsForDevice(deviceId: string): Channel[] {
    return this.allChannels().filter((c) => c.deviceId === deviceId);
  }

  accountChannels(slot: string, deviceId?: string): Channel[] {
    const conns = this.allChannels().filter(
      (c) => c.kind.kind === "account" && c.kind.slot === slot,
    );
    return deviceId === undefined
      ? conns
      : conns.filter((c) => c.deviceId === deviceId);
  }

  register(channel: Channel) {
    this.pendingConns.delete(channel);
    if (channel.deviceId !== null) {
      const set = this.deviceConns.get(channel.deviceId) ?? new Set();
      set.add(channel);
      this.deviceConns.set(channel.deviceId, set);
      this.store.touchDevice(channel.deviceId);
    }
    if (channel.kind.kind === "control") this.controlConns.add(channel);
    if (channel.kind.kind === "account") {
      const slot = channel.kind.slot;
      const set = this.accountConns.get(slot) ?? new Set();
      set.add(channel);
      this.accountConns.set(slot, set);
    }
  }

  unregister(channel: Channel) {
    this.pendingConns.delete(channel);
    if (channel.deviceId !== null) {
      this.deviceConns.get(channel.deviceId)?.delete(channel);
    }
    this.controlConns.delete(channel);
    if (channel.kind.kind === "account") {
      this.accountConns.get(channel.kind.slot)?.delete(channel);
    }
  }

  broadcastAccount(slot: string, event: string, data?: unknown, seq?: number) {
    for (const ch of this.accountConns.get(slot) ?? []) {
      ch.sendEvent(event, data, seq);
    }
  }

  notifyManifestChanged() {
    for (const cb of this.manifestListeners) cb();
    if (this.manifestTimer !== null) return;
    this.manifestTimer = setTimeout(() => {
      this.manifestTimer = null;
      for (const ch of this.controlConns) {
        ch.sendEvent("manifest.changed");
      }
    }, 500);
    this.manifestTimer.unref?.();
  }

  reserveUploadBytes(deviceId: string | null, bytes: number): boolean {
    const key = deviceId ?? "__anon__";
    const cur = this.deviceUploadBytes.get(key) ?? 0;
    if (cur + bytes > this.limits.maxUploadBytesPerDevice) return false;
    this.deviceUploadBytes.set(key, cur + bytes);
    return true;
  }

  releaseUploadBytes(deviceId: string | null, bytes: number) {
    const key = deviceId ?? "__anon__";
    const next = Math.max(0, (this.deviceUploadBytes.get(key) ?? 0) - bytes);
    if (next === 0) this.deviceUploadBytes.delete(key);
    else this.deviceUploadBytes.set(key, next);
  }

  private checkRateLimit(deviceId: string | null, method: string): boolean {
    const key = deviceId ?? "__anon__";
    let bucketKey: string | null = null;
    let cfg: { burst: number; refillPerSec: number } | null = null;
    if (method === "media.fetch" || method.startsWith("stickers.")) {
      bucketKey = `${key}:media`;
      cfg = this.limits.rateLimitMedia;
    } else if (method.startsWith("messages.send") || method === "messages.forward") {
      bucketKey = `${key}:send`;
      cfg = this.limits.rateLimitSend;
    }
    if (bucketKey === null || cfg === null) return true;
    let b = this.rateBuckets.get(bucketKey);
    if (b === undefined) {
      b = new TokenBucket(cfg.burst, cfg.refillPerSec);
      this.rateBuckets.set(bucketKey, b);
    }
    return b.take(1);
  }

  private accept(ws: WebSocket, kind: ChannelKind) {
    if (this.allChannels().length >= this.limits.maxConnections) {
      ws.close(CLOSE_TRY_AGAIN);
      return;
    }
    const prologue = new TextEncoder().encode(this.prologueFor(kind));
    const session = noise.Session.responder(prologue, this.serverKey.private);
    const channel = new Channel(ws, session, kind, this);
    this.pendingConns.add(channel);

    channel.onJson = (msg) => this.dispatch(channel, msg);

    // Early route-level rejection: known-shape but unknown target. Pre-auth
    // always closes 4001 so the code reveals nothing about existence.
    if (kind.kind === "pair" && this.store.pairingById(kind.pairingId) === null) {
      ws.close(CLOSE_AUTH);
      this.pendingConns.delete(channel);
      return;
    }
    if (
      kind.kind === "account" &&
      this.store.accountBySlot(kind.slot) === null
    ) {
      ws.close(CLOSE_AUTH);
      this.pendingConns.delete(channel);
      return;
    }

    // Idle sockets that never send handshake message 1 are dropped.
    const handshakeTimer = setTimeout(() => {
      if (!session.is_handshake_finished()) ws.close(CLOSE_AUTH);
    }, 10_000);
    handshakeTimer.unref?.();

    ws.on("message", (data: Buffer | Uint8Array, isBinary: boolean) => {
      const preAuth = !channel.authenticated;
      try {
        if (!isBinary) {
          channel.fail(preAuth ? CLOSE_AUTH : CLOSE_PROTOCOL);
          return;
        }
        const bytes = new Uint8Array(data as Uint8Array);
        if (!session.is_handshake_finished()) {
          session.read_handshake(bytes);
          clearTimeout(handshakeTimer);
          const psk = this.resolvePsk(channel);
          if (psk === null) {
            auditEvent({
              event: "auth.fail",
              outcome: "denied",
              deviceId: channel.deviceId,
              slot: kind.kind === "account" ? kind.slot : null,
              method: kind.kind,
              reason: "psk_or_acl_rejected",
            });
            channel.fail(CLOSE_AUTH);
            return;
          }
          session.set_psk(psk);
          channel.sendRaw(session.write_handshake(new Uint8Array(0)));
          // The peer has not proven it knows the psk yet (message 1 is
          // replayable); only a successful transport decrypt authenticates.
          channel.authTimer = setTimeout(() => {
            if (!channel.authenticated) channel.fail(CLOSE_AUTH);
          }, 10_000);
          channel.authTimer.unref?.();
          return;
        }
        channel.feedTransport(session.decrypt(bytes));
      } catch {
        channel.fail(preAuth ? CLOSE_AUTH : CLOSE_PROTOCOL);
      }
    });
    ws.on("close", () => {
      clearTimeout(handshakeTimer);
      this.unregister(channel);
      channel.dispose();
    });
    ws.on("error", () => {
      clearTimeout(handshakeTimer);
      this.unregister(channel);
      channel.dispose();
    });
  }

  private prologueFor(kind: ChannelKind): string {
    switch (kind.kind) {
      case "pair":
        return `zalos/1/pair/${kind.pairingId}`;
      case "control":
        return "zalos/1/control";
      case "account":
        return `zalos/1/account/${kind.slot}`;
    }
  }

  private resolvePsk(channel: Channel): Uint8Array | null {
    const remote = channel.session.remote_static();
    if (remote === null) return null;
    const remoteHex = Buffer.from(remote).toString("hex");
    const kind = channel.kind;
    switch (kind.kind) {
      case "pair": {
        const pairing = this.store.pairingById(kind.pairingId);
        if (
          pairing === null ||
          pairing.used_at !== null ||
          pairing.expires_at < Date.now()
        ) {
          return null;
        }
        return fromHex(pairing.secret);
      }
      case "control":
      case "account": {
        const device = this.store.deviceByPublicKey(remoteHex);
        if (device === null || device.revoked_at !== null) return null;
        if (
          kind.kind === "account" &&
          !this.store.hasAcl(device.id, kind.slot)
        ) {
          return null;
        }
        const existingForDevice = this.connectionsForDevice(device.id).length;
        if (existingForDevice >= this.limits.maxConnectionsPerDevice) {
          channel.fail(CLOSE_TRY_AGAIN);
          return null;
        }
        channel.deviceId = device.id;
        return fromHex(device.psk);
      }
    }
  }

  private async dispatch(channel: Channel, msg: JsonRequest) {
    if (
      msg === null ||
      typeof msg !== "object" ||
      typeof msg.id !== "number" ||
      typeof msg.method !== "string"
    ) {
      return;
    }
    // Every request re-validates the device (revocation may have landed via
    // CLI or another admin since the handshake).
    if (!this.stillAllowed(channel)) {
      channel.close(CLOSE_AUTH);
      return;
    }
    const handler = this.methods[channel.kind.kind].get(msg.method);
    if (handler === undefined) {
      channel.sendJson({
        id: msg.id,
        error: { code: "unknown_method", message: msg.method },
      });
      return;
    }
    if (!this.checkRateLimit(channel.deviceId, msg.method)) {
      channel.sendJson({
        id: msg.id,
        error: { code: "rate_limited", message: "too many requests" },
      });
      return;
    }
    const devKey = channel.deviceId ?? "__anon__";
    const devInflight = this.deviceInflightRpcs.get(devKey) ?? 0;
    if (
      channel.inflightRpcs >= this.limits.maxInflightRpcsPerChannel ||
      devInflight >= this.limits.maxInflightRpcsPerDevice
    ) {
      channel.sendJson({
        id: msg.id,
        error: { code: "rate_limited", message: "too many concurrent requests" },
      });
      return;
    }
    const params =
      msg.params !== null && typeof msg.params === "object" && !Array.isArray(msg.params)
        ? (msg.params as Record<string, unknown>)
        : {};
    channel.inflightRpcs++;
    this.deviceInflightRpcs.set(devKey, devInflight + 1);
    try {
      const result = await handler(
        { channel, store: this.store, accounts: this.accounts, server: this },
        params,
      );
      channel.sendJson({ id: msg.id, result: result ?? null });
    } catch (e) {
      const err =
        e instanceof RpcError
          ? { code: e.code, message: e.message }
          : { code: "internal", message: "internal error" };
      if (e instanceof RpcError && e.code === "forbidden") {
        auditEvent({
          event: "authz.denied",
          outcome: "denied",
          deviceId: channel.deviceId,
          slot: channel.kind.kind === "account" ? channel.kind.slot : null,
          method: msg.method,
          reason: e.message,
        });
      } else if (!(e instanceof RpcError)) {
        logSafeError("rpc", e, {
          method: msg.method,
          deviceId: channel.deviceId,
        });
      }
      channel.sendJson({ id: msg.id, error: err });
    } finally {
      channel.inflightRpcs = Math.max(0, channel.inflightRpcs - 1);
      const cur = (this.deviceInflightRpcs.get(devKey) ?? 1) - 1;
      if (cur <= 0) this.deviceInflightRpcs.delete(devKey);
      else this.deviceInflightRpcs.set(devKey, cur);
    }
  }

  // Drop a temp blob file after it has been consumed.
  discardUpload(u: { filePath: string }) {
    try {
      unlinkSync(u.filePath);
    } catch {}
  }
}
