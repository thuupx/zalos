// Ephemeral active-call state and multi-device signaling coordinator.
// Never writes signaling transitions to SQLite `events` — only ephemeral
// Noise tunnel broadcasts keep ring/connect/answeredElsewhere sub-second
// without polluting durable replay history (CallLog bubbles arrive separately
// through normal messaging when a call finishes).
import {
  DEFAULT_ZRTC_AUDIO_CODECS,
  buildZrtcExtendData,
} from "@zalos/zalo-sdk";
import { logSafeError } from "../security/audit.ts";
import type { Store } from "../store/db.ts";
import { RpcError } from "../tunnel/rpc.ts";
import type { TunnelServer } from "../tunnel/server.ts";
import type {
  ActiveCall,
  CallMediaKind,
  GatewayVoipEvent,
  ThreadType,
  ZaloGateway,
} from "../gateway/types.ts";
import {
  CallMediaGateway,
  parseIceServers,
  parseZaloOpusClockRate,
  type IceCandidateJson,
} from "./call_media_gateway.ts";
import {
  ZrtcRelaySession,
  type ZrtcConnectParams,
  type ZrtcServerCandidate,
} from "./zrtc_session.ts";

const RING_TIMEOUT_MS = 45_000;

function parseZrtcServers(raw: unknown): ZrtcServerCandidate[] | undefined {
  if (Array.isArray(raw)) {
    return raw as ZrtcServerCandidate[];
  }
  if (typeof raw === "string" && raw.trim() !== "") {
    try {
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed)) {
        return parsed as ZrtcServerCandidate[];
      }
    } catch {
      return undefined;
    }
  }
  return undefined;
}

function uidShape(raw: unknown): { type: string; len: number; isUint32: boolean } {
  const s = raw === undefined || raw === null ? "" : String(raw);
  const n = Number(s);
  return {
    type: typeof raw,
    len: s.length,
    isUint32: Number.isSafeInteger(n) && n >= 0 && n <= 0xffffffff,
  };
}

function safeZrtcFlags(zrtcCfg: unknown): Record<string, boolean | number> | undefined {
  if (!zrtcCfg || typeof zrtcCfg !== "object") return undefined;
  const src = zrtcCfg as Record<string, unknown>;
  const out: Record<string, boolean | number> = {};
  for (const k of [
    "forceTCP",
    "supportTCP",
    "protocol",
    "useTCP",
    "tcpPort",
    "enableTCP",
    "enableTcp",
    "enableChangeZRTP",
  ]) {
    const v = src[k];
    if (typeof v === "boolean" || typeof v === "number") {
      out[k] = v;
    }
  }
  return Object.keys(out).length > 0 ? out : undefined;
}

export class CallManager {
  private calls = new Map<string, Map<string, ActiveCall>>();
  private ringTimers = new Map<string, ReturnType<typeof setTimeout>>();

  constructor(
    private readonly gatewayOf: (slot: string) => ZaloGateway,
    private readonly tunnel: TunnelServer,
    private readonly store: Store,
    readonly mediaGateway: CallMediaGateway = new CallMediaGateway(),
    private readonly zrtcOpts: {
      factory?: () => ZrtcRelaySession;
      timeoutMs?: number;
      maxAttempts?: number;
    } = {},
  ) {}

  mediaConfig(): { iceServers: ReturnType<typeof parseIceServers> } {
    return { iceServers: parseIceServers() };
  }

  private async connectZrtcWithRetry(
    params: ZrtcConnectParams,
    shouldAbort: () => boolean,
  ): Promise<{
    zrtc: ZrtcRelaySession;
    relay: {
      token: number;
      rtpAddress: string;
      rtcpAddress: string;
      transport: "udp" | "tcp";
    };
  }> {
    const maxAttempts = Math.max(1, this.zrtcOpts.maxAttempts ?? 2);
    const baseTimeout = params.timeoutMs ?? this.zrtcOpts.timeoutMs ?? 3_500;
    let lastErr: unknown;

    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      if (shouldAbort()) {
        throw new Error("call ended before ZRTC connect");
      }
      const zrtc = (this.zrtcOpts.factory ?? (() => new ZrtcRelaySession()))();
      try {
        const attemptTimeout =
          attempt === 0 ? baseTimeout : Math.min(baseTimeout, 2_500);
        const relay = await zrtc.connect({
          ...params,
          timeoutMs: attemptTimeout,
        });
        if (shouldAbort()) {
          zrtc.close();
          throw new Error("call ended during ZRTC connect");
        }
        return { zrtc, relay };
      } catch (err) {
        zrtc.close();
        lastErr = err;
      }
    }
    throw lastErr instanceof Error ? lastErr : new Error(String(lastErr));
  }

  activeCalls(slot: string): ActiveCall[] {
    const map = this.calls.get(slot);
    if (!map) return [];
    return [...map.values()];
  }

  private slotMap(slot: string): Map<string, ActiveCall> {
    let map = this.calls.get(slot);
    if (!map) {
      map = new Map<string, ActiveCall>();
      this.calls.set(slot, map);
    }
    return map;
  }

  private timerKey(slot: string, callId: string): string {
    return `${slot}\0${callId}`;
  }

  private clearTimer(slot: string, callId: string): void {
    const key = this.timerKey(slot, callId);
    const t = this.ringTimers.get(key);
    if (t !== undefined) {
      clearTimeout(t);
      this.ringTimers.delete(key);
    }
  }

  private startRingTimeout(slot: string, callId: string): void {
    this.clearTimer(slot, callId);
    const key = this.timerKey(slot, callId);
    const t = setTimeout(() => {
      this.ringTimers.delete(key);
      const map = this.calls.get(slot);
      const call = map?.get(callId);
      if (call === undefined || call.status !== "ringing") return;
      map?.delete(callId);
      this.tunnel.broadcastAccount(slot, "call.ended", {
        callId,
        reason: "timeout",
      });
    }, RING_TIMEOUT_MS);
    t.unref?.();
    this.ringTimers.set(key, t);
  }

  private resolvePeerInfo(
    slot: string,
    peerId: string,
    threadId: string,
    threadType: ThreadType,
  ): { peerName: string; peerAvatarUrl?: string } {
    const p = this.store.getProfile(
      slot,
      threadType === "group" ? threadId : peerId,
      threadType,
    );
    return {
      peerName: p?.name && p.name !== "" ? p.name : peerId || threadId,
      ...(p?.avatar_url ? { peerAvatarUrl: p.avatar_url } : {}),
    };
  }

  onVoipEvent(slot: string, evt: GatewayVoipEvent): void {
    const act = evt.act;
    const d = evt.data;
    const callId = String(
      d.callId ?? d.call_id ?? d.sessId ?? d.session ?? evt.conversationId ?? evt.ts,
    );
    if (!callId) return;

    if (act === "request" || act === "group_request") {
      const isGroup = act === "group_request" || Boolean(evt.groupId);
      const threadType: ThreadType = isGroup ? "group" : "user";
      const threadId = String(evt.groupId ?? evt.conversationId ?? evt.callerId ?? "");
      const peerId = String(evt.callerId ?? evt.conversationId ?? threadId);
      const callTypeRaw = Number(d.calltype ?? d.callType ?? d.typeRequest ?? 1);
      const media: CallMediaKind =
        callTypeRaw === 3 || callTypeRaw === 6 || d.isVideo === true ? "video" : "voice";
      const peer = this.resolvePeerInfo(slot, peerId, threadId, threadType);
      const call: ActiveCall = {
        callId,
        threadId: threadId || peerId,
        threadType,
        peerId,
        peerName: String(d.callerName ?? peer.peerName),
        ...(peer.peerAvatarUrl ? { peerAvatarUrl: peer.peerAvatarUrl } : {}),
        media,
        direction: "incoming",
        status: "ringing",
        startedAt: evt.ts || Date.now(),
        isGroup,
        ...(isGroup && d.groupCallId ? { groupCallId: String(d.groupCallId) } : {}),
        ...(Array.isArray(d.participants)
          ? { participants: d.participants.map(String) }
          : {}),
        signalingData: d,
      };
      this.slotMap(slot).set(callId, call);
      this.startRingTimeout(slot, callId);
      this.tunnel.broadcastAccount(slot, "call.incoming", { call });
      if (!isGroup && peerId) {
        const gw = this.gatewayOf(slot);
        void gw.sendRingRing?.(callId, peerId).catch(() => {});
      }
      return;
    }

    if (act === "answer" || act === "group_answer" || act === "ready") {
      const call = this.calls.get(slot)?.get(callId);
      if (!call) {
        this.tunnel.broadcastAccount(slot, "call.voipSignal", {
          act,
          callId,
          conversationId: evt.conversationId,
          callerId: evt.callerId,
          groupId: evt.groupId,
          data: d,
        });
        return;
      }
      this.clearTimer(slot, callId);
      call.status = "active";
      call.answeredAt = call.answeredAt ?? Date.now();
      call.signalingData = { ...(call.signalingData ?? {}), ...d };
      if (!call.isGroup && act === "answer" && call.direction === "outgoing") {
        const gw = this.gatewayOf(slot);
        void gw.answerAck?.(callId, call.peerId).catch(() => {});
      }
      this.tunnel.broadcastAccount(slot, "call.state", { call });
      return;
    }

    if (
      act === "reject" ||
      act === "cancel" ||
      act === "finish" ||
      act === "end" ||
      act === "endcall" ||
      act === "group_end" ||
      act === "timeout" ||
      act === "busy"
    ) {
      this.clearTimer(slot, callId);
      const had = this.calls.get(slot)?.delete(callId) ?? false;
      void this.mediaGateway.closeCall(slot, callId);
      if (had) {
        this.tunnel.broadcastAccount(slot, "call.ended", {
          callId,
          reason: act,
        });
      }
      return;
    }

    this.tunnel.broadcastAccount(slot, "call.voipSignal", {
      act,
      callId,
      conversationId: evt.conversationId,
      callerId: evt.callerId,
      groupId: evt.groupId,
      inCallStatus: evt.inCallStatus,
      data: d,
    });
  }

  async start(
    slot: string,
    threadId: string,
    threadType: ThreadType,
    media: CallMediaKind,
    deviceId: string,
  ): Promise<{ call: ActiveCall }> {
    const gw = this.gatewayOf(slot);
    if (!gw.startCall) {
      throw new RpcError("not_supported", "calls are not supported on this account");
    }
    const res = await gw.startCall(threadId, threadType, media);
    const peer = this.resolvePeerInfo(slot, threadId, threadId, threadType);
    const call: ActiveCall = {
      callId: res.callId,
      threadId,
      threadType,
      peerId: threadId,
      peerName: peer.peerName,
      ...(peer.peerAvatarUrl ? { peerAvatarUrl: peer.peerAvatarUrl } : {}),
      media,
      direction: "outgoing",
      status: "ringing",
      startedAt: Date.now(),
      answeredByDeviceId: deviceId,
      isGroup: threadType === "group",
      ...(res.groupCallId ? { groupCallId: res.groupCallId } : {}),
      ...(res.serverConfig ? { signalingData: res.serverConfig } : {}),
    };
    this.slotMap(slot).set(call.callId, call);
    this.startRingTimeout(slot, call.callId);
    this.tunnel.broadcastAccount(slot, "call.state", { call });

    // For 1-1 calls against real Zalo, bind ZRTC relay and send step 2 (416 invite)
    // asynchronously so caller starts ringing immediately.
    if (threadType === "user" && res.serverConfig && gw.sendCallInvite) {
      void this.initCallerZrtcAndInvite(slot, gw, call, res.serverConfig);
    }

    return { call };
  }

  private async sendInviteWithAddress(
    gw: ZaloGateway,
    call: ActiveCall,
    sessionId: string,
    rtpAddress: string,
    rtcpAddress: string,
    codec: string,
  ): Promise<void> {
    await gw.sendCallInvite?.(call.callId, {
      calleeId: call.peerId,
      rtpAddress,
      rtcpAddress,
      codec,
      session: sessionId,
      extendData: buildZrtcExtendData({
        isVideo: call.media === "video",
        rtpAddress,
        rtcpAddress,
      }),
    });
  }

  private async initCallerZrtcAndInvite(
    slot: string,
    gw: ZaloGateway,
    call: ActiveCall,
    cfg: Record<string, unknown>,
  ): Promise<void> {
    const sessionId = typeof cfg.sessId === "string" ? cfg.sessId : "";
    const servers = parseZrtcServers(cfg.servers);
    const rtpIP = typeof cfg.rtpIP === "string" ? cfg.rtpIP : undefined;
    const rtcpIP = typeof cfg.rtcpIP === "string" ? cfg.rtcpIP : undefined;
    const numericCallId = Number(call.callId);

    console.log(
      JSON.stringify({
        ts: new Date().toISOString(),
        kind: "info",
        context: "zrtc.callerInit.start",
        slot,
        callId: call.callId,
        protocol: cfg.protocol,
        hasSessId: Boolean(sessionId),
        sessIdLen: sessionId.length,
        serverCount: servers?.length ?? 0,
        serversPreview: (servers ?? []).slice(0, 3).map((s) => ({
          ...(s.rtpaddr ? { rtpaddr: s.rtpaddr } : {}),
          ...(s.rtcpaddr ? { rtcpaddr: s.rtcpaddr } : {}),
          ...(s.rtpaddr2 ? { rtpaddr2: s.rtpaddr2 } : {}),
          ...(s.rtcpaddr2 ? { rtcpaddr2: s.rtcpaddr2 } : {}),
          ...(s.rtp ? { rtp: s.rtp } : {}),
          ...(s.rtcp ? { rtcp: s.rtcp } : {}),
          ...(s.tpType !== undefined ? { tpType: s.tpType } : {}),
          ...(s.spTcp !== undefined ? { spTcp: s.spTcp } : {}),
        })),
        hasRtpIP: Boolean(rtpIP),
        hasFromId: cfg.fromId !== undefined,
        hasToId: cfg.toId !== undefined,
        fromIdInfo: uidShape(cfg.fromId ?? gw.self.uid),
        toIdInfo: uidShape(cfg.toId ?? call.peerId),
        cfgKeys: Object.keys(cfg),
        serverKeys: servers?.[0] ? Object.keys(servers[0]) : [],
        settingsKeys:
          cfg.settings && typeof cfg.settings === "object"
            ? Object.keys(cfg.settings as object)
            : [],
        zrtcConfigKeys:
          cfg.zrtc_config && typeof cfg.zrtc_config === "object"
            ? Object.keys(cfg.zrtc_config as object)
            : typeof cfg.zrtc_config,
        zrtcConfigFlags: safeZrtcFlags(cfg.zrtc_config),
        rtpIP,
        rtcpIP,
        changeZRTP: cfg.changeZRTP,
      }),
    );

    if (!sessionId || !Number.isFinite(numericCallId) || (!servers?.length && !rtpIP)) {
      console.log(
        JSON.stringify({
          ts: new Date().toISOString(),
          kind: "warn",
          context: "zrtc.callerInit.skipped",
          slot,
          callId: call.callId,
          hasSessId: Boolean(sessionId),
          isFiniteCallId: Number.isFinite(numericCallId),
          serverCount: servers?.length ?? 0,
          hasRtpIP: Boolean(rtpIP),
        }),
      );
      return;
    }

    try {
      const { zrtc, relay } = await this.connectZrtcWithRetry(
        {
          isCallee: false,
          userId: Number(cfg.fromId ?? gw.self.uid ?? 0),
          partnerId: Number(cfg.toId ?? call.peerId ?? 0),
          callId: numericCallId,
          sessionId,
          isVideo: call.media === "video",
          servers,
          rtpIP,
          rtcpIP,
          transport: "auto",
        },
        () => this.calls.get(slot)?.get(call.callId) !== call,
      );
      console.log(
        JSON.stringify({
          ts: new Date().toISOString(),
          kind: "info",
          context: "zrtc.callerInit.connected",
          slot,
          callId: call.callId,
          transport: relay.transport,
          rtpAddress: relay.rtpAddress,
          rtcpAddress: relay.rtcpAddress,
        }),
      );
      this.mediaGateway.attachZrtc(slot, call.callId, zrtc, {
        audioClockRate: parseZaloOpusClockRate(cfg.codec),
      });
      try {
        const codec =
          typeof cfg.codec === "string" && cfg.codec !== "" && cfg.codec !== "[]"
            ? cfg.codec
            : DEFAULT_ZRTC_AUDIO_CODECS;
        await this.sendInviteWithAddress(
          gw,
          call,
          sessionId,
          relay.rtpAddress,
          relay.rtcpAddress,
          codec,
        );
        console.log(
          JSON.stringify({
            ts: new Date().toISOString(),
            kind: "info",
            context: "zrtc.callerInvite.sent",
            slot,
            callId: call.callId,
          }),
        );
      } catch (inviteErr) {
        logSafeError("zrtc.callerInvite.send", inviteErr, {
          slot,
          callId: call.callId,
        });
        await this.failCallerSetup(slot, gw, call, "invite_failed");
      }
    } catch (err) {
      logSafeError("zrtc.callerInvite.relay", err, { slot, callId: call.callId });
      await this.failCallerSetup(slot, gw, call, "relay_failed");
    }
  }

  private async failCallerSetup(
    slot: string,
    gw: ZaloGateway,
    call: ActiveCall,
    reason: string,
  ): Promise<void> {
    if (this.calls.get(slot)?.get(call.callId) !== call) {
      await this.mediaGateway.closeCall(slot, call.callId);
      return;
    }
    this.clearTimer(slot, call.callId);
    this.calls.get(slot)?.delete(call.callId);
    await this.mediaGateway.closeCall(slot, call.callId);
    void gw.cancelCall?.(call.callId, { peerId: call.peerId, media: call.media }).catch(() => {});
    this.tunnel.broadcastAccount(slot, "call.ended", {
      callId: call.callId,
      reason,
    });
  }

  async accept(
    slot: string,
    callId: string,
    deviceId: string,
  ): Promise<{ call: ActiveCall }> {
    const call = this.calls.get(slot)?.get(callId);
    if (!call || call.status === "ended") {
      throw new RpcError("not_found", `call not found: ${callId}`);
    }
    if (
      call.answeredByDeviceId !== undefined &&
      call.answeredByDeviceId !== deviceId
    ) {
      throw new RpcError(
        "conflict",
        `call ${callId} already answered on another device`,
      );
    }

    const prevDeviceId = call.answeredByDeviceId;
    const prevStatus = call.status;
    // Claim synchronously before awaiting gateway so concurrent accept RPCs lose cleanly.
    call.answeredByDeviceId = deviceId;
    call.status = "connecting";
    this.clearTimer(slot, callId);

    try {
      const gw = this.gatewayOf(slot);
      let rtpAddress: string | undefined;
      let rtcpAddress: string | undefined;
      const sig = call.signalingData ?? {};
      const sessionId = String(sig.session ?? sig.sessId ?? callId);
      const callerRtp =
        typeof sig.rtpAddress === "string"
          ? sig.rtpAddress
          : typeof sig.rtpIP === "string"
            ? sig.rtpIP
            : undefined;
      const callerRtcp =
        typeof sig.rtcpAddress === "string"
          ? sig.rtcpAddress
          : typeof sig.rtcpIP === "string"
            ? sig.rtcpIP
            : callerRtp;

      if (!call.isGroup && callerRtp && callerRtcp && Number.isFinite(Number(callId))) {
        let connected;
        try {
          connected = await this.connectZrtcWithRetry(
            {
              isCallee: true,
              userId: Number(sig.toId ?? sig.calleeId ?? gw.self.uid ?? 0),
              partnerId: Number(sig.fromId ?? sig.callerId ?? call.peerId ?? 0),
              callId: Number(callId),
              sessionId,
              isVideo: call.media === "video",
              rtpIP: callerRtp,
              rtcpIP: callerRtcp,
              transport: "auto",
            },
            () => this.calls.get(slot)?.get(callId) !== call,
          );
        } catch (err) {
          logSafeError("zrtc.calleeAccept", err, { slot, callId });
          throw new RpcError("relay_failed", "failed to connect to call media relay");
        }
        rtpAddress = connected.relay.rtpAddress;
        rtcpAddress = connected.relay.rtcpAddress;
        this.mediaGateway.attachZrtc(slot, callId, connected.zrtc, {
          audioClockRate: parseZaloOpusClockRate(sig.codec),
        });
      }

      if (gw.answerCall) {
        const res = await gw.answerCall(callId, {
          callerId: call.peerId,
          ...(call.isGroup ? { groupId: call.threadId } : {}),
          media: call.media,
          ...(rtpAddress ? { rtpAddress } : {}),
          ...(rtcpAddress ? { rtcpAddress } : {}),
          codec: DEFAULT_ZRTC_AUDIO_CODECS,
          sessionId,
          extendData: buildZrtcExtendData({
            isVideo: call.media === "video",
            rtpAddress,
            rtcpAddress,
          }),
        });
        if (res.serverConfig) {
          call.signalingData = { ...(call.signalingData ?? {}), ...res.serverConfig };
        }
      }
    } catch (err) {
      await this.mediaGateway.closeCall(slot, callId);
      call.answeredByDeviceId = prevDeviceId;
      call.status = prevStatus;
      if (prevStatus === "ringing" && this.calls.get(slot)?.get(callId) === call) {
        this.startRingTimeout(slot, callId);
      }
      throw err;
    }

    call.status = "active";
    call.answeredAt = call.answeredAt ?? Date.now();
    this.tunnel.broadcastAccount(slot, "call.state", { call });
    for (const ch of this.tunnel.accountChannels(slot)) {
      if (ch.deviceId !== deviceId) {
        ch.sendEvent("call.answeredElsewhere", {
          callId,
          answeredByDeviceId: deviceId,
        });
      }
    }
    return { call };
  }

  async reject(
    slot: string,
    callId: string,
    deviceId: string,
    scope: "local" | "global" = "global",
  ): Promise<{ ok: true; scope: "local" | "global" }> {
    const call = this.calls.get(slot)?.get(callId);
    if (!call) {
      throw new RpcError("not_found", `call not found: ${callId}`);
    }
    if (scope === "local") {
      for (const ch of this.tunnel.accountChannels(slot, deviceId)) {
        ch.sendEvent("call.ended", { callId, reason: "silenced_locally" });
      }
      return { ok: true, scope: "local" };
    }

    this.clearTimer(slot, callId);
    const gw = this.gatewayOf(slot);
    if (gw.rejectCall) {
      await gw.rejectCall(callId, {
        callerId: call.peerId,
        ...(call.isGroup ? { groupId: call.threadId } : {}),
      });
    }
    await this.mediaGateway.closeCall(slot, callId);
    this.calls.get(slot)?.delete(callId);
    this.tunnel.broadcastAccount(slot, "call.ended", {
      callId,
      reason: "rejected",
    });
    return { ok: true, scope: "global" };
  }

  async hangup(
    slot: string,
    callId: string,
    reason = "hangup",
  ): Promise<{ ok: true }> {
    const call = this.calls.get(slot)?.get(callId);
    if (!call) {
      throw new RpcError("not_found", `call not found: ${callId}`);
    }
    this.clearTimer(slot, callId);
    const durationSec = call.answeredAt
      ? Math.max(0, Math.floor((Date.now() - call.answeredAt) / 1000))
      : 0;
    const gw = this.gatewayOf(slot);
    if (!call.isGroup && call.direction === "outgoing" && call.status === "ringing" && gw.cancelCall) {
      await gw.cancelCall(callId, { peerId: call.peerId, media: call.media }).catch(() => {});
    } else if (gw.endCall) {
      await gw.endCall(callId, {
        peerId: call.peerId,
        ...(call.isGroup ? { groupId: call.threadId } : {}),
        durationSec,
      });
    }
    await this.mediaGateway.closeCall(slot, callId);
    this.calls.get(slot)?.delete(callId);
    this.tunnel.broadcastAccount(slot, "call.ended", { callId, reason });
    return { ok: true };
  }

  async handleMediaOffer(
    slot: string,
    callId: string,
    deviceId: string,
    sdp: string,
  ): Promise<{
    sdp: string;
    type: "answer";
    iceServers: Array<{ urls: string | string[]; username?: string; credential?: string }>;
  }> {
    const call = this.calls.get(slot)?.get(callId);
    if (!call) {
      throw new RpcError("not_found", `call not found: ${callId}`);
    }
    return this.mediaGateway.handleClientOffer({
      slot,
      callId,
      deviceId,
      sdp,
      media: call.media,
      onServerIce: (candidate) => {
        for (const ch of this.tunnel.accountChannels(slot, deviceId)) {
          ch.sendEvent("call.media.ice", { callId, candidate });
        }
      },
    });
  }

  async handleMediaIce(
    slot: string,
    callId: string,
    candidate: IceCandidateJson,
  ): Promise<{ ok: true }> {
    await this.mediaGateway.handleClientIce(slot, callId, candidate);
    return { ok: true };
  }

  async groupState(
    slot: string,
    groupId: string,
  ): Promise<Record<string, unknown>> {
    const gw = this.gatewayOf(slot);
    if (!gw.getGroupCallState) {
      throw new RpcError("not_supported", "group calls are not supported on this account");
    }
    return gw.getGroupCallState(groupId);
  }

  async zaloSignal(
    slot: string,
    callId: string,
    action: string,
    payload: Record<string, unknown>,
  ): Promise<{ ok: true; result?: unknown }> {
    const gw = this.gatewayOf(slot);
    if (!gw.sendCallSignal) {
      throw new RpcError("not_supported", "call signaling is not supported on this account");
    }
    const result = await gw.sendCallSignal(action, { callId, ...payload });
    return { ok: true, ...(result !== undefined ? { result } : {}) };
  }

  clearSlot(slot: string): void {
    const map = this.calls.get(slot);
    if (map) {
      for (const callId of map.keys()) {
        this.clearTimer(slot, callId);
      }
      this.calls.delete(slot);
    }
    void this.mediaGateway.closeSlot(slot);
  }
}
