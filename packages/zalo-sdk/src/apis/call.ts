import { gzipSync } from "node:zlib";
import { CALL_SIGNAL_CMD, QOS_UPLOAD_CALL_LOG_URL } from "../core/constants.ts";
import type { ZaloContext } from "../core/context.ts";
import { ZaloApiError } from "../core/errors.ts";
import type { ZaloHttpClient } from "../core/http.ts";
import type { ZCallServerConfig } from "../models/events.ts";

const LOG_END_CALL_RETRY_MS = [1000, 1000, 2000, 3000, 5000, 8000, 13000];

/**
 * Default ZRTC audio codec descriptor expected by Zalo `/api/voicecall/requestcall`
 * and `/api/voicecall/request` (matches `zcall_mac.node` `getActiveAudioCodecs()`).
 */
export const DEFAULT_ZRTC_AUDIO_CODECS = JSON.stringify([
  { name: "opus/16000/1", payload: 112, frmPtime: 20, dynamicFptime: 1 },
]);

/**
 * Generates a positive signed 32-bit integer call ID in `[1, 0x7fffffff]`.
 * Zalo's call backend and native `zrtc::CallController` reject 64-bit timestamps.
 */
export function generateCallId(): number {
  const buf = new Uint32Array(1);
  crypto.getRandomValues(buf);
  const id = buf[0]! & 0x7fffffff;
  return id === 0 ? 1 : id;
}

/**
 * Builds the `extendData` JSON string matching `zrtc::CallController::getExtendData()`.
 * The official desktop client advertises its h264 capability independently of
 * whether the current call starts as audio or video.
 */
export function buildZrtcExtendData(opts: {
  isVideo: boolean;
  rtpAddress?: string;
  rtcpAddress?: string;
  extraInfo?: Record<string, unknown>;
  p2p?: Record<string, unknown> | unknown[];
}): string {
  const payload: Record<string, unknown> = {
    video: { codec: [{ name: "h264", payload: 97 }] },
    callType: opts.isVideo ? 1 : 0,
    newZrtc: 1,
    supportCallBusy: 1,
  };
  if (
    typeof opts.rtpAddress === "string" &&
    opts.rtpAddress.trim() !== "" &&
    typeof opts.rtcpAddress === "string" &&
    opts.rtcpAddress.trim() !== ""
  ) {
    payload.serverAddr = [{ rtp: opts.rtpAddress, rtcp: opts.rtcpAddress }];
  }
  if (opts.extraInfo !== undefined && opts.extraInfo !== null && !Array.isArray(opts.extraInfo)) {
    payload.extraInfo = { ...opts.extraInfo };
  }
  if (Array.isArray(opts.p2p) ? opts.p2p.length > 0 : opts.p2p && Object.keys(opts.p2p).length > 0) {
    payload.p2p = opts.p2p;
  }
  return JSON.stringify(payload);
}

function normalizeCallId(callId: string | number): string | number {
  if (typeof callId === "number") {
    if (!Number.isFinite(callId) || callId <= 0) return generateCallId();
    return Math.trunc(callId) >>> 0;
  }
  const trimmed = callId.trim();
  if (/^\d+$/.test(trimmed)) {
    const n = Number(trimmed);
    if (Number.isSafeInteger(n) && n > 0 && n <= 0xffffffff) {
      return n;
    }
    return generateCallId();
  }
  return trimmed;
}

export interface RequestCallParams {
  calleeId: string;
  callId: string | number;
  codec?: string;
  typeRequest: number;
}

export interface SendCallInviteParams {
  calleeId: string;
  rtcpAddress: string;
  rtpAddress: string;
  codec: string;
  session: unknown;
  callId: string | number;
  extendData?: unknown;
}

export interface AnswerCallParams {
  callerId: string;
  callId: string | number;
  status: number;
  codec?: string;
  rtcpAddress: string;
  rtpAddress: string;
  session_id: string;
  extendData?: unknown;
}

export interface LogEndCallParams {
  call_id: string | number;
  partner_id: string;
  status: number;
  logdata: unknown;
  duration: number;
  role: number;
}

export interface GroupCallInviteParams {
  calleeId?: string | string[];
  callId: string | number;
  callType: number;
  hostCall?: string;
  data?: unknown;
  session?: unknown;
  partners?: unknown[];
  groupId?: string;
}

/**
 * Complete Zalo Voice Call, Video Call & Group Call REST signaling client
 * (all 28 `/api/voicecall/*` and `/api/voicecall/group/*` commands + `/api/znoise` + QoS upload).
 */
export class CallApi {
  useQueue = true;

  constructor(
    private readonly http: ZaloHttpClient,
    private readonly ctx: ZaloContext,
  ) {}

  private enqueueOrRun<T>(fn: () => Promise<T>): Promise<T> {
    return this.useQueue ? this.http.callQueue.enqueue(fn) : fn();
  }

  private getCall<T = unknown>(path: string, params: Record<string, unknown>): Promise<T> {
    return this.enqueueOrRun(() => {
      const url = this.http.serviceUrl("voice_call", path);
      return this.http.getEncrypted<T>(url, params);
    });
  }

  // ---- 1:1 Voice & Video Calls ----

  /** Cmd `401` — `GET {voice_call[0]}/api/voicecall/requestcall`. */
  requestCall(params: RequestCallParams): Promise<ZCallServerConfig> {
    return this.getCall<ZCallServerConfig>("/api/voicecall/requestcall", {
      calleeId: params.calleeId,
      callId: normalizeCallId(params.callId),
      codec: params.codec ?? DEFAULT_ZRTC_AUDIO_CODECS,
      typeRequest: params.typeRequest,
      imei: this.ctx.imei,
    });
  }

  /** Cmd `416` — `GET {voice_call[0]}/api/voicecall/request`. */
  sendCallInvite(params: SendCallInviteParams): Promise<unknown> {
    return this.getCall("/api/voicecall/request", {
      calleeId: params.calleeId,
      rtcpAddress: params.rtcpAddress,
      rtpAddress: params.rtpAddress,
      codec: params.codec,
      session: params.session,
      callId: normalizeCallId(params.callId),
      imei: this.ctx.imei,
      ...(params.extendData !== undefined
        ? { extendData: params.extendData, subCommand: 3 }
        : {}),
    });
  }

  /** Cmd `407` — `GET {voice_call[0]}/api/voicecall/ringring`. */
  sendRingRing(callerId: string, callId: string | number, status = 0): Promise<unknown> {
    return this.getCall("/api/voicecall/ringring", {
      callerId,
      callId: normalizeCallId(callId),
      status,
      imei: this.ctx.imei,
    });
  }

  /** Cmd `402` — `GET {voice_call[0]}/api/voicecall/answer` (accept, reject, or busy). */
  answerCall(params: AnswerCallParams): Promise<unknown> {
    return this.getCall("/api/voicecall/answer", {
      callerId: params.callerId,
      callId: normalizeCallId(params.callId),
      status: params.status,
      codec: params.codec || "",
      rtcpAddress: params.rtcpAddress,
      rtpAddress: params.rtpAddress,
      session_id: params.session_id,
      ...(params.extendData !== undefined
        ? { extendData: params.extendData, subCommand: 3 }
        : {}),
    });
  }

  /** Cmd `408` — `GET {voice_call[0]}/api/voicecall/answerack`. */
  answerAck(calleeId: string, callId: string | number, status = 0): Promise<unknown> {
    return this.getCall("/api/voicecall/answerack", {
      calleeId,
      callId: normalizeCallId(callId),
      status,
      imei: this.ctx.imei,
    });
  }

  /** Cmd `405` — `GET {voice_call[0]}/api/voicecall/cancel` (note: Zalo maps `toId` -> `callerId`). */
  cancelCall(toId: string, callId: string | number, callType = 1, status = 0): Promise<unknown> {
    return this.getCall("/api/voicecall/cancel", {
      callerId: toId,
      callId: normalizeCallId(callId),
      callType,
      status,
      imei: this.ctx.imei,
    });
  }

  /** Cmd `409` — `GET {voice_call[0]}/api/voicecall/endcall`. */
  endCall(toId: string, callId: string | number, status = 3): Promise<unknown> {
    return this.getCall("/api/voicecall/endcall", {
      uidTo: toId,
      callId: normalizeCallId(callId),
      status,
      imei: this.ctx.imei,
    });
  }

  /**
   * Cmd `406` — `GET {voice_call[0]}/api/voicecall/logendcall`.
   * Retries on network error or `error_code === 112` with Zalo PC backoff schedule.
   */
  async logEndCall(params: LogEndCallParams, retryScheduleMs = LOG_END_CALL_RETRY_MS): Promise<unknown> {
    const payload = { ...params, imei: this.ctx.imei };
    let lastError: unknown;
    for (let attempt = 0; attempt <= retryScheduleMs.length; attempt++) {
      try {
        return await this.getCall("/api/voicecall/logendcall", payload);
      } catch (err) {
        lastError = err;
        const isRetryable =
          !(err instanceof ZaloApiError) || err.code === null || err.code === 112;
        if (!isRetryable || attempt >= retryScheduleMs.length) {
          throw err;
        }
        await new Promise((r) => setTimeout(r, retryScheduleMs[attempt]));
      }
    }
    throw lastError;
  }

  /** Cmd `411` — `GET {voice_call[0]}/api/voicecall/holdreq`. */
  holdRequest(toId: string): Promise<unknown> {
    return this.getCall("/api/voicecall/holdreq", { toId });
  }

  /** Cmd `412` — `GET {voice_call[0]}/api/voicecall/holdresp`. */
  holdResponse(toId: string): Promise<unknown> {
    return this.getCall("/api/voicecall/holdresp", { toId });
  }

  /** Cmd `413` — `GET {voice_call[0]}/api/voicecall/unholdreq`. */
  unholdRequest(toId: string): Promise<unknown> {
    return this.getCall("/api/voicecall/unholdreq", { toId });
  }

  /** Cmd `414` — `GET {voice_call[0]}/api/voicecall/unholdresp`. */
  unholdResponse(toId: string): Promise<unknown> {
    return this.getCall("/api/voicecall/unholdresp", { toId });
  }

  /** Cmd `12006` — `GET {voice_call[0]}/api/voicecall/conf` (camera/mic state toggle). */
  updateCallConfig(params: {
    calleeId: string;
    callId: string | number;
    isOnCam: boolean | number;
    isOnMic: boolean | number;
    data?: unknown;
  }): Promise<unknown> {
    return this.getCall("/api/voicecall/conf", {
      calleeId: params.calleeId,
      callId: normalizeCallId(params.callId),
      isOnCam: params.isOnCam,
      isOnMic: params.isOnMic,
      data: params.data ?? {},
    });
  }

  /** Cmd `12064` — `GET {voice_call[0]}/api/voicecall/requestsharescreen`. */
  requestShareScreen(uidTo: string, callId: string | number, status: number): Promise<unknown> {
    return this.getCall("/api/voicecall/requestsharescreen", { uidTo, callId, status });
  }

  /** Cmd `12056` — `GET {voice_call[0]}/api/voicecall/requestaudio2video`. */
  requestAudioToVideo(params: Record<string, unknown>): Promise<unknown> {
    return this.getCall("/api/voicecall/requestaudio2video", params);
  }

  // ---- Group Voice & Video Calls ----

  /** Cmd `12433` — `GET {voice_call[0]}/api/voicecall/group/requestcall`. */
  groupRequestCall(params: {
    groupId: string;
    callId: string | number;
    typeRequest: number;
    data?: unknown;
    partners?: unknown[];
  }): Promise<unknown> {
    return this.getCall("/api/voicecall/group/requestcall", {
      groupId: params.groupId,
      callId: normalizeCallId(params.callId),
      typeRequest: params.typeRequest,
      data: params.data ?? {},
      partners: params.partners ?? [],
    });
  }

  /** Cmd `12434` — `GET {voice_call[0]}/api/voicecall/group/request`. */
  groupSendInvite(params: GroupCallInviteParams): Promise<unknown> {
    return this.getCall("/api/voicecall/group/request", { ...params });
  }

  /** Cmd `12435` — `GET {voice_call[0]}/api/voicecall/group/adduser`. */
  groupAddUser(params: GroupCallInviteParams): Promise<unknown> {
    return this.getCall("/api/voicecall/group/adduser", { ...params });
  }

  /** Cmd `12436` — `GET {voice_call[0]}/api/voicecall/group/answer`. */
  groupAnswer(params: GroupCallInviteParams): Promise<unknown> {
    return this.getCall("/api/voicecall/group/answer", { ...params });
  }

  /** Cmd `12437` — `GET {voice_call[0]}/api/voicecall/group/cancel`. */
  groupCancel(params: GroupCallInviteParams): Promise<unknown> {
    return this.getCall("/api/voicecall/group/cancel", { ...params });
  }

  /** Cmd `12438` — `GET {voice_call[0]}/api/voicecall/group/endcall`. */
  groupEndCall(params: GroupCallInviteParams): Promise<unknown> {
    return this.getCall("/api/voicecall/group/endcall", { ...params });
  }

  /** Cmd `12439` — `GET {voice_call[0]}/api/voicecall/group/ringring`. */
  groupRingRing(params: GroupCallInviteParams): Promise<unknown> {
    return this.getCall("/api/voicecall/group/ringring", { ...params });
  }

  /** Cmd `12445` — `GET {voice_call[0]}/api/voicecall/group/state`. */
  groupState(params: { callId: string | number; hostCall: string; callType: number }): Promise<unknown> {
    return this.getCall("/api/voicecall/group/state", params);
  }

  /** Cmd `12446` — `GET {voice_call[0]}/api/voicecall/group/finish`. */
  groupFinish(params: {
    callId: string | number;
    callType: number;
    data?: unknown;
    duration: number;
    hostCall: string;
    partners?: unknown[];
    status: number;
    joinTime?: number;
  }): Promise<unknown> {
    return this.getCall("/api/voicecall/group/finish", params);
  }

  /** Cmd `12447` — `GET {voice_call[0]}/api/voicecall/group/notify`. */
  groupNotify(params: {
    callId: string | number;
    hostCall: string;
    callType: number;
    status: number;
    data?: unknown;
  }): Promise<unknown> {
    return this.getCall("/api/voicecall/group/notify", params);
  }

  /** Cmd `12097` — `GET {voice_call[0]}/api/voicecall/group/ping`. */
  groupPing(params: {
    callId: string | number;
    hostCall: string;
    userId: string;
    callstate: number;
    audiostate: number;
    videostate: number;
    params?: unknown;
  }): Promise<unknown> {
    return this.getCall("/api/voicecall/group/ping", params);
  }

  /** Cmd `12098` — `GET {voice_call[0]}/api/voicecall/group/broadcast`. */
  groupBroadcast(params: {
    callId: string | number;
    hostCall: string;
    userId: string;
    callstate: number;
    audiostate: number;
    videostate: number;
    params?: unknown;
  }): Promise<unknown> {
    return this.getCall("/api/voicecall/group/broadcast", params);
  }

  /** Cmd `12043` — `GET {voice_call[0]}/api/voicecall/group/join`. */
  groupJoin(params: {
    userId: string;
    callId: string | number;
    hostCall: string;
    status: number;
    srcJoinCall?: number;
    audiostate?: number;
    videostate?: number;
    data?: unknown;
  }): Promise<unknown> {
    return this.getCall("/api/voicecall/group/join", params);
  }

  /** Cmd `12044` — `GET {voice_call[0]}/api/voicecall/group/sharescreen`. */
  groupShareScreen(params: {
    userId: string;
    callId: string | number;
    hostCall: string;
    status: number;
    audiostate?: number;
    videostate?: number;
    data?: unknown;
  }): Promise<unknown> {
    return this.getCall("/api/voicecall/group/sharescreen", params);
  }

  // ---- Supporting Call APIs ----

  /** GET `{profile[0]}/api/znoise` — converts internal/raw UIDs & group IDs to/from noised IDs. */
  resolveZNoise(fids: string[] = [], gids: string[] = []): Promise<unknown> {
    const url = this.http.serviceUrl("profile", "/api/znoise");
    return this.http.getEncrypted(url, { fids, gids });
  }

  /** POST `https://qos.talk.zing.vn/api/qos/uploadcalllog` — uploads gzipped call log. */
  async uploadCallLog(payload: {
    callId: string | number;
    ownerId: string;
    partnerId?: string;
    hostCall?: string;
    joinTime?: number;
    timestamp: number;
    duration: number;
    logType?: number;
    logBytes: Uint8Array | Buffer;
    alreadyGzipped?: boolean;
  }): Promise<unknown> {
    const gz = payload.alreadyGzipped
      ? Buffer.from(payload.logBytes)
      : gzipSync(Buffer.from(payload.logBytes));
    const form = new FormData();
    form.append("call_id", String(payload.callId));
    form.append("owner_id", payload.ownerId);
    if (payload.partnerId !== undefined) form.append("partner_id", payload.partnerId);
    if (payload.hostCall !== undefined) form.append("host_call", payload.hostCall);
    if (payload.joinTime !== undefined) form.append("join_time", String(payload.joinTime));
    form.append("time_stamp", String(payload.timestamp));
    form.append("duration", String(payload.duration));
    if (payload.logType !== undefined) form.append("log_type", String(payload.logType));
    form.append("file", new Blob([gz], { type: "application/gzip" }), "call.log.gz");

    const res = await this.http.requestRaw(QOS_UPLOAD_CALL_LOG_URL, {
      method: "POST",
      kind: "multipart",
      body: form,
    });
    if (!res.ok) {
      throw new ZaloApiError(`Call log upload failed with status ${res.status}`, res.status);
    }
    return res.json().catch(() => ({ ok: true }));
  }

  /**
   * Dispatches any numeric native `ZaloCall` signaling command (`401..12447`)
   * directly to its corresponding `/api/voicecall/*` endpoint.
   */
  dispatchNativeSignal(command: number, data: Record<string, unknown> = {}): Promise<unknown> {
    switch (command) {
      case CALL_SIGNAL_CMD.REQUEST_CALL:
        return this.getCall("/api/voicecall/requestcall", { imei: this.ctx.imei, ...data });
      case CALL_SIGNAL_CMD.REQUEST_INVITE:
        return this.getCall("/api/voicecall/request", { imei: this.ctx.imei, ...data });
      case CALL_SIGNAL_CMD.RING_RING:
        return this.getCall("/api/voicecall/ringring", { imei: this.ctx.imei, ...data });
      case CALL_SIGNAL_CMD.ANSWER:
        return this.getCall("/api/voicecall/answer", data);
      case CALL_SIGNAL_CMD.ANSWER_ACK:
        return this.getCall("/api/voicecall/answerack", { imei: this.ctx.imei, ...data });
      case CALL_SIGNAL_CMD.CANCEL:
        return this.getCall("/api/voicecall/cancel", { imei: this.ctx.imei, ...data });
      case CALL_SIGNAL_CMD.END_CALL:
        return this.getCall("/api/voicecall/endcall", { imei: this.ctx.imei, ...data });
      case CALL_SIGNAL_CMD.LOG_END_CALL:
        return this.logEndCall(data as unknown as LogEndCallParams);
      case CALL_SIGNAL_CMD.HOLD_REQ:
        return this.getCall("/api/voicecall/holdreq", data);
      case CALL_SIGNAL_CMD.HOLD_RESP:
        return this.getCall("/api/voicecall/holdresp", data);
      case CALL_SIGNAL_CMD.UNHOLD_REQ:
        return this.getCall("/api/voicecall/unholdreq", data);
      case CALL_SIGNAL_CMD.UNHOLD_RESP:
        return this.getCall("/api/voicecall/unholdresp", data);
      case CALL_SIGNAL_CMD.CONF:
        return this.getCall("/api/voicecall/conf", data);
      case CALL_SIGNAL_CMD.REQUEST_SHARE_SCREEN:
        return this.getCall("/api/voicecall/requestsharescreen", data);
      case CALL_SIGNAL_CMD.REQUEST_AUDIO_TO_VIDEO:
        return this.getCall("/api/voicecall/requestaudio2video", data);
      case CALL_SIGNAL_CMD.GROUP_REQUEST_CALL:
        return this.getCall("/api/voicecall/group/requestcall", data);
      case CALL_SIGNAL_CMD.GROUP_REQUEST_INVITE:
        return this.getCall("/api/voicecall/group/request", data);
      case CALL_SIGNAL_CMD.GROUP_ADD_USER:
        return this.getCall("/api/voicecall/group/adduser", data);
      case CALL_SIGNAL_CMD.GROUP_ANSWER:
        return this.getCall("/api/voicecall/group/answer", data);
      case CALL_SIGNAL_CMD.GROUP_CANCEL:
        return this.getCall("/api/voicecall/group/cancel", data);
      case CALL_SIGNAL_CMD.GROUP_END_CALL:
        return this.getCall("/api/voicecall/group/endcall", data);
      case CALL_SIGNAL_CMD.GROUP_RING_RING:
        return this.getCall("/api/voicecall/group/ringring", data);
      case CALL_SIGNAL_CMD.GROUP_STATE:
        return this.getCall("/api/voicecall/group/state", data);
      case CALL_SIGNAL_CMD.GROUP_FINISH:
        return this.getCall("/api/voicecall/group/finish", data);
      case CALL_SIGNAL_CMD.GROUP_NOTIFY:
        return this.getCall("/api/voicecall/group/notify", data);
      case CALL_SIGNAL_CMD.GROUP_PING:
        return this.getCall("/api/voicecall/group/ping", data);
      case CALL_SIGNAL_CMD.GROUP_BROADCAST:
        return this.getCall("/api/voicecall/group/broadcast", data);
      case CALL_SIGNAL_CMD.GROUP_JOIN:
        return this.getCall("/api/voicecall/group/join", data);
      case CALL_SIGNAL_CMD.GROUP_SHARE_SCREEN:
        return this.getCall("/api/voicecall/group/sharescreen", data);
      default:
        return Promise.reject(new ZaloApiError(`Unsupported native call signal command: ${command}`));
    }
  }
}
