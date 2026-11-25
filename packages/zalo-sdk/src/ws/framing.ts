import { ZaloProtocolError } from "../core/errors.ts";

export interface WsFrame {
  version: number;
  cmd: number;
  subCmd: number;
  bodyText: string;
}

/**
 * Encodes a Zalo WebSocket binary frame:
 * `[version:u8, cmd:u16le, subCmd:u8, ...utf8JsonPayload]`.
 */
export function encodeWsFrame(
  version: number,
  cmd: number,
  subCmd: number,
  payload: unknown = "",
): Buffer {
  const body =
    typeof payload === "string"
      ? Buffer.from(payload, "utf8")
      : Buffer.from(JSON.stringify(payload), "utf8");
  const header = Buffer.alloc(4);
  header.writeUInt8(version & 0xff, 0);
  header.writeUInt16LE(cmd & 0xffff, 1);
  header.writeUInt8(subCmd & 0xff, 3);
  return Buffer.concat([header, body]);
}

/**
 * Decodes a 4-byte little-endian Zalo WebSocket binary frame header + UTF-8 body.
 */
export function decodeWsFrame(raw: Uint8Array | Buffer): WsFrame {
  const buf = Buffer.isBuffer(raw) ? raw : Buffer.from(raw);
  if (buf.length < 4) {
    throw new ZaloProtocolError(`WebSocket frame too short: ${buf.length} bytes`);
  }
  const version = buf.readUInt8(0);
  const cmd = buf.readUInt16LE(1);
  const subCmd = buf.readUInt8(3);
  const bodyText = buf.subarray(4).toString("utf8");
  return { version, cmd, subCmd, bodyText };
}
