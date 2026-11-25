import dgram from "node:dgram";
import { ZrtcTcpSocket } from "./zrtc_tcp.ts";
import {
  encodeAudioRtcp,
  encodeAudioRtp,
  encodeEndCall,
  encodeInitCall,
  encodePing,
  encodeVideoRtcp,
  encodeVideoRtp,
  parseZrtpPacket,
} from "./zrtc_packet.ts";

export interface ZrtcServerCandidate {
  rtpaddr?: string;
  rtcpaddr?: string;
  rtpaddr2?: string;
  rtcpaddr2?: string;
  rtp?: string;
  rtcp?: string;
  tpType?: number;
  spTcp?: number;
}

export interface ZrtcUdpSocket {
  on(event: "message", listener: (msg: Buffer, rinfo: { address: string; port: number }) => void): this;
  on(event: "error", listener: (err: Error) => void): this;
  send(msg: Uint8Array | Buffer, port: number, address: string, cb?: (err: Error | null) => void): void;
  close(cb?: () => void): void;
}

export type ZrtcSocketFactory = () => ZrtcUdpSocket;

export interface ZrtcConnectParams {
  isCallee: boolean;
  userId: number;
  partnerId: number;
  callId: number;
  sessionId: string;
  isVideo: boolean;
  servers?: ZrtcServerCandidate[];
  rtpIP?: string;
  rtcpIP?: string;
  extraInfo?: string;
  timeoutMs?: number;
  /** Transport mode: "auto" races UDP & TCP simultaneously; "udp" or "tcp" forces one. */
  transport?: "auto" | "udp" | "tcp";
  /** Legacy alias for transport ("tcp" when true, "udp" when false). */
  tcp?: boolean;
}

/** Default `ZMakeCallParam` blob the official client appends to caller and callee InitCall. */
const DEFAULT_INIT_EXTRA = new Uint8Array([2, 0, 0, 0, 0]);

export function parseHostPort(addr: string | undefined): { host: string; port: number } | null {
  if (!addr) return null;
  const trimmed = addr.trim();
  const idx = trimmed.lastIndexOf(":");
  if (idx <= 0 || idx >= trimmed.length - 1) return null;
  const host = trimmed.slice(0, idx).replace(/^\[|\]$/g, "");
  const port = Number(trimmed.slice(idx + 1));
  if (!host || !Number.isInteger(port) || port <= 0 || port > 65535) return null;
  return { host, port };
}

export class ZrtcRelaySession {
  private readonly socketFactory: ZrtcSocketFactory;
  private readonly hasCustomSocketFactory: boolean;
  private rtpSock: ZrtcUdpSocket | null = null;
  private rtcpSock: ZrtcUdpSocket | null = null;
  private handshakingSockets: ZrtcUdpSocket[] = [];
  private chosenRtp: { host: string; port: number } | null = null;
  private chosenRtcp: { host: string; port: number } | null = null;
  private pingTimer: ReturnType<typeof setInterval> | null = null;
  private seq = 1;
  private closed = false;

  token = 0;
  rtpAddress = "";
  rtcpAddress = "";

  private userId = 0;
  private callId = 0;
  private sessionId = "";

  onAudioRtp?: (payload: Uint8Array) => void;
  onVideoRtp?: (payload: Uint8Array) => void;
  onAudioRtcp?: (payload: Uint8Array) => void;
  onVideoRtcp?: (payload: Uint8Array) => void;

  constructor(socketFactory?: ZrtcSocketFactory) {
    this.hasCustomSocketFactory = socketFactory !== undefined;
    this.socketFactory = socketFactory ?? (() => dgram.createSocket("udp4") as unknown as ZrtcUdpSocket);
  }

  private nextSeq(): number {
    this.seq = (this.seq + 1) >>> 0;
    return this.seq;
  }

  buildCandidates(params: Pick<ZrtcConnectParams, "servers" | "rtpIP" | "rtcpIP">): Array<{
    rtp: { host: string; port: number };
    rtcp: { host: string; port: number };
    rtpAddress: string;
    rtcpAddress: string;
  }> {
    const pairs: Array<{ rtpStr?: string; rtcpStr?: string }> = [];
    if (Array.isArray(params.servers)) {
      for (const c of params.servers) {
        const primaryRtp = c.rtpaddr ?? c.rtp;
        const primaryRtcp = c.rtcpaddr ?? c.rtcp ?? primaryRtp;
        if (primaryRtp) {
          pairs.push({ rtpStr: primaryRtp, rtcpStr: primaryRtcp });
        }
        if (c.rtpaddr2) {
          pairs.push({
            rtpStr: c.rtpaddr2,
            rtcpStr: c.rtcpaddr2 ?? c.rtpaddr2,
          });
        }
      }
    }
    if (params.rtpIP) {
      pairs.push({
        rtpStr: params.rtpIP,
        rtcpStr: params.rtcpIP ?? params.rtpIP,
      });
    }
    const seen = new Set<string>();
    const out: Array<{
      rtp: { host: string; port: number };
      rtcp: { host: string; port: number };
      rtpAddress: string;
      rtcpAddress: string;
    }> = [];
    for (const p of pairs) {
      const rtp = parseHostPort(p.rtpStr);
      const rtcp = parseHostPort(p.rtcpStr);
      if (!rtp || !rtcp) continue;
      const key = `${rtp.host}:${rtp.port}|${rtcp.host}:${rtcp.port}`;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({
        rtp,
        rtcp,
        rtpAddress: `${rtp.host}:${rtp.port}`,
        rtcpAddress: `${rtcp.host}:${rtcp.port}`,
      });
    }
    return out;
  }

  async connect(params: ZrtcConnectParams): Promise<{
    token: number;
    rtpAddress: string;
    rtcpAddress: string;
    transport: "udp" | "tcp";
  }> {
    if (this.closed) {
      throw new Error("ZrtcRelaySession already closed");
    }
    const candidates = this.buildCandidates(params);
    if (candidates.length === 0) {
      throw new Error("No valid ZRTC relay server candidates");
    }

    this.userId = params.userId >>> 0;
    this.callId = params.callId >>> 0;
    this.sessionId = params.sessionId;

    const mode: "auto" | "udp" | "tcp" =
      params.transport ??
      (params.tcp === true
        ? "tcp"
        : params.tcp === false
          ? "udp"
          : this.hasCustomSocketFactory
            ? "udp"
            : "auto");

    const useUdp = mode === "udp" || mode === "auto";
    const useTcp = mode === "tcp" || mode === "auto";

    const udpRtpSock = useUdp ? this.socketFactory() : null;
    const udpRtcpSock = useUdp ? this.socketFactory() : null;
    const tcpSock = useTcp ? new ZrtcTcpSocket() : null;
    const tcpAsUdp = tcpSock ? (tcpSock as unknown as ZrtcUdpSocket) : null;

    this.handshakingSockets = [
      ...(udpRtpSock ? [udpRtpSock] : []),
      ...(udpRtcpSock ? [udpRtcpSock] : []),
      ...(tcpAsUdp ? [tcpAsUdp] : []),
    ];
    this.rtpSock = udpRtpSock ?? tcpAsUdp;
    this.rtcpSock = udpRtcpSock ?? tcpAsUdp;

    const timeoutMs = params.timeoutMs ?? 4_000;

    return new Promise((resolve, reject) => {
      let settled = false;
      let retryTimer: ReturnType<typeof setInterval> | null = null;
      let timeoutTimer: ReturnType<typeof setTimeout> | null = null;
      let udpRecv = 0;
      let tcpRecv = 0;
      let lastResCode: number | null = null;
      let lastRecvSummary: string | null = null;
      let sendErrors = 0;

      for (const s of this.handshakingSockets) {
        s.on("error", () => {
          sendErrors++;
        });
      }

      const cleanupTimers = () => {
        if (retryTimer !== null) {
          clearInterval(retryTimer);
          retryTimer = null;
        }
        if (timeoutTimer !== null) {
          clearTimeout(timeoutTimer);
          timeoutTimer = null;
        }
      };

      const fail = (err: Error) => {
        if (settled) return;
        settled = true;
        cleanupTimers();
        reject(err);
      };

      const handleInbound = (
        msg: Buffer,
        source: "udp" | "tcp",
        rinfo?: { address: string; port: number },
      ) => {
        if (this.closed) return;
        const parsed = parseZrtpPacket(msg);

        if (!settled) {
          if (source === "udp") udpRecv++;
          else tcpRecv++;
          if (!parsed) {
            lastRecvSummary = `src=${source},len=${msg.length},type=${msg[0] ?? "none"},kind=null`;
          } else if (parsed.kind === "init_response") {
            lastRecvSummary = `src=${source},len=${msg.length},type=${msg[0]},kind=${parsed.kind},cmd=${parsed.cmd},resCode=${parsed.resCode}`;
            if (parsed.resCode !== 0) {
              lastResCode = parsed.resCode;
            }
          } else if (parsed.kind === "control_response") {
            lastRecvSummary = `src=${source},len=${msg.length},type=${msg[0]},kind=${parsed.kind},cmd=${parsed.cmd}`;
          } else {
            lastRecvSummary = `src=${source},len=${msg.length},type=${msg[0]},kind=${parsed.kind}`;
          }
        }

        if (!parsed) return;

        if (parsed.kind === "init_response") {
          if (settled) return;
          if (parsed.resCode !== 0) {
            return;
          }
          const matched =
            (rinfo
              ? candidates.find(
                  (c) =>
                    (c.rtp.host === rinfo.address && c.rtp.port === rinfo.port) ||
                    (c.rtcp.host === rinfo.address && c.rtcp.port === rinfo.port),
                )
              : undefined) ?? candidates[0]!;
          this.token = parsed.token;
          this.chosenRtp = matched.rtp;
          if (source === "tcp") {
            this.chosenRtcp = matched.rtp;
            this.rtpAddress = matched.rtpAddress;
            this.rtcpAddress = matched.rtpAddress;
            this.rtpSock = tcpAsUdp;
            this.rtcpSock = tcpAsUdp;
            try { udpRtpSock?.close(); } catch {}
            try { udpRtcpSock?.close(); } catch {}
          } else {
            this.chosenRtcp = matched.rtcp;
            this.rtpAddress = matched.rtpAddress;
            this.rtcpAddress = matched.rtcpAddress;
            this.rtpSock = udpRtpSock;
            if (matched.rtpAddress === matched.rtcpAddress) {
              this.rtcpSock = udpRtpSock;
              try { udpRtcpSock?.close(); } catch {}
            } else {
              this.rtcpSock = udpRtcpSock;
              if (this.rtcpSock && this.token !== 0) {
                const rtcpPing = encodePing({
                  userId: this.userId,
                  token: this.token,
                  sessionId: this.sessionId,
                  seq: this.nextSeq(),
                });
                this.rtcpSock.send(rtcpPing, matched.rtcp.port, matched.rtcp.host);
              }
            }
            try { tcpSock?.close(); } catch {}
          }
          this.handshakingSockets = [];
          settled = true;
          cleanupTimers();

          this.startPingLoop();
          resolve({
            token: this.token,
            rtpAddress: this.rtpAddress,
            rtcpAddress: this.rtcpAddress,
            transport: source,
          });
          return;
        }

        if (parsed.kind === "audio_rtp") {
          this.onAudioRtp?.(parsed.payload);
        } else if (parsed.kind === "video_rtp") {
          this.onVideoRtp?.(parsed.payload);
        } else if (parsed.kind === "audio_rtcp") {
          this.onAudioRtcp?.(parsed.payload);
        } else if (parsed.kind === "video_rtcp") {
          this.onVideoRtcp?.(parsed.payload);
        }
      };

      if (udpRtpSock) {
        udpRtpSock.on("message", (msg, rinfo) => handleInbound(msg, "udp", rinfo));
      }
      if (udpRtcpSock) {
        udpRtcpSock.on("message", (msg, rinfo) => handleInbound(msg, "udp", rinfo));
      }
      if (tcpAsUdp) {
        tcpAsUdp.on("message", (msg, rinfo) => handleInbound(msg, "tcp", rinfo));
      }

      const sendInitOn = (sock: ZrtcUdpSocket) => {
        if (settled || this.closed) return;
        const pkt = encodeInitCall({
          isCallee: params.isCallee,
          userId: this.userId,
          partnerId: params.partnerId >>> 0,
          callId: this.callId,
          sessionId: this.sessionId,
          isVideo: params.isVideo,
          extraInfo: params.extraInfo ?? DEFAULT_INIT_EXTRA,
          seq: this.nextSeq(),
        });
        for (const c of candidates) {
          sock.send(pkt, c.rtp.port, c.rtp.host);
        }
      };

      if (udpRtpSock) {
        sendInitOn(udpRtpSock);
        retryTimer = setInterval(() => sendInitOn(udpRtpSock), 400);
        retryTimer.unref?.();
      }
      if (tcpAsUdp) {
        // TCP is reliable: sending once per candidate avoids duplicate InitCall.
        sendInitOn(tcpAsUdp);
      }

      timeoutTimer = setTimeout(() => {
        fail(
          new Error(
            `ZRTC relay InitCall timeout after ${timeoutMs}ms (` +
              `mode=${mode}, candidates=${candidates.map((c) => c.rtpAddress).join(",")}, ` +
              `tcp=${tcpSock ? `[${tcpSock.summary()}]` : "off"}, ` +
              `udpRecv=${udpRecv}, tcpRecv=${tcpRecv}, lastResCode=${lastResCode}, ` +
              `last=${lastRecvSummary ?? "none"}, sendErrs=${sendErrors})`,
          ),
        );
      }, timeoutMs);
      timeoutTimer.unref?.();
    });
  }

  private startPingLoop(): void {
    if (this.pingTimer !== null) return;
    this.pingTimer = setInterval(() => {
      if (this.closed || !this.rtpSock || !this.chosenRtp || this.token === 0) return;
      const pkt = encodePing({
        userId: this.userId,
        token: this.token,
        sessionId: this.sessionId,
        seq: this.nextSeq(),
      });
      this.rtpSock.send(pkt, this.chosenRtp.port, this.chosenRtp.host);
      if (this.rtcpSock && this.rtcpSock !== this.rtpSock && this.chosenRtcp) {
        const rtcpPkt = encodePing({
          userId: this.userId,
          token: this.token,
          sessionId: this.sessionId,
          seq: this.nextSeq(),
        });
        this.rtcpSock.send(rtcpPkt, this.chosenRtcp.port, this.chosenRtcp.host);
      }
    }, 3_000);
    this.pingTimer.unref?.();
  }

  sendAudioRtp(rtp: Uint8Array): void {
    if (this.closed || !this.rtpSock || !this.chosenRtp || this.token === 0) return;
    this.rtpSock.send(
      encodeAudioRtp(this.token, rtp),
      this.chosenRtp.port,
      this.chosenRtp.host,
    );
  }

  sendVideoRtp(rtp: Uint8Array): void {
    if (this.closed || !this.rtpSock || !this.chosenRtp || this.token === 0) return;
    this.rtpSock.send(
      encodeVideoRtp(this.token, rtp),
      this.chosenRtp.port,
      this.chosenRtp.host,
    );
  }

  sendAudioRtcp(rtcp: Uint8Array): void {
    if (this.closed || !this.rtcpSock || !this.chosenRtcp || this.token === 0) return;
    this.rtcpSock.send(
      encodeAudioRtcp(this.token, rtcp),
      this.chosenRtcp.port,
      this.chosenRtcp.host,
    );
  }

  sendVideoRtcp(rtcp: Uint8Array): void {
    if (this.closed || !this.rtcpSock || !this.chosenRtcp || this.token === 0) return;
    this.rtcpSock.send(
      encodeVideoRtcp(this.token, rtcp),
      this.chosenRtcp.port,
      this.chosenRtcp.host,
    );
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    if (this.pingTimer !== null) {
      clearInterval(this.pingTimer);
      this.pingTimer = null;
    }
    if (this.rtpSock && this.chosenRtp && this.token !== 0) {
      try {
        const end = encodeEndCall({
          userId: this.userId,
          token: this.token,
          callId: this.callId,
          seq: this.nextSeq(),
        });
        this.rtpSock.send(end, this.chosenRtp.port, this.chosenRtp.host);
      } catch {
        // ignore best-effort end packet
      }
    }
    for (const s of this.handshakingSockets) {
      try {
        s.close();
      } catch {}
    }
    this.handshakingSockets = [];
    try {
      this.rtpSock?.close();
    } catch {}
    if (this.rtcpSock && this.rtcpSock !== this.rtpSock) {
      try {
        this.rtcpSock.close();
      } catch {}
    }
    this.rtpSock = null;
    this.rtcpSock = null;
  }
}
