import type { ZaloContext } from "../core/context.ts";
import type { ZaloHttpClient } from "../core/http.ts";
import type { LabelData } from "../models/entities.ts";
import { MuteAction, MuteDuration, ThreadType } from "../models/enums.ts";

export interface SetMuteOptions {
  duration?: MuteDuration | number;
  action?: MuteAction;
}

export class ConversationsApi {
  constructor(
    private readonly http: ZaloHttpClient,
    private readonly ctx: ZaloContext,
  ) {}

  /** POST `{conversation[0]}/api/pinconvers/updatev2`. */
  async setPinnedConversations(
    pinned: boolean,
    threadId: string | string[],
    type: ThreadType = ThreadType.User,
  ): Promise<unknown> {
    const ids = Array.isArray(threadId) ? threadId : [threadId];
    const url = this.http.serviceUrl("conversation", "/api/pinconvers/updatev2");
    const prefix = type === ThreadType.Group ? "g" : "u";
    return this.http.postEncrypted(url, {
      actionType: pinned ? 1 : 2,
      conversations: ids.map((id) => (id.startsWith("u") || id.startsWith("g") ? id : `${prefix}${id}`)),
    });
  }

  /** GET `{conversation[0]}/api/pinconvers/list`. */
  async getPinConversations(): Promise<{ conversations: string[]; version?: number }> {
    const url = this.http.serviceUrl("conversation", "/api/pinconvers/list");
    return this.http.getEncrypted(url, { imei: this.ctx.imei });
  }

  /** POST `{profile[0]}/api/social/profile/setmute`. */
  async setMute(
    options: SetMuteOptions = {},
    threadId: string,
    type: ThreadType = ThreadType.User,
  ): Promise<unknown> {
    const action = options.action ?? MuteAction.MUTE;
    const duration = options.duration ?? MuteDuration.FOREVER;
    let muteDuration: number;
    if (action === MuteAction.UNMUTE || duration === MuteDuration.FOREVER) {
      muteDuration = -1;
    } else if (duration === MuteDuration.UNTIL_8AM) {
      const now = new Date();
      const next8AM = new Date(now);
      next8AM.setHours(8, 0, 0, 0);
      if (now.getHours() >= 8) next8AM.setDate(next8AM.getDate() + 1);
      muteDuration = Math.floor((next8AM.getTime() - now.getTime()) / 1000);
    } else {
      muteDuration = Number(duration);
    }

    const url = this.http.serviceUrl("profile", "/api/social/profile/setmute");
    return this.http.postEncrypted(url, {
      toid: threadId,
      duration: muteDuration,
      action,
      startTime: Math.floor(Date.now() / 1000),
      muteType: type === ThreadType.User ? 1 : 2,
      imei: this.ctx.imei,
    });
  }

  /** GET `{profile[0]}/api/social/profile/getmute`. */
  async getMute(): Promise<{
    chatEntries: Array<{
      id: string;
      duration: number;
      startTime: number;
      systemTime: number;
      currentTime: number;
      muteMode: number;
    }>;
    groupChatEntries: Array<{
      id: string;
      duration: number;
      startTime: number;
      systemTime: number;
      currentTime: number;
      muteMode: number;
    }>;
  }> {
    const url = this.http.serviceUrl("profile", "/api/social/profile/getmute");
    return this.http.getEncrypted(url, { imei: this.ctx.imei });
  }

  /** GET `{conversation[0]}/api/hiddenconvers/get-all`. */
  async getHiddenConversations(): Promise<unknown> {
    const url = this.http.serviceUrl("conversation", "/api/hiddenconvers/get-all");
    return this.http.getEncrypted(url, { imei: this.ctx.imei });
  }

  /** POST `{conversation[0]}/api/hiddenconvers/add-remove`. */
  async setHiddenConversations(
    hidden: boolean,
    threadId: string | string[],
    type: ThreadType = ThreadType.User,
  ): Promise<unknown> {
    const ids = Array.isArray(threadId) ? threadId : [threadId];
    const isGroup = type === ThreadType.Group ? 1 : 0;
    const url = this.http.serviceUrl("conversation", "/api/hiddenconvers/add-remove");
    return this.http.postEncrypted(url, {
      [hidden ? "add_threads" : "del_threads"]: JSON.stringify(
        ids.map((id) => ({ thread_id: id, is_group: isGroup })),
      ),
      [hidden ? "del_threads" : "add_threads"]: "[]",
      imei: this.ctx.imei,
    });
  }

  /** GET `{conversation[0]}/api/hiddenconvers/update-pin`. */
  async updateHiddenConversPin(newPin: string): Promise<unknown> {
    const url = this.http.serviceUrl("conversation", "/api/hiddenconvers/update-pin");
    return this.http.getEncrypted(url, { new_pin: newPin, imei: this.ctx.imei });
  }

  /** GET `{conversation[0]}/api/hiddenconvers/reset`. */
  async resetHiddenConversPin(): Promise<unknown> {
    const url = this.http.serviceUrl("conversation", "/api/hiddenconvers/reset");
    return this.http.getEncrypted(url, {});
  }

  /** GET `{label[0]}/api/archivedchat/list`. */
  async getArchivedChatList(): Promise<unknown> {
    const url = this.http.serviceUrl("label", "/api/archivedchat/list");
    return this.http.getEncrypted(url, { version: 1, imei: this.ctx.imei });
  }

  /** POST `{label[0]}/api/archivedchat/update`. */
  async updateArchivedChatList(
    isArchived: boolean,
    threadsOrIds: string | string[] | Array<{ id: string; type: ThreadType }>,
    type: ThreadType = ThreadType.User,
  ): Promise<{ needSync?: unknown; needResync?: unknown; version?: number }> {
    const list = Array.isArray(threadsOrIds) ? threadsOrIds : [threadsOrIds];
    const ids = list.map((item) => (typeof item === "string" ? { id: item, type } : item));
    const url = this.http.serviceUrl("label", "/api/archivedchat/update");
    return this.http.postEncrypted(url, {
      actionType: isArchived ? 0 : 1,
      ids,
      imei: this.ctx.imei,
      version: 0,
    });
  }

  /** POST `{conversation[0]}/api/conv/addUnreadMark`. */
  async addUnreadMark(
    threadId: string,
    type: ThreadType = ThreadType.User,
  ): Promise<unknown> {
    const isGroup = type === ThreadType.Group;
    const url = this.http.serviceUrl("conversation", "/api/conv/addUnreadMark");
    return this.http.postEncrypted(url, {
      param: JSON.stringify({
        [isGroup ? "convsGroup" : "convsUser"]: [
          { id: threadId, cliMsgId: Date.now(), fromUid: this.ctx.uid, ts: Date.now() },
        ],
        [isGroup ? "convsUser" : "convsGroup"]: [],
        imei: this.ctx.imei,
      }),
    });
  }

  /** POST `{conversation[0]}/api/conv/removeUnreadMark`. */
  async removeUnreadMark(
    threadId: string,
    type: ThreadType = ThreadType.User,
  ): Promise<unknown> {
    const isGroup = type === ThreadType.Group;
    const url = this.http.serviceUrl("conversation", "/api/conv/removeUnreadMark");
    return this.http.postEncrypted(url, {
      param: JSON.stringify({
        [isGroup ? "convsGroup" : "convsUser"]: [{ id: threadId, ts: Date.now() }],
        [isGroup ? "convsUser" : "convsGroup"]: [],
      }),
    });
  }

  /** GET `{conversation[0]}/api/conv/getUnreadMark`. */
  async getUnreadMark(): Promise<unknown> {
    const url = this.http.serviceUrl("conversation", "/api/conv/getUnreadMark");
    const res = await this.http.getEncrypted<{ data?: unknown; status?: number }>(url, {});
    if (res && typeof res.data === "string") {
      return { ...res, data: JSON.parse(res.data) };
    }
    return res;
  }

  /** GET `{conversation[0]}/api/conv/autodelete/getConvers`. */
  async getAutoDeleteChat(): Promise<unknown> {
    const url = this.http.serviceUrl("conversation", "/api/conv/autodelete/getConvers");
    return this.http.getEncrypted(url, {});
  }

  /** POST `{conversation[0]}/api/conv/autodelete/updateConvers`. */
  async updateAutoDeleteChat(
    ttl: number,
    threadId: string,
    type: ThreadType = ThreadType.User,
  ): Promise<unknown> {
    const url = this.http.serviceUrl("conversation", "/api/conv/autodelete/updateConvers");
    return this.http.postEncrypted(url, {
      threadId,
      isGroup: type === ThreadType.Group ? 1 : 0,
      ttl,
      clientLang: this.ctx.language,
    });
  }

  /** GET `{label[0]}/api/convlabel/get`. */
  async getLabels(): Promise<{ labelData: LabelData[]; version: number; lastUpdateTime?: number }> {
    const url = this.http.serviceUrl("label", "/api/convlabel/get");
    const res = await this.http.getEncrypted<{
      labelData: string | LabelData[];
      version: number;
      lastUpdateTime?: number;
    }>(url, { imei: this.ctx.imei });
    return {
      ...res,
      labelData: typeof res.labelData === "string" ? (JSON.parse(res.labelData) as LabelData[]) : res.labelData,
    };
  }

  /** POST `{label[0]}/api/convlabel/update`. */
  async updateLabels(payload: {
    labelData: LabelData[];
    version: number;
  }): Promise<{ labelData: LabelData[]; version: number; lastUpdateTime?: number }> {
    const url = this.http.serviceUrl("label", "/api/convlabel/update");
    const res = await this.http.postEncrypted<{
      labelData: string | LabelData[];
      version: number;
      lastUpdateTime?: number;
    }>(url, {
      labelData: JSON.stringify(payload.labelData),
      version: payload.version,
      imei: this.ctx.imei,
    });
    return {
      ...res,
      labelData:
        typeof res?.labelData === "string" ? (JSON.parse(res.labelData) as LabelData[]) : res?.labelData ?? [],
    };
  }

  /** POST `{chat[0]}/api/message/deleteconver` (1:1) or `{group[0]}/api/group/deleteconver` (Group). */
  async deleteChat(
    lastMessage: { ownerId: string; cliMsgId: string | number; globalMsgId: string | number },
    threadId: string,
    type: ThreadType = ThreadType.User,
  ): Promise<unknown> {
    const isGroup = type === ThreadType.Group;
    const url = this.http.serviceUrl(
      isGroup ? "group" : "chat",
      isGroup ? "/api/group/deleteconver" : "/api/message/deleteconver",
    );
    return this.http.postEncrypted(url, {
      [isGroup ? "grid" : "toid"]: threadId,
      cliMsgId: Date.now(),
      conver: lastMessage,
      onlyMe: 1,
      imei: this.ctx.imei,
    });
  }
}
