// Byte-exact codec for Zalo's proprietary ZRTP relay UDP wire format,
// reverse-engineered from zcall_mac.node (`zrtc::ZRTPPacket`).

export const ZRTP_PKT_TYPE = {
  REQUEST: 1,
  RESPONSE: 2,
  AUDIO_RTP_OUT: 3,
  AUDIO_RTP_IN: 4,
  AUDIO_RTCP: 5,
  VIDEO_RTP_OUT: 13,
  VIDEO_RTP_IN: 14,
  VIDEO_RTCP: 15,
} as const;

export const ZRTP_CMD = {
  PING: 2,
  PEER_PING: 5,
  END_CALL: 3,
  ECHO_ANON: 5,
  INIT_CALL_CALLER: 11,
  INIT_CALL_CALLEE: 12,
  CHANGE_ADDRESS: 14,
  REQUEST_FORWARD: 32,
} as const;

const HEADER_LEN = 21;
const encoder = new TextEncoder();
const decoder = new TextDecoder();

function writeControlHeader(
  view: DataView,
  opts: {
    type: number;
    version?: number;
    seq?: number;
    flag?: number;
    userId?: number;
    token?: number;
    cmd: number;
    subCmd?: number;
  },
): void {
  const seqOrFlag =
    opts.flag !== undefined && opts.flag !== 0
      ? opts.flag
      : (opts.seq ?? opts.flag ?? 0);
  view.setUint8(0, opts.type & 0xff);
  view.setUint8(1, (opts.version ?? 1) & 0xff);
  view.setUint32(2, 0, true);
  view.setUint32(6, seqOrFlag >>> 0, true);
  view.setUint32(10, (opts.userId ?? 0) >>> 0, true);
  view.setUint32(14, (opts.token ?? 0) >>> 0, true);
  view.setUint16(18, opts.cmd & 0xffff, true);
  view.setUint8(20, (opts.subCmd ?? 0) & 0xff);
}

function encodeExtraBytes(extraInfo?: string | Uint8Array): Uint8Array | null {
  if (extraInfo instanceof Uint8Array) {
    return extraInfo.length > 0 ? extraInfo : null;
  }
  return extraInfo ? encoder.encode(extraInfo) : null;
}

export function encodeInitCall(opts: {
  isCallee: boolean;
  userId: number;
  partnerId: number;
  callId: number;
  sessionId: string;
  isVideo: boolean;
  extraInfo?: string | Uint8Array;
  seq?: number;
}): Uint8Array {
  const sessBytes = encoder.encode(opts.sessionId);
  const extraBytes = encodeExtraBytes(opts.extraInfo);
  const bodyLen =
    10 + sessBytes.length + (extraBytes ? 2 + extraBytes.length : 0);
  const buf = new Uint8Array(HEADER_LEN + bodyLen);
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);

  writeControlHeader(view, {
    type: ZRTP_PKT_TYPE.REQUEST,
    version: 1,
    seq: opts.seq,
    userId: opts.userId,
    token: 0,
    cmd: opts.isCallee ? ZRTP_CMD.INIT_CALL_CALLEE : ZRTP_CMD.INIT_CALL_CALLER,
    subCmd: opts.isVideo ? 2 : 1,
  });

  view.setUint32(21, opts.callId >>> 0, true);
  view.setUint32(25, opts.partnerId >>> 0, true);
  view.setUint16(29, sessBytes.length, true);
  buf.set(sessBytes, 31);

  if (extraBytes) {
    const off = 31 + sessBytes.length;
    view.setUint16(off, extraBytes.length, true);
    buf.set(extraBytes, off + 2);
  }
  return buf;
}

export function encodePing(opts: {
  userId: number;
  token: number;
  sessionId: string;
  extraInfo?: string | Uint8Array;
  seq?: number;
}): Uint8Array {
  const sessBytes = encoder.encode(opts.sessionId);
  const extraBytes = encodeExtraBytes(opts.extraInfo);
  const bodyLen = 2 + sessBytes.length + (extraBytes ? 2 + extraBytes.length : 0);
  const buf = new Uint8Array(HEADER_LEN + bodyLen);
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);

  writeControlHeader(view, {
    type: ZRTP_PKT_TYPE.REQUEST,
    version: 1,
    seq: opts.seq,
    userId: opts.userId,
    token: opts.token,
    cmd: ZRTP_CMD.PING,
    subCmd: 3,
  });
  view.setUint16(21, sessBytes.length, true);
  buf.set(sessBytes, 23);
  if (extraBytes) {
    const off = 23 + sessBytes.length;
    view.setUint16(off, extraBytes.length, true);
    buf.set(extraBytes, off + 2);
  }
  return buf;
}

export function encodeRelayPing(opts: {
  userId: number;
  token: number;
  sessionId: string;
}): Uint8Array {
  const sessBytes = encoder.encode(opts.sessionId);
  const buf = new Uint8Array(23 + sessBytes.length);
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  view.setUint8(0, ZRTP_PKT_TYPE.REQUEST);
  view.setUint8(1, 1);
  view.setUint32(2, 0, true);
  view.setUint32(6, 0, true);
  view.setUint32(10, opts.userId >>> 0, true);
  view.setUint32(14, opts.token >>> 0, true);
  view.setUint16(18, ZRTP_CMD.PING, true);
  view.setUint8(20, 1);
  view.setUint16(21, sessBytes.length, true);
  buf.set(sessBytes, 23);
  return buf;
}

export function encodePeerPing(opts: {
  userId: number;
  partnerId: number;
  callId: number;
  elapsedMs: number;
  seqNum?: number;
}): Uint8Array {
  const elapsedBytes = encoder.encode(String(Math.max(1, Math.floor(opts.elapsedMs))));
  const rawLen = 23 + elapsedBytes.length;
  const buf = new Uint8Array(Math.max(rawLen, 40));
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  view.setUint8(0, ZRTP_PKT_TYPE.REQUEST);
  view.setUint8(1, 1);
  view.setUint32(2, (opts.seqNum ?? 0) >>> 0, true);
  view.setUint32(6, opts.callId >>> 0, true);
  view.setUint32(10, opts.userId >>> 0, true);
  view.setUint32(14, opts.partnerId >>> 0, true);
  view.setUint16(18, ZRTP_CMD.PEER_PING, true);
  view.setUint8(20, 1);
  view.setUint16(21, elapsedBytes.length, true);
  buf.set(elapsedBytes, 23);
  return buf;
}

export function encodeRequestForward(opts: {
  userId: number;
  token: number;
  subCmd?: number;
  flag?: number;
  seq?: number;
}): Uint8Array {
  const buf = new Uint8Array(HEADER_LEN);
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  writeControlHeader(view, {
    type: ZRTP_PKT_TYPE.REQUEST,
    version: 1,
    seq: opts.seq,
    flag: opts.flag,
    userId: opts.userId,
    token: opts.token,
    cmd: ZRTP_CMD.REQUEST_FORWARD,
    subCmd: opts.subCmd ?? 1,
  });
  return buf;
}

export function encodeRequestForwardWithPayload(opts: {
  userId: number;
  token: number;
  subCmd: number;
  payload?: Uint8Array;
  seqNum?: number;
  seqId?: number;
}): Uint8Array {
  const payload = opts.payload ?? new Uint8Array(0);
  const buf = new Uint8Array(25 + payload.length);
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  view.setUint8(0, ZRTP_PKT_TYPE.REQUEST);
  view.setUint8(1, 1);
  view.setUint32(2, (opts.seqNum ?? 0) >>> 0, true);
  view.setUint32(6, (opts.seqId ?? 0) >>> 0, true);
  view.setUint32(10, opts.userId >>> 0, true);
  view.setUint32(14, opts.token >>> 0, true);
  view.setUint16(18, ZRTP_CMD.REQUEST_FORWARD, true);
  view.setUint8(20, opts.subCmd & 0xff);
  view.setUint32(21, payload.length >>> 0, true);
  buf.set(payload, 25);
  return buf;
}

export function encodeEndCall(opts: {
  userId: number;
  token: number;
  callId: number;
  seq?: number;
}): Uint8Array {
  const buf = new Uint8Array(HEADER_LEN + 4);
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  writeControlHeader(view, {
    type: ZRTP_PKT_TYPE.REQUEST,
    version: 1,
    seq: opts.seq,
    userId: opts.userId,
    token: opts.token,
    cmd: ZRTP_CMD.END_CALL,
    subCmd: 0,
  });
  view.setUint32(21, opts.callId >>> 0, true);
  return buf;
}

export function encodeEchoAnonymous(opts: {
  seq?: number;
  extraInfo?: string | Uint8Array;
  userId?: number;
  token?: number;
} = {}): Uint8Array {
  const extraBytes = encodeExtraBytes(opts.extraInfo);
  const extraLen = extraBytes ? extraBytes.length : 0;
  const buf = new Uint8Array(HEADER_LEN + 2 + extraLen);
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  writeControlHeader(view, {
    type: ZRTP_PKT_TYPE.REQUEST,
    version: 1,
    seq: opts.seq,
    userId: opts.userId ?? 4101989,
    token: opts.token ?? 19891004,
    cmd: ZRTP_CMD.ECHO_ANON,
    subCmd: 0,
  });
  view.setUint16(21, extraLen, true);
  if (extraBytes) {
    buf.set(extraBytes, 23);
  }
  return buf;
}

export function encodeChangeAddress(opts: {
  userId: number;
  token: number;
  sessionId: string;
  flag?: number;
  seq?: number;
  extraInfo?: string | Uint8Array;
}): Uint8Array {
  const sessBytes = encoder.encode(opts.sessionId);
  const extraBytes = encodeExtraBytes(opts.extraInfo);
  const bodyLen = 2 + sessBytes.length + (extraBytes ? 2 + extraBytes.length : 0);
  const buf = new Uint8Array(HEADER_LEN + bodyLen);
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  writeControlHeader(view, {
    type: ZRTP_PKT_TYPE.REQUEST,
    version: 1,
    seq: opts.seq,
    flag: opts.flag,
    userId: opts.userId,
    token: opts.token,
    cmd: ZRTP_CMD.CHANGE_ADDRESS,
    subCmd: 1,
  });
  view.setUint16(21, sessBytes.length, true);
  buf.set(sessBytes, 23);
  if (extraBytes) {
    const off = 23 + sessBytes.length;
    view.setUint16(off, extraBytes.length, true);
    buf.set(extraBytes, off + 2);
  }
  return buf;
}

function encodeMediaPacket(
  packetType: number,
  token: number,
  payload: Uint8Array,
): Uint8Array {
  const buf = new Uint8Array(5 + payload.length);
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  view.setUint8(0, packetType & 0xff);
  view.setUint32(1, token >>> 0, true);
  buf.set(payload, 5);
  return buf;
}

export function encodeAudioRtp(token: number, rtp: Uint8Array): Uint8Array {
  return encodeMediaPacket(ZRTP_PKT_TYPE.AUDIO_RTP_OUT, token, rtp);
}

export function encodeVideoRtp(token: number, rtp: Uint8Array): Uint8Array {
  return encodeMediaPacket(ZRTP_PKT_TYPE.VIDEO_RTP_OUT, token, rtp);
}

export function encodeAudioRtcp(token: number, rtcp: Uint8Array): Uint8Array {
  return encodeMediaPacket(ZRTP_PKT_TYPE.AUDIO_RTCP, token, rtcp);
}

export function encodeVideoRtcp(token: number, rtcp: Uint8Array): Uint8Array {
  return encodeMediaPacket(ZRTP_PKT_TYPE.VIDEO_RTCP, token, rtcp);
}

export type ParsedZrtpPacket =
  | { kind: "audio_rtp"; payload: Uint8Array }
  | { kind: "video_rtp"; payload: Uint8Array }
  | { kind: "audio_rtcp"; token: number; payload: Uint8Array }
  | { kind: "video_rtcp"; token: number; payload: Uint8Array }
  | {
      kind: "init_response";
      cmd: number;
      resCode: number;
      callId: number;
      token: number;
      extra?: string;
    }
  | {
      kind: "change_address_response";
      resCode: number;
    }
  | {
      kind: "control_response";
      cmd: number;
      subCmd: number;
      reserved: number;
      seq: number;
      flag: number;
      userId: number;
      token: number;
      body: Uint8Array;
    }
  | { kind: "unknown"; packetType: number };

export function parseZrtpPacket(buf: Uint8Array): ParsedZrtpPacket | null {
  if (buf.length < 1) return null;
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const packetType = view.getUint8(0);

  if (packetType === ZRTP_PKT_TYPE.AUDIO_RTP_IN) {
    return { kind: "audio_rtp", payload: buf.subarray(1) };
  }
  if (packetType === ZRTP_PKT_TYPE.VIDEO_RTP_IN) {
    return { kind: "video_rtp", payload: buf.subarray(1) };
  }
  if (packetType === ZRTP_PKT_TYPE.AUDIO_RTCP) {
    if (buf.length < 5) return null;
    return {
      kind: "audio_rtcp",
      token: view.getUint32(1, true),
      payload: buf.subarray(5),
    };
  }
  if (packetType === ZRTP_PKT_TYPE.VIDEO_RTCP) {
    if (buf.length < 5) return null;
    return {
      kind: "video_rtcp",
      token: view.getUint32(1, true),
      payload: buf.subarray(5),
    };
  }
  if (packetType !== ZRTP_PKT_TYPE.RESPONSE) {
    return { kind: "unknown", packetType };
  }
  if (buf.length < HEADER_LEN) return null;

  const reserved = view.getUint32(2, true);
  const seq = view.getUint32(6, true);
  const flag = seq;
  const userId = view.getUint32(10, true);
  const token = view.getUint32(14, true);
  const cmd = view.getUint16(18, true);
  const subCmd = view.getUint8(20);

  if (cmd === ZRTP_CMD.INIT_CALL_CALLEE || cmd === ZRTP_CMD.INIT_CALL_CALLER) {
    if (buf.length < 25) return null;
    const resCode = view.getInt32(21, true);
    if (resCode !== 0) {
      return {
        kind: "init_response",
        cmd,
        resCode,
        callId: 0,
        token: 0,
      };
    }
    const callId = buf.length >= 29 ? view.getUint32(25, true) : 0;
    const respToken = buf.length >= 33 ? view.getUint32(29, true) : token;
    let extra: string | undefined;
    if (buf.length >= 35) {
      const extraLen = view.getUint16(33, true);
      if (extraLen > 0 && 35 + extraLen <= buf.length) {
        extra = decoder.decode(buf.subarray(35, 35 + extraLen));
      }
    }
    return {
      kind: "init_response",
      cmd,
      resCode,
      callId,
      token: respToken,
      ...(extra !== undefined ? { extra } : {}),
    };
  }

  if (cmd === ZRTP_CMD.CHANGE_ADDRESS) {
    if (buf.length < 25) return null;
    return {
      kind: "change_address_response",
      resCode: view.getInt32(21, true),
    };
  }

  return {
    kind: "control_response",
    cmd,
    subCmd,
    reserved,
    seq,
    flag,
    userId,
    token,
    body: buf.subarray(HEADER_LEN),
  };
}
