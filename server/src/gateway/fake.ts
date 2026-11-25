// In-memory fake gateway for tests and --fake dev mode.
import { RpcError } from "../tunnel/rpc.ts";
import { createFakeExtendedMethods } from "./fake_extended.ts";
import { AUTO_DELETE_TTLS } from "./types.ts";
import type {
  AccountStatus,
  ArchivedChatList,
  AutoDeleteChat,
  AutoDeleteConversation,
  BankAccount,
  BankAccounts,
  BankCard,
  BankInfo,
  Contact,
  ConversationRef,
  ConversationSyncState,
  Credentials,
  FriendPresence,
  FriendRecommendation,
  FriendRequestStatus,
  GatewayEvents,
  GatewayFactory,
  GatewaySelf,
  GroupInfo,
  HiddenConversations,
  Label,
  LabelsState,
  LastSeen,
  LinkPreview,
  LinkedDevices,
  LoginQrCallbacks,
  Mention,
  Message,
  OaCredentials,
  OaHooks,
  OutgoingFile,
  QuickMessage,
  QuickMessageDraft,
  QuickMessageMedia,
  QuickMessages,
  ReceivedFriendRequest,
  ReportReason,
  SentFriendRequest,
  StickerRef,
  StyleRun,
  ThreadType,
  Urgency,
  UserInfo,
  UserProfile,
  ZaloGateway,
} from "./types.ts";

type Handler = (...args: never[]) => void;

let counter = 0;

export class FakeGateway implements ZaloGateway {
  status: AccountStatus = "offline";
  readonly self: GatewaySelf;
  readonly calls: { method: string; args: unknown[] }[] = [];
  readonly sentMessages: Message[] = [];
  private handlers = new Map<string, Handler[]>();
  private msgSeq = 1;
  // Start-timestamp prefix keeps fake msg ids unique across restarts.
  private readonly idPrefix = `gm-${Date.now().toString(36)}`;
  private qrPng: Uint8Array | null = null;

  constructor(self?: Partial<GatewaySelf>) {
    this.self = {
      uid: self?.uid !== undefined && self.uid !== "" ? self.uid : `fake-uid-${++counter}`,
      displayName: self?.displayName ?? "Fake Account",
      avatarUrl: self?.avatarUrl ?? "https://example.com/avatar.png",
    };
    this.linkedDevicesValue = { masterId: this.self.uid, companions: [] };
    Object.assign(this, createFakeExtendedMethods(this));
  }

  // ---- seedable friend state for tests ----
  readonly foundUsers = new Map<string, UserProfile>();
  requestStatusValue: FriendRequestStatus = {
    isFriend: false,
    isRequested: false,
    isRequesting: false,
    addFriendPrivacy: 0,
    isSeen: false,
  };
  receivedRequests: ReceivedFriendRequest[] = [];
  sentRequests: SentFriendRequest[] = [];
  recommendations: FriendRecommendation[] = [];
  presence: FriendPresence[] = [];
  lastSeen: LastSeen = { showOnlineStatus: true, lastOnline: 0 };
  readonly friendAliases = new Map<string, string>();
  closeFriendIds = new Set<string>();
  // groupInfo reports this account as owner unless a test overrides it.
  groupOwnerId: string | null = null;
  groupAdminIds: string[] = [];

  // ---- seedable conversation state for tests ----
  syncPinned: ConversationRef[] = [];
  syncMuted: ConversationRef[] = [];
  hiddenThreads: ConversationRef[] = [];
  hiddenPinSet = false;
  hiddenPinSets = 0;
  archivedThreads: ConversationRef[] = [];
  archiveVersion = 1;
  labelsValue: LabelsState = { labels: [], version: 1, lastUpdateTime: 0 };
  autoDeleteConversations: AutoDeleteConversation[] = [];
  linkedDevicesValue: LinkedDevices;

  // ---- seedable Phase D messaging state ----
  linkPreviews = new Map<string, LinkPreview>();
  bankListValue: BankInfo[] = [
    {
      bin: 970436,
      logo: "https://example.com/banks/vcb.png",
      name: "Ngân hàng TMCP Ngoại Thương Việt Nam",
      nameEn: "Joint Stock Commercial Bank for Foreign Trade of Vietnam",
      shortName: "Vietcombank",
      searchKeyword: "vietcombank vcb",
    },
    {
      bin: 970422,
      logo: "https://example.com/banks/mb.png",
      name: "Ngân hàng TMCP Quân đội",
      nameEn: "Military Commercial Joint Stock Bank",
      shortName: "MB Bank",
      searchKeyword: "mb bank quân đội",
    },
  ];
  bankAccountsValue: BankAccount[] = [
    {
      id: "ba-1",
      bin: 970436,
      accountNumber: "0123456789",
      holderName: "NGUYEN VAN A",
      isDefault: true,
      accountId: 11,
      bankName: "Vietcombank",
      createdAt: 1_700_000_000_000,
      updatedAt: 1_700_000_000_000,
    },
  ];
  quickMessagesValue: QuickMessages = {
    items: [
      {
        id: 1,
        keyword: "chao",
        title: "Chào bạn, mình có thể giúp gì?",
        type: 0,
        createdTime: 1_700_000_000_000,
        lastModified: 1_700_000_000_000,
        media: [],
      },
      {
        id: 2,
        keyword: "banggia",
        title: "Bảng giá tháng này",
        type: 1,
        createdTime: 1_700_000_000_000,
        lastModified: 1_700_000_000_000,
        media: [
          {
            type: 0,
            photoId: 9001,
            title: "",
            width: 640,
            height: 480,
            previewThumb: "https://example.com/qm/thumb.jpg",
            rawUrl: "https://example.com/qm/raw.jpg",
            thumbUrl: "https://example.com/qm/thumb.jpg",
            normalUrl: "https://example.com/qm/normal.jpg",
            hdUrl: "https://example.com/qm/hd.jpg",
          },
        ],
      },
    ],
    version: 4,
    cursor: 2,
  };

  // Personal fakes expose everything; FakeOaGateway narrows this.
  capabilities(): string[] {
    return [
      "groups",
      "stickers",
      "reactions",
      "recall",
      "deleteForMe",
      "forward",
      "mentions",
      "video",
      "voice",
      "typing",
      "pin",
      "mute",
      "markUnread",
      "deleteThread",
      "deliveryState",
      "fullAvatar",
      "friends",
      "presence",
      "contactCard",
      "report",
      "deleteForAll",
      "archive",
      "hidden",
      "labels",
      "autoDelete",
      "zaloDevices",
      "styledText",
      "gif",
      "linkPreview",
      "bankCard",
      "bankAccounts",
      "quickMessages",
      "urgency",
      "messageTtl",
      "pinMessage",
      "polls",
      "notes",
      "reminders",
      "voiceCall",
      "videoCall",
      "groupManage",
      "profileSettings",
      "businessTools",
      "mediaStore",
      "e2ee",
    ];
  }

  on<E extends keyof GatewayEvents>(
    event: E,
    cb: (...args: GatewayEvents[E]) => void,
  ) {
    const list = this.handlers.get(event) ?? [];
    list.push(cb as unknown as Handler);
    this.handlers.set(event, list);
  }

  emit<E extends keyof GatewayEvents>(
    event: E,
    ...args: GatewayEvents[E]
  ) {
    for (const cb of this.handlers.get(event) ?? []) {
      (cb as (...a: unknown[]) => void)(...args);
    }
  }

  async start() {
    this.calls.push({ method: "start", args: [] });
    this.status = "online";
    this.emit("status", "online");
  }

  async stop() {
    this.calls.push({ method: "stop", args: [] });
    this.status = "offline";
    this.emit("status", "offline");
  }

  // Minimal TMessage-shaped payload; enough for action refs and quoting.
  private makeRaw(msg: {
    id: string;
    cliId: string | null;
    threadId: string;
    uidFrom: string;
    dName: string;
    ts: number;
    text?: string;
  }) {
    return {
      msgId: msg.id,
      cliMsgId: msg.cliId ?? "",
      uidFrom: msg.uidFrom,
      idTo: msg.threadId,
      msgType: "webchat",
      ts: msg.ts,
      st: 0,
      at: 0,
      cmd: 0,
      ttl: 0,
      dName: msg.dName,
      content: msg.text ?? "",
    };
  }

  private makeSelf(
    threadId: string,
    threadType: ThreadType,
    kind: Message["kind"],
    cliId: string,
    extra: Partial<Message> = {},
  ): Message {
    const msg: Message = {
      id: `${this.idPrefix}-${this.msgSeq++}`,
      cliId,
      threadId,
      threadType,
      senderId: this.self.uid,
      senderName: this.self.displayName,
      ts: Date.now(),
      isSelf: true,
      kind,
      reactions: {},
      recalled: false,
      ...extra,
    };
    msg.raw = this.makeRaw({
      id: msg.id,
      cliId,
      threadId,
      uidFrom: this.self.uid,
      dName: this.self.displayName,
      ts: msg.ts,
      text: msg.text,
    });
    if (msg.card !== undefined) {
      const raw = msg.raw as Record<string, unknown>;
      raw.msgType = "chat.recommended";
      raw.content = {
        title: msg.card.displayName,
        description: JSON.stringify({
          ...(msg.card.phone !== undefined ? { phone: msg.card.phone } : {}),
          ...(msg.card.qrCodeUrl !== undefined
            ? { qrCodeUrl: msg.card.qrCodeUrl }
            : {}),
        }),
        thumb: msg.card.avatarUrl,
      };
    }
    this.sentMessages.push(msg);
    return msg;
  }

  async sendText(
    threadId: string,
    threadType: ThreadType,
    text: string,
    opts?: {
      quote?: { raw?: unknown };
      mentions?: Mention[];
      styles?: StyleRun[];
      urgency?: Urgency;
      ttl?: number;
    },
  ) {
    this.calls.push({
      method: "sendText",
      args: [threadId, threadType, text, opts],
    });
    const cliId = `cli-${this.msgSeq}`;
    const ttl = opts?.ttl !== undefined && opts.ttl > 0 ? opts.ttl : undefined;
    const msg = this.makeSelf(threadId, threadType, "text", cliId, {
      text,
      quote: opts?.quote as unknown as Message["quote"],
      mentions: opts?.mentions,
      ...(opts?.styles !== undefined ? { styles: opts.styles } : {}),
      ...(opts?.urgency !== undefined ? { urgency: opts.urgency } : {}),
      ...(ttl !== undefined ? { ttl, expiresAt: Date.now() + ttl } : {}),
    });
    const raw = msg.raw as Record<string, unknown>;
    if (ttl !== undefined) raw.ttl = ttl;
    return { msgId: msg.id, cliId };
  }

  async sendMedia(
    threadId: string,
    threadType: ThreadType,
    kind: "image" | "video" | "file" | "voice" | "gif",
    file: OutgoingFile,
    caption?: string,
    cliId?: string,
    opts?: { ttl?: number; urgency?: Urgency },
  ) {
    const data = new Uint8Array(await Bun.file(file.path).arrayBuffer());
    this.calls.push({
      method: "sendMedia",
      args: [threadId, threadType, kind, file, caption, data, cliId, opts],
    });
    // zca-js routes a `.gif` attachment to the gif upload; mirror that so
    // the selfListen echo does not downgrade the local gif kind.
    const recordKind =
      kind === "gif" || (kind === "image" && /\.gif$/i.test(file.name))
        ? "gif"
        : kind;
    const id = cliId ?? `cli-${this.msgSeq}`;
    const url = `fake://media/${this.idPrefix}-${this.msgSeq}/${msgName(file.name)}`;
    this.uploads.set(url, data);
    const ttl = opts?.ttl !== undefined && opts.ttl > 0 ? opts.ttl : undefined;
    const msg = this.makeSelf(threadId, threadType, recordKind, id, {
      text: caption,
      attachments: [
        { kind: recordKind, url, name: file.name, size: data.length },
      ],
      ...(opts?.urgency !== undefined ? { urgency: opts.urgency } : {}),
      ...(ttl !== undefined ? { ttl } : {}),
    });
    if (ttl !== undefined) msg.expiresAt = msg.ts + ttl;
    const raw = msg.raw as Record<string, unknown>;
    if (recordKind === "gif") raw.msgType = "chat.gif";
    if (ttl !== undefined) raw.ttl = ttl;
    this.lastUpload = data;
    // selfListen echo: the gateway replays our own send, now with the real
    // attachment urls (the optimistic record has none).
    setTimeout(() => this.emit("message", { ...msg }));
    return { msgId: msg.id, cliId: id };
  }

  // Uploaded blobs addressable by their fake://media url.
  private readonly uploads = new Map<string, Uint8Array>();

  lastUpload: Uint8Array | null = null;

  async sendSticker(
    threadId: string,
    threadType: ThreadType,
    sticker: StickerRef,
  ) {
    this.calls.push({
      method: "sendSticker",
      args: [threadId, threadType, sticker],
    });
    const cliId = `cli-${this.msgSeq}`;
    const msg = this.makeSelf(threadId, threadType, "sticker", cliId, {
      sticker,
    });
    return { msgId: msg.id, cliId };
  }

  async sendCard(
    threadId: string,
    threadType: ThreadType,
    card: { userId: string; phoneNumber?: string; ttl?: number },
  ) {
    this.calls.push({
      method: "sendCard",
      args: [threadId, threadType, card],
    });
    const cliId = `cli-${this.msgSeq}`;
    const msg = this.makeSelf(threadId, threadType, "card", cliId, {
      card: {
        uid: card.userId,
        displayName: `User ${card.userId}`,
        avatarUrl: `https://example.com/${card.userId}.png`,
        ...(card.phoneNumber !== undefined
          ? { phone: card.phoneNumber }
          : {}),
        qrCodeUrl: `https://example.com/qr/${card.userId}.png`,
      },
    });
    return { msgId: msg.id, cliId };
  }

  async parseLink(link: string): Promise<LinkPreview> {
    this.calls.push({ method: "parseLink", args: [link] });
    const seeded = this.linkPreviews.get(link);
    if (seeded !== undefined) return { ...seeded };
    return {
      title: `Preview of ${link}`,
      description: "A link preview",
      srcUrl: link,
      href: link,
      thumbUrl: "https://example.com/link-thumb.jpg",
    };
  }

  async sendLink(
    threadId: string,
    threadType: ThreadType,
    opts: { link: string; msg?: string; ttl?: number },
  ) {
    this.calls.push({ method: "sendLink", args: [threadId, threadType, opts] });
    const preview = await this.parseLink(opts.link);
    const cliId = `cli-${this.msgSeq}`;
    const ttl = opts.ttl !== undefined && opts.ttl > 0 ? opts.ttl : undefined;
    const msg = this.makeSelf(threadId, threadType, "link", cliId, {
      text: opts.msg ?? preview.title,
      attachments: [
        {
          kind: "link",
          url: preview.href,
          thumbUrl: preview.thumbUrl,
          name: preview.title,
        },
      ],
      ...(ttl !== undefined ? { ttl, expiresAt: Date.now() + ttl } : {}),
    });
    const raw = msg.raw as Record<string, unknown>;
    raw.msgType = "chat.link";
    raw.content = {
      title: preview.title,
      description: preview.description,
      href: preview.href,
      thumb: preview.thumbUrl ?? "",
    };
    if (ttl !== undefined) raw.ttl = ttl;
    return { msgId: msg.id };
  }

  async sendBankCard(
    threadId: string,
    threadType: ThreadType,
    card: { bin: number; accountNumber: string; holderName?: string },
  ) {
    this.calls.push({
      method: "sendBankCard",
      args: [threadId, threadType, card],
    });
    const cliId = `cli-${this.msgSeq}`;
    const bankName = this.bankListValue.find((b) => b.bin === card.bin)?.shortName;
    const body: BankCard = {
      bin: card.bin,
      accountNumber: card.accountNumber,
      ...(card.holderName !== undefined ? { holderName: card.holderName } : {}),
      ...(bankName !== undefined ? { bankName } : {}),
    };
    const msg = this.makeSelf(threadId, threadType, "bank", cliId, {
      bankCard: body,
      text: bankName ?? "Bank card",
    });
    const raw = msg.raw as Record<string, unknown>;
    raw.msgType = "chat.bankcard";
    raw.content = {
      params: JSON.stringify({
        binBank: card.bin,
        numAccBank: card.accountNumber,
        ...(card.holderName !== undefined
          ? { nameAccBank: card.holderName }
          : {}),
        ...(bankName !== undefined ? { bankName } : {}),
      }),
    };
    // Real Zalo answers with an empty body; the listener echo carries the
    // real message, so the fake emits the same echo asynchronously.
    setTimeout(() => this.emit("message", { ...msg, cliId: null }), 0);
    return { msgId: "" };
  }

  async bankList(): Promise<BankInfo[]> {
    this.calls.push({ method: "bankList", args: [] });
    return structuredClone(this.bankListValue);
  }

  async bankAccounts(page: number, limit: number): Promise<BankAccounts> {
    this.calls.push({ method: "bankAccounts", args: [page, limit] });
    const start = page * limit;
    const rows = this.bankAccountsValue.slice(start, start + limit);
    return {
      accounts: structuredClone(rows),
      total: this.bankAccountsValue.length,
      hasMore: start + rows.length < this.bankAccountsValue.length,
    };
  }

  async quickMessages(): Promise<QuickMessages> {
    this.calls.push({ method: "quickMessages", args: [] });
    return structuredClone(this.quickMessagesValue);
  }

  async addQuickMessage(draft: QuickMessageDraft) {
    this.calls.push({ method: "addQuickMessage", args: [draft] });
    const id =
      Math.max(0, ...this.quickMessagesValue.items.map((i) => i.id)) + 1;
    const item: QuickMessage = {
      id,
      keyword: draft.keyword,
      title: draft.title,
      type: draft.media !== undefined ? 1 : 0,
      createdTime: Date.now(),
      lastModified: Date.now(),
      media: [],
    };
    this.quickMessagesValue = {
      items: [...this.quickMessagesValue.items, item],
      version: this.quickMessagesValue.version + 1,
      cursor: this.quickMessagesValue.cursor,
    };
    return { item: structuredClone(item), version: this.quickMessagesValue.version };
  }

  async updateQuickMessage(id: number, draft: QuickMessageDraft) {
    this.calls.push({ method: "updateQuickMessage", args: [id, draft] });
    const existing = this.quickMessagesValue.items.find((i) => i.id === id);
    if (existing === undefined) {
      throw new RpcError("not_found", `quick message ${id}`);
    }
    // A draft without media keeps the stored photo; a replacement swaps it.
    const media =
      draft.media !== undefined
        ? [this.fakeQuickMedia(draft.media.name)]
        : existing.media;
    const item: QuickMessage = {
      ...existing,
      keyword: draft.keyword,
      title: draft.title,
      type: media.length > 0 ? 1 : existing.type,
      media,
      lastModified: Date.now(),
    };
    this.quickMessagesValue = {
      items: this.quickMessagesValue.items.map((i) => (i.id === id ? item : i)),
      version: this.quickMessagesValue.version + 1,
      cursor: this.quickMessagesValue.cursor,
    };
    return { item: structuredClone(item), version: this.quickMessagesValue.version };
  }

  private quickPhotoSeq = 9100;

  private fakeQuickMedia(name: string): QuickMessageMedia {
    const url = `fake://qm/${this.idPrefix}/${++this.quickPhotoSeq}/${msgName(name)}`;
    return {
      type: 0,
      photoId: this.quickPhotoSeq,
      title: "",
      width: 640,
      height: 480,
      previewThumb: url,
      rawUrl: url,
      thumbUrl: url,
      normalUrl: url,
      hdUrl: url,
    };
  }

  async removeQuickMessages(ids: number[]) {
    this.calls.push({ method: "removeQuickMessages", args: [ids] });
    const remove = new Set(ids);
    this.quickMessagesValue = {
      items: this.quickMessagesValue.items.filter((i) => !remove.has(i.id)),
      version: this.quickMessagesValue.version + 1,
      cursor: this.quickMessagesValue.cursor,
    };
    return { itemIds: [...ids], version: this.quickMessagesValue.version };
  }

  async sendReport(
    threadId: string,
    threadType: ThreadType,
    opts: { reason: ReportReason; content?: string },
  ) {
    this.calls.push({
      method: "sendReport",
      args: [threadId, threadType, opts],
    });
    return { reportId: `report-${this.msgSeq++}` };
  }

  async searchStickers(query: string) {
    this.calls.push({ method: "searchStickers", args: [query] });
    return [
      { id: 1, cateId: 10, type: 1, url: "https://example.com/st1.png" },
      { id: 2, cateId: 10, type: 1, url: "https://example.com/st2.png" },
    ];
  }

  async stickerCategory(cateId: number) {
    this.calls.push({ method: "stickerCategory", args: [cateId] });
    return [
      { id: 1, cateId, type: 1, url: "https://example.com/st1.png" },
      { id: 2, cateId, type: 1, url: "https://example.com/st2.png" },
    ];
  }

  private fakePins = new Map<string, import("./types.ts").PinnedTopic[]>();
  private fakePolls = new Map<number, import("./types.ts").PollDetail>();
  private fakeReminders = new Map<string, import("./types.ts").ReminderItem[]>();
  private fakePollSeq = 100;

  async listPins(threadId: string, threadType: ThreadType) {
    return {
      items: [...(this.fakePins.get(`${threadType}:${threadId}`) ?? [])],
      version: 1,
    };
  }

  async listBoard(groupId: string) {
    return [...(this.fakePins.get(`group:${groupId}`) ?? [])];
  }

  async pinMessage(
    threadId: string,
    threadType: ThreadType,
    payload: {
      msgId: string;
      cliMsgId?: string;
      senderId: string;
      senderName: string;
      title: string;
      kind: import("./types.ts").MessageKind;
      thumbUrl?: string;
    },
  ) {
    const key = `${threadType}:${threadId}`;
    const list = this.fakePins.get(key) ?? [];
    const topic: import("./types.ts").PinnedTopic = {
      id: `pin-${payload.msgId}`,
      topicType: 2,
      kind: "message",
      title: payload.title,
      senderId: payload.senderId,
      senderName: payload.senderName,
      msgId: payload.msgId,
      cliMsgId: payload.cliMsgId,
      thumbUrl: payload.thumbUrl,
      createdAt: Date.now(),
      pinned: true,
    };
    const next = [topic, ...list.filter((t) => t.msgId !== payload.msgId)];
    this.fakePins.set(key, next);
    return { items: next, version: next.length };
  }

  async pinBoardItem(groupId: string, topicId: string, topicType: number) {
    const key = `group:${groupId}`;
    const list = this.fakePins.get(key) ?? [];
    if (!list.some((t) => t.id === topicId)) {
      const poll = topicType === 3 ? this.fakePolls.get(Number(topicId)) : undefined;
      list.unshift({
        id: topicId,
        topicType,
        kind: topicType === 3 ? "poll" : "note",
        title: poll?.question ?? `Topic ${topicId}`,
        pollId: topicType === 3 ? Number(topicId) : undefined,
        pinned: true,
      });
      this.fakePins.set(key, list);
    }
  }

  async unpinTopic(
    threadId: string,
    threadType: ThreadType,
    topicId: string,
  ) {
    const key = `${threadType}:${threadId}`;
    const next = (this.fakePins.get(key) ?? []).filter((t) => t.id !== topicId);
    this.fakePins.set(key, next);
    return { items: next, version: next.length };
  }

  async createPoll(
    groupId: string,
    opts: {
      question: string;
      options: string[];
      expiredTime?: number;
      allowMultiChoices?: boolean;
      allowAddNewOption?: boolean;
      hideVotePreview?: boolean;
      isAnonymous?: boolean;
      pin?: boolean;
    },
  ) {
    const id = this.fakePollSeq++;
    const poll: import("./types.ts").PollDetail = {
      id,
      groupId,
      question: opts.question,
      creatorId: this.self.uid,
      createdAt: Date.now(),
      expiredAt: opts.expiredTime ?? 0,
      closed: false,
      multiple: opts.allowMultiChoices ?? true,
      allowAdd: opts.allowAddNewOption ?? true,
      hidePreview: opts.hideVotePreview ?? false,
      anonymous: opts.isAnonymous ?? false,
      totalVotes: 0,
      options: opts.options.map((content, idx) => ({
        id: idx + 1,
        content,
        votes: 0,
        voted: false,
        voters: [],
      })),
    };
    this.fakePolls.set(id, poll);
    if (opts.pin) {
      await this.pinBoardItem(groupId, String(id), 3);
    }
    return poll;
  }

  async pollDetail(pollId: number) {
    const poll = this.fakePolls.get(pollId);
    if (!poll) throw new Error(`poll ${pollId} not found`);
    return poll;
  }

  async votePoll(pollId: number, optionIds: number[]) {
    const poll = await this.pollDetail(pollId);
    const chosen = new Set(optionIds);
    for (const o of poll.options) {
      o.voted = chosen.has(o.id);
      o.voters = o.voted ? [this.self.uid] : [];
      o.votes = o.voters.length;
    }
    poll.totalVotes = chosen.size > 0 ? 1 : 0;
    return poll;
  }

  async addPollOption(
    pollId: number,
    content: string,
    votedOptionIds: number[],
    voteNew = true,
  ) {
    const poll = await this.pollDetail(pollId);
    const nextId = poll.options.reduce((m, o) => Math.max(m, o.id), 0) + 1;
    poll.options.push({
      id: nextId,
      content,
      votes: voteNew ? 1 : 0,
      voted: voteNew,
      voters: voteNew ? [this.self.uid] : [],
    });
    return this.votePoll(
      pollId,
      voteNew ? [...votedOptionIds, nextId] : votedOptionIds,
    );
  }

  async lockPoll(pollId: number) {
    const poll = await this.pollDetail(pollId);
    poll.closed = true;
    return poll;
  }

  async sharePoll(_pollId: number) {}

  async createNote(groupId: string, title: string, pin = false) {
    const item: import("./types.ts").PinnedTopic = {
      id: `note-${this.msgSeq++}`,
      topicType: 0,
      kind: "note",
      title,
      senderId: this.self.uid,
      senderName: this.self.displayName,
      createdAt: Date.now(),
      pinned: pin,
    };
    if (pin) {
      const key = `group:${groupId}`;
      this.fakePins.set(key, [item, ...(this.fakePins.get(key) ?? [])]);
    }
    return item;
  }

  async editNote(groupId: string, topicId: string, title: string, pin = false) {
    const key = `group:${groupId}`;
    const list = this.fakePins.get(key) ?? [];
    const updated: import("./types.ts").PinnedTopic = {
      id: topicId,
      topicType: 0,
      kind: "note",
      title,
      senderId: this.self.uid,
      senderName: this.self.displayName,
      createdAt: Date.now(),
      pinned: pin,
    };
    this.fakePins.set(
      key,
      pin
        ? [updated, ...list.filter((x) => x.id !== topicId)]
        : list.filter((x) => x.id !== topicId),
    );
    return updated;
  }

  async listReminders(threadId: string, threadType: ThreadType) {
    return [...(this.fakeReminders.get(`${threadType}:${threadId}`) ?? [])];
  }

  async createReminder(
    threadId: string,
    threadType: ThreadType,
    opts: { title: string; emoji?: string; startTime: number; repeat?: number },
  ) {
    const key = `${threadType}:${threadId}`;
    const item: import("./types.ts").ReminderItem = {
      id: `rem-${this.msgSeq++}`,
      title: opts.title,
      emoji: opts.emoji ?? "⏰",
      startTime: opts.startTime,
      repeat: opts.repeat ?? 0,
      creatorId: this.self.uid,
      createdAt: Date.now(),
    };
    this.fakeReminders.set(key, [item, ...(this.fakeReminders.get(key) ?? [])]);
    return item;
  }

  async editReminder(
    threadId: string,
    threadType: ThreadType,
    opts: {
      id: string;
      title: string;
      emoji?: string;
      startTime: number;
      repeat?: number;
    },
  ) {
    const key = `${threadType}:${threadId}`;
    const item: import("./types.ts").ReminderItem = {
      id: opts.id,
      title: opts.title,
      emoji: opts.emoji ?? "⏰",
      startTime: opts.startTime,
      repeat: opts.repeat ?? 0,
      creatorId: this.self.uid,
    };
    const list = this.fakeReminders.get(key) ?? [];
    this.fakeReminders.set(key, [item, ...list.filter((r) => r.id !== opts.id)]);
    return item;
  }

  async removeReminder(threadId: string, threadType: ThreadType, id: string) {
    const key = `${threadType}:${threadId}`;
    this.fakeReminders.set(
      key,
      (this.fakeReminders.get(key) ?? []).filter((r) => r.id !== id),
    );
  }

  async react(
    msgId: string,
    threadId: string,
    threadType: ThreadType,
    icon: string,
  ) {
    this.calls.push({ method: "react", args: [msgId, threadId, threadType, icon] });
  }

  async recall(msgId: string, threadId: string, threadType: ThreadType) {
    this.calls.push({ method: "recall", args: [msgId, threadId, threadType] });
    this.emit("recall", { threadId, threadType, msgId, isSelf: true });
  }

  async deleteMessage(msgId: string, threadId: string, threadType: ThreadType) {
    this.calls.push({
      method: "deleteMessage",
      args: [msgId, threadId, threadType],
    });
  }

  async deleteMessageForAll(
    msgId: string,
    threadId: string,
    threadType: ThreadType,
  ) {
    this.calls.push({
      method: "deleteMessageForAll",
      args: [msgId, threadId, threadType],
    });
  }

  async markSeen(threadId: string, threadType: ThreadType) {
    this.calls.push({ method: "markSeen", args: [threadId, threadType] });
  }

  async sendTyping(threadId: string, threadType: ThreadType) {
    this.calls.push({ method: "sendTyping", args: [threadId, threadType] });
  }

  async setPinned(threadId: string, threadType: ThreadType, pinned: boolean) {
    this.calls.push({
      method: "setPinned",
      args: [threadId, threadType, pinned],
    });
  }

  async setMuted(threadId: string, threadType: ThreadType, muted: boolean) {
    this.calls.push({
      method: "setMuted",
      args: [threadId, threadType, muted],
    });
  }

  async markUnread(threadId: string, threadType: ThreadType) {
    this.calls.push({ method: "markUnread", args: [threadId, threadType] });
  }

  async removeUnreadMark(threadId: string, threadType: ThreadType) {
    this.calls.push({ method: "removeUnreadMark", args: [threadId, threadType] });
  }

  async deleteConversation(threadId: string, threadType: ThreadType, lastRef: unknown) {
    this.calls.push({
      method: "deleteConversation",
      args: [threadId, threadType, lastRef],
    });
  }

  async forward(
    payload: { message: string; reference?: { ts: number; id: string; logSrcType?: number; fwLvl?: number } },
    to: { threadId: string; threadType: ThreadType }[],
  ) {
    this.calls.push({ method: "forward", args: [payload, to] });
    for (const t of to) {
      const msgId = `fwd-${Date.now()}-${t.threadId}`;
      this.emit("message", {
        id: msgId,
        cliId: String(Date.now()),
        threadId: t.threadId,
        threadType: t.threadType,
        senderId: this.self.uid,
        senderName: this.self.displayName,
        ts: Date.now(),
        isSelf: true,
        kind: "text",
        text: payload.message,
        reactions: {},
        recalled: false,
      });
    }
  }

  async syncConversationState(): Promise<ConversationSyncState> {
    this.calls.push({ method: "syncConversationState", args: [] });
    return {
      pinned: [...this.syncPinned],
      muted: [...this.syncMuted],
      hidden: [...this.hiddenThreads],
      archived: [...this.archivedThreads],
      autoDelete: structuredClone(this.autoDeleteConversations),
    };
  }

  async hiddenConversations(): Promise<HiddenConversations> {
    this.calls.push({ method: "hiddenConversations", args: [] });
    return { pinSet: this.hiddenPinSet, threads: [...this.hiddenThreads] };
  }

  async setHiddenConversations(threads: ConversationRef[], hidden: boolean) {
    this.calls.push({
      method: "setHiddenConversations",
      args: [threads, hidden],
    });
    const keys = new Set(threads.map(convKey));
    this.hiddenThreads = this.hiddenThreads.filter((t) => !keys.has(convKey(t)));
    if (hidden) {
      for (const t of threads) {
        if (!this.hiddenThreads.some((x) => convKey(x) === convKey(t))) {
          this.hiddenThreads.push(t);
        }
      }
    }
  }

  async setHiddenPin(pin: string) {
    if (!/^\d{4}$/.test(pin)) {
      throw new RpcError("bad_request", "pin must be 4 digits");
    }
    // Never keep the plaintext PIN, even in a test double.
    this.calls.push({ method: "setHiddenPin", args: ["****"] });
    this.hiddenPinSet = true;
    this.hiddenPinSets++;
  }

  async resetHiddenPin() {
    this.calls.push({ method: "resetHiddenPin", args: [] });
    this.hiddenPinSet = false;
  }

  async archivedChatList(): Promise<ArchivedChatList> {
    this.calls.push({ method: "archivedChatList", args: [] });
    return {
      threads: [...this.archivedThreads],
      version: this.archiveVersion,
    };
  }

  async updateArchivedChatList(archived: boolean, threads: ConversationRef[]) {
    this.calls.push({
      method: "updateArchivedChatList",
      args: [archived, threads],
    });
    const keys = new Set(threads.map(convKey));
    this.archivedThreads = this.archivedThreads.filter(
      (t) => !keys.has(convKey(t)),
    );
    if (archived) {
      for (const t of threads) {
        if (!this.archivedThreads.some((x) => convKey(x) === convKey(t))) {
          this.archivedThreads.push(t);
        }
      }
    }
    this.archiveVersion++;
    return { needResync: false, version: this.archiveVersion };
  }

  async labels(): Promise<LabelsState> {
    this.calls.push({ method: "labels", args: [] });
    return structuredClone(this.labelsValue);
  }

  async updateLabels(labels: Label[], version: number): Promise<LabelsState> {
    this.calls.push({ method: "updateLabels", args: [labels, version] });
    if (version !== this.labelsValue.version) {
      throw new RpcError("conflict", "labels version is stale");
    }
    this.labelsValue = {
      labels: structuredClone(labels),
      version: version + 1,
      lastUpdateTime: Date.now(),
    };
    return structuredClone(this.labelsValue);
  }

  async autoDeleteChat(): Promise<AutoDeleteChat> {
    this.calls.push({ method: "autoDeleteChat", args: [] });
    return { conversations: structuredClone(this.autoDeleteConversations) };
  }

  async updateAutoDeleteChat(
    threadId: string,
    threadType: ThreadType,
    ttl: number,
  ) {
    this.calls.push({
      method: "updateAutoDeleteChat",
      args: [threadId, threadType, ttl],
    });
    if (!(AUTO_DELETE_TTLS as readonly number[]).includes(ttl)) {
      throw new RpcError("bad_request", "unsupported auto-delete ttl");
    }
    this.autoDeleteConversations = this.autoDeleteConversations.filter(
      (c) => !(c.threadId === threadId && c.threadType === threadType),
    );
    if (ttl > 0) {
      this.autoDeleteConversations.push({ threadId, threadType, ttl });
    }
  }

  async linkedDevices(): Promise<LinkedDevices> {
    this.calls.push({ method: "linkedDevices", args: [] });
    return structuredClone(this.linkedDevicesValue);
  }

  async groupMembersInfo(uids: string[]): Promise<UserInfo[]> {
    this.calls.push({ method: "groupMembersInfo", args: [uids] });
    return uids.map((uid) => ({
      uid,
      displayName: `User ${uid}`,
      avatarUrl: `https://example.com/${uid}.png`,
    }));
  }

  async keepAlive() {
    this.calls.push({ method: "keepAlive", args: [] });
  }

  async logout() {
    this.calls.push({ method: "logout", args: [] });
  }

  async listFriends(): Promise<Contact[]> {
    this.calls.push({ method: "listFriends", args: [] });
    const alias = this.friendAliases.get("friend-1");
    return [
      {
        uid: "friend-1",
        displayName: "Friend One",
        avatarUrl: "https://example.com/f1.png",
        ...(alias !== undefined ? { alias } : {}),
        ...(this.closeFriendIds.has("friend-1") ? { closeFriend: true } : {}),
      },
    ];
  }

  async findUserByPhone(phone: string): Promise<UserProfile | null> {
    this.calls.push({ method: "findUserByPhone", args: [phone] });
    return this.foundUsers.get(phone) ?? null;
  }

  async findUserByUsername(username: string): Promise<UserProfile | null> {
    this.calls.push({ method: "findUserByUsername", args: [username] });
    return this.foundUsers.get(username) ?? null;
  }

  async friendRequestStatus(uid: string): Promise<FriendRequestStatus> {
    this.calls.push({ method: "friendRequestStatus", args: [uid] });
    return this.requestStatusValue;
  }

  async sendFriendRequest(uid: string, message: string) {
    this.calls.push({ method: "sendFriendRequest", args: [uid, message] });
    this.sentRequests.push({
      uid,
      displayName: `User ${uid}`,
      avatarUrl: `https://example.com/${uid}.png`,
      ...(message !== "" ? { message } : {}),
      ts: Date.now(),
    });
  }

  async receivedFriendRequests() {
    this.calls.push({ method: "receivedFriendRequests", args: [] });
    return this.receivedRequests;
  }

  async sentFriendRequests() {
    this.calls.push({ method: "sentFriendRequests", args: [] });
    return this.sentRequests;
  }

  async acceptFriendRequest(uid: string) {
    this.calls.push({ method: "acceptFriendRequest", args: [uid] });
    this.receivedRequests = this.receivedRequests.filter((r) => r.uid !== uid);
  }

  async rejectFriendRequest(uid: string) {
    this.calls.push({ method: "rejectFriendRequest", args: [uid] });
    this.receivedRequests = this.receivedRequests.filter((r) => r.uid !== uid);
  }

  async undoFriendRequest(uid: string) {
    this.calls.push({ method: "undoFriendRequest", args: [uid] });
    this.sentRequests = this.sentRequests.filter((r) => r.uid !== uid);
  }

  async friendRecommendations() {
    this.calls.push({ method: "friendRecommendations", args: [] });
    return this.recommendations;
  }

  async setFriendAlias(uid: string, alias: string) {
    this.calls.push({ method: "setFriendAlias", args: [uid, alias] });
    this.friendAliases.set(uid, alias);
  }

  async removeFriendAlias(uid: string) {
    this.calls.push({ method: "removeFriendAlias", args: [uid] });
    this.friendAliases.delete(uid);
  }

  async removeFriend(uid: string) {
    this.calls.push({ method: "removeFriend", args: [uid] });
    this.friendAliases.delete(uid);
  }

  async blockUser(uid: string) {
    this.calls.push({ method: "blockUser", args: [uid] });
  }

  async unblockUser(uid: string) {
    this.calls.push({ method: "unblockUser", args: [uid] });
  }

  async friendOnlines() {
    this.calls.push({ method: "friendOnlines", args: [] });
    return this.presence;
  }

  async lastOnline(uid: string) {
    this.calls.push({ method: "lastOnline", args: [uid] });
    return this.lastSeen;
  }

  async listGroups(): Promise<GroupInfo[]> {
    this.calls.push({ method: "listGroups", args: [] });
    return [
      {
        id: "group-1",
        name: "Group One",
        avatarUrl: "https://example.com/g1.png",
        memberIds: [this.self.uid, "friend-1"],
      },
    ];
  }

  // Seedable history page for the messages.list on-demand fetch.
  historyMessages: Message[] = [];
  historyMore = false;
  async groupHistory(groupId: string, count: number) {
    this.calls.push({ method: "groupHistory", args: [groupId, count] });
    return { messages: this.historyMessages, more: this.historyMore };
  }

  async fullAvatar(uid: string): Promise<string> {
    this.calls.push({ method: "fullAvatar", args: [uid] });
    return `https://example.com/full/${uid}.jpg`;
  }

  async groupInfo(groupId: string): Promise<GroupInfo> {
    this.calls.push({ method: "groupInfo", args: [groupId] });
    return {
      id: groupId,
      name: "Group One",
      avatarUrl: "https://example.com/g1.png",
      memberIds: [this.self.uid, "friend-1"],
      ownerId: this.groupOwnerId ?? this.self.uid,
      adminIds: this.groupAdminIds,
    };
  }

  async userInfo(uids: string[]): Promise<UserInfo[]> {
    this.calls.push({ method: "userInfo", args: [uids] });
    return uids.map((uid) => ({
      uid,
      displayName: `User ${uid}`,
      avatarUrl: `https://example.com/${uid}.png`,
    }));
  }

  async fetchMedia(url: string) {
    this.calls.push({ method: "fetchMedia", args: [url] });
    const uploaded = this.uploads.get(url);
    if (uploaded !== undefined) {
      return { data: uploaded, contentType: "application/octet-stream" };
    }
    // `?size=N` controls the payload size so multi-chunk sealed media can
    // be exercised in tests.
    const m = /[?&]size=(\d+)/.exec(url);
    if (m !== null) {
      const n = Math.min(Number(m[1]), 20 * 1024 * 1024);
      const data = new Uint8Array(n);
      for (let i = 0; i < n; i++) data[i] = i % 251;
      return { data, contentType: "application/octet-stream" };
    }
    return {
      data: new TextEncoder().encode(`fake media bytes for ${url}`),
      contentType: "application/octet-stream",
    };
  }

  // ---- test helpers ----

  injectReceipt(t: {
    threadId: string;
    threadType: "user" | "group";
    kind: "seen" | "delivered";
    userIds: string[];
    msgId: string;
  }) {
    this.emit("receipt", t);
  }

  injectFriend(t: unknown) {
    this.emit("friendEvent", t);
  }

  injectGroup(t: unknown) {
    this.emit("groupEvent", t);
  }

  injectIncoming(partial: Partial<Message> & { threadId: string }): Message {
    const msg: Message = {
      id: `${this.idPrefix}-${this.msgSeq++}`,
      cliId: null,
      threadType: "user",
      senderId: "friend-1",
      senderName: "Friend One",
      ts: Date.now(),
      isSelf: false,
      kind: "text",
      text: "incoming",
      reactions: {},
      recalled: false,
      ...partial,
    };
    msg.raw = this.makeRaw({
      id: msg.id,
      cliId: msg.cliId,
      threadId: msg.threadId,
      uidFrom: msg.senderId,
      dName: msg.senderName,
      ts: msg.ts,
      text: msg.text,
    });
    this.emit("message", msg);
    return msg;
  }

  // ---- Voice & Video Calls ----

  private callSeq = 1;
  groupCallStates = new Map<string, Record<string, unknown>>();

  async startCall(
    threadId: string,
    threadType: ThreadType,
    media: "voice" | "video",
  ) {
    const callId = `fake-call-${this.callSeq++}`;
    this.calls.push({ method: "startCall", args: [threadId, threadType, media] });
    return {
      callId,
      ...(threadType === "group" ? { groupCallId: `grp-call-${callId}` } : {}),
      serverConfig: { callId, media, rtpaddr: "127.0.0.1:40000" },
    };
  }

  async sendCallInvite(
    callId: string,
    opts: {
      calleeId: string;
      rtpAddress: string;
      rtcpAddress: string;
      codec: string;
      session: string;
      extendData?: string;
    },
  ) {
    this.calls.push({ method: "sendCallInvite", args: [callId, opts] });
    return { ok: true };
  }

  async sendRingRing(callId: string, callerId: string) {
    this.calls.push({ method: "sendRingRing", args: [callId, callerId] });
    return { ok: true };
  }

  async answerCall(
    callId: string,
    opts: {
      callerId?: string;
      groupId?: string;
      media: "voice" | "video";
      rtpAddress?: string;
      rtcpAddress?: string;
      codec?: string;
      sessionId?: string;
      extendData?: string;
    },
  ) {
    this.calls.push({ method: "answerCall", args: [callId, opts] });
    return { serverConfig: { callId, accepted: true, rtpaddr: "127.0.0.1:40002" } };
  }

  async answerAck(callId: string, calleeId: string) {
    this.calls.push({ method: "answerAck", args: [callId, calleeId] });
    return { ok: true };
  }

  async cancelCall(callId: string, opts: { peerId: string; media: "voice" | "video" }) {
    this.calls.push({ method: "cancelCall", args: [callId, opts] });
    return { ok: true };
  }

  async rejectCall(
    callId: string,
    opts: { callerId?: string; groupId?: string; reason?: number },
  ) {
    this.calls.push({ method: "rejectCall", args: [callId, opts] });
  }

  async endCall(
    callId: string,
    opts: {
      peerId?: string;
      groupId?: string;
      durationSec?: number;
      reason?: number;
    },
  ) {
    this.calls.push({ method: "endCall", args: [callId, opts] });
  }

  async getGroupCallState(groupId: string) {
    this.calls.push({ method: "getGroupCallState", args: [groupId] });
    return this.groupCallStates.get(groupId) ?? { groupId, active: false, members: [] };
  }

  async sendCallSignal(action: string, payload: Record<string, unknown>) {
    this.calls.push({ method: "sendCallSignal", args: [action, payload] });
    return { ok: true, action, payload };
  }

  simulateIncomingCall(opts: {
    callId: string;
    callerId: string;
    callerName?: string;
    groupId?: string;
    media?: "voice" | "video";
  }) {
    const isGroup = opts.groupId !== undefined;
    const media = opts.media ?? "voice";
    this.emit("voip", {
      act: isGroup ? "group_request" : "request",
      ts: Date.now(),
      conversationId: opts.groupId ?? opts.callerId,
      callerId: opts.callerId,
      ...(opts.groupId ? { groupId: opts.groupId } : {}),
      inCallStatus: null,
      data: {
        callId: opts.callId,
        callerId: opts.callerId,
        ...(opts.callerName ? { callerName: opts.callerName } : {}),
        calltype: media === "video" ? (isGroup ? 6 : 3) : isGroup ? 5 : 1,
      },
    });
  }
}

function msgName(name: string): string {
  return name.replace(/[^a-zA-Z0-9._-]/g, "_");
}

function convKey(t: ConversationRef): string {
  return `${t.threadType}:${t.threadId}`;
}

// OA-shaped fake: full message flow, none of the capability enum. Token
// rotation is exercised through setTokens + the onCredentials hook.
export class FakeOaGateway extends FakeGateway {
  readonly rotated: string[] = [];
  override capabilities(): string[] {
    return [];
  }
  setTokens(accessToken: string, refreshToken: string): void {
    this.rotated.push(`${accessToken}/${refreshToken}`);
  }
  override parseLink(): Promise<never> {
    return Promise.reject(
      new RpcError("not_supported", "link previews are not supported for OA"),
    );
  }
  override sendLink(): Promise<{ msgId: string }> {
    return Promise.reject(
      new RpcError("not_supported", "links are not supported for OA"),
    );
  }
  override sendBankCard(): Promise<{ msgId: string }> {
    return Promise.reject(
      new RpcError("not_supported", "bank cards are not supported for OA"),
    );
  }
  override bankList(): Promise<never> {
    return Promise.reject(
      new RpcError("not_supported", "banks are not supported for OA"),
    );
  }
  override bankAccounts(): Promise<never> {
    return Promise.reject(
      new RpcError("not_supported", "banks are not supported for OA"),
    );
  }
  override quickMessages(): Promise<never> {
    return Promise.reject(
      new RpcError("not_supported", "quick messages are not supported for OA"),
    );
  }
  override addQuickMessage(): Promise<never> {
    return Promise.reject(
      new RpcError("not_supported", "quick messages are not supported for OA"),
    );
  }
  override updateQuickMessage(): Promise<never> {
    return Promise.reject(
      new RpcError("not_supported", "quick messages are not supported for OA"),
    );
  }
  override removeQuickMessages(): Promise<never> {
    return Promise.reject(
      new RpcError("not_supported", "quick messages are not supported for OA"),
    );
  }
}

export class FakeGatewayFactory implements GatewayFactory {
  readonly gateways: FakeGateway[] = [];
  qrPng: Uint8Array = new TextEncoder().encode("fake-qr-png");
  oaPersisted: unknown[] = [];
  private oaHooks: OaHooks | null = null;

  fromCredentials(_creds: Credentials, self?: GatewaySelf): FakeGateway {
    const gw = new FakeGateway(self);
    this.gateways.push(gw);
    return gw;
  }

  fromOaCredentials(
    _creds: OaCredentials,
    self: GatewaySelf,
    hooks: OaHooks,
  ): FakeOaGateway {
    this.oaHooks = hooks;
    const gw = new FakeOaGateway(self);
    // The real gateway fills the shared self during start(); mirror that
    // so the manager's credential validation sees a non-empty uid.
    self.uid = gw.self.uid;
    self.displayName = gw.self.displayName;
    self.avatarUrl = gw.self.avatarUrl;
    this.gateways.push(gw);
    return gw;
  }

  // Test helper: simulate the OA token manager rotating the pair; the
  // fake must persist via the same hook the real gateway uses.
  oaRotate(creds: OaCredentials) {
    this.oaHooks?.onCredentials(creds);
    this.oaPersisted.push(creds);
  }

  async loginQr(callbacks: LoginQrCallbacks) {
    callbacks.onQr(this.qrPng);
    const self = {
      uid: `fake-uid-${++counter}`,
      displayName: "Fake Account",
      avatarUrl: "https://example.com/avatar.png",
    };
    callbacks.onScanned({
      displayName: self.displayName,
      avatarUrl: self.avatarUrl,
    });
    return {
      credentials: {
        imei: "fake-imei",
        cookie: { url: "https://fake", cookies: [] },
        userAgent: "fake-ua",
      },
      self,
    };
  }
}
