import { describe, expect, test } from "bun:test";
import { EventEmitter } from "node:events";
import {
  ZRTP_CMD,
  ZRTP_PKT_TYPE,
  encodeAudioRtcp,
  encodeAudioRtp,
  encodeChangeAddress,
  encodeEchoAnonymous,
  encodeEndCall,
  encodeInitCall,
  encodePing,
  encodeRequestForward,
  encodeVideoRtcp,
  encodeVideoRtp,
  parseZrtpPacket,
} from "../src/accounts/zrtc_packet.ts";
import { ZrtcRelaySession, parseHostPort } from "../src/accounts/zrtc_session.ts";

describe("zrtc_packet", () => {
  test("encodes caller and callee InitCall with exact byte layout", () => {
    expect(ZRTP_CMD.INIT_CALL_CALLER).toBe(11);
    expect(ZRTP_CMD.INIT_CALL_CALLEE).toBe(12);

    const caller = encodeInitCall({
      isCallee: false,
      userId: 113733669,
      partnerId: 156444475,
      callId: 42,
      sessionId: "SESS-123",
      isVideo: true,
      extraInfo: "{\"v\":1}",
      seq: 7,
    });
    const dv = new DataView(caller.buffer);
    expect(dv.getUint8(0)).toBe(ZRTP_PKT_TYPE.REQUEST);
    expect(dv.getUint8(1)).toBe(1);
    expect(dv.getUint32(2, true)).toBe(0);
    expect(dv.getUint32(6, true)).toBe(7);
    expect(dv.getUint32(10, true)).toBe(113733669);
    expect(dv.getUint32(14, true)).toBe(0);
    expect(dv.getUint16(18, true)).toBe(11);
    expect(dv.getUint8(20)).toBe(2); // isVideo -> subCmd 2
    expect(dv.getUint32(21, true)).toBe(42);
    expect(dv.getUint32(25, true)).toBe(156444475);
    expect(dv.getUint16(29, true)).toBe(8);
    expect(Buffer.from(caller.subarray(31, 39)).toString()).toBe("SESS-123");
    expect(dv.getUint16(39, true)).toBe(7);
    expect(Buffer.from(caller.subarray(41)).toString()).toBe("{\"v\":1}");

    const callee = encodeInitCall({
      isCallee: true,
      userId: 156444475,
      partnerId: 113733669,
      callId: 42,
      sessionId: "SESS-123",
      isVideo: false,
      extraInfo: new Uint8Array([0x01, 0x02]),
    });
    const cdv = new DataView(callee.buffer);
    expect(cdv.getUint32(2, true)).toBe(0);
    expect(cdv.getUint32(6, true)).toBe(0);
    expect(cdv.getUint16(18, true)).toBe(12);
    expect(cdv.getUint8(20)).toBe(1); // audio -> subCmd 1
    expect(cdv.getUint16(39, true)).toBe(2);
    expect(Array.from(callee.subarray(41))).toEqual([0x01, 0x02]);
    expect(callee.length).toBe(31 + 8 + 4);
  });

  test("encodes Ping, RequestForward, EndCall, EchoAnonymous, and ChangeAddress with bytes[2..5]=0", () => {
    const ping = encodePing({ userId: 100, token: 999, sessionId: "abc", seq: 3 });
    const pdv = new DataView(ping.buffer);
    expect(pdv.getUint32(2, true)).toBe(0);
    expect(pdv.getUint32(6, true)).toBe(3);
    expect(pdv.getUint16(18, true)).toBe(ZRTP_CMD.PING);
    expect(pdv.getUint8(20)).toBe(3);
    expect(pdv.getUint32(14, true)).toBe(999);
    expect(pdv.getUint16(21, true)).toBe(3);

    const pingWithExtra = encodePing({
      userId: 100,
      token: 999,
      sessionId: "abc",
      extraInfo: new Uint8Array([9, 8]),
    });
    const pxdv = new DataView(pingWithExtra.buffer);
    expect(pxdv.getUint32(2, true)).toBe(0);
    expect(pxdv.getUint16(26, true)).toBe(2);
    expect(Array.from(pingWithExtra.subarray(28))).toEqual([9, 8]);

    const fwdFlagOnly = encodeRequestForward({ userId: 100, token: 999, subCmd: 1, flag: 42 });
    const fdv = new DataView(fwdFlagOnly.buffer);
    expect(fwdFlagOnly.length).toBe(21);
    expect(fdv.getUint32(2, true)).toBe(0);
    expect(fdv.getUint32(6, true)).toBe(42);
    expect(fdv.getUint16(18, true)).toBe(ZRTP_CMD.REQUEST_FORWARD);
    expect(fdv.getUint8(20)).toBe(1);

    const fwdFlagWithZeroSeq = encodeRequestForward({
      userId: 100,
      token: 999,
      subCmd: 2,
      flag: 42,
      seq: 0,
    });
    expect(new DataView(fwdFlagWithZeroSeq.buffer).getUint32(6, true)).toBe(42);

    const fwdSeqOnly = encodeRequestForward({ userId: 100, token: 999, seq: 9 });
    expect(new DataView(fwdSeqOnly.buffer).getUint32(2, true)).toBe(0);
    expect(new DataView(fwdSeqOnly.buffer).getUint32(6, true)).toBe(9);

    const end = encodeEndCall({ userId: 100, token: 999, callId: 55, seq: 11 });
    const edv = new DataView(end.buffer);
    expect(end.length).toBe(25);
    expect(edv.getUint32(2, true)).toBe(0);
    expect(edv.getUint32(6, true)).toBe(11);
    expect(edv.getUint16(18, true)).toBe(ZRTP_CMD.END_CALL);
    expect(edv.getUint32(21, true)).toBe(55);

    const echo = encodeEchoAnonymous({ seq: 5, extraInfo: "hi" });
    const ecdv = new DataView(echo.buffer);
    expect(ecdv.getUint8(0)).toBe(ZRTP_PKT_TYPE.REQUEST);
    expect(ecdv.getUint8(1)).toBe(1);
    expect(ecdv.getUint32(2, true)).toBe(0);
    expect(ecdv.getUint32(6, true)).toBe(5);
    expect(ecdv.getUint32(10, true)).toBe(4101989);
    expect(ecdv.getUint32(14, true)).toBe(19891004);
    expect(ecdv.getUint16(18, true)).toBe(ZRTP_CMD.ECHO_ANON);
    expect(ecdv.getUint8(20)).toBe(0);
    expect(ecdv.getUint16(21, true)).toBe(2);
    expect(Buffer.from(echo.subarray(23)).toString()).toBe("hi");

    const chg = encodeChangeAddress({
      userId: 100,
      token: 999,
      sessionId: "S1",
      flag: 77,
      extraInfo: "ex",
    });
    const chdv = new DataView(chg.buffer);
    expect(chdv.getUint32(2, true)).toBe(0);
    expect(chdv.getUint32(6, true)).toBe(77);
    expect(chdv.getUint16(18, true)).toBe(ZRTP_CMD.CHANGE_ADDRESS);
    expect(chdv.getUint8(20)).toBe(1);
    expect(chdv.getUint16(21, true)).toBe(2);
    expect(Buffer.from(chg.subarray(23, 25)).toString()).toBe("S1");
    expect(chdv.getUint16(25, true)).toBe(2);
    expect(Buffer.from(chg.subarray(27)).toString()).toBe("ex");
  });

  test("parseZrtpPacket reads reserved at offset 2 and seq/flag at offset 6", () => {
    const ctrl = new Uint8Array(25);
    const cv = new DataView(ctrl.buffer);
    cv.setUint8(0, ZRTP_PKT_TYPE.RESPONSE);
    cv.setUint8(1, 1);
    cv.setUint32(2, 0, true);
    cv.setUint32(6, 123, true);
    cv.setUint32(10, 100, true);
    cv.setUint32(14, 999, true);
    cv.setUint16(18, ZRTP_CMD.PING, true);
    cv.setUint8(20, 3);
    cv.setInt32(21, 0, true);
    expect(parseZrtpPacket(ctrl)).toEqual({
      kind: "control_response",
      cmd: ZRTP_CMD.PING,
      subCmd: 3,
      reserved: 0,
      seq: 123,
      flag: 123,
      userId: 100,
      token: 999,
      body: ctrl.subarray(21),
    });

    const chgResp = new Uint8Array(25);
    const chrv = new DataView(chgResp.buffer);
    chrv.setUint8(0, ZRTP_PKT_TYPE.RESPONSE);
    chrv.setUint8(1, 1);
    chrv.setUint16(18, ZRTP_CMD.CHANGE_ADDRESS, true);
    chrv.setInt32(21, -2, true);
    expect(parseZrtpPacket(chgResp)).toEqual({
      kind: "change_address_response",
      resCode: -2,
    });
  });

  test("encodes outbound media frames and parses inbound media + init response", () => {
    const payload = new Uint8Array([0x80, 0x6f, 0x00, 0x01]);
    const aOut = encodeAudioRtp(1234, payload);
    expect(aOut[0]).toBe(ZRTP_PKT_TYPE.AUDIO_RTP_OUT);
    expect(new DataView(aOut.buffer).getUint32(1, true)).toBe(1234);
    expect(aOut.subarray(5)).toEqual(payload);

    const vOut = encodeVideoRtp(1234, payload);
    expect(vOut[0]).toBe(ZRTP_PKT_TYPE.VIDEO_RTP_OUT);

    const arOut = encodeAudioRtcp(1234, payload);
    expect(arOut[0]).toBe(ZRTP_PKT_TYPE.AUDIO_RTCP);
    expect(parseZrtpPacket(arOut)).toEqual({
      kind: "audio_rtcp",
      token: 1234,
      payload,
    });

    const vrOut = encodeVideoRtcp(1234, payload);
    expect(parseZrtpPacket(vrOut)).toEqual({
      kind: "video_rtcp",
      token: 1234,
      payload,
    });

    const aIn = new Uint8Array([ZRTP_PKT_TYPE.AUDIO_RTP_IN, ...payload]);
    expect(parseZrtpPacket(aIn)).toEqual({ kind: "audio_rtp", payload });

    const vIn = new Uint8Array([ZRTP_PKT_TYPE.VIDEO_RTP_IN, ...payload]);
    expect(parseZrtpPacket(vIn)).toEqual({ kind: "video_rtp", payload });

    // Construct INIT response packet
    const resp = new Uint8Array(33);
    const rv = new DataView(resp.buffer);
    rv.setUint8(0, ZRTP_PKT_TYPE.RESPONSE);
    rv.setUint8(1, 1);
    rv.setUint16(18, ZRTP_CMD.INIT_CALL_CALLER, true);
    rv.setInt32(21, 0, true);
    rv.setUint32(25, 42, true);
    rv.setUint32(29, 8888, true);
    expect(parseZrtpPacket(resp)).toEqual({
      kind: "init_response",
      cmd: ZRTP_CMD.INIT_CALL_CALLER,
      resCode: 0,
      callId: 42,
      token: 8888,
    });
  });

  test("parseHostPort validates IPv4 and rejects invalid inputs", () => {
    expect(parseHostPort("120.138.74.196:8020")).toEqual({
      host: "120.138.74.196",
      port: 8020,
    });
    expect(parseHostPort("bad")).toBeNull();
    expect(parseHostPort("127.0.0.1:99999")).toBeNull();
  });

  test("ZrtcRelaySession completes InitCall handshake without RequestForward, registers distinct RTCP socket, and relays audio RTP", async () => {
    class MockSocket extends EventEmitter {
      sent: Array<{ buf: Buffer; port: number; address: string }> = [];
      closed = false;
      send(msg: Uint8Array, port: number, address: string) {
        const buf = Buffer.from(msg);
        this.sent.push({ buf, port, address });
        // Auto-reply to InitCall (enforce bytes[2..5] === 0 like production ZRTC relays)
        const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
        if (dv.getUint32(2, true) !== 0) return;
        if (buf[0] === ZRTP_PKT_TYPE.REQUEST && dv.getUint16(18, true) === ZRTP_CMD.INIT_CALL_CALLER) {
          queueMicrotask(() => {
            const resp = new Uint8Array(33);
            const rv = new DataView(resp.buffer);
            rv.setUint8(0, ZRTP_PKT_TYPE.RESPONSE);
            rv.setUint8(1, 1);
            rv.setUint16(18, ZRTP_CMD.INIT_CALL_CALLER, true);
            rv.setInt32(21, 0, true);
            rv.setUint32(25, 99, true);
            rv.setUint32(29, 7777, true);
            this.emit("message", Buffer.from(resp), { address, port });
          });
        }
      }
      close() {
        this.closed = true;
      }
    }

    const sockets: MockSocket[] = [];
    const session = new ZrtcRelaySession(() => {
      const s = new MockSocket();
      sockets.push(s);
      return s;
    });

    const receivedAudio: Uint8Array[] = [];
    session.onAudioRtp = (p) => receivedAudio.push(p);

    const res = await session.connect({
      isCallee: false,
      userId: 1001,
      partnerId: 2002,
      callId: 99,
      sessionId: "sess-abc",
      isVideo: false,
      servers: [{ rtpaddr: "120.138.74.196:8020", rtcpaddr: "120.138.74.196:4004" }],
    });

    expect(res).toEqual({
      token: 7777,
      rtpAddress: "120.138.74.196:8020",
      rtcpAddress: "120.138.74.196:4004",
      transport: "udp",
    });

    const rtpSock = sockets[0]!;
    const rtcpSock = sockets[1]!;
    // Sent ONLY InitCall on rtpSock (no spurious RequestForward)
    expect(rtpSock.sent.length).toBe(1);
    const initView = new DataView(
      rtpSock.sent[0]!.buf.buffer,
      rtpSock.sent[0]!.buf.byteOffset,
      rtpSock.sent[0]!.buf.byteLength,
    );
    expect(initView.getUint32(2, true)).toBe(0);
    expect(initView.getUint16(18, true)).toBe(ZRTP_CMD.INIT_CALL_CALLER);

    // Registered distinct rtcpSock with a PING to the RTCP port
    expect(rtcpSock.closed).toBe(false);
    expect(rtcpSock.sent.length).toBe(1);
    expect(rtcpSock.sent[0]!.port).toBe(4004);
    const pingView = new DataView(
      rtcpSock.sent[0]!.buf.buffer,
      rtcpSock.sent[0]!.buf.byteOffset,
      rtcpSock.sent[0]!.buf.byteLength,
    );
    expect(pingView.getUint32(2, true)).toBe(0);
    expect(pingView.getUint32(14, true)).toBe(7777);
    expect(pingView.getUint16(18, true)).toBe(ZRTP_CMD.PING);

    // Outbound RTP
    session.sendAudioRtp(new Uint8Array([0x80, 0x6f, 0x11, 0x22]));
    const lastSent = rtpSock.sent[rtpSock.sent.length - 1]!.buf;
    expect(lastSent[0]).toBe(ZRTP_PKT_TYPE.AUDIO_RTP_OUT);
    expect(new DataView(lastSent.buffer, lastSent.byteOffset).getUint32(1, true)).toBe(7777);

    // Inbound RTP
    rtpSock.emit("message", Buffer.from([ZRTP_PKT_TYPE.AUDIO_RTP_IN, 0xaa, 0xbb]), {
      address: "120.138.74.196",
      port: 8020,
    });
    expect(receivedAudio).toEqual([new Uint8Array([0xaa, 0xbb])]);

    session.close();
    expect(rtpSock.closed).toBe(true);
    expect(rtcpSock.closed).toBe(true);
  });

  test("ZrtcRelaySession sends DEFAULT_INIT_EXTRA on callee InitCall and reuses rtpSock when rtpAddress === rtcpAddress", async () => {
    class MockSocket extends EventEmitter {
      sent: Array<{ buf: Buffer; port: number; address: string }> = [];
      closeCount = 0;
      get closed() {
        return this.closeCount > 0;
      }
      send(msg: Uint8Array, port: number, address: string) {
        const buf = Buffer.from(msg);
        this.sent.push({ buf, port, address });
        const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
        if (dv.getUint32(2, true) !== 0) return;
        if (buf[0] === ZRTP_PKT_TYPE.REQUEST && dv.getUint16(18, true) === ZRTP_CMD.INIT_CALL_CALLEE) {
          queueMicrotask(() => {
            const resp = new Uint8Array(33);
            const rv = new DataView(resp.buffer);
            rv.setUint8(0, ZRTP_PKT_TYPE.RESPONSE);
            rv.setUint8(1, 1);
            rv.setUint16(18, ZRTP_CMD.INIT_CALL_CALLEE, true);
            rv.setInt32(21, 0, true);
            rv.setUint32(25, 101, true);
            rv.setUint32(29, 8888, true);
            this.emit("message", Buffer.from(resp), { address, port });
          });
        }
      }
      close() {
        this.closeCount++;
      }
    }

    const sockets: MockSocket[] = [];
    const session = new ZrtcRelaySession(() => {
      const s = new MockSocket();
      sockets.push(s);
      return s;
    });

    const res = await session.connect({
      isCallee: true,
      userId: 2002,
      partnerId: 1001,
      callId: 101,
      sessionId: "callee-s",
      isVideo: true,
      servers: [{ rtpaddr: "171.244.25.89:4200", rtcpaddr: "171.244.25.89:4200" }],
    });

    expect(res.token).toBe(8888);
    const rtpSock = sockets[0]!;
    const unusedRtcpSock = sockets[1]!;
    expect(unusedRtcpSock.closed).toBe(true);
    expect(unusedRtcpSock.sent).toHaveLength(0);

    const initBuf = rtpSock.sent[0]!.buf;
    const idv = new DataView(initBuf.buffer, initBuf.byteOffset, initBuf.byteLength);
    expect(idv.getUint32(2, true)).toBe(0);
    expect(idv.getUint16(18, true)).toBe(ZRTP_CMD.INIT_CALL_CALLEE);
    const sessLen = idv.getUint16(29, true);
    expect(idv.getUint16(31 + sessLen, true)).toBe(5);
    expect(Array.from(initBuf.subarray(33 + sessLen))).toEqual([2, 0, 0, 0, 0]);

    session.sendVideoRtcp(new Uint8Array([0x81, 206, 0, 2]));
    const sentRtcp = rtpSock.sent[rtpSock.sent.length - 1]!;
    expect(sentRtcp.port).toBe(4200);
    expect(sentRtcp.buf[0]).toBe(ZRTP_PKT_TYPE.VIDEO_RTCP);

    session.close();
    expect(rtpSock.closeCount).toBe(1);
    expect(unusedRtcpSock.closeCount).toBe(1);
  });

  test("ZrtcRelaySession handshakes over framed TCP (protocol 3)", async () => {
    const net = await import("node:net");
    let sawFrame: { len: number; type: number; cmd: number; extraLen: number } | null = null;
    const server = net.createServer((sock) => {
      let rx = Buffer.alloc(0);
      sock.on("data", (d: Buffer | string) => {
        rx = Buffer.concat([rx, typeof d === "string" ? Buffer.from(d) : d]);
        while (rx.length >= 4) {
          const len = rx.readUInt32LE(0);
          if (rx.length < len) return;
          const p = rx.subarray(4, len);
          rx = rx.subarray(len);
          if (p.readUInt32LE(2) !== 0) continue;
          if (p[0] === ZRTP_PKT_TYPE.REQUEST && p.readUInt16LE(18) === ZRTP_CMD.INIT_CALL_CALLER) {
            const sessLen = p.readUInt16LE(29);
            sawFrame = { len, type: p[0], cmd: p.readUInt16LE(18), extraLen: p.readUInt16LE(31 + sessLen) };
            const resp = Buffer.alloc(33);
            resp[0] = ZRTP_PKT_TYPE.RESPONSE;
            resp[1] = 1;
            resp.writeUInt16LE(ZRTP_CMD.INIT_CALL_CALLER, 18);
            resp.writeInt32LE(0, 21);
            resp.writeUInt32LE(99, 25);
            resp.writeUInt32LE(5555, 29);
            const out = Buffer.alloc(4 + resp.length);
            out.writeUInt32LE(out.length, 0);
            resp.copy(out, 4);
            sock.write(out);
          }
        }
      });
    });
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
    const port = (server.address() as { port: number }).port;
    const session = new ZrtcRelaySession();
    try {
      const res = await session.connect({
        isCallee: false,
        userId: 1,
        partnerId: 2,
        callId: 99,
        sessionId: "tcp-sess",
        isVideo: false,
        tcp: true,
        servers: [{ rtpaddr: `127.0.0.1:${port}`, rtcpaddr: `127.0.0.1:${port + 1}` }],
        timeoutMs: 2000,
      });
      expect(res.token).toBe(5555);
      expect(res.rtcpAddress).toBe(res.rtpAddress);
      expect(sawFrame!.cmd).toBe(ZRTP_CMD.INIT_CALL_CALLER);
      expect(sawFrame!.extraLen).toBe(5);
    } finally {
      session.close();
      server.close();
    }
  });

  test("ZrtcRelaySession surfaces lastResCode in timeout diagnostics on non-zero relay error", async () => {
    class ErrorReplySocket extends EventEmitter {
      closed = false;
      send(msg: Uint8Array, port: number, address: string) {
        const buf = Buffer.from(msg);
        const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
        if (dv.getUint32(2, true) !== 0) return;
        if (buf[0] === ZRTP_PKT_TYPE.REQUEST && dv.getUint16(18, true) === ZRTP_CMD.INIT_CALL_CALLER) {
          queueMicrotask(() => {
            const resp = new Uint8Array(25);
            const rv = new DataView(resp.buffer);
            rv.setUint8(0, ZRTP_PKT_TYPE.RESPONSE);
            rv.setUint8(1, 1);
            rv.setUint16(18, ZRTP_CMD.INIT_CALL_CALLER, true);
            rv.setInt32(21, -5, true);
            this.emit("message", Buffer.from(resp), { address, port });
          });
        }
      }
      close() {
        this.closed = true;
      }
    }

    const session = new ZrtcRelaySession(() => new ErrorReplySocket());
    let errMsg = "";
    try {
      await session.connect({
        isCallee: false,
        userId: 1001,
        partnerId: 2002,
        callId: 99,
        sessionId: "sess-err",
        isVideo: false,
        servers: [{ rtpaddr: "120.138.74.196:8020", rtcpaddr: "120.138.74.196:4004" }],
        timeoutMs: 60,
      });
    } catch (err) {
      errMsg = err instanceof Error ? err.message : String(err);
    } finally {
      session.close();
    }
    expect(errMsg).toContain("lastResCode=-5");
    expect(errMsg).toContain("candidates=120.138.74.196:8020");
  });

  test("ZrtcRelaySession buildCandidates extracts rtpaddr2/rtcpaddr2", () => {
    const session = new ZrtcRelaySession();
    const list = session.buildCandidates({
      servers: [
        {
          rtpaddr: "171.244.25.87:4200",
          rtcpaddr: "171.244.25.87:4004",
          rtpaddr2: "171.244.25.87:4201",
          rtcpaddr2: "171.244.25.87:4005",
        },
        {
          rtpaddr: "171.244.25.87:4200",
          rtcpaddr: "171.244.25.87:4004",
        },
      ],
      rtpIP: "58.187.8.114:8020",
      rtcpIP: "58.187.8.114:4003",
    });
    expect(list.map((c) => c.rtpAddress)).toEqual([
      "171.244.25.87:4200",
      "171.244.25.87:4201",
      "58.187.8.114:8020",
    ]);
    expect(list[1]!.rtcpAddress).toBe("171.244.25.87:4005");
  });

  test("ZrtcRelaySession transport=auto races UDP and TCP and cleans up losing socket", async () => {
    const net = await import("node:net");
    const server = net.createServer((sock) => {
      let rx = Buffer.alloc(0);
      sock.on("data", (d: Buffer | string) => {
        rx = Buffer.concat([rx, typeof d === "string" ? Buffer.from(d) : d]);
        while (rx.length >= 4) {
          const len = rx.readUInt32LE(0);
          if (rx.length < len) return;
          const p = rx.subarray(4, len);
          rx = rx.subarray(len);
          if (p.readUInt32LE(2) !== 0) continue;
          if (p[0] === ZRTP_PKT_TYPE.REQUEST && p.readUInt16LE(18) === ZRTP_CMD.INIT_CALL_CALLER) {
            const resp = Buffer.alloc(33);
            resp[0] = ZRTP_PKT_TYPE.RESPONSE;
            resp[1] = 1;
            resp.writeUInt16LE(ZRTP_CMD.INIT_CALL_CALLER, 18);
            resp.writeInt32LE(0, 21);
            resp.writeUInt32LE(99, 25);
            resp.writeUInt32LE(6666, 29);
            const out = Buffer.alloc(4 + resp.length);
            out.writeUInt32LE(out.length, 0);
            resp.copy(out, 4);
            sock.write(out);
          }
        }
      });
    });
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
    const port = (server.address() as { port: number }).port;

    class SilentUdpSocket extends EventEmitter {
      closed = false;
      send() {}
      close() {
        this.closed = true;
      }
    }
    const udpSockets: SilentUdpSocket[] = [];
    const session = new ZrtcRelaySession(() => {
      const s = new SilentUdpSocket();
      udpSockets.push(s);
      return s;
    });

    try {
      const res = await session.connect({
        isCallee: false,
        userId: 1,
        partnerId: 2,
        callId: 99,
        sessionId: "race-sess",
        isVideo: false,
        transport: "auto",
        servers: [{ rtpaddr: `127.0.0.1:${port}`, rtcpaddr: `127.0.0.1:${port + 1}` }],
        timeoutMs: 2000,
      });
      expect(res.transport).toBe("tcp");
      expect(res.token).toBe(6666);
      expect(res.rtcpAddress).toBe(res.rtpAddress);
      expect(udpSockets.every((s) => s.closed)).toBe(true);
    } finally {
      session.close();
      server.close();
    }
  });
});
