import { describe, expect, test } from "bun:test";
import {
  FullIntraRequest,
  MediaStreamTrack,
  PictureLossIndication,
  RTCPeerConnection,
  RTCRtpCodecParameters,
  RtcpPacketConverter,
  RtcpPayloadSpecificFeedback,
} from "werift";
import {
  CallMediaGateway,
  RtpTimestampScaler,
  filterAndRewriteIceCandidate,
  parseZaloOpusClockRate,
  rewriteIceCandidateHost,
  rewriteRtpPayloadType,
  rewriteSdpIceCandidates,
} from "../src/accounts/call_media_gateway.ts";
import type { ZrtcRelaySession } from "../src/accounts/zrtc_session.ts";

describe("CallMediaGateway", () => {
  test("rewriteIceCandidateHost replaces private container IP with ZALOS_PUBLIC_HOST", () => {
    const orig =
      "candidate:1 1 udp 2122260223 172.18.0.2 40012 typ host generation 0";
    expect(rewriteIceCandidateHost(orig, "100.114.189.55")).toBe(
      "candidate:1 1 udp 2122260223 100.114.189.55 40012 typ host generation 0",
    );
    expect(rewriteIceCandidateHost(orig, "127.0.0.1")).toBe(orig);
    expect(rewriteIceCandidateHost(orig, "zalos.tail.ts.net")).toBe(orig);
  });

  test("rewriteRtpPayloadType preserves marker bit and updates 7-bit PT", () => {
    const rtp = new Uint8Array([0x80, 0x80 | 96, 0x00, 0x01]);
    const rewritten = rewriteRtpPayloadType(rtp, 111);
    expect(rewritten[1]).toBe(0x80 | 111);
    expect(rtp[1]).toBe(0x80 | 96); // does not mutate input
  });

  test("negotiates SDP offer/answer and attaches ZRTC bridge", async () => {
    const gw = new CallMediaGateway();
    const sentToZrtc: Uint8Array[] = [];
    const mockZrtc = {
      sendAudioRtp: (p: Uint8Array) => sentToZrtc.push(p),
      sendVideoRtp: () => {},
      close: () => {},
      onAudioRtp: undefined as ((p: Uint8Array) => void) | undefined,
      onVideoRtp: undefined as ((p: Uint8Array) => void) | undefined,
    } as unknown as ZrtcRelaySession;

    gw.attachZrtc("main", "1001", mockZrtc);

    const client = new RTCPeerConnection({
      codecs: {
        audio: [new RTCRtpCodecParameters({ mimeType: "audio/opus", clockRate: 48000, channels: 2 })],
        video: [
          new RTCRtpCodecParameters({
            mimeType: "video/H264",
            clockRate: 90000,
            rtcpFeedback: [{ type: "nack" }],
            parameters: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
          }),
        ],
      },
    });
    client.addTrack(new MediaStreamTrack({ kind: "audio" }));
    client.addTrack(new MediaStreamTrack({ kind: "video" }));
    const offer = await client.createOffer();
    await client.setLocalDescription(offer);

    const ans = await gw.handleClientOffer({
      slot: "main",
      callId: "1001",
      deviceId: "dev-1",
      sdp: offer.sdp,
      media: "video",
      onServerIce: () => {},
    });
    expect(ans.type).toBe("answer");
    expect(ans.sdp).toContain("m=audio");
    expect(ans.sdp).toContain("m=video");
    await client.setRemoteDescription({ type: "answer", sdp: ans.sdp });

    const bridge = gw.getBridge("main", "1001");
    expect(bridge?.audioOut).toBeDefined();
    expect(bridge?.videoOut).toBeDefined();

    // Simulate incoming ZRTC audio RTP flowing into server outTrack without throwing
    expect(() => mockZrtc.onAudioRtp?.(new Uint8Array([0x80, 111, 0, 1, 0, 0, 0, 10, 0, 0, 0, 1, 1, 2, 3]))).not.toThrow();

    await client.close();
    await gw.closeSlot("main");
    expect(gw.getBridge("main", "1001")).toBeUndefined();
  });

  test("filterAndRewriteIceCandidate and rewriteSdpIceCandidates rewrite private IPs and drop loopback / out-of-range srflx", () => {
    const portRange: [number, number] = [40000, 40050];
    const sdp = [
      "v=0",
      "o=- 1 2 IN IP4 127.0.0.1",
      "s=-",
      "c=IN IP4 192.168.148.2",
      "m=audio 40002 UDP/TLS/RTP/SAVPF 111",
      "c=IN IP4 192.168.148.2",
      "a=candidate:1 1 udp 2122260223 192.168.148.2 40002 typ host generation 0",
      "a=candidate:2 1 udp 2122260222 127.0.0.1 40003 typ host generation 0",
      "a=candidate:3 1 udp 1686052607 203.0.113.5 54321 typ srflx raddr 192.168.148.2 rport 40002",
      "a=candidate:4 1 udp 1686052606 203.0.113.5 40010 typ srflx raddr 192.168.148.2 rport 40010",
      "m=video 0 UDP/TLS/RTP/SAVPF 102",
      "c=IN IP4 0.0.0.0",
      "a=candidate:1 1 udp 2122260223 192.168.148.2 40002 typ host generation 0",
      "",
    ].join("\r\n");

    const rewritten = rewriteSdpIceCandidates(sdp, "100.114.189.55", portRange);
    expect(rewritten).toContain("\r\n");
    expect(rewritten).toContain("c=IN IP4 100.114.189.55");
    expect(rewritten).toContain("c=IN IP4 0.0.0.0");
    expect(rewritten).toContain(
      "a=candidate:1 1 udp 2122260223 100.114.189.55 40002 typ host generation 0",
    );
    expect(rewritten).not.toContain("192.168.148.2");
    expect(rewritten).not.toContain(" 127.0.0.1 40003 typ host");
    expect(rewritten).not.toContain(" 54321 typ srflx");
    expect(rewritten).toContain(
      "a=candidate:4 1 udp 1686052606 203.0.113.5 40010 typ srflx raddr 0.0.0.0 rport 40010",
    );

    expect(rewriteSdpIceCandidates(sdp, undefined, portRange)).toBe(sdp);
    expect(rewriteSdpIceCandidates(sdp, "127.0.0.1", portRange)).toBe(sdp);
    expect(
      filterAndRewriteIceCandidate(
        "candidate:1 1 udp 2122260223 192.168.148.2 40002 typ host",
        "100.114.189.55",
        portRange,
      ),
    ).toBe("candidate:1 1 udp 2122260223 100.114.189.55 40002 typ host");
  });

  test("handleClientOffer rewrites localDescription SDP candidates when ZALOS_PUBLIC_HOST is set", async () => {
    const prevHost = process.env.ZALOS_PUBLIC_HOST;
    const prevMin = process.env.ZALOS_RTC_PORT_MIN;
    const prevMax = process.env.ZALOS_RTC_PORT_MAX;
    process.env.ZALOS_PUBLIC_HOST = "100.114.189.55";
    process.env.ZALOS_RTC_PORT_MIN = "40000";
    process.env.ZALOS_RTC_PORT_MAX = "40050";

    const gw = new CallMediaGateway();
    const client = new RTCPeerConnection({
      codecs: {
        audio: [new RTCRtpCodecParameters({ mimeType: "audio/opus", clockRate: 48000, channels: 2 })],
      },
    });
    client.addTrack(new MediaStreamTrack({ kind: "audio" }));
    try {
      const offer = await client.createOffer();
      await client.setLocalDescription(offer);
      const ans = await gw.handleClientOffer({
        slot: "main",
        callId: "1002",
        deviceId: "dev-1",
        sdp: offer.sdp,
        media: "voice",
        onServerIce: () => {},
      });
      const candidateLines = ans.sdp
        .split(/\r?\n/)
        .filter((l) => l.startsWith("a=candidate:"));
      for (const line of candidateLines) {
        const tokens = line.split(" ");
        if (tokens[7] === "host") {
          expect(tokens[4]).not.toBe("127.0.0.1");
          expect(tokens[4]).not.toMatch(/^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/);
        }
      }
    } finally {
      if (prevHost === undefined) delete process.env.ZALOS_PUBLIC_HOST;
      else process.env.ZALOS_PUBLIC_HOST = prevHost;
      if (prevMin === undefined) delete process.env.ZALOS_RTC_PORT_MIN;
      else process.env.ZALOS_RTC_PORT_MIN = prevMin;
      if (prevMax === undefined) delete process.env.ZALOS_RTC_PORT_MAX;
      else process.env.ZALOS_RTC_PORT_MAX = prevMax;
      await client.close();
      await gw.closeSlot("main");
    }
  });

  test("CallMediaGateway forwards RTCP PLI/FIR bidirectionally and rescales Opus RTP timestamps", async () => {
    const gw = new CallMediaGateway();
    const sentAudioRtp: Uint8Array[] = [];
    const sentVideoRtcp: Uint8Array[] = [];
    const mockZrtc = {
      sendAudioRtp: (p: Uint8Array) => sentAudioRtp.push(p),
      sendVideoRtp: () => {},
      sendAudioRtcp: () => {},
      sendVideoRtcp: (p: Uint8Array) => sentVideoRtcp.push(p),
      close: () => {},
      onAudioRtp: undefined as ((p: Uint8Array) => void) | undefined,
      onVideoRtp: undefined as ((p: Uint8Array) => void) | undefined,
      onAudioRtcp: undefined as ((p: Uint8Array) => void) | undefined,
      onVideoRtcp: undefined as ((p: Uint8Array) => void) | undefined,
    } as unknown as ZrtcRelaySession;

    gw.attachZrtc("main", "1003", mockZrtc);

    const client = new RTCPeerConnection({
      codecs: {
        audio: [new RTCRtpCodecParameters({ mimeType: "audio/opus", clockRate: 48000, channels: 2 })],
        video: [
          new RTCRtpCodecParameters({
            mimeType: "video/H264",
            clockRate: 90000,
            rtcpFeedback: [
              { type: "nack" },
              { type: "nack", parameter: "pli" },
              { type: "ccm", parameter: "fir" },
            ],
            parameters: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
          }),
        ],
      },
    });
    client.addTrack(new MediaStreamTrack({ kind: "audio" }));
    client.addTrack(new MediaStreamTrack({ kind: "video" }));
    const offer = await client.createOffer();
    await client.setLocalDescription(offer);

    const ans = await gw.handleClientOffer({
      slot: "main",
      callId: "1003",
      deviceId: "dev-1",
      sdp: offer.sdp,
      media: "video",
      onServerIce: () => {},
    });
    await client.setRemoteDescription({ type: "answer", sdp: ans.sdp });

    const bridge = gw.getBridge("main", "1003")!;
    // Simulate incoming Zalo video RTP so remoteVideoSsrc is learned
    const remoteVidRtp = Buffer.alloc(14);
    remoteVidRtp[0] = 0x80;
    remoteVidRtp[1] = 102;
    remoteVidRtp.writeUInt32BE(0x11223344, 8);
    mockZrtc.onVideoRtp?.(remoteVidRtp);
    expect(bridge.remoteVideoSsrc).toBe(0x11223344);

    // Outgoing keyframe requests (PLI & FIR) forward to ZRTC with learned remoteVideoSsrc
    bridge.videoSender!.onKeyFrameRequest.execute("pli");
    bridge.videoSender!.onKeyFrameRequest.execute("fir");
    expect(sentVideoRtcp.length).toBe(2);
    const parsedPli = RtcpPacketConverter.deSerialize(Buffer.from(sentVideoRtcp[0]!))[0] as RtcpPayloadSpecificFeedback;
    expect(parsedPli.feedback).toBeInstanceOf(PictureLossIndication);
    expect((parsedPli.feedback as PictureLossIndication).mediaSsrc).toBe(0x11223344);
    const parsedFir = RtcpPacketConverter.deSerialize(Buffer.from(sentVideoRtcp[1]!))[0] as RtcpPayloadSpecificFeedback;
    expect(parsedFir.feedback).toBeInstanceOf(FullIntraRequest);
    expect((parsedFir.feedback as FullIntraRequest).fir[0]?.ssrc).toBe(0x11223344);

    // Inbound ZRTC PLI and FIR invoke videoReceiver.sendRtcpPLI(clientVideoSsrc)
    bridge.clientVideoSsrc = 0x55667788;
    const pliCalls: number[] = [];
    bridge.videoReceiver!.sendRtcpPLI = async (ssrc: number) => {
      pliCalls.push(ssrc);
    };
    const inboundPli = new RtcpPayloadSpecificFeedback({
      feedback: new PictureLossIndication({ senderSsrc: 1, mediaSsrc: 0x55667788 }),
    }).serialize();
    const inboundFir = new RtcpPayloadSpecificFeedback({
      feedback: new FullIntraRequest({
        senderSsrc: 1,
        mediaSsrc: 0x55667788,
        fir: [{ ssrc: 0x55667788, sequenceNumber: 1 }],
      }),
    }).serialize();
    mockZrtc.onVideoRtcp?.(inboundPli);
    mockZrtc.onVideoRtcp?.(inboundFir);
    expect(pliCalls).toEqual([0x55667788, 0x55667788]);

    // Inbound ZRTC audio RTP (16 kHz) scales timestamps 3x to 48 kHz for WebRTC outTrack
    const receivedOutTs: number[] = [];
    bridge.audioOut!.onReceiveRtp.subscribe((pkt) => {
      receivedOutTs.push(pkt.header.timestamp);
    });
    const makeAudioPkt = (ts: number) => {
      const p = Buffer.alloc(16);
      p[0] = 0x80;
      p[1] = 111;
      p.writeUInt32BE(ts >>> 0, 4);
      p.writeUInt32BE(0x99887766, 8);
      return p;
    };
    mockZrtc.onAudioRtp?.(makeAudioPkt(1000));
    mockZrtc.onAudioRtp?.(makeAudioPkt(1320));
    expect(receivedOutTs).toEqual([1000, 1960]);

    // Outgoing WebRTC audio RTP (48 kHz) scales timestamps 1/3x to 16 kHz for ZRTC
    const audioRxTrack = bridge.audioReceiver!.track;
    const inPkt1 = makeAudioPkt(2000);
    const inPkt2 = makeAudioPkt(2960);
    const { RtpPacket } = await import("werift");
    audioRxTrack.onReceiveRtp.execute(RtpPacket.deSerialize(inPkt1));
    audioRxTrack.onReceiveRtp.execute(RtpPacket.deSerialize(inPkt2));
    expect(sentAudioRtp).toHaveLength(2);
    expect(Buffer.from(sentAudioRtp[0]!).readUInt32BE(4)).toBe(2000);
    expect(Buffer.from(sentAudioRtp[1]!).readUInt32BE(4)).toBe(2320);

    await client.close();
    await gw.closeSlot("main");
  });

  test("RtpTimestampScaler handles wraparound, out-of-order packets, peekScale, and codec parsing", () => {
    const down = new RtpTimestampScaler(48000, 16000);
    expect(down.scale(0xfffffe00)).toBe(0xfffffe00);
    expect(down.peekScale(0xfffffe00 + 960)).toBe((0xfffffe00 + 320) >>> 0);
    // peekScale must not mutate state
    expect(down.scale((0xfffffe00 + 960) >>> 0)).toBe((0xfffffe00 + 320) >>> 0);
    // Out-of-order: +1920 then -960
    expect(down.scale((0xfffffe00 + 2880) >>> 0)).toBe((0xfffffe00 + 960) >>> 0);
    expect(down.scale((0xfffffe00 + 1920) >>> 0)).toBe((0xfffffe00 + 640) >>> 0);

    expect(parseZaloOpusClockRate('[{"name":"opus/16000/1","payload":111}]')).toBe(16000);
    expect(parseZaloOpusClockRate('[{"name":"opus/48000/2","payload":111}]')).toBe(48000);
    expect(parseZaloOpusClockRate("bad-json")).toBe(16000);
  });
});
