// Speaks the real zalos protocol through the vendored wasm Noise initiator.
import { WebSocket } from "ws";
import { createRequire } from "node:module";
import { encodeMessage, TYPE_BLOB, TYPE_JSON } from "../../src/tunnel/framer.ts";

const require = createRequire(import.meta.url);
const noise = require("../../vendor/zalos-noise/zalos_noise.js");

export function fromHex(hex: string): Uint8Array {
  return new Uint8Array(Buffer.from(hex, "hex"));
}

export function toHex(b: Uint8Array): string {
  return Buffer.from(b).toString("hex");
}

export type ClientEvent = { event: string; seq?: number; data?: unknown };

type Pending = {
  resolve: (v: unknown) => void;
  reject: (e: Error) => void;
  timer: Timer;
};

export class Client {
  session!: InstanceType<typeof noise.Session>;
  ws!: WebSocket;
  private pending = new Map<number, Pending>();
  private nextId = 1;
  private outStream = 1;
  private jsonBuf = new Map<number, Uint8Array[]>();
  private blobBuf = new Map<number, Uint8Array[]>();
  events: ClientEvent[] = [];
  blobs = new Map<number, Uint8Array>();
  onEvent: ((e: ClientEvent) => void) | null = null;
  closed = Promise as never as Promise<number>;
  closeCode = 0;

  static async connect(opts: {
    url: string;
    prologue: string;
    devicePrivate: Uint8Array;
    serverPublic: Uint8Array;
    psk: Uint8Array;
    waitHandshake?: boolean;
  }): Promise<Client> {
    const c = new Client();
    c.session = noise.Session.initiator(
      new TextEncoder().encode(opts.prologue),
      opts.devicePrivate,
      opts.serverPublic,
      opts.psk,
    );
    const ws = new WebSocket(opts.url);
    c.ws = ws;
    c.closed = new Promise<number>((r) =>
      ws.on("close", (code: number) => {
        c.closeCode = code;
        r(code);
      }),
    );
    ws.on("message", (data: Buffer) => c.onMessage(new Uint8Array(data)));
    await new Promise<void>((res, rej) => {
      ws.on("open", res);
      ws.on("error", rej);
    });
    ws.send(Buffer.from(c.session.write_handshake(new Uint8Array(0))));
    if (opts.waitHandshake === false) return c;
    await new Promise<void>((res, rej) => {
      const poll = setInterval(() => {
        if (c.session.is_handshake_finished()) {
          clearInterval(poll);
          res();
        }
      }, 5);
      c.closed.then(() => {
        clearInterval(poll);
        rej(new Error(`closed before handshake: ${c.closeCode}`));
      });
      setTimeout(() => {
        clearInterval(poll);
        rej(new Error("handshake timeout"));
      }, 10000);
    });
    return c;
  }

  private onMessage(bytes: Uint8Array) {
    let plain: Uint8Array;
    if (!this.session.is_handshake_finished()) {
      this.session.read_handshake(bytes);
      return;
    }
    plain = this.session.decrypt(bytes);
    if (plain.length < 6) return;
    const type = plain[0];
    const flags = plain[1];
    const stream = new DataView(plain.buffer, plain.byteOffset).getUint32(2);
    const chunk = plain.subarray(6);
    const buf = type === TYPE_JSON ? this.jsonBuf : this.blobBuf;
    const list = buf.get(stream) ?? [];
    list.push(chunk);
    if (!(flags & 1)) {
      buf.set(stream, list);
      return;
    }
    buf.delete(stream);
    const size = list.reduce((n, c) => n + c.length, 0);
    const data = new Uint8Array(size);
    let off = 0;
    for (const c of list) {
      data.set(c, off);
      off += c.length;
    }
    if (type === TYPE_BLOB) {
      this.blobs.set(stream, data);
      this.onEvent?.({ event: "__blob__", data: { stream, size: data.length } });
      return;
    }
    const msg = JSON.parse(new TextDecoder().decode(data));
    if (typeof msg.id === "number") {
      const p = this.pending.get(msg.id);
      if (p) {
        this.pending.delete(msg.id);
        clearTimeout(p.timer);
        if (msg.error) p.reject(Object.assign(new Error(msg.error.message), { code: msg.error.code }));
        else p.resolve(msg.result);
      }
      return;
    }
    const evt: ClientEvent = { event: msg.event, seq: msg.seq, data: msg.data };
    this.events.push(evt);
    this.onEvent?.(evt);
  }

  private sendPlain(frames: Iterable<Uint8Array>) {
    for (const f of frames) {
      this.ws.send(Buffer.from(this.session.encrypt(f)));
    }
  }

  request(method: string, params: Record<string, unknown> = {}): Promise<unknown> {
    const id = this.nextId++;
    const stream = this.outStream++;
    this.sendPlain(
      encodeMessage(TYPE_JSON, stream, new TextEncoder().encode(JSON.stringify({ id, method, params }))),
    );
    return new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`request ${method} timed out`)),
        15000,
      );
      this.pending.set(id, { resolve, reject, timer });
    });
  }

  sendBlob(data: Uint8Array): number {
    const stream = this.outStream++;
    this.sendPlain(encodeMessage(TYPE_BLOB, stream, data));
    return stream;
  }

  async waitEvent(
    name: string,
    timeoutMs = 5000,
    match?: (e: ClientEvent) => boolean,
  ): Promise<ClientEvent> {
    const ok = (e: ClientEvent) =>
      e.event === name && (match === undefined || match(e));
    const existing = this.events.find(ok);
    if (existing) return existing;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`event ${name} timed out; got: ${JSON.stringify(this.events.map(e=>e.event))}`)),
        timeoutMs,
      );
      const prev = this.onEvent;
      this.onEvent = (e) => {
        prev?.(e);
        if (ok(e)) {
          clearTimeout(timer);
          resolve(e);
        }
      };
    });
  }

  waitBlob(stream: number, timeoutMs = 10000): Promise<Uint8Array> {
    const hit = this.blobs.get(stream);
    if (hit) return Promise.resolve(hit);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("blob timeout")), timeoutMs);
      const prev = this.onEvent;
      this.onEvent = (e) => {
        prev?.(e);
        const d = this.blobs.get(stream);
        if (d) {
          clearTimeout(timer);
          resolve(d);
        }
      };
    });
  }

  close(code?: number) {
    this.ws.close(code);
  }
}

export function noiseKeypair() {
  return noise.generate_keypair();
}
