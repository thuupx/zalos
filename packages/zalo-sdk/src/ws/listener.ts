import { EventEmitter } from "node:events";
import WebSocket from "ws";

import { WS_CMD, WS_SUB_CMD } from "../core/constants.ts";
import type { ZaloContext } from "../core/context.ts";
import { decodeWsPayload, parseJsonSafe, type WsEnvelope } from "../core/crypto.ts";
import { ZaloProtocolError } from "../core/errors.ts";
import {
  CloseReason,
  FriendEventType,
  GroupEventType,
  ThreadType,
} from "../models/enums.ts";
import type {
  ActionItem,
  ControlItem,
  DeliveredMessage,
  FriendEvent,
  GroupEvent,
  SeenMessage,
  TMessage,
  TReaction,
  TypingEvent,
  UndoEvent,
  VoipControlEvent,
  ZaloMessage,
  ZaloReaction,
} from "../models/events.ts";
import { decodeWsFrame, encodeWsFrame } from "./framing.ts";

export interface ListenerOptions {
  /** Reconnect automatically on close (default false so callers may own backoff). */
  retryOnClose?: boolean;
  /** Keepalive ping interval in ms (default 60_000, or server settings socket.ping_interval). */
  pingIntervalMs?: number;
  /** Optional hook reporting whether an active call is running (`"zalo"` busy annotation). */
  isInCall?: () => boolean;
}

const DEFAULT_RETRY_TIMES = [2000, 3000, 5000, 8000];

export class ZaloListener extends EventEmitter {
  readonly ctx: ZaloContext;
  private readonly options: ListenerOptions;
  private ws: WebSocket | null = null;
  private cipherKey: string | undefined;
  private authenticated = false;
  private manualStop = false;
  private pingTimer: ReturnType<typeof setInterval> | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private retryCount = 0;
  private wsIndex = 0;
  private reqCounter = 1;
  private pendingRequests = new Map<
    number | string,
    { resolve: (value: unknown) => void; reject: (err: Error) => void; timer: ReturnType<typeof setTimeout> }
  >();
  private queuedFrames: Buffer[] = [];
  private lastVoipActionTs = new Map<string, number>();

  constructor(ctx: ZaloContext, options: ListenerOptions = {}) {
    super();
    this.ctx = ctx;
    this.options = options;
  }

  get isConnected(): boolean {
    return this.ws !== null && this.ws.readyState === WebSocket.OPEN;
  }

  get currentCipherKey(): string | undefined {
    return this.cipherKey;
  }

  start(opts: { retryOnClose?: boolean } = {}): void {
    if (opts.retryOnClose !== undefined) {
      this.options.retryOnClose = opts.retryOnClose;
    }
    this.manualStop = false;
    this.openSocket();
  }

  stop(code = CloseReason.Normal, reason = "manual"): void {
    this.manualStop = true;
    this.clearTimers();
    this.rejectAllPending(new Error("WebSocket listener stopped"));
    if (this.ws) {
      try {
        this.ws.close(code, reason);
      } catch {
        this.ws.terminate();
      }
      this.ws = null;
    }
    this.authenticated = false;
  }

  private openSocket(): void {
    const urls = this.ctx.wsUrls;
    if (!urls.length) {
      this.emit("error", new ZaloProtocolError("No WebSocket URLs in session (zpw_ws empty)"));
      return;
    }
    const base = urls[this.wsIndex % urls.length]!;
    const url = new URL(base);
    url.searchParams.set("t", String(Date.now()));
    if (!url.searchParams.has("zpw_ver")) {
      url.searchParams.set("zpw_ver", String(this.ctx.apiVersion));
    }
    if (!url.searchParams.has("zpw_type")) {
      url.searchParams.set("zpw_type", String(this.ctx.apiType));
    }

    const cookie = this.ctx.cookie.getCookieStringSync(url.toString());
    const ws = new WebSocket(url.toString(), {
      headers: {
        ...(cookie ? { Cookie: cookie } : {}),
        "User-Agent": this.ctx.userAgent,
        Origin: this.ctx.profile.wsOrigin,
      },
    });
    ws.binaryType = "arraybuffer";
    this.ws = ws;

    ws.on("message", (raw: Buffer | ArrayBuffer | Buffer[]) => {
      const buf = Array.isArray(raw)
        ? Buffer.concat(raw)
        : raw instanceof ArrayBuffer
          ? Buffer.from(raw)
          : raw;
      this.handleBinaryFrame(buf);
    });

    ws.on("error", (err) => {
      this.emit("error", err);
    });

    ws.on("close", (code, reasonBuf) => {
      const reason = reasonBuf?.toString("utf8") ?? "";
      this.clearTimers();
      this.authenticated = false;
      if (this.ws === ws) this.ws = null;

      this.emit("disconnected", code, reason);
      if (this.manualStop || !this.options.retryOnClose || code === CloseReason.Normal) {
        this.emit("closed", code, reason);
        return;
      }

      if (code === CloseReason.DuplicateConnection || code === CloseReason.KickConnection) {
        // Let caller or reconnect schedule handle kick codes explicitly.
        if (code === CloseReason.DuplicateConnection) {
          this.emit("closed", code, reason);
          return;
        }
      }

      this.wsIndex = (this.wsIndex + 1) % urls.length;
      const delay =
        DEFAULT_RETRY_TIMES[Math.min(this.retryCount, DEFAULT_RETRY_TIMES.length - 1)] ?? 8000;
      this.retryCount += 1;
      this.reconnectTimer = setTimeout(() => this.openSocket(), delay);
    });
  }

  sendFrame(cmd: number, subCmd: number, payload: unknown): void {
    const frame = encodeWsFrame(1, cmd, subCmd, payload);
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      this.queuedFrames.push(frame);
      return;
    }
    this.ws.send(frame);
  }

  sendLightweightPing(at = Date.now()): number {
    const reqId = this.nextReqId();
    this.sendFrame(WS_CMD.PING_ACTIVE, 1, { at, reqId });
    return reqId;
  }

  requestCommand<T = unknown>(
    cmd: number,
    subCmd: number,
    data: Record<string, unknown>,
    timeoutMs = 10_000,
    useSnakeReqId = false,
  ): Promise<T> {
    const reqId = this.nextReqId();
    const payload = useSnakeReqId ? { ...data, req_id: `req_${reqId}` } : { ...data, reqId };
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingRequests.delete(reqId);
        reject(new ZaloProtocolError(`WebSocket request timeout for cmd=${cmd} subCmd=${subCmd}`));
      }, timeoutMs);
      this.pendingRequests.set(reqId, {
        resolve: resolve as (v: unknown) => void,
        reject,
        timer,
      });
      this.sendFrame(cmd, subCmd, payload);
    });
  }

  requestOldMessages(threadType: ThreadType, lastId: string | null = null): void {
    const cmd = threadType === ThreadType.Group ? WS_CMD.OFFLINE_MSG_GROUP : WS_CMD.OFFLINE_MSG_1_1;
    this.sendFrame(cmd, WS_SUB_CMD.OFFLINE_V2, {
      first: lastId === null,
      lastId,
      preIds: [],
      req_id: `req_${this.nextReqId()}`,
    });
  }

  requestOldReactions(threadType: ThreadType, lastId: string | null = null): void {
    const cmd = threadType === ThreadType.Group ? WS_CMD.CTRL_PULL_REACT_GROUP : WS_CMD.CTRL_PULL_REACT;
    this.sendFrame(cmd, WS_SUB_CMD.OFFLINE_V2, {
      first: lastId === null,
      lastId,
      preIds: [],
      req_id: `req_${this.nextReqId()}`,
    });
  }

  pullOfflineControl(lastId: string | null = null): void {
    this.sendFrame(WS_CMD.CTRL_PULL_CTRL, WS_SUB_CMD.OFFLINE_V1, {
      first: lastId === null,
      lastId,
      preIds: [],
      reqId: this.nextReqId(),
    });
  }

  pullOfflineVoip(lastId: string | null = null): void {
    this.sendFrame(WS_CMD.CTRL_PULL_VOIP, WS_SUB_CMD.OFFLINE_V1, {
      first: lastId === null,
      lastId,
      preIds: [],
      reqId: this.nextReqId(),
    });
  }

  private handleBinaryFrame(buf: Buffer): void {
    let frame;
    try {
      frame = decodeWsFrame(buf);
    } catch (err) {
      this.emit("error", err);
      return;
    }

    if (!frame.bodyText) return;
    let envelope: WsEnvelope;
    try {
      envelope = parseJsonSafe<WsEnvelope>(frame.bodyText);
    } catch (err) {
      this.emit("error", err);
      return;
    }

    if (frame.cmd === WS_CMD.AUTHEN && frame.subCmd === WS_SUB_CMD.AUTHEN) {
      if (typeof envelope.key === "string" && envelope.key.length > 0) {
        this.cipherKey = envelope.key;
      }
      let decoded: unknown = envelope;
      try {
        decoded = decodeWsPayload(envelope, this.cipherKey);
      } catch {
        // Handshake succeeded with cipherKey; ignore non-JSON opaque AUTHEN data (as the official web client does).
      }
      this.authenticated = true;
      this.retryCount = 0;
      this.startPingTimer();
      this.flushQueuedFrames();
      this.emit("connected", decoded);
      this.emit("raw_frame", { ...frame, envelope, data: decoded });
      return;
    }

    if (frame.cmd === WS_CMD.MAX_CONNECTION || envelope.error_code === 600) {
      this.emit("kickout", { cmd: frame.cmd, subCmd: frame.subCmd, envelope });
      this.stop(CloseReason.DuplicateConnection, "max_connection");
      return;
    }

    const decoded = this.safeDecode(envelope) as {
      error_code?: number;
      data?: Record<string, unknown>;
      reqId?: number;
      req_id?: string | number;
      [k: string]: unknown;
    } | null;

    if (!decoded) return;
    const inner = (decoded.data !== undefined && typeof decoded.data === "object" && decoded.data !== null
      ? decoded.data
      : decoded) as Record<string, unknown>;

    this.emit("raw_frame", { ...frame, envelope, data: decoded });

    const reqId = (inner.reqId ?? decoded.reqId ?? inner.req_id ?? decoded.req_id) as
      | number
      | string
      | undefined;
    if (reqId !== undefined) {
      const numericId =
        typeof reqId === "string" && reqId.startsWith("req_") ? Number(reqId.slice(4)) : Number(reqId);
      const pending = this.pendingRequests.get(numericId) ?? this.pendingRequests.get(reqId);
      if (pending) {
        this.pendingRequests.delete(numericId);
        this.pendingRequests.delete(reqId);
        clearTimeout(pending.timer);
        pending.resolve(inner);
      }
    }

    this.dispatchCommand(frame.cmd, frame.subCmd, inner);
  }

  private safeDecode(envelope: WsEnvelope): unknown {
    try {
      return decodeWsPayload(envelope, this.cipherKey);
    } catch (err) {
      this.emit("error", err);
      return null;
    }
  }

  private dispatchCommand(cmd: number, subCmd: number, data: Record<string, unknown>): void {
    switch (cmd) {
      case WS_CMD.PING:
      case WS_CMD.PING_ACTIVE:
        this.emit("pong", data);
        return;

      case WS_CMD.PUSH_MSG_1_1:
      case WS_CMD.PUSH_MSG_GROUP:
      case WS_CMD.PUSH_MISS_MSG:
      case WS_CMD.GET_MSG: {
        const isGroup = cmd === WS_CMD.PUSH_MSG_GROUP || Boolean(data.groupMsgs);
        const list = (data.groupMsgs ?? data.msgs ?? []) as TMessage[];
        if (Array.isArray(list)) {
          for (const m of list) this.handleInboundMessage(m, isGroup, false);
        }
        return;
      }

      case WS_CMD.OFFLINE_MSG_1_1:
      case WS_CMD.OFFLINE_MSG_1_1_IDZ3:
      case WS_CMD.OFFLINE_MSG_GROUP:
      case WS_CMD.OFFLINE_MSG_GROUP_IDZ3: {
        const isGroup =
          cmd === WS_CMD.OFFLINE_MSG_GROUP || cmd === WS_CMD.OFFLINE_MSG_GROUP_IDZ3;
        const rawList = (isGroup ? data.groupMsgs : data.msgs) as TMessage[] | undefined;
        if (Array.isArray(rawList) && rawList.length > 0) {
          const normalized = rawList
            .map((m) => this.normalizeMessage(m, isGroup))
            .filter((x): x is ZaloMessage => x !== null);
          if (normalized.length > 0) {
            this.emit("old_messages", normalized, isGroup ? ThreadType.Group : ThreadType.User);
          }
        }
        return;
      }

      case WS_CMD.PUSH_STATUS_1_1:
      case WS_CMD.PUSH_STATUS_GROUP: {
        const isGroup = cmd === WS_CMD.PUSH_STATUS_GROUP;
        const threadType = isGroup ? ThreadType.Group : ThreadType.User;
        const delivereds = data.delivereds as Array<Record<string, unknown>> | undefined;
        if (Array.isArray(delivereds) && delivereds.length > 0) {
          const mapped: DeliveredMessage[] = delivereds.map((d) => ({
            type: threadType,
            threadId: String(d.groupId ?? d.idTo ?? (Array.isArray(d.deliveredUids) ? d.deliveredUids[0] ?? "" : "")),
            isSelf: false,
            data: d as DeliveredMessage["data"],
          }));
          this.emit("delivered_messages", mapped);
        }
        const seensRaw = (isGroup ? data.groupSeens : data.seens) as Array<Record<string, unknown>> | undefined;
        if (Array.isArray(seensRaw) && seensRaw.length > 0) {
          const mapped: SeenMessage[] = seensRaw.map((s) => ({
            type: threadType,
            threadId: String(isGroup ? (s.groupId ?? s.idTo ?? "") : (s.idTo ?? s.msgSender ?? "")),
            isSelf: String(s.msgSender ?? "") === this.ctx.uid,
            data: s as SeenMessage["data"],
          }));
          this.emit("seen_messages", mapped);
        }
        return;
      }

      case WS_CMD.CLEAR_UNREADS_1_1:
      case WS_CMD.CLEAR_UNREADS_GROUP:
        this.emit("clear_unreads", {
          threadType: cmd === WS_CMD.CLEAR_UNREADS_GROUP ? ThreadType.Group : ThreadType.User,
          data,
        });
        return;

      case WS_CMD.CTRL_PUSH_REACT:
      case WS_CMD.CTRL_PULL_REACT:
      case WS_CMD.CTRL_PULL_REACT_GROUP: {
        const isOld = cmd === WS_CMD.CTRL_PULL_REACT || cmd === WS_CMD.CTRL_PULL_REACT_GROUP;
        const oneOne = (data.reacts ?? []) as Array<Record<string, unknown>>;
        const grp = (data.reactGroups ?? []) as Array<Record<string, unknown>>;
        const parseList = (items: Array<Record<string, unknown>>, isGroup: boolean): ZaloReaction[] =>
          items.map((item) => {
            const parsedContent =
              typeof item.content === "string" ? parseJsonSafe(item.content) : item.content;
            const r = { ...item, content: parsedContent } as unknown as TReaction;
            const isSelf = r.uidFrom === "0" || r.uidFrom === this.ctx.uid;
            if (r.uidFrom === "0") r.uidFrom = this.ctx.uid;
            if (r.idTo === "0") r.idTo = this.ctx.uid;
            const threadId = isGroup || isSelf ? String(r.idTo) : String(r.uidFrom);
            return {
              type: isGroup ? ThreadType.Group : ThreadType.User,
              threadId,
              isSelf,
              isGroup,
              data: r,
            };
          });

        if (isOld) {
          const list =
            cmd === WS_CMD.CTRL_PULL_REACT_GROUP ? parseList(grp, true) : parseList(oneOne, false);
          if (list.length > 0) {
            this.emit(
              "old_reactions",
              list,
              cmd === WS_CMD.CTRL_PULL_REACT_GROUP ? ThreadType.Group : ThreadType.User,
            );
          }
        } else {
          for (const r of [...parseList(oneOne, false), ...parseList(grp, true)]) {
            if (!r.isSelf || this.ctx.options.selfListen) {
              this.emit("reaction", r);
            }
          }
        }
        return;
      }

      case WS_CMD.CTRL_PUSH_CLEAR_REACT:
        this.emit("clear_reaction", data);
        return;

      case WS_CMD.CTRL_ACTION: {
        const actions = data.actions as ActionItem[] | undefined;
        if (!Array.isArray(actions)) return;
        for (const action of actions) {
          this.handleAction(action);
        }
        return;
      }

      case WS_CMD.CTRL_PUSH_CTRL:
      case WS_CMD.CTRL_PULL_CTRL: {
        const controls = data.controls as ControlItem[] | undefined;
        if (!Array.isArray(controls)) return;
        for (const item of controls) {
          this.handleControl(item);
        }
        return;
      }

      case WS_CMD.CTRL_PULL_VOIP: {
        const controls = (data.controls ?? data.voips ?? []) as ControlItem[];
        if (Array.isArray(controls)) {
          for (const item of controls) this.handleControl(item);
        }
        return;
      }

      case WS_CMD.CLOUD_PUSH:
      case WS_CMD.CLOUD_NEED_VERIFY:
      case WS_CMD.CLOUD_DONE_MIGRATE:
        this.emit("cloud_event", { cmd, data });
        return;

      case WS_CMD.PUSH_INTERACTIVE_FILE:
        this.emit("interactive_file", data);
        return;

      default: {
        // E2EE / Signal commands (513..582 except messaging ones handled above)
        if (
          (cmd >= 513 && cmd <= 519) ||
          (cmd >= 535 && cmd <= 564) ||
          (cmd >= 580 && cmd <= 582) ||
          cmd === 713 ||
          cmd === 715
        ) {
          if (cmd === WS_CMD.E2EE_MSG_RECEIVE_1_1 || cmd === WS_CMD.E2EE_MSG_RECEIVE_GROUP) {
            this.emit("e2ee_message", { cmd, subCmd, data });
          } else if (
            cmd === WS_CMD.E2EE_ACK_DELIVER_SEEN_1_1 ||
            cmd === WS_CMD.E2EE_ACK_DELIVER_SEEN_GROUP ||
            cmd === WS_CMD.E2EE_OFFLINE_ACK_1_1 ||
            cmd === WS_CMD.E2EE_OFFLINE_ACK_GROUP
          ) {
            this.emit("e2ee_ack", { cmd, subCmd, data });
          } else {
            this.emit("e2ee_init", { cmd, subCmd, data });
          }
          this.emit("e2ee_control", { cmd, subCmd, data });
        }
      }
    }
  }

  private normalizeMessage(raw: TMessage, isGroup: boolean): ZaloMessage | null {
    const msg = { ...raw };
    const isSelf = msg.uidFrom === "0" || msg.uidFrom === this.ctx.uid;
    if (msg.uidFrom === "0") msg.uidFrom = this.ctx.uid;
    if (msg.idTo === "0") msg.idTo = this.ctx.uid;
    if (!isSelf || this.ctx.options.selfListen) {
      const threadId = isGroup || isSelf ? String(msg.idTo) : String(msg.uidFrom);
      return isGroup
        ? { type: ThreadType.Group, threadId, isSelf, data: msg }
        : { type: ThreadType.User, threadId, isSelf, data: msg };
    }
    return null;
  }

  private handleInboundMessage(raw: TMessage, isGroup: boolean, isOld: boolean): void {
    if (
      raw.content &&
      typeof raw.content === "object" &&
      "deleteMsg" in raw.content &&
      !isOld
    ) {
      const isSelf = raw.uidFrom === "0" || raw.uidFrom === this.ctx.uid;
      const uidFrom = raw.uidFrom === "0" ? this.ctx.uid : raw.uidFrom;
      const idTo = raw.idTo === "0" ? this.ctx.uid : raw.idTo;
      const undoEvt: UndoEvent = {
        type: isGroup ? ThreadType.Group : ThreadType.User,
        threadId: isGroup || isSelf ? String(idTo) : String(uidFrom),
        isSelf,
        isGroup,
        data: { ...raw, uidFrom, idTo } as UndoEvent["data"],
      };
      if (!isSelf || this.ctx.options.selfListen) {
        this.emit("undo", undoEvt);
      }
      return;
    }

    const msg = this.normalizeMessage(raw, isGroup);
    if (msg) this.emit("message", msg);
  }

  private handleAction(action: ActionItem): void {
    this.emit("action", action);
    const { act_type, act, data } = action;
    if (act_type === "typing") {
      // Zalo PC quirk: typing action.data omits outer curly braces.
      const parsed =
        typeof data === "string"
          ? parseJsonSafe<Record<string, unknown>>(
              data.trim().startsWith("{") ? data : `{${data}}`,
            )
          : ((data ?? {}) as Record<string, unknown>);
      const isGroup = act === "gtyping" || Boolean(parsed.gid);
      const uid = String(parsed.uid ?? "");
      const threadId = String(parsed.gid ?? uid);
      const evt: TypingEvent = {
        type: isGroup ? ThreadType.Group : ThreadType.User,
        threadId,
        isSelf: uid === this.ctx.uid,
        data: parsed as TypingEvent["data"],
      };
      this.emit("typing", evt);
      return;
    }

    if (act_type === "fsending") {
      const parsed =
        typeof data === "string" ? parseJsonSafe<Record<string, unknown>>(data) : data;
      this.emit("file_sending", { act, data: parsed });
      return;
    }

    if (act_type === "profile" && act === "online_status") {
      this.emit("online_status", typeof data === "string" ? parseJsonSafe(data) : data);
      return;
    }

    if (act_type === "profile" && act === "ekyc") {
      this.emit("ekyc", typeof data === "string" ? parseJsonSafe(data) : data);
      return;
    }

    if (act_type === "recent_search") {
      this.emit("recent_search", typeof data === "string" ? parseJsonSafe(data) : data);
    }
  }

  private handleControl(item: ControlItem): void {
    const content = item.content;
    if (!content) return;
    const rawData =
      typeof content.data === "string" &&
      (content.data.startsWith("{") || content.data.startsWith("["))
        ? parseJsonSafe<Record<string, unknown>>(content.data)
        : ((content.data ?? {}) as Record<string, unknown>);

    this.emit("control", { ...item, content: { ...content, data: rawData } });

    const { act_type, act } = content;

    // Async media upload completion callbacks (`asyncfile/upload`)
    if (
      act_type === "file_done" ||
      act_type === "video_done" ||
      act_type === "photo_success" ||
      act_type === "voice_aac_success"
    ) {
      const fileId = String(content.fileId ?? rawData.fileId ?? "");
      const cb = this.ctx.uploadCallbacks.get(fileId);
      if (cb) {
        this.ctx.uploadCallbacks.delete(fileId);
        cb(rawData);
      }
      this.emit("upload_done", { actType: act_type, fileId, data: rawData });
      return;
    }

    // VoIP call signaling push (`act_type === "voip"`)
    if (act_type === "voip") {
      const tsRaw = Number(rawData.ts ?? content.ts ?? Date.now());
      // Drop stale call invites older than 60 seconds per Zalo PC OU7N rule.
      if (Number.isFinite(tsRaw) && Date.now() - tsRaw > 60_000) {
        this.emit("voip_dropped_stale", { act, data: rawData });
        return;
      }
      const inCallStatus =
        (act === "request" || act === "group_request") && this.options.isInCall?.()
          ? "zalo"
          : null;
      const conversationId = String(
        rawData.uidN ?? rawData.groupId ?? rawData.gid ?? rawData.callerId ?? rawData.fromUid ?? "",
      );
      if (
        conversationId &&
        (act === "request" || act === "answer" || act === "group_request" || act === "group_answer")
      ) {
        this.lastVoipActionTs.set(conversationId, tsRaw);
      }
      const voipEvent: VoipControlEvent = {
        actType: "voip",
        act: act ?? "",
        ts: tsRaw,
        conversationId: conversationId || undefined,
        callerId: rawData.callerId ? String(rawData.callerId) : rawData.fromUid ? String(rawData.fromUid) : undefined,
        groupId: rawData.groupId ? String(rawData.groupId) : rawData.gid ? String(rawData.gid) : undefined,
        inCallStatus,
        data: rawData,
        raw: content,
      };
      this.emit("voip_control", voipEvent);
      return;
    }

    if (act_type === "group") {
      const eventType = Object.values(GroupEventType).includes(act as GroupEventType)
        ? (act as GroupEventType)
        : GroupEventType.UNKNOWN;
      const threadId = String(rawData.groupId ?? rawData.grid ?? rawData.gid ?? "");
      const evt: GroupEvent = {
        type: eventType,
        threadId,
        act,
        data: rawData,
        isSelf: String(rawData.creatorId ?? rawData.sourceId ?? "") === this.ctx.uid,
      };
      this.emit("group_event", evt);
      return;
    }

    if (act_type === "fr") {
      const eventType = Object.values(FriendEventType).includes(act as FriendEventType)
        ? (act as FriendEventType)
        : FriendEventType.UNKNOWN;
      const threadId = String(rawData.uid ?? rawData.fid ?? rawData.conversationId ?? "");
      const evt: FriendEvent = {
        type: eventType,
        threadId,
        act,
        data: rawData,
      };
      this.emit("friend_event", evt);
      return;
    }

    if (act_type === "poll") {
      this.emit("poll_event", { act: act ?? content.action, data: rawData });
      return;
    }

    if (act_type === "oneone" || act_type === "personal_board") {
      this.emit("reminder_event", { actType: act_type, act, data: rawData });
      return;
    }

    if (
      act_type === "pinned_convers" ||
      act_type === "mute" ||
      act_type === "archived_chat" ||
      act_type === "hidden_chat" ||
      act_type === "mark_unread" ||
      act_type === "label_convers" ||
      act_type === "conv_settings"
    ) {
      this.emit("conversation_sync", { actType: act_type, act, controlId: item.controlId, data: rawData });
    }
  }

  getLastVoipActionTs(conversationId: string): number | undefined {
    return this.lastVoipActionTs.get(conversationId);
  }

  private startPingTimer(): void {
    if (this.pingTimer) clearInterval(this.pingTimer);
    const settingsSocket = (this.ctx.settings.features as Record<string, unknown> | undefined)?.socket as
      | Record<string, unknown>
      | undefined;
    const ms =
      this.options.pingIntervalMs ??
      (typeof settingsSocket?.ping_interval === "number" ? settingsSocket.ping_interval : 60_000);
    this.pingTimer = setInterval(() => {
      if (this.ws && this.ws.readyState === WebSocket.OPEN && this.authenticated) {
        this.sendFrame(WS_CMD.PING, WS_SUB_CMD.PING_CONNECTION, { eventId: Date.now() });
      }
    }, ms);
  }

  private flushQueuedFrames(): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    while (this.queuedFrames.length > 0) {
      const f = this.queuedFrames.shift()!;
      this.ws.send(f);
    }
  }

  private clearTimers(): void {
    if (this.pingTimer) {
      clearInterval(this.pingTimer);
      this.pingTimer = null;
    }
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  private rejectAllPending(err: Error): void {
    for (const [, p] of this.pendingRequests) {
      clearTimeout(p.timer);
      p.reject(err);
    }
    this.pendingRequests.clear();
  }

  private nextReqId(): number {
    this.reqCounter += 1;
    return this.reqCounter;
  }
}
