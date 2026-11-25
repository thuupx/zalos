import { WS_CMD, WS_SUB_CMD } from "../core/constants.ts";
import type { ZaloContext } from "../core/context.ts";
import type { ZaloHttpClient } from "../core/http.ts";
import type { ZaloListener } from "../ws/listener.ts";

export interface PreKeyUpload {
  id: number;
  key: string;
}

export class E2eeApi {
  constructor(
    private readonly http: ZaloHttpClient,
    private readonly ctx: ZaloContext,
    private readonly getListener: () => ZaloListener,
  ) {}

  // ---- WebSocket Signal Protocol Commands (540..582) ----

  submitBundle(payload: {
    identityKey: string;
    signedPreKey: { id: number; key: string; signature: string };
    opKeys: PreKeyUpload[];
    deviceId: number;
  }): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.E2EE_SUBMIT_BUNDLE, WS_SUB_CMD.E2EE_REQUEST, payload);
  }

  getBundle(uids: Array<{ uid: string; deviceId?: number }>, isReInit = 0, isAutoUpgrade = 0): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.E2EE_GET_BUNDLE, WS_SUB_CMD.E2EE_REQUEST, {
      uids,
      isReInit,
      isAutoUpgrade,
    });
  }

  submitPreKeys(deviceId: number, id: number, opKeys: PreKeyUpload[]): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.E2EE_SUBMIT_PREKEYS, WS_SUB_CMD.E2EE_REQUEST, {
      deviceId,
      id,
      opKeys,
    });
  }

  initSession(type: number, uidTo: string, data: unknown): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.E2EE_INIT_SESSION, WS_SUB_CMD.E2EE_REQUEST, {
      type,
      uidTo,
      data,
    });
  }

  ackInitSession(type: number, uidTo: string, data: Array<Record<string, unknown>>): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.E2EE_ACK_INIT_SESSION, WS_SUB_CMD.E2EE_REQUEST, {
      type,
      uidTo,
      data,
    });
  }

  markSessionProcessed(queueName: string, info: unknown): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.E2EE_DONE_PROCESS_SESSION, WS_SUB_CMD.E2EE_REQUEST, {
      queueName,
      info,
    });
  }

  ackGroupSessionsStale(groupIds: string[], ts = Date.now()): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.E2EE_ACK_GROUP_STALE, WS_SUB_CMD.E2EE_REQUEST, {
      groupIds,
      ts,
    });
  }

  deleteKey(payload: { uids?: string[]; groupIds?: string[]; keyId: number; ts?: number }): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.E2EE_DELETE_KEY, WS_SUB_CMD.E2EE_REQUEST, {
      ts: Date.now(),
      ...payload,
    });
  }

  deleteOfflineAck(isGroup: boolean, delivereds: unknown[]): Promise<unknown> {
    const cmd = isGroup ? WS_CMD.E2EE_DELETE_QUEUE_ACK_GROUP : WS_CMD.E2EE_DELETE_QUEUE_ACK_1_1;
    return this.getListener().requestCommand(cmd, WS_SUB_CMD.E2EE_REQUEST, { delivereds });
  }

  checkCompatible(uids: string[]): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.E2EE_CHECK_COMPATIBLE, WS_SUB_CMD.E2EE_REQUEST, { uids });
  }

  initGroupSession(
    type: number,
    uidTo: string,
    tId: string,
    data: Array<Record<string, unknown>>,
  ): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.E2EE_INIT_SESSION_GROUP, WS_SUB_CMD.E2EE_REQUEST, {
      type,
      uidTo,
      tId,
      data,
    });
  }

  checkGroupCompatible(uids: string[], groupId: string, enableEE = 1): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.E2EE_CHECK_COMPATIBLE_GROUP, WS_SUB_CMD.E2EE_REQUEST, {
      uids,
      groupId,
      enableEE,
    });
  }

  getE2eeUsers(first = true, lastId: string | null = null): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.E2EE_GET_LIST_USER, WS_SUB_CMD.E2EE_REQUEST, {
      first,
      lastId,
      reqIid: 1,
    });
  }

  getKeyId(platformType = 2): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.E2EE_GET_KEY_ID, WS_SUB_CMD.E2EE_REQUEST, {
      platformType,
    });
  }

  enableE2ee(payload: Record<string, unknown>): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.E2EE_ENABLE, WS_SUB_CMD.E2EE_REQUEST, payload);
  }

  disableE2ee(payload: Record<string, unknown>): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.E2EE_DISABLE, WS_SUB_CMD.E2EE_REQUEST, payload);
  }

  downgradeGroupE2ee(destId: string, id: string | number, reason = 0): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.E2EE_DOWNGRADE_GROUP, WS_SUB_CMD.E2EE_REQUEST, {
      destId,
      id,
      reason,
    });
  }

  // ---- HTTP E2EE Messaging Endpoints (`chat_e2e` / `group_e2e`) ----

  sendE2eeMessage(
    kind: "sms" | "photo" | "file" | "gif" | "link" | "sticker" | "contact" | "quote" | "forward" | "mention",
    payload: Record<string, unknown>,
    isGroup = false,
  ): Promise<unknown> {
    const key = isGroup ? "group_e2e" : "chat_e2e";
    const path = isGroup ? `/api/e2ee/pc/group/${kind}` : `/api/e2ee/pc/message/${kind}`;
    const url = this.http.serviceUrl(key, path);
    return this.http.postEncrypted(url, { imei: this.ctx.imei, ...payload });
  }

  undoE2eeMessage(
    params: { msgId: string; clientId: number; cliMsgIdUndo: string; threadId: string; visibility?: number; destType?: number },
    isGroup = false,
  ): Promise<unknown> {
    const key = isGroup ? "group_e2e" : "chat_e2e";
    const path = isGroup ? "/api/e2ee/pc/group/undoMsg" : "/api/e2ee/pc/message/undo";
    const url = this.http.serviceUrl(key, path);
    return this.http.postEncrypted(
      url,
      isGroup
        ? {
            msgId: params.msgId,
            grid: params.threadId,
            clientId: params.clientId,
            visibility: params.visibility ?? 0,
            cliMsgIdUndo: params.cliMsgIdUndo,
            imei: this.ctx.imei,
          }
        : {
            msgId: params.msgId,
            toid: params.threadId,
            clientId: params.clientId,
            cliMsgIdUndo: params.cliMsgIdUndo,
            destType: params.destType ?? 3,
          },
    );
  }

  multiUndoE2eeMessage(threadId: string, msgs: unknown[], isGroup = false): Promise<unknown> {
    const key = isGroup ? "group_e2e" : "chat_e2e";
    const path = isGroup ? "/api/e2ee/pc/group/multiUndoMsg" : "/api/e2ee/pc/message/multi_undo";
    const url = this.http.serviceUrl(key, path);
    return this.http.postEncrypted(url, isGroup ? { grid: threadId, msgs } : { toid: threadId, msgs });
  }

  deleteE2eeMessage(payload: Record<string, unknown>, isGroup = false): Promise<unknown> {
    const key = isGroup ? "group_e2e" : "chat_e2e";
    const path = isGroup ? "/api/e2ee/pc/group/deleteMsg" : "/api/e2ee/pc/message/delete";
    const url = this.http.serviceUrl(key, path);
    return this.http.postEncrypted(url, { imei: this.ctx.imei, ...payload });
  }

  deleteE2eeConversation(payload: Record<string, unknown>, isGroup = false): Promise<unknown> {
    const key = isGroup ? "group_e2e" : "chat_e2e";
    const path = isGroup ? "/api/e2ee/pc/group/deleteConv" : "/api/e2ee/pc/message/deleteconver";
    const url = this.http.serviceUrl(key, path);
    return this.http.postEncrypted(url, { imei: this.ctx.imei, ...payload });
  }

  sendE2eeDelivered(payload: Record<string, unknown>, isGroup = false): Promise<unknown> {
    const key = isGroup ? "group_e2e" : "chat_e2e";
    const path = isGroup ? "/api/e2ee/pc/t/group/delivered" : "/api/e2ee/pc/t/message/delivered";
    const url = this.http.serviceUrl(key, path);
    return this.http.postEncrypted(url, payload);
  }

  sendE2eeSeen(payload: Record<string, unknown>, isGroup = false): Promise<unknown> {
    const key = isGroup ? "group_e2e" : "chat_e2e";
    const path = isGroup ? "/api/e2ee/pc/t/group/seen" : "/api/e2ee/pc/t/message/seen";
    const url = this.http.serviceUrl(key, path);
    return this.http.postEncrypted(url, { imei: this.ctx.imei, ...payload });
  }
}
