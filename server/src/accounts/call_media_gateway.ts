import { isIP } from "node:net";
import {
  FullIntraRequest,
  GenericNack,
  MediaStreamTrack,
  PictureLossIndication,
  RTCIceCandidate,
  RTCPeerConnection,
  RTCRtpCodecParameters,
  RtcpPacketConverter,
  RtcpPayloadSpecificFeedback,
  RtcpReceiverInfo,
  RtcpRrPacket,
  RtcpSenderInfo,
  RtcpSrPacket,
  RtcpTransportLayerFeedback,
  RtpPacket,
  type RTCRtpReceiver,
  type RTCRtpSender,
  type RtcpPacket,
} from "werift";
import type { CallMediaKind } from "../gateway/types.ts";
import {
  WebrtcH264ToZaloRepacketizer,
  ZaloH264ToWebrtcRepacketizer,
  ZALO_H264_DELTA_PT,
} from "./h264_rtp_transform.ts";
import { ZrtcRelaySession } from "./zrtc_session.ts";

export const ZALO_OPUS_PT = 112;
export const ZALO_H264_PT = ZALO_H264_DELTA_PT;
export const ZALO_OPUS_CLOCK_RATE = 16000;
export const WEBRTC_OPUS_CLOCK_RATE = 48000;

export interface IceCandidateJson {
  candidate: string;
  sdpMid?: string | null;
  sdpMLineIndex?: number | null;
}

export function parseZaloOpusClockRate(codecRaw: unknown): number {
  let entries: unknown = codecRaw;
  if (typeof codecRaw === "string" && codecRaw.trim() !== "") {
    try {
      entries = JSON.parse(codecRaw);
    } catch {
      return ZALO_OPUS_CLOCK_RATE;
    }
  }
  if (!Array.isArray(entries)) return ZALO_OPUS_CLOCK_RATE;
  for (const item of entries) {
    if (!item || typeof item !== "object") continue;
    const name = (item as { name?: unknown }).name;
    if (typeof name !== "string") continue;
    const parts = name.toLowerCase().split("/");
    if (parts[0] === "opus" && parts[1]) {
      const rate = Number(parts[1]);
      if (Number.isInteger(rate) && rate > 0) return rate;
    }
  }
  return ZALO_OPUS_CLOCK_RATE;
}

export function parseZaloOpusPayloadType(codecRaw: unknown): number {
  let entries: unknown = codecRaw;
  if (typeof codecRaw === "string" && codecRaw.trim() !== "") {
    try {
      entries = JSON.parse(codecRaw);
    } catch {
      return ZALO_OPUS_PT;
    }
  }
  if (!Array.isArray(entries)) return ZALO_OPUS_PT;
  for (const item of entries) {
    if (!item || typeof item !== "object") continue;
    const name = (item as { name?: unknown }).name;
    if (typeof name !== "string" || !name.toLowerCase().startsWith("opus/")) continue;
    const payload = Number((item as { payload?: unknown }).payload);
    if (Number.isInteger(payload) && payload >= 0 && payload <= 127) return payload;
  }
  return ZALO_OPUS_PT;
}

/**
 * Rescales 32-bit wrapping RTP timestamps across differing codec clock rates
 * (e.g. WebRTC Opus 48 kHz <-> Zalo Opus 16 kHz) while preserving packet deltas.
 */
export class RtpTimestampScaler {
  private lastIn: number | null = null;
  private unwrappedDelta = 0n;
  private baseOut = 0n;

  constructor(
    readonly inRate: number,
    readonly outRate: number,
  ) {}

  scale(ts: number): number {
    const u32 = ts >>> 0;
    if (this.inRate === this.outRate || this.inRate <= 0 || this.outRate <= 0) {
      return u32;
    }
    if (this.lastIn === null) {
      this.lastIn = u32;
      this.unwrappedDelta = 0n;
      this.baseOut = BigInt(u32);
      return u32;
    }
    const delta = (u32 - this.lastIn) | 0;
    this.lastIn = u32;
    this.unwrappedDelta += BigInt(delta);
    const scaled =
      (this.baseOut + (this.unwrappedDelta * BigInt(this.outRate)) / BigInt(this.inRate)) &
      0xffffffffn;
    return Number(scaled);
  }

  /** Computes the scaled timestamp relative to the active stream without advancing state. */
  peekScale(ts: number): number {
    const u32 = ts >>> 0;
    if (this.inRate === this.outRate || this.inRate <= 0 || this.outRate <= 0) {
      return u32;
    }
    if (this.lastIn === null) {
      return u32;
    }
    const delta = (u32 - this.lastIn) | 0;
    const totalDelta = this.unwrappedDelta + BigInt(delta);
    const scaled =
      (this.baseOut + (totalDelta * BigInt(this.outRate)) / BigInt(this.inRate)) &
      0xffffffffn;
    return Number(scaled);
  }

  reset(): void {
    this.lastIn = null;
    this.unwrappedDelta = 0n;
    this.baseOut = 0n;
  }
}

export function rewriteRtpHeader(
  rawRtp: Uint8Array,
  targetPt: number,
  timestamp?: number,
): Buffer {
  const copy = Buffer.from(rawRtp);
  if (copy.length >= 2) {
    copy[1] = (copy[1]! & 0x80) | (targetPt & 0x7f);
  }
  if (timestamp !== undefined && copy.length >= 12) {
    copy.writeUInt32BE(timestamp >>> 0, 4);
  }
  return copy;
}

export function rewriteRtpPayloadType(
  rawRtp: Uint8Array,
  targetPt: number,
): Buffer {
  return rewriteRtpHeader(rawRtp, targetPt);
}

export function isPrivateIpv4(ip: string): boolean {
  const parts = ip.split(".").map(Number);
  if (parts.length !== 4 || parts.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) {
    return false;
  }
  const [a, b] = parts as [number, number, number, number];
  if (a === 10) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && b === 168) return true;
  if (a === 169 && b === 254) return true;
  return false;
}

function shouldRewritePublicHost(publicHost: string | undefined): publicHost is string {
  return Boolean(publicHost && isIP(publicHost) === 4 && publicHost !== "127.0.0.1");
}

/**
 * Rewrites private container bridge host ICE candidate IPs (e.g. `172.18.0.2`)
 * to `publicHost` (e.g. Tailscale IP `100.114.189.55`) so mobile clients can reach
 * the published UDP port range directly.
 */
export function rewriteIceCandidateHost(
  candidateStr: string,
  publicHost: string | undefined,
): string {
  if (!shouldRewritePublicHost(publicHost)) {
    return candidateStr;
  }
  const hasPrefix = candidateStr.startsWith("a=");
  const raw = hasPrefix ? candidateStr.slice(2) : candidateStr;
  // SDP candidate format: candidate:<foundation> <component> <proto> <prio> <ip> <port> typ <type> ...
  const tokens = raw.split(" ");
  if (tokens.length >= 8 && tokens[6] === "typ" && tokens[7] === "host") {
    const ip = tokens[4]!;
    if (isIP(ip) === 4 && isPrivateIpv4(ip)) {
      tokens[4] = publicHost;
      const rewritten = tokens.join(" ");
      return hasPrefix ? `a=${rewritten}` : rewritten;
    }
  }
  return candidateStr;
}

export function filterAndRewriteIceCandidate(
  candidateStr: string,
  publicHost: string | undefined,
  portRange?: [number, number],
): string | null {
  if (!shouldRewritePublicHost(publicHost)) {
    return candidateStr;
  }
  const hasPrefix = candidateStr.startsWith("a=");
  const raw = hasPrefix ? candidateStr.slice(2) : candidateStr;
  const tokens = raw.split(" ");
  if (tokens.length < 8 || tokens[6] !== "typ") {
    return candidateStr;
  }
  const ip = tokens[4]!;
  const port = Number(tokens[5]);
  const candType = tokens[7]!;

  if (candType === "host") {
    if (ip === "127.0.0.1" || ip === "::1") {
      return null;
    }
    if (isIP(ip) === 4 && isPrivateIpv4(ip)) {
      tokens[4] = publicHost;
    }
    const rewritten = tokens.join(" ");
    return hasPrefix ? `a=${rewritten}` : rewritten;
  }

  if (candType === "srflx") {
    if (portRange && (!Number.isInteger(port) || port < portRange[0] || port > portRange[1])) {
      return null;
    }
    for (let i = 8; i + 1 < tokens.length; i++) {
      if (tokens[i] === "raddr") {
        const raddr = tokens[i + 1]!;
        if (isIP(raddr) === 4 && (isPrivateIpv4(raddr) || raddr === "127.0.0.1")) {
          tokens[i + 1] = "0.0.0.0";
        }
      }
    }
    const rewritten = tokens.join(" ");
    return hasPrefix ? `a=${rewritten}` : rewritten;
  }

  return candidateStr;
}

export function rewriteSdpIceCandidates(
  sdp: string,
  publicHost: string | undefined,
  portRange?: [number, number],
): string {
  if (!shouldRewritePublicHost(publicHost)) {
    return sdp;
  }
  const eol = sdp.includes("\r\n") ? "\r\n" : "\n";
  const lines = sdp.split(eol);
  const out: string[] = [];
  let seenCandidates = new Set<string>();

  for (const line of lines) {
    if (line.startsWith("m=")) {
      seenCandidates = new Set<string>();
      out.push(line);
      continue;
    }
    if (line.startsWith("a=candidate:")) {
      const rewritten = filterAndRewriteIceCandidate(line, publicHost, portRange);
      if (!rewritten || seenCandidates.has(rewritten)) {
        continue;
      }
      seenCandidates.add(rewritten);
      out.push(rewritten);
      continue;
    }
    if (line.startsWith("c=IN IP4 ")) {
      const ip = line.slice("c=IN IP4 ".length).trim();
      if (ip !== "0.0.0.0" && isIP(ip) === 4 && isPrivateIpv4(ip)) {
        out.push(`c=IN IP4 ${publicHost}`);
        continue;
      }
    }
    out.push(line);
  }
  return out.join(eol);
}

export function parseRtcPortRange(): [number, number] {
  const min = Number(process.env.ZALOS_RTC_PORT_MIN ?? 40000);
  const max = Number(process.env.ZALOS_RTC_PORT_MAX ?? 40050);
  if (Number.isInteger(min) && Number.isInteger(max) && min > 0 && max >= min) {
    return [min, max];
  }
  return [40000, 40050];
}

export function parseIceServers(): Array<{ urls: string | string[]; username?: string; credential?: string }> {
  const raw = process.env.ZALOS_ICE_SERVERS;
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed)) return parsed;
    } catch {
      // fall through to default STUN
    }
  }
  return [{ urls: "stun:stun.l.google.com:19302" }];
}

export interface CallMediaBridge {
  slot: string;
  callId: string;
  deviceId: string;
  pc?: RTCPeerConnection;
  audioOut?: MediaStreamTrack;
  videoOut?: MediaStreamTrack;
  audioSender?: RTCRtpSender;
  videoSender?: RTCRtpSender;
  audioReceiver?: RTCRtpReceiver;
  videoReceiver?: RTCRtpReceiver;
  audioPt: number;
  videoPt: number;
  zaloAudioPt: number;
  zaloAudioClockRate: number;
  remoteAudioSsrc?: number;
  remoteVideoSsrc?: number;
  clientVideoSsrc?: number;
  firSeq: number;
  audioOutTsScaler: RtpTimestampScaler;
  audioInTsScaler: RtpTimestampScaler;
  webrtcToZaloVideo: WebrtcH264ToZaloRepacketizer;
  zaloToWebrtcVideo: ZaloH264ToWebrtcRepacketizer;
  mediaStats: {
    clientAudioRtp: number;
    zaloAudioRtp: number;
    clientVideoRtp: number;
    zaloVideoRtp: number;
    zaloVideoFrames: number;
    clientVideoFrames: number;
  };
  mediaStatsTimer?: ReturnType<typeof setInterval>;
  zrtc?: ZrtcRelaySession;
}

export class CallMediaGateway {
  private readonly bridges = new Map<string, CallMediaBridge>();
  private readonly onClosedCallbacks = new Map<string, () => void>();

  private keyOf(slot: string, callId: string): string {
    return `${slot}\0${callId}`;
  }

  getBridge(slot: string, callId: string): CallMediaBridge | undefined {
    return this.bridges.get(this.keyOf(slot, callId));
  }

  private ensureBridge(slot: string, callId: string, deviceId = ""): CallMediaBridge {
    const k = this.keyOf(slot, callId);
    let b = this.bridges.get(k);
    if (!b) {
      b = {
        slot,
        callId,
        deviceId,
        audioPt: ZALO_OPUS_PT,
        videoPt: ZALO_H264_PT,
        zaloAudioPt: ZALO_OPUS_PT,
        zaloAudioClockRate: ZALO_OPUS_CLOCK_RATE,
        firSeq: 0,
        audioOutTsScaler: new RtpTimestampScaler(
          WEBRTC_OPUS_CLOCK_RATE,
          ZALO_OPUS_CLOCK_RATE,
        ),
        audioInTsScaler: new RtpTimestampScaler(
          ZALO_OPUS_CLOCK_RATE,
          WEBRTC_OPUS_CLOCK_RATE,
        ),
        webrtcToZaloVideo: new WebrtcH264ToZaloRepacketizer(),
        zaloToWebrtcVideo: new ZaloH264ToWebrtcRepacketizer(),
        mediaStats: {
          clientAudioRtp: 0,
          zaloAudioRtp: 0,
          clientVideoRtp: 0,
          zaloVideoRtp: 0,
          zaloVideoFrames: 0,
          clientVideoFrames: 0,
        },
      };
      this.bridges.set(k, b);
    } else if (deviceId) {
      b.deviceId = deviceId;
    }
    return b;
  }

  attachZrtc(
    slot: string,
    callId: string,
    zrtc: ZrtcRelaySession,
    opts?: { audioClockRate?: number; audioPayloadType?: number },
  ): void {
    const b = this.ensureBridge(slot, callId);
    if (b.zrtc && b.zrtc !== zrtc) {
      b.zrtc.close();
    }
    if (opts?.audioClockRate && opts.audioClockRate > 0) {
      b.zaloAudioClockRate = opts.audioClockRate;
    }
    if (
      opts?.audioPayloadType !== undefined &&
      Number.isInteger(opts.audioPayloadType) &&
      opts.audioPayloadType >= 0 &&
      opts.audioPayloadType <= 127
    ) {
      b.zaloAudioPt = opts.audioPayloadType;
    }
    b.audioOutTsScaler = new RtpTimestampScaler(
      WEBRTC_OPUS_CLOCK_RATE,
      b.zaloAudioClockRate,
    );
    b.audioInTsScaler = new RtpTimestampScaler(
      b.zaloAudioClockRate,
      WEBRTC_OPUS_CLOCK_RATE,
    );
    b.zrtc = zrtc;
    if (b.mediaStatsTimer) clearInterval(b.mediaStatsTimer);
    b.mediaStatsTimer = setInterval(() => {
      const stats = b.mediaStats;
      if (
        stats.clientAudioRtp === 0 &&
        stats.zaloAudioRtp === 0 &&
        stats.clientVideoRtp === 0 &&
        stats.zaloVideoRtp === 0
      ) {
        return;
      }
      console.info(JSON.stringify({
        ts: new Date().toISOString(),
        kind: "info",
        context: "zrtc.media.stats",
        slot: b.slot,
        callId: b.callId,
        ...stats,
      }));
    }, 5_000);
    b.mediaStatsTimer.unref?.();

    zrtc.onAudioRtp = (rtp) => {
      if (!b.audioOut) return;
      try {
        b.mediaStats.zaloAudioRtp++;
        if (rtp.length >= 12) {
          const dv = new DataView(rtp.buffer, rtp.byteOffset, rtp.byteLength);
          b.remoteAudioSsrc = dv.getUint32(8, false);
          const scaledTs = b.audioInTsScaler.scale(dv.getUint32(4, false));
          b.audioOut.writeRtp(rewriteRtpHeader(rtp, b.audioPt, scaledTs));
        } else {
          b.audioOut.writeRtp(rewriteRtpPayloadType(rtp, b.audioPt));
        }
      } catch {
        // ignore transient write errors when peer is tearing down
      }
    };
    zrtc.onVideoRtp = (rtp) => {
      if (!b.videoOut) return;
      try {
        b.mediaStats.zaloVideoRtp++;
        if (rtp.length >= 12) {
          const dv = new DataView(rtp.buffer, rtp.byteOffset, rtp.byteLength);
          b.remoteVideoSsrc = dv.getUint32(8, false);
        }
        const packets = b.zaloToWebrtcVideo.processRtp(rtp, b.videoPt);
        if (packets.length > 0) b.mediaStats.zaloVideoFrames++;
        for (const packet of packets) {
          b.videoOut.writeRtp(packet);
        }
      } catch {
        // ignore transient write errors when peer is tearing down
      }
    };
    zrtc.onAudioRtcp = (rtcp) => {
      const receiver = b.audioReceiver;
      if (!receiver?.transport || receiver.transport.state !== "connected") return;
      let packets: RtcpPacket[];
      try {
        packets = RtcpPacketConverter.deSerialize(Buffer.from(rtcp));
      } catch {
        return;
      }
      for (const pkt of packets) {
        if (pkt instanceof RtcpTransportLayerFeedback) {
          void receiver.transport.sendRtcp([pkt]).catch(() => {});
        }
      }
    };
    zrtc.onVideoRtcp = (rtcp) => {
      const receiver = b.videoReceiver;
      if (!receiver) return;
      let packets: RtcpPacket[];
      try {
        packets = RtcpPacketConverter.deSerialize(Buffer.from(rtcp));
      } catch {
        return;
      }
      const mediaSsrc = b.clientVideoSsrc ?? receiver.track.ssrc;
      for (const pkt of packets) {
        if (
          pkt instanceof RtcpPayloadSpecificFeedback &&
          (pkt.feedback instanceof PictureLossIndication ||
            pkt.feedback instanceof FullIntraRequest)
        ) {
          if (mediaSsrc !== undefined) {
            void receiver.sendRtcpPLI(mediaSsrc).catch(() => {});
          }
        } else if (
          pkt instanceof RtcpTransportLayerFeedback &&
          pkt.feedback instanceof GenericNack &&
          receiver.transport?.state === "connected" &&
          b.clientVideoSsrc !== undefined &&
          pkt.feedback.mediaSourceSsrc === b.clientVideoSsrc
        ) {
          void receiver.transport.sendRtcp([pkt]).catch(() => {});
        }
      }
    };
  }

  async handleClientOffer(opts: {
    slot: string;
    callId: string;
    deviceId: string;
    sdp: string;
    media: CallMediaKind;
    onServerIce: (candidate: IceCandidateJson) => void;
  }): Promise<{
    sdp: string;
    type: "answer";
    iceServers: Array<{ urls: string | string[]; username?: string; credential?: string }>;
  }> {
    const bridge = this.ensureBridge(opts.slot, opts.callId, opts.deviceId);
    if (bridge.pc) {
      try {
        await bridge.pc.close();
      } catch {}
    }
    bridge.audioOutTsScaler.reset();

    const iceServers = parseIceServers();
    const portRange = parseRtcPortRange();
    const pc = new RTCPeerConnection({
      iceServers,
      icePortRange: portRange,
      codecs: {
        audio: [
          new RTCRtpCodecParameters({
            mimeType: "audio/opus",
            clockRate: 48000,
            channels: 2,
          }),
        ],
        video: [
          new RTCRtpCodecParameters({
            mimeType: "video/H264",
            clockRate: 90000,
            rtcpFeedback: [
              { type: "nack" },
              { type: "nack", parameter: "pli" },
              { type: "ccm", parameter: "fir" },
            ],
            parameters:
              "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
          }),
        ],
      },
    });
    bridge.pc = pc;

    const publicHost = process.env.ZALOS_PUBLIC_HOST;
    pc.onIceCandidate.subscribe((cand) => {
      if (!cand?.candidate) return;
      const rewritten = filterAndRewriteIceCandidate(
        cand.candidate,
        publicHost,
        portRange,
      );
      if (!rewritten) return;
      opts.onServerIce({
        candidate: rewritten,
        sdpMid: cand.sdpMid ?? null,
        sdpMLineIndex: cand.sdpMLineIndex ?? null,
      });
    });

    await pc.setRemoteDescription({ type: "offer", sdp: opts.sdp });

    for (const tr of pc.getTransceivers()) {
      if (tr.kind !== "audio" && tr.kind !== "video") continue;
      if (tr.kind === "video" && opts.media !== "video") {
        tr.direction = "inactive";
        continue;
      }
      tr.direction = "sendrecv";
      const outTrack = new MediaStreamTrack({ kind: tr.kind });
      await tr.sender.replaceTrack(outTrack);

      const pt = tr.codecs?.[0]?.payloadType;
      if (tr.kind === "audio") {
        bridge.audioOut = outTrack;
        bridge.audioSender = tr.sender;
        bridge.audioReceiver = tr.receiver;
        if (typeof pt === "number") bridge.audioPt = pt;
        tr.receiver.track.onReceiveRtp.subscribe((pkt: RtpPacket) => {
          if (!bridge.zrtc) return;
          try {
            bridge.mediaStats.clientAudioRtp++;
            const scaledTs = bridge.audioOutTsScaler.scale(pkt.header.timestamp);
            const raw = rewriteRtpHeader(pkt.serialize(), bridge.zaloAudioPt, scaledTs);
            bridge.zrtc.sendAudioRtp(raw);
          } catch {
            // ignore dropped frame
          }
        });
        tr.sender.onRtcp.subscribe((pkt: RtcpPacket) => {
          if (!bridge.zrtc) return;
          if (pkt instanceof RtcpRrPacket) {
            const remoteSsrc = bridge.remoteAudioSsrc;
            const reports = pkt.reports.map((r) =>
              remoteSsrc !== undefined && r.ssrc === tr.sender.ssrc
                ? new RtcpReceiverInfo({
                    ssrc: remoteSsrc,
                    fractionLost: r.fractionLost,
                    packetsLost: r.packetsLost,
                    highestSequence: r.highestSequence,
                    jitter: r.jitter,
                    lsr: r.lsr,
                    dlsr: r.dlsr,
                  })
                : r,
            );
            bridge.zrtc.sendAudioRtcp(
              new RtcpRrPacket({ ssrc: pkt.ssrc, reports }).serialize(),
            );
          }
        });
        tr.receiver.onRtcp.subscribe((pkt: RtcpPacket) => {
          if (!bridge.zrtc) return;
          if (pkt instanceof RtcpSrPacket) {
            const sr =
              bridge.zaloAudioClockRate !== WEBRTC_OPUS_CLOCK_RATE
                ? new RtcpSrPacket({
                    ssrc: pkt.ssrc,
                    senderInfo: new RtcpSenderInfo({
                      ntpTimestamp: pkt.senderInfo.ntpTimestamp,
                      rtpTimestamp: bridge.audioOutTsScaler.peekScale(
                        pkt.senderInfo.rtpTimestamp,
                      ),
                      packetCount: pkt.senderInfo.packetCount,
                      octetCount: pkt.senderInfo.octetCount,
                    }),
                    reports: pkt.reports,
                  })
                : pkt;
            bridge.zrtc.sendAudioRtcp(sr.serialize());
          }
        });
      } else if (tr.kind === "video") {
        bridge.videoOut = outTrack;
        bridge.videoSender = tr.sender;
        bridge.videoReceiver = tr.receiver;
        if (typeof pt === "number") bridge.videoPt = pt;
        tr.receiver.track.onReceiveRtp.subscribe((pkt: RtpPacket) => {
          bridge.clientVideoSsrc = pkt.header.ssrc;
          if (!bridge.zrtc) return;
          try {
            bridge.mediaStats.clientVideoRtp++;
            const packets = bridge.webrtcToZaloVideo.processRtp(pkt.serialize());
            if (packets.length > 0) bridge.mediaStats.clientVideoFrames++;
            for (const packet of packets) {
              bridge.zrtc.sendVideoRtp(packet);
            }
          } catch {
            // ignore dropped frame
          }
        });
        tr.sender.onKeyFrameRequest.subscribe((kind) => {
          if (!bridge.zrtc) return;
          const mediaSsrc = bridge.remoteVideoSsrc ?? 0;
          const senderSsrc = bridge.clientVideoSsrc ?? tr.sender.ssrc;
          if (kind === "fir" && mediaSsrc !== 0) {
            bridge.firSeq = (bridge.firSeq + 1) & 0xff;
            const firPkt = new RtcpPayloadSpecificFeedback({
              feedback: new FullIntraRequest({
                senderSsrc,
                mediaSsrc,
                fir: [{ ssrc: mediaSsrc, sequenceNumber: bridge.firSeq }],
              }),
            });
            bridge.zrtc.sendVideoRtcp(firPkt.serialize());
          } else {
            const pliPkt = new RtcpPayloadSpecificFeedback({
              feedback: new PictureLossIndication({ senderSsrc, mediaSsrc }),
            });
            bridge.zrtc.sendVideoRtcp(pliPkt.serialize());
          }
        });
        tr.sender.onRtcp.subscribe((pkt: RtcpPacket) => {
          if (!bridge.zrtc) return;
          if (
            pkt instanceof RtcpPayloadSpecificFeedback &&
            (pkt.feedback instanceof PictureLossIndication ||
              pkt.feedback instanceof FullIntraRequest)
          ) {
            // Handled via onKeyFrameRequest above to avoid duplicate PLI/FIR sends.
            return;
          }
          if (pkt instanceof RtcpRrPacket) {
            const remoteSsrc = bridge.remoteVideoSsrc;
            const reports = pkt.reports.map((r) =>
              remoteSsrc !== undefined && r.ssrc === tr.sender.ssrc
                ? new RtcpReceiverInfo({
                    ssrc: remoteSsrc,
                    fractionLost: r.fractionLost,
                    packetsLost: r.packetsLost,
                    highestSequence: r.highestSequence,
                    jitter: r.jitter,
                    lsr: r.lsr,
                    dlsr: r.dlsr,
                  })
                : r,
            );
            bridge.zrtc.sendVideoRtcp(
              new RtcpRrPacket({ ssrc: pkt.ssrc, reports }).serialize(),
            );
          } else if (
            pkt instanceof RtcpTransportLayerFeedback &&
            pkt.feedback instanceof GenericNack
          ) {
            const fb = pkt.feedback;
            const mapped = new GenericNack({
              senderSsrc: fb.senderSsrc,
              mediaSourceSsrc:
                bridge.remoteVideoSsrc !== undefined &&
                fb.mediaSourceSsrc === tr.sender.ssrc
                  ? bridge.remoteVideoSsrc
                  : fb.mediaSourceSsrc,
              lost: [...fb.lost],
            });
            bridge.zrtc.sendVideoRtcp(
              new RtcpTransportLayerFeedback({ feedback: mapped }).serialize(),
            );
          }
        });
        tr.receiver.onRtcp.subscribe((pkt: RtcpPacket) => {
          if (!bridge.zrtc) return;
          if (pkt instanceof RtcpSrPacket) {
            bridge.zrtc.sendVideoRtcp(pkt.serialize());
          }
        });
      }
    }

    const answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);

    const rawSdp = pc.localDescription?.sdp ?? answer.sdp;
    return {
      sdp: rewriteSdpIceCandidates(rawSdp, publicHost, portRange),
      type: "answer",
      iceServers,
    };
  }

  async handleClientIce(
    slot: string,
    callId: string,
    candidate: IceCandidateJson | null | undefined,
  ): Promise<void> {
    if (!candidate?.candidate) return;
    const bridge = this.getBridge(slot, callId);
    if (!bridge?.pc) return;
    try {
      await bridge.pc.addIceCandidate(
        new RTCIceCandidate({
          candidate: candidate.candidate,
          sdpMid: candidate.sdpMid ?? undefined,
          sdpMLineIndex: candidate.sdpMLineIndex ?? undefined,
        }),
      );
    } catch {
      // Ignore late or duplicate ICE candidates during teardown
    }
  }

  async closeCall(slot: string, callId: string): Promise<void> {
    const k = this.keyOf(slot, callId);
    const bridge = this.bridges.get(k);
    if (!bridge) return;
    this.bridges.delete(k);
    if (bridge.mediaStatsTimer) clearInterval(bridge.mediaStatsTimer);
    bridge.zrtc?.close();
    if (bridge.pc) {
      try {
        await bridge.pc.close();
      } catch {}
    }
    this.onClosedCallbacks.get(k)?.();
    this.onClosedCallbacks.delete(k);
  }

  async closeSlot(slot: string): Promise<void> {
    const keys = [...this.bridges.keys()].filter((k) => k.startsWith(`${slot}\0`));
    await Promise.all(
      keys.map((k) => {
        const callId = k.slice(slot.length + 1);
        return this.closeCall(slot, callId);
      }),
    );
  }
}
