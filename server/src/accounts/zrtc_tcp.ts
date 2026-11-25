import net from "node:net";
import { EventEmitter } from "node:events";

const MAX_FRAME = 4 + 2048;

/**
 * TCP transport for the ZRTC relay (`protocol: 3`). Frames are
 * `u32le totalLength (including the 4 header bytes) + ZRTP packet`, matching
 * `zrtc::TcpIOThread::SendData`/`HandleRead` in libzrtc.so.
 *
 * Exposes the same surface as a dgram socket: connections are opened lazily per
 * `host:port` on first `send`, and inbound frames surface as `message` events.
 */
export class ZrtcTcpSocket extends EventEmitter {
  private conns = new Map<string, net.Socket>();
  private pending = new Map<string, Buffer[]>();
  private closed = false;
  connectErrors = 0;
  connected = 0;
  rxBytes = 0;
  firstRx = "";
  events: string[] = [];

  summary(): string {
    return `connected=${this.connected},rxBytes=${this.rxBytes},firstRx=${this.firstRx || "none"},ev=${this.events.slice(0, 12).join("|")}`;
  }

  send(
    msg: Uint8Array | Buffer,
    port: number,
    address: string,
    cb?: (err: Error | null) => void,
  ): void {
    if (this.closed) return;
    const key = `${address}:${port}`;
    const frame = Buffer.alloc(4 + msg.length);
    frame.writeUInt32LE(4 + msg.length, 0);
    frame.set(msg, 4);

    let sock = this.conns.get(key);
    if (!sock) {
      sock = net.createConnection({ host: address, port });
      sock.setNoDelay(true);
      this.conns.set(key, sock);
      this.pending.set(key, []);
      let rx: Buffer = Buffer.alloc(0);
      sock.on("connect", () => {
        this.connected++;
        this.events.push(`${key}:connect`);
        const q = this.pending.get(key) ?? [];
        this.pending.delete(key);
        for (const f of q) sock!.write(f);
      });
      sock.on("data", (chunk: Buffer | string) => {
        const d = typeof chunk === "string" ? Buffer.from(chunk) : chunk;
        this.rxBytes += d.length;
        if (this.firstRx === "") this.firstRx = d.subarray(0, 24).toString("hex");
        rx = rx.length === 0 ? d : Buffer.concat([rx, d]);
        while (rx.length >= 4) {
          const len = rx.readUInt32LE(0);
          if (len < 5 || len > MAX_FRAME) {
            this.events.push(`${key}:badlen:${len}`);
            sock!.destroy();
            return;
          }
          if (rx.length < len) break;
          const payload = Buffer.from(rx.subarray(4, len));
          rx = rx.subarray(len);
          this.emit("message", payload, { address, port });
        }
      });
      sock.on("error", (e: NodeJS.ErrnoException) => {
        this.connectErrors++;
        this.events.push(`${key}:error:${e.code ?? e.message}`);
        this.conns.delete(key);
        this.pending.delete(key);
      });
      sock.on("close", () => {
        this.events.push(`${key}:close`);
        this.conns.delete(key);
        this.pending.delete(key);
      });
    }
    const q = this.pending.get(key);
    if (q) q.push(frame);
    else sock.write(frame);
    cb?.(null);
  }

  close(cb?: () => void): void {
    this.closed = true;
    for (const s of this.conns.values()) {
      try {
        s.destroy();
      } catch {}
    }
    this.conns.clear();
    this.pending.clear();
    cb?.();
  }
}
