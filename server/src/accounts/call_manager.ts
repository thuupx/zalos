// Ephemeral active-call state and multi-device signaling coordinator.
// Never writes signaling transitions to SQLite `events` — only ephemeral
// Noise tunnel broadcasts keep ring/connect/answeredElsewhere sub-second
// without polluting durable replay history (CallLog bubbles arrive separately
// through normal messaging when a call finishes).
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

const RING_TIMEOUT_MS = 45_000;

export class CallManager {
  private calls = new Map<string, Map<string, ActiveCall>>();
  private ringTimers = new Map<string, ReturnType<typeof setTimeout>>();

  constructor(
    private readonly gatewayOf: (slot: string) => ZaloGateway,
    private readonly tunnel: TunnelServer,
    private readonly store: Store,
  ) {}

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
      this.tunnel.broadcastAccount(slot, "call.state", { call });
      return;
    }

    if (
      act === "reject" ||
      act === "cancel" ||
      act === "finish" ||
      act === "end" ||
      act === "group_end" ||
      act === "timeout" ||
      act === "busy"
    ) {
      this.clearTimer(slot, callId);
      const had = this.calls.get(slot)?.delete(callId) ?? false;
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
    return { call };
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
      if (gw.answerCall) {
        const res = await gw.answerCall(callId, {
          callerId: call.peerId,
          ...(call.isGroup ? { groupId: call.threadId } : {}),
          media: call.media,
        });
        if (res.serverConfig) {
          call.signalingData = { ...(call.signalingData ?? {}), ...res.serverConfig };
        }
      }
    } catch (err) {
      call.answeredByDeviceId = prevDeviceId;
      call.status = prevStatus;
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
    if (gw.endCall) {
      await gw.endCall(callId, {
        peerId: call.peerId,
        ...(call.isGroup ? { groupId: call.threadId } : {}),
        durationSec,
      });
    }
    this.calls.get(slot)?.delete(callId);
    this.tunnel.broadcastAccount(slot, "call.ended", { callId, reason });
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
  }
}
