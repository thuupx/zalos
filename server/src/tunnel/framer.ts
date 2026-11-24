// Plaintext framing inside the Noise session:
//   type:u8 | flags:u8 | stream:u32be | chunk (<= 60000 bytes)
// type 1 = JSON message, type 2 = blob data. flags bit0 = FIN.
import { mkdirSync, unlinkSync } from "node:fs";
import { join } from "node:path";

export const FRAME_CHUNK = 60000;
export const JSON_LIMIT = 1024 * 1024;
export const BLOB_LIMIT = 100 * 1024 * 1024;

export const TYPE_JSON = 1;
export const TYPE_BLOB = 2;
export const FLAG_FIN = 1;

export class FrameError extends Error {}

export function encodeFrame(
  type: number,
  flags: number,
  stream: number,
  chunk: Uint8Array,
): Uint8Array {
  const out = new Uint8Array(6 + chunk.length);
  out[0] = type;
  out[1] = flags;
  new DataView(out.buffer).setUint32(2, stream);
  out.set(chunk, 6);
  return out;
}

export function* encodeMessage(
  type: number,
  stream: number,
  data: Uint8Array,
): Generator<Uint8Array> {
  if (data.length === 0) {
    yield encodeFrame(type, FLAG_FIN, stream, data);
    return;
  }
  for (let off = 0; off < data.length; off += FRAME_CHUNK) {
    const chunk = data.subarray(off, Math.min(off + FRAME_CHUNK, data.length));
    const fin = off + FRAME_CHUNK >= data.length ? FLAG_FIN : 0;
    yield encodeFrame(type, fin, stream, chunk);
  }
}

export const MAX_OPEN_STREAMS = 8;

type Pending = {
  type: number;
  buffer?: Uint8Array[];
  size: number;
  filePath?: string;
  writer?: ReturnType<ReturnType<typeof Bun.file>["writer"]>;
};

export type InboundMessage =
  | { type: typeof TYPE_JSON; stream: number; data: Uint8Array }
  | { type: typeof TYPE_BLOB; stream: number; filePath: string; size: number };

export class Assembler {
  private pending = new Map<number, Pending>();
  private blobDir: string;
  private blobCounter = 0;

  constructor(blobDir: string) {
    this.blobDir = blobDir;
    mkdirSync(blobDir, { recursive: true, mode: 0o700 });
  }

  feed(frame: Uint8Array): InboundMessage | null {
    if (frame.length < 6) throw new FrameError("short frame");
    const type = frame[0];
    const flags = frame[1];
    const stream = new DataView(frame.buffer, frame.byteOffset).getUint32(2);
    const chunk = frame.subarray(6);
    if (type !== TYPE_JSON && type !== TYPE_BLOB) {
      throw new FrameError(`unknown frame type ${type}`);
    }
    if (chunk.length > FRAME_CHUNK) {
      throw new FrameError("oversized chunk");
    }

    let p = this.pending.get(stream);
    if (p === undefined) {
      if (this.pending.size >= MAX_OPEN_STREAMS) {
        throw new FrameError("too many open streams");
      }
      p = { type, size: 0 };
      if (type === TYPE_JSON) p.buffer = [];
      this.pending.set(stream, p);
    }
    if (p.type !== type) throw new FrameError("stream type changed");

    p.size += chunk.length;
    if (type === TYPE_JSON) {
      if (p.size > JSON_LIMIT) throw new FrameError("json limit exceeded");
      p.buffer!.push(chunk);
    } else {
      if (p.size > BLOB_LIMIT) throw new FrameError("blob limit exceeded");
      if (p.writer === undefined) {
        p.filePath = join(this.blobDir, `up-${Date.now()}-${this.blobCounter++}`);
        p.writer = Bun.file(p.filePath).writer();
      }
      p.writer.write(chunk);
    }

    if (!(flags & FLAG_FIN)) return null;
    this.pending.delete(stream);
    if (type === TYPE_JSON) {
      const data = new Uint8Array(p.size);
      let off = 0;
      for (const c of p.buffer!) {
        data.set(c, off);
        off += c.length;
      }
      return { type: TYPE_JSON, stream, data };
    }
    p.writer!.end();
    return { type: TYPE_BLOB, stream, filePath: p.filePath!, size: p.size };
  }

  // Drop every half-finished stream: end blob writers, delete their temp
  // files and release buffered JSON chunks.
  dispose() {
    for (const p of this.pending.values()) {
      p.buffer = undefined;
      if (p.writer !== undefined) {
        try {
          p.writer.end();
        } catch {}
        if (p.filePath !== undefined) {
          try {
            unlinkSync(p.filePath);
          } catch {}
        }
      }
    }
    this.pending.clear();
  }
}

export function b64(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64");
}

export function b64url(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64url");
}

export function unb64(s: string): Uint8Array {
  return new Uint8Array(Buffer.from(s, "base64"));
}
