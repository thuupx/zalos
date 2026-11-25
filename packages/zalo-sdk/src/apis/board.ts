import type { ZaloContext } from "../core/context.ts";
import type { ZaloHttpClient } from "../core/http.ts";
import type { PollDetail } from "../models/entities.ts";
import { BoardType, ReminderRepeatMode, ThreadType } from "../models/enums.ts";

export interface CreatePollOptions {
  question: string;
  options: string[];
  expiredTime?: number;
  pinned?: boolean;
  allowMultiChoices?: boolean;
  allowAddNewOption?: boolean;
  hideVotePreview?: boolean;
  isAnonymous?: boolean;
}

export interface NoteInput {
  title: string;
  pinAct?: boolean;
}

export interface ReminderInput {
  title: string;
  emoji?: string;
  startTime?: number;
  repeat?: ReminderRepeatMode;
}

export interface FriendPinTopicInput {
  msgId: string | number;
  cliMsgId?: string | number;
  senderUid?: string;
  senderName?: string;
  msgType?: number;
  title?: string;
  params?: Record<string, unknown>;
}

export class BoardApi {
  constructor(
    private readonly http: ZaloHttpClient,
    private readonly ctx: ZaloContext,
  ) {}

  // ---- Polls ----

  /** POST `{group[0]}/api/poll/create`. */
  async createPoll(options: CreatePollOptions, groupId: string): Promise<PollDetail> {
    const url = this.http.serviceUrl("group", "/api/poll/create");
    return this.http.postEncrypted<PollDetail>(url, {
      group_id: groupId,
      question: options.question,
      options: options.options,
      expired_time: options.expiredTime ?? 0,
      pinAct: options.pinned ? 1 : 0,
      allow_multi_choices: options.allowMultiChoices ? 1 : 0,
      allow_add_new_option: options.allowAddNewOption ? 1 : 0,
      is_hide_vote_preview: options.hideVotePreview ? 1 : 0,
      is_anonymous: options.isAnonymous ? 1 : 0,
      poll_type: 0,
      src: 1,
      imei: this.ctx.imei,
    });
  }

  /** POST `{group[0]}/api/poll/detail`. */
  async getPollDetail(pollId: number): Promise<PollDetail> {
    const url = this.http.serviceUrl("group", "/api/poll/detail");
    return this.http.postEncrypted<PollDetail>(url, { poll_id: pollId, imei: this.ctx.imei });
  }

  /** GET `{group[0]}/api/poll/vote`. */
  async votePoll(pollId: number, optionIds: number | number[]): Promise<unknown> {
    const ids = Array.isArray(optionIds) ? optionIds : [optionIds];
    const url = this.http.serviceUrl("group", "/api/poll/vote");
    return this.http.getEncrypted(url, { poll_id: pollId, option_ids: ids, imei: this.ctx.imei });
  }

  /** GET `{group[0]}/api/poll/option/add`. */
  async addPollOptions(payload: {
    pollId: number;
    options?: Array<{ content: string; voted?: boolean }>;
    newOptions?: Array<{ content: string; voted?: boolean }>;
    votedOptionIds?: number[];
  }): Promise<unknown> {
    const url = this.http.serviceUrl("group", "/api/poll/option/add");
    return this.http.getEncrypted(url, {
      poll_id: payload.pollId,
      new_options: JSON.stringify(payload.options ?? payload.newOptions ?? []),
      voted_option_ids: payload.votedOptionIds ?? [],
    });
  }

  /** POST `{group[0]}/api/poll/end`. */
  async lockPoll(pollId: number): Promise<unknown> {
    const url = this.http.serviceUrl("group", "/api/poll/end");
    return this.http.postEncrypted(url, { poll_id: pollId, imei: this.ctx.imei });
  }

  /** POST `{group[0]}/api/poll/share`. */
  async sharePoll(pollId: number): Promise<unknown> {
    const url = this.http.serviceUrl("group", "/api/poll/share");
    return this.http.postEncrypted(url, { poll_id: pollId, imei: this.ctx.imei });
  }

  // ---- Group Board & Notes ----

  /** GET `{group_board[0]}/api/board/list`. */
  async getListBoard(
    options: { boardType?: number; page?: number; count?: number; lastId?: number; lastType?: number } = {},
    groupId: string,
  ): Promise<{ items: Array<{ boardType: BoardType; data: Record<string, unknown> }>; count?: number }> {
    const url = this.http.serviceUrl("group_board", "/api/board/list");
    const data = await this.http.getEncrypted<{
      items?: Array<{ boardType: BoardType; data: Record<string, unknown> }>;
      count?: number;
    }>(url, {
      group_id: groupId,
      board_type: options.boardType ?? 0,
      page: options.page ?? 1,
      count: options.count ?? 20,
      last_id: options.lastId ?? 0,
      last_type: options.lastType ?? 0,
      imei: this.ctx.imei,
    });
    if (Array.isArray(data?.items)) {
      for (const item of data.items) {
        if (item.boardType !== BoardType.Poll && typeof item.data?.params === "string") {
          try {
            item.data.params = JSON.parse(item.data.params);
          } catch {
            // Keep string params if malformed JSON.
          }
        }
      }
    }
    return { items: data?.items ?? [], count: data?.count };
  }

  /** POST `{group_board[0]}/api/board/topic/createv2` (note type 0). */
  async createNote(options: NoteInput, groupId: string): Promise<unknown> {
    const url = this.http.serviceUrl("group_board", "/api/board/topic/createv2");
    return this.http.postEncrypted(url, {
      grid: groupId,
      type: 0,
      color: -16777216,
      emoji: "",
      startTime: -1,
      duration: -1,
      params: JSON.stringify({ title: options.title }),
      repeat: 0,
      src: 1,
      imei: this.ctx.imei,
      pinAct: options.pinAct ? 1 : 0,
    });
  }

  /** POST `{group_board[0]}/api/board/topic/updatev2`. */
  async editNote(options: NoteInput & { topicId: string }, groupId: string): Promise<unknown> {
    const url = this.http.serviceUrl("group_board", "/api/board/topic/updatev2");
    return this.http.postEncrypted(url, {
      grid: groupId,
      type: 0,
      color: -16777216,
      emoji: "",
      startTime: -1,
      duration: -1,
      params: JSON.stringify({ title: options.title }),
      repeat: 0,
      src: 1,
      topicId: options.topicId,
      imei: this.ctx.imei,
      pinAct: options.pinAct ? 1 : 2,
    });
  }

  /** POST `{group_board[0]}/api/board/topic/remove`. */
  async removeGroupNote(topicId: string, groupId: string): Promise<unknown> {
    const url = this.http.serviceUrl("group_board", "/api/board/topic/remove");
    return this.http.postEncrypted(url, { grid: groupId, topicId });
  }

  // ---- Reminders (1:1 & Group) ----

  async createReminder(
    options: ReminderInput,
    threadId: string,
    type: ThreadType = ThreadType.User,
  ): Promise<unknown> {
    if (type === ThreadType.User) {
      const url = this.http.serviceUrl("group_board", "/api/board/oneone/create");
      return this.http.postEncrypted(url, {
        objectData: JSON.stringify({
          toUid: threadId,
          type: 0,
          color: -16245706,
          emoji: options.emoji ?? "⏰",
          startTime: options.startTime ?? Date.now(),
          duration: -1,
          params: { title: options.title },
          needPin: false,
          repeat: options.repeat ?? ReminderRepeatMode.None,
          creatorUid: this.ctx.uid,
          src: 1,
        }),
        imei: this.ctx.imei,
      });
    }
    const url = this.http.serviceUrl("group_board", "/api/board/topic/createv2");
    return this.http.postEncrypted(url, {
      grid: threadId,
      type: 0,
      color: -16245706,
      emoji: options.emoji ?? "⏰",
      startTime: options.startTime ?? Date.now(),
      duration: -1,
      params: JSON.stringify({ title: options.title }),
      repeat: options.repeat ?? ReminderRepeatMode.None,
      src: 1,
      imei: this.ctx.imei,
      pinAct: 0,
    });
  }

  async editReminder(
    options: ReminderInput & { topicId: string },
    threadId: string,
    type: ThreadType = ThreadType.User,
  ): Promise<unknown> {
    if (type === ThreadType.User) {
      const url = this.http.serviceUrl("group_board", "/api/board/oneone/update");
      return this.http.postEncrypted(url, {
        objectData: JSON.stringify({
          toUid: threadId,
          type: 0,
          color: -16245706,
          emoji: options.emoji ?? "⏰",
          startTime: options.startTime ?? Date.now(),
          duration: -1,
          params: { title: options.title },
          needPin: false,
          repeat: options.repeat ?? ReminderRepeatMode.None,
          creatorUid: this.ctx.uid,
          src: 1,
          reminderId: options.topicId,
        }),
        imei: this.ctx.imei,
      });
    }
    const url = this.http.serviceUrl("group_board", "/api/board/topic/updatev2");
    return this.http.postEncrypted(url, {
      grid: threadId,
      type: 0,
      color: -16245706,
      emoji: options.emoji ?? "⏰",
      startTime: options.startTime ?? Date.now(),
      duration: -1,
      params: JSON.stringify({ title: options.title }),
      repeat: options.repeat ?? ReminderRepeatMode.None,
      src: 1,
      topicId: options.topicId,
      imei: this.ctx.imei,
      pinAct: 2,
    });
  }

  async removeReminder(
    reminderId: string,
    threadId: string,
    type: ThreadType = ThreadType.User,
  ): Promise<unknown> {
    if (type === ThreadType.User) {
      const url = this.http.serviceUrl("group_board", "/api/board/oneone/remove");
      return this.http.postEncrypted(url, { reminderId, imei: this.ctx.imei });
    }
    const url = this.http.serviceUrl("group_board", "/api/board/topic/remove");
    return this.http.postEncrypted(url, { grid: threadId, topicId: reminderId });
  }

  async getListReminder(
    options: { page?: number; count?: number; lastId?: number; lastType?: number } = {},
    threadId: string,
    type: ThreadType = ThreadType.User,
  ): Promise<unknown> {
    const isGroup = type === ThreadType.Group;
    const url = this.http.serviceUrl(
      "group_board",
      isGroup ? "/api/board/listReminder" : "/api/board/oneone/list",
    );
    const data = await this.http.getEncrypted<unknown>(url, {
      objectData: JSON.stringify({
        ...(isGroup ? { group_id: threadId } : { uid: threadId }),
        board_type: 1,
        page: options.page ?? 1,
        count: options.count ?? 20,
        last_id: options.lastId ?? 0,
        last_type: options.lastType ?? 0,
      }),
      ...(isGroup ? { imei: this.ctx.imei } : {}),
    });
    return typeof data === "string" ? JSON.parse(data) : data;
  }

  /** GET `{group_board[0]}/api/board/topic/getReminder`. */
  async getReminder(reminderId: string): Promise<unknown> {
    const url = this.http.serviceUrl("group_board", "/api/board/topic/getReminder");
    return this.http.getEncrypted(url, { eventId: reminderId, imei: this.ctx.imei });
  }

  /** GET `{group_board[0]}/api/board/topic/listResponseEvent`. */
  async getReminderResponses(reminderId: string): Promise<unknown> {
    const url = this.http.serviceUrl("group_board", "/api/board/topic/listResponseEvent");
    return this.http.getEncrypted(url, { eventId: reminderId });
  }

  // ---- 1:1 & Group Message Pins (first-class SDK endpoints) ----

  /** GET `{friend_board[0]}/api/friendboard/list`. */
  async getFriendBoardList(conversationId: string, version = 0): Promise<unknown> {
    const url = this.http.serviceUrl("friend_board", "/api/friendboard/list");
    return this.http.getEncrypted(url, { conversationId, version, imei: this.ctx.imei });
  }

  /** GET `{friend_board[0]}/api/friendboard/create`. */
  async createFriendPin(
    conversationId: string,
    topic: FriendPinTopicInput | Record<string, unknown>,
    version = 0,
  ): Promise<unknown> {
    const url = this.http.serviceUrl("friend_board", "/api/friendboard/create");
    const hasMsgId = "msgId" in topic;
    const topicParams = hasMsgId
      ? {
          ...((topic.params as Record<string, unknown> | undefined) ?? {}),
          client_msg_id: String((topic as FriendPinTopicInput).cliMsgId ?? ""),
          global_msg_id: String((topic as FriendPinTopicInput).msgId),
          msg_type: (topic as FriendPinTopicInput).msgType ?? 0,
          senderUid: (topic as FriendPinTopicInput).senderUid ?? "",
          senderName: (topic as FriendPinTopicInput).senderName ?? "",
          title: (topic as FriendPinTopicInput).title ?? "",
        }
      : topic;
    return this.http.getEncrypted(url, {
      conversationId,
      topic: {
        color: -16777216,
        duration: -1,
        emoji: "",
        params: JSON.stringify(topicParams),
        repeat: 0,
        startTime: -1,
        type: 2,
        src: -1,
        pinAct: 1,
      },
      version,
      lang: "vi",
    });
  }

  /** GET `{friend_board[0]}/api/friendboard/multi_unpin`. */
  async unpinFriendTopics(
    conversationId: string,
    topicIds: Array<string | number | Record<string, unknown>>,
    version = 0,
  ): Promise<unknown> {
    const url = this.http.serviceUrl("friend_board", "/api/friendboard/multi_unpin");
    return this.http.getEncrypted(url, {
      conversationId,
      topics: topicIds,
      version,
      lang: "vi",
    });
  }

  /** POST `{friend_board[0]}/api/friendboard/reorder`. */
  async reorderFriendPins(
    conversationId: string,
    topics: Array<string | number | Record<string, unknown>>,
    boardVersion = 0,
  ): Promise<unknown> {
    const url = this.http.serviceUrl("friend_board", "/api/friendboard/reorder");
    return this.http.postEncrypted(url, {
      conversationId,
      topics,
      boardVersion,
      imei: this.ctx.imei,
    });
  }

  /** GET `{group_board[0]}/api/board/pin/list`. */
  async listGroupPins(groupId: string, boardVersion = 0): Promise<unknown> {
    const url = this.http.serviceUrl("group_board", "/api/board/pin/list");
    return this.http.getEncrypted(url, { groupId, boardVersion, imei: this.ctx.imei });
  }

  /** POST `{group_board[0]}/api/board/topic/createv2` with `type: 2` (MSG_TOPIC). */
  async pinGroupMessage(
    groupId: string,
    params: Record<string, unknown>,
    pinAct = 1,
  ): Promise<unknown> {
    const url = this.http.serviceUrl("group_board", "/api/board/topic/createv2");
    return this.http.postEncrypted(url, {
      grid: groupId,
      type: 2,
      color: -16777216,
      emoji: "",
      startTime: -1,
      duration: -1,
      params: JSON.stringify(params),
      repeat: 0,
      src: 1,
      imei: this.ctx.imei,
      pinAct,
    });
  }

  /** GET `{group_board[0]}/api/board/pinv2`. */
  async pinGroupBoardItem(
    groupId: string,
    topicId: string | number,
    topicType = 3,
  ): Promise<unknown> {
    const url = this.http.serviceUrl("group_board", "/api/board/pinv2");
    return this.http.getEncrypted(url, { grid: groupId, topicId, type: topicType });
  }

  /** GET `{group_board[0]}/api/board/unpinv2`. */
  async unpinGroupTopic(
    groupId: string,
    topicId: string | number,
    topicType = 2,
    boardVersion = 0,
  ): Promise<unknown> {
    const url = this.http.serviceUrl("group_board", "/api/board/unpinv2");
    return this.http.getEncrypted(url, {
      grid: groupId,
      topic: { topicId, topicType },
      boardVersion,
      imei: this.ctx.imei,
    });
  }

  /** GET `{group_board[0]}/api/board/multi_unpin`. */
  async multiUnpinGroupTopics(
    groupId: string,
    topics: Array<Record<string, unknown>>,
    boardVersion = 0,
  ): Promise<unknown> {
    const url = this.http.serviceUrl("group_board", "/api/board/multi_unpin");
    return this.http.getEncrypted(url, { grid: groupId, topics, boardVersion });
  }

  /** POST `{group_board[0]}/api/board/pin/update` (reorders pinned topics in a group). */
  async reorderGroupPins(
    groupId: string,
    topics: Array<Record<string, unknown>>,
    boardVersion = 0,
  ): Promise<unknown> {
    const url = this.http.serviceUrl("group_board", "/api/board/pin/update");
    return this.http.postEncrypted(url, { groupId, topics, boardVersion });
  }
}
