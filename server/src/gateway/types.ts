// Abstraction over Zalo. The zca-js adapter implements these interfaces;
// every payload is a normalized shape, never a zca-js type.

export type ThreadType = "user" | "group";

export type Attachment = {
  kind: "image" | "video" | "file" | "voice" | "link" | "gif";
  url: string;
  thumbUrl?: string;
  name?: string;
  size?: number;
  width?: number;
  height?: number;
  durationMs?: number;
};

export type StickerRef = {
  id: number;
  cateId: number;
  type: number;
  url?: string;
  spriteUrl?: string;
  frames?: number;
  durationMs?: number;
  animatedWebp?: boolean;
};

export type BoardItemKind = "message" | "poll" | "note" | "reminder" | "link";

export type PinnedTopic = {
  id: string;
  topicType: number; // 0=text/note, 1=link, 2=message, 3=poll, 4=reminder
  kind: BoardItemKind;
  title: string;
  senderId?: string;
  senderName?: string;
  msgId?: string;
  cliMsgId?: string;
  pollId?: number;
  thumbUrl?: string;
  createdAt?: number;
  pinned: boolean;
};

export type PinBoardState = {
  items: PinnedTopic[];
  version: number;
};

export type PollOptionDetail = {
  id: number;
  content: string;
  votes: number;
  voted: boolean;
  voters: string[];
};

export type PollDetail = {
  id: number;
  groupId: string;
  question: string;
  creatorId: string;
  createdAt: number;
  expiredAt: number;
  closed: boolean;
  multiple: boolean;
  allowAdd: boolean;
  hidePreview: boolean;
  anonymous: boolean;
  totalVotes: number;
  options: PollOptionDetail[];
};

export type ReminderItem = {
  id: string;
  title: string;
  emoji: string;
  startTime: number;
  repeat: number; // 0=none, 1=daily, 2=weekly, 3=monthly
  creatorId?: string;
  createdAt?: number;
};

export type Quote = {
  msgId: string;
  senderId: string;
  senderName: string;
  text: string;
};

export type Mention = { uid: string; pos: number; len: number };

export type MessageKind =
  | "text"
  | "image"
  | "video"
  | "file"
  | "voice"
  | "gif"
  | "sticker"
  | "link"
  | "card"
  | "bank"
  | "location"
  | "poll"
  | "note"
  | "reminder"
  | "call"
  | "doodle"
  | "album"
  | "todo"
  | "system"
  | "other";

// zca-js TextStyle values (sendMessage styles). `ind_$` is the indent
// marker; indentSize carries the depth.
export const TEXT_STYLE_CODES = [
  "b",
  "i",
  "u",
  "s",
  "c_db342e",
  "c_f27806",
  "c_f7b503",
  "c_15a85f",
  "f_13",
  "f_18",
  "lst_1",
  "lst_2",
  "ind_$",
] as const;
export type TextStyleCode = (typeof TEXT_STYLE_CODES)[number];

export type StyleRun = {
  start: number;
  len: number;
  st: TextStyleCode;
  // Only meaningful for "ind_$"; zca-js multiplies it by 10.
  indentSize?: number;
};

export const URGENCIES = ["default", "important", "urgent"] as const;
export type Urgency = (typeof URGENCIES)[number];

// Per-message TTL bound. Zalo's composer offers up to 7 days; anything
// longer is almost certainly a unit mistake, so the RPC rejects it.
export const MAX_MESSAGE_TTL_MS = 7 * 86_400_000;

export type Message = {
  id: string;
  cliId: string | null;
  threadId: string;
  threadType: ThreadType;
  senderId: string;
  senderName: string;
  ts: number;
  isSelf: boolean;
  kind: MessageKind;
  text?: string;
  attachments?: Attachment[];
  sticker?: StickerRef;
  card?: ContactCard;
  bankCard?: BankCard;
  location?: Location;
  poll?: Poll;
  note?: Note;
  reminder?: Reminder;
  callLog?: CallLog;
  doodle?: Doodle;
  album?: Album;
  todo?: Todo;
  quote?: Quote;
  mentions?: Mention[];
  // Styled text runs and delivery urgency as sent; inbound payloads rarely
  // carry them, so they are usually only present on own sends.
  styles?: StyleRun[];
  urgency?: Urgency;
  // Per-message self-destruct window in ms and its absolute expiry. This
  // is independent of the per-conversation auto-delete TTL.
  ttl?: number;
  expiresAt?: number;
  reactions: Record<string, string[]>;
  recalled: boolean;
  // Opaque original gateway payload; persisted as raw_json so methods that
  // need original Zalo fields (react, undo, seen, quote) can replay them.
  raw?: unknown;
};

export type Thread = {
  id: string;
  type: ThreadType;
  name: string;
  avatarUrl: string;
  lastMessage: Message | null;
  lastTs: number;
  unread: number;
  pinned: boolean;
  muted: boolean;
  hidden: boolean;
  archived: boolean;
  // Per-conversation auto-delete TTL in ms; 0 is off.
  autoDeleteTtl: number;
};

// A conversation reference used by state sync and the hidden/archive
// lists.
export type ConversationRef = {
  threadId: string;
  threadType: ThreadType;
};

// Hidden conversations as Zalo holds them. The PIN hash Zalo returns is
// deliberately absent: the client only needs to know whether a PIN is
// set so it can gate its own local unlock UI.
export type HiddenConversations = {
  pinSet: boolean;
  threads: ConversationRef[];
};

export type ArchivedChatList = {
  threads: ConversationRef[];
  version: number;
};

// Conversation labels (tags). Whole-set updates carry a version; a stale
// version is a conflict. Names and assignments are clear metadata, never
// sealed message content.
export type Label = {
  id: number;
  text: string;
  textKey: string;
  conversations: string[];
  color: string;
  offset: number;
  emoji: string;
  createTime: number;
};

export type LabelsState = {
  labels: Label[];
  version: number;
  lastUpdateTime: number;
};

// Auto-delete TTLs Zalo supports, in milliseconds; 0 is off.
export const AUTO_DELETE_TTLS = [
  0, 86_400_000, 604_800_000, 1_209_600_000,
] as const;
export type AutoDeleteTtl = (typeof AUTO_DELETE_TTLS)[number];

export type AutoDeleteConversation = ConversationRef & {
  ttl: number;
  createdAt?: number;
};

export type AutoDeleteChat = {
  conversations: AutoDeleteConversation[];
};

// Linked Zalo devices (the account's companion sessions), read only.
// Opaque cryptographic fields (identity/signature blobs) stay inside the
// gateway: they are never logged and never returned.
export type LinkedDeviceCompanion = {
  id?: string;
  name?: string;
  platform?: string;
  lastUpdateTs?: number;
  current?: boolean;
  // Fallback for an unrecognized companion shape: a value-free summary
  // (container shape and field names only), never key material.
  summary?: string;
};

export type LinkedDevices = {
  masterId: string;
  lastUpdateTs?: number;
  companions: LinkedDeviceCompanion[];
};

// Zalo's conversation state pulled on connect so local threads converge.
// Every section is absent when its endpoint failed: the manager keeps the
// local flags instead of clearing them. A present empty list means the
// endpoint answered and Zalo reports nothing set.
export type ConversationSyncState = {
  pinned?: ConversationRef[];
  muted?: ConversationRef[];
  hidden?: ConversationRef[];
  archived?: ConversationRef[];
  autoDelete?: AutoDeleteConversation[];
};

export type Contact = {
  uid: string;
  displayName: string;
  avatarUrl: string;
  alias?: string;
  // getCloseFriends membership, merged into the friend list.
  closeFriend?: boolean;
};

export type GroupMember = {
  uid: string;
  displayName: string;
  avatarUrl: string;
  role: "owner" | "deputy" | "member";
};

export type GroupInfo = {
  id: string;
  name: string;
  avatarUrl: string;
  // Normalized member ids. Real accounts may only expose a page of members,
  // so this can be shorter than memberCount.
  memberIds: string[];
  // Total members Zalo reports; falls back to memberIds.length when absent.
  memberCount?: number;
  ownerId?: string;
  adminIds?: string[];
  // Display-name/avatar seeds for memberIds when the source already carries
  // them (zca currentMems), so a failed profile lookup still shows names.
  members?: GroupMember[];
};

export type UserInfo = {
  uid: string;
  displayName: string;
  avatarUrl: string;
  gender?: string;
};

// A user found by phone number or username. Never a raw zca-js UserBasic.
export type UserProfile = {
  uid: string;
  displayName: string;
  avatarUrl: string;
  zaloName?: string;
  gender?: string;
  phoneNumber?: string;
};

export type FriendRequestStatus = {
  isFriend: boolean;
  // The other side has a pending request to this account.
  isRequested: boolean;
  // This account has a pending request to the other side.
  isRequesting: boolean;
  addFriendPrivacy: number;
  // Whether the pending request has been seen.
  isSeen: boolean;
};

// getFriendRecommendations recommType 2: requests received from others.
export type ReceivedFriendRequest = {
  uid: string;
  displayName: string;
  avatarUrl: string;
  message?: string;
  ts?: number;
};

// getSentFriendRequest: requests this account sent and can cancel.
export type SentFriendRequest = {
  uid: string;
  displayName: string;
  avatarUrl: string;
  message?: string;
  ts?: number;
};

// getFriendRecommendations recommType 1: suggested friends.
export type FriendRecommendation = {
  uid: string;
  displayName: string;
  avatarUrl: string;
  phoneNumber?: string;
  gender?: string;
  message?: string;
};

export type FriendPresence = {
  uid: string;
  status: string;
  online: boolean;
};

export type LastSeen = {
  showOnlineStatus: boolean;
  lastOnline: number;
};

// Contact card (danh thiếp): sendCard emits it and inbound
// chat.recommended messages carry it.
export type ContactCard = {
  uid: string;
  displayName: string;
  avatarUrl: string;
  phone?: string;
  qrCodeUrl?: string;
};

// Bank card (thẻ ngân hàng): sendBankCard emits it. Inbound payload shapes
// are not enumerated by zca-js, so every field except bin/accountNumber is
// best effort and the raw payload stays sealed alongside it.
export type BankCard = {
  bin: number;
  accountNumber: string;
  holderName?: string;
  bankName?: string;
  bankLogo?: string;
};

// The composer reads the supported bank list and the account's own saved
// accounts before sending a bank card.
export type BankInfo = {
  bin: number;
  logo: string;
  name: string;
  nameEn: string;
  shortName: string;
  searchKeyword: string;
};

export type BankAccount = {
  id: string;
  bin: number;
  accountNumber: string;
  holderName: string;
  isDefault: boolean;
  accountId: number;
  bankName?: string;
  bankLogo?: string;
  createdAt: number;
  updatedAt: number;
};

export type BankAccounts = {
  accounts: BankAccount[];
  total: number;
  hasMore: boolean;
};

export type Location = {
  lat: number;
  lng: number;
  name?: string;
  address?: string;
  thumbUrl?: string;
};

export type PollOption = {
  id: number;
  text: string;
  votes?: number;
  voted?: boolean;
};

export type Poll = {
  id?: number;
  question: string;
  options: PollOption[];
  multiple?: boolean;
  closed?: boolean;
  anonymous?: boolean;
  totalVotes?: number;
  expiredAt?: number;
};

export type Note = {
  id?: string;
  title: string;
  text?: string;
  pinned?: boolean;
};

export type Reminder = {
  id?: string;
  title: string;
  startTime?: number;
  repeat?: number;
  emoji?: string;
};

export type CallLog = {
  callType: "voice" | "video" | "unknown";
  durationMs?: number;
  missed?: boolean;
  state?: string;
};

export type Doodle = {
  url: string;
  thumbUrl?: string;
  width?: number;
  height?: number;
};

export type Album = {
  items: Attachment[];
  caption?: string;
};

export type TodoItem = {
  text: string;
  done?: boolean;
};

export type Todo = {
  id?: string;
  title: string;
  items: TodoItem[];
  done?: boolean;
};

// Link preview from parseLink; sendLink reuses it for the outbound bubble.
export type LinkPreview = {
  title: string;
  description: string;
  srcUrl: string;
  href: string;
  thumbUrl?: string;
  mediaType?: number;
  mediaCount?: number;
  mediaTitle?: string;
  mediaArtist?: string;
  streamUrl?: string;
};

export type QuickMessageMedia = {
  type: number;
  photoId: number;
  title: string;
  width: number;
  height: number;
  previewThumb: string;
  rawUrl: string;
  thumbUrl: string;
  normalUrl: string;
  hdUrl: string;
};

// A stored composer shortcut. Insertion into the composer is a client
// concern; the server only mirrors Zalo's real list and mutations.
export type QuickMessage = {
  id: number;
  keyword: string;
  title: string;
  type: number;
  createdTime: number;
  lastModified: number;
  media: QuickMessageMedia[];
};

export type QuickMessages = {
  items: QuickMessage[];
  version: number;
  cursor: number;
};

export type QuickMessageDraft = {
  keyword: string;
  title: string;
  // A replacement photo. On update, omitting it keeps the stored media;
  // it never clears the photo.
  media?: OutgoingFile;
};

export type ReportReason = "sensitive" | "annoy" | "fraud" | "other";

export type AccountStatus =
  | "starting"
  | "online"
  | "reconnecting"
  | "displaced"
  | "needs_login"
  | "offline"
  | "error";

export type GatewaySelf = {
  uid: string;
  displayName: string;
  avatarUrl: string;
};

export type Credentials = {
  imei: string;
  cookie: unknown;
  userAgent: string;
  language?: string;
};

// Official Account credentials (kind "oa"): app id/secret from the Zalo
// for Developers console plus the token pair from its API Explorer.
export type OaCredentials = {
  appId: string;
  appSecret: string;
  accessToken: string;
  refreshToken: string;
  // ms epoch; absent means "expires soon", so the first call refreshes.
  accessTokenExpiresAt?: number;
  oaId?: string;
};

export type OaHooks = {
  // Persist the rotated token pair synchronously; called before the new
  // pair is ever used so a crash never strands the refresh token.
  onCredentials(creds: OaCredentials): void;
  // Whether any client is currently connected to this account slot.
  clientConnected(): boolean;
};

export type CallMediaKind = "voice" | "video";
export type CallDirection = "incoming" | "outgoing";
export type CallStatus = "ringing" | "connecting" | "active" | "ended";

export type ActiveCall = {
  callId: string;
  threadId: string;
  threadType: ThreadType;
  peerId: string;
  peerName: string;
  peerAvatarUrl?: string;
  media: CallMediaKind;
  direction: CallDirection;
  status: CallStatus;
  startedAt: number;
  answeredAt?: number;
  answeredByDeviceId?: string;
  isGroup: boolean;
  groupCallId?: string;
  participants?: string[];
  signalingData?: Record<string, unknown>;
};

export type GatewayVoipEvent = {
  act: string;
  ts: number;
  conversationId?: string;
  callerId?: string;
  groupId?: string;
  inCallStatus: "zalo" | null;
  data: Record<string, unknown>;
};

export type GatewayEvents = {
  message: [message: Message];
  typing: [t: { threadId: string; threadType: ThreadType; userId: string }];
  receipt: [
    t: {
      threadId: string;
      threadType: ThreadType;
      kind: "seen" | "delivered";
      userIds: string[];
      msgId: string;
    },
  ];
  reaction: [
    t: {
      threadId: string;
      threadType: ThreadType;
      msgId: string;
      icon: string;
      userId: string;
      isSelf: boolean;
    },
  ];
  recall: [
    t: { threadId: string; threadType: ThreadType; msgId: string; isSelf: boolean },
  ];
  status: [status: AccountStatus];
  // The account's own uid/name/avatar was resolved or refreshed.
  self: [self: GatewaySelf];
  // Bulk history ingest (zca old_messages): persist but no per-message events.
  history: [messages: Message[]];
  // The live session credentials changed (Zalo rotated a cookie); the
  // manager persists them so a restart resumes without a new QR.
  credentials: [creds: Credentials];
  friendEvent: [t: unknown];
  groupEvent: [t: unknown];
  voip: [evt: GatewayVoipEvent];
};

export type OutgoingFile = {
  name: string;
  path: string;
  contentType?: string;
};

export interface ZaloGateway {
  readonly status: AccountStatus;
  readonly self: GatewaySelf;
  // Feature names this account kind supports (see client AccountCapability).
  // Personal accounts return all; OA accounts return only what exists.
  capabilities(): string[];
  // OA only: replace rotated-out tokens after accounts.updateOaTokens.
  setTokens?(accessToken: string, refreshToken: string): void;
  // OA only: the live credential pair, post any in-flight rotation. The
  // manager stores this so a refresh that ran before the slot existed is
  // not lost.
  oaCredentials?(): OaCredentials;
  on<E extends keyof GatewayEvents>(
    event: E,
    cb: (...args: GatewayEvents[E]) => void,
  ): void;
  start(): Promise<void>;
  stop(): Promise<void>;
  sendText(
    threadId: string,
    threadType: ThreadType,
    text: string,
    // quote: the client passes back the decrypted `raw` object of the
    // quoted message's body; the gateway validates and replays it.
    opts?: {
      quote?: { raw?: unknown };
      mentions?: Mention[];
      styles?: StyleRun[];
      urgency?: Urgency;
      ttl?: number;
    },
  ): Promise<{ msgId: string; cliId: string }>;
  sendMedia(
    threadId: string,
    threadType: ThreadType,
    kind: "image" | "video" | "file" | "voice" | "gif",
    file: OutgoingFile,
    caption?: string,
    cliId?: string,
    // Per-message TTL and urgency, same contract as sendText. zca-js only
    // accepts urgency for sendMessage attachments (image/gif/file); voice
    // and video sends carry ttl alone.
    opts?: { ttl?: number; urgency?: Urgency },
  ): Promise<{ msgId: string; cliId: string }>;
  sendSticker(
    threadId: string,
    threadType: ThreadType,
    sticker: StickerRef,
  ): Promise<{ msgId: string; cliId: string }>;
  sendCard(
    threadId: string,
    threadType: ThreadType,
    card: { userId: string; phoneNumber?: string; ttl?: number },
  ): Promise<{ msgId: string; cliId: string }>;
  // Link preview for the composer (title, description, thumbnail).
  parseLink(link: string): Promise<LinkPreview>;
  sendLink(
    threadId: string,
    threadType: ThreadType,
    opts: { link: string; msg?: string; ttl?: number },
  ): Promise<{ msgId: string }>;
  // sendBankCard returns an empty response on real accounts; the listener
  // echo carries the real message. Never invent a msgId here.
  sendBankCard(
    threadId: string,
    threadType: ThreadType,
    card: { bin: number; accountNumber: string; holderName?: string },
  ): Promise<{ msgId: string }>;
  bankList(): Promise<BankInfo[]>;
  bankAccounts(page: number, limit: number): Promise<BankAccounts>;
  quickMessages(): Promise<QuickMessages>;
  addQuickMessage(
    draft: QuickMessageDraft,
  ): Promise<{ item: QuickMessage; version: number }>;
  updateQuickMessage(
    id: number,
    draft: QuickMessageDraft,
  ): Promise<{ item: QuickMessage; version: number }>;
  removeQuickMessages(
    ids: number[],
  ): Promise<{ itemIds: number[]; version: number }>;
  sendReport(
    threadId: string,
    threadType: ThreadType,
    opts: { reason: ReportReason; content?: string },
  ): Promise<{ reportId: string }>;
  searchStickers(query: string): Promise<StickerRef[]>;
  stickerCategory?(cateId: number): Promise<StickerRef[]>;
  listPins?(threadId: string, threadType: ThreadType): Promise<PinBoardState>;
  listBoard?(
    groupId: string,
    page?: number,
    count?: number,
  ): Promise<PinnedTopic[]>;
  pinMessage?(
    threadId: string,
    threadType: ThreadType,
    payload: {
      msgId: string;
      cliMsgId?: string;
      senderId: string;
      senderName: string;
      title: string;
      kind: MessageKind;
      thumbUrl?: string;
      href?: string;
      raw?: unknown;
    },
  ): Promise<PinBoardState>;
  pinBoardItem?(
    groupId: string,
    topicId: string,
    topicType: number,
  ): Promise<void>;
  unpinTopic?(
    threadId: string,
    threadType: ThreadType,
    topicId: string,
    topicType: number,
  ): Promise<PinBoardState>;
  createPoll?(
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
  ): Promise<PollDetail>;
  pollDetail?(pollId: number, groupId?: string): Promise<PollDetail>;
  votePoll?(
    pollId: number,
    optionIds: number[],
    groupId?: string,
  ): Promise<PollDetail>;
  addPollOption?(
    pollId: number,
    content: string,
    votedOptionIds: number[],
    voteNew?: boolean,
    groupId?: string,
  ): Promise<PollDetail>;
  lockPoll?(pollId: number, groupId?: string): Promise<PollDetail>;
  sharePoll?(pollId: number): Promise<void>;
  createNote?(
    groupId: string,
    title: string,
    pin?: boolean,
  ): Promise<PinnedTopic>;
  editNote?(
    groupId: string,
    topicId: string,
    title: string,
    pin?: boolean,
  ): Promise<PinnedTopic>;
  listReminders?(
    threadId: string,
    threadType: ThreadType,
    page?: number,
    count?: number,
  ): Promise<ReminderItem[]>;
  createReminder?(
    threadId: string,
    threadType: ThreadType,
    opts: {
      title: string;
      emoji?: string;
      startTime: number;
      repeat?: number;
    },
  ): Promise<ReminderItem>;
  editReminder?(
    threadId: string,
    threadType: ThreadType,
    opts: {
      id: string;
      title: string;
      emoji?: string;
      startTime: number;
      repeat?: number;
    },
  ): Promise<ReminderItem>;
  removeReminder?(
    threadId: string,
    threadType: ThreadType,
    id: string,
  ): Promise<void>;
  react(
    msgId: string,
    threadId: string,
    threadType: ThreadType,
    icon: string,
    raw?: unknown,
  ): Promise<void>;
  recall(
    msgId: string,
    threadId: string,
    threadType: ThreadType,
    raw?: unknown,
  ): Promise<void>;
  deleteMessage(
    msgId: string,
    threadId: string,
    threadType: ThreadType,
    raw?: unknown,
  ): Promise<void>;
  // Group owner/deputy only: delete another member's message for everyone.
  deleteMessageForAll(
    msgId: string,
    threadId: string,
    threadType: ThreadType,
    raw?: unknown,
  ): Promise<void>;
  markSeen(
    threadId: string,
    threadType: ThreadType,
    raw?: unknown,
  ): Promise<void>;
  sendTyping(threadId: string, threadType: ThreadType): Promise<void>;
  setPinned(
    threadId: string,
    threadType: ThreadType,
    pinned: boolean,
  ): Promise<void>;
  setMuted(
    threadId: string,
    threadType: ThreadType,
    muted: boolean,
  ): Promise<void>;
  markUnread(threadId: string, threadType: ThreadType): Promise<void>;
  removeUnreadMark(threadId: string, threadType: ThreadType): Promise<void>;
  deleteConversation(
    threadId: string,
    threadType: ThreadType,
    lastRef: unknown,
  ): Promise<void>;
  forward(
    payload: { message: string; reference?: { ts: number; id: string; logSrcType?: number; fwLvl?: number } },
    to: { threadId: string; threadType: ThreadType }[],
  ): Promise<void>;
  // Pinned and muted conversation state as Zalo has it; read on connect so
  // local threads converge to the server side truth. The same pull carries
  // hidden, archived and auto-delete state.
  syncConversationState(): Promise<ConversationSyncState>;
  // ---- hidden, archived, labels, auto-delete, linked devices ----
  hiddenConversations(): Promise<HiddenConversations>;
  setHiddenConversations(
    threads: ConversationRef[],
    hidden: boolean,
  ): Promise<void>;
  // The PIN is sent to Zalo once and never stored or returned.
  setHiddenPin(pin: string): Promise<void>;
  resetHiddenPin(): Promise<void>;
  archivedChatList(): Promise<ArchivedChatList>;
  updateArchivedChatList(
    archived: boolean,
    threads: ConversationRef[],
  ): Promise<{ needResync: boolean; version: number }>;
  labels(): Promise<LabelsState>;
  // Whole-set update; a stale version is rejected by Zalo.
  updateLabels(labels: Label[], version: number): Promise<LabelsState>;
  autoDeleteChat(): Promise<AutoDeleteChat>;
  updateAutoDeleteChat(
    threadId: string,
    threadType: ThreadType,
    ttl: number,
  ): Promise<void>;
  linkedDevices(): Promise<LinkedDevices>;
  groupMembersInfo(uids: string[]): Promise<UserInfo[]>;
  keepAlive(): Promise<void>;
  logout(): Promise<void>;
  listFriends(): Promise<Contact[]>;
  // ---- friends and contacts (personal accounts) ----
  findUserByPhone(phone: string): Promise<UserProfile | null>;
  findUserByUsername(username: string): Promise<UserProfile | null>;
  friendRequestStatus(uid: string): Promise<FriendRequestStatus>;
  sendFriendRequest(uid: string, message: string): Promise<void>;
  receivedFriendRequests(): Promise<ReceivedFriendRequest[]>;
  sentFriendRequests(): Promise<SentFriendRequest[]>;
  acceptFriendRequest(uid: string): Promise<void>;
  rejectFriendRequest(uid: string): Promise<void>;
  undoFriendRequest(uid: string): Promise<void>;
  friendRecommendations(): Promise<FriendRecommendation[]>;
  setFriendAlias(uid: string, alias: string): Promise<void>;
  removeFriendAlias(uid: string): Promise<void>;
  removeFriend(uid: string): Promise<void>;
  blockUser(uid: string): Promise<void>;
  unblockUser(uid: string): Promise<void>;
  // On demand only; there is no presence event to subscribe to.
  friendOnlines(): Promise<FriendPresence[]>;
  lastOnline(uid: string): Promise<LastSeen>;
  listGroups(): Promise<GroupInfo[]>;
  groupInfo(groupId: string): Promise<GroupInfo>;
  // Older-than-stored group messages fetched on demand when a client
  // pages past local history (zca getGroupChatHistory). The endpoint has
  // no cursor, only the newest `count` messages; `more` is whether Zalo
  // holds older ones. Optional: kinds without server-side history leave
  // it undefined.
  groupHistory?(
    groupId: string,
    count: number,
  ): Promise<{ messages: Message[]; more: boolean }>;
  userInfo(uids: string[]): Promise<UserInfo[]>;
  // Full-size profile avatar url (zca getFullAvatar). Optional: kinds
  // without it leave it undefined.
  fullAvatar?(uid: string): Promise<string>;
  fetchMedia(url: string): Promise<{ data: Uint8Array; contentType: string }>;
  fetchMediaToFile?(
    url: string,
    outPath: string,
  ): Promise<{ size: number; contentType: string }>;
  // ---- voice & video calls (personal accounts) ----
  startCall?(
    threadId: string,
    threadType: ThreadType,
    media: CallMediaKind,
  ): Promise<{
    callId: string;
    serverConfig?: Record<string, unknown>;
    groupCallId?: string;
  }>;
  sendCallInvite?(
    callId: string,
    opts: {
      calleeId: string;
      rtpAddress: string;
      rtcpAddress: string;
      codec: string;
      session: string;
      extendData?: string;
    },
  ): Promise<unknown>;
  sendRingRing?(callId: string, callerId: string): Promise<unknown>;
  answerCall?(
    callId: string,
    opts: {
      callerId?: string;
      groupId?: string;
      media: CallMediaKind;
      rtpAddress?: string;
      rtcpAddress?: string;
      codec?: string;
      sessionId?: string;
      extendData?: string;
    },
  ): Promise<{ serverConfig?: Record<string, unknown> }>;
  answerAck?(callId: string, calleeId: string): Promise<unknown>;
  cancelCall?(
    callId: string,
    opts: { peerId: string; media: CallMediaKind },
  ): Promise<unknown>;
  rejectCall?(
    callId: string,
    opts: { callerId?: string; groupId?: string; reason?: number },
  ): Promise<void>;
  endCall?(
    callId: string,
    opts: {
      peerId?: string;
      groupId?: string;
      durationSec?: number;
      reason?: number;
    },
  ): Promise<void>;
  getGroupCallState?(groupId: string): Promise<Record<string, unknown>>;
  sendCallSignal?(
    action: string,
    payload: Record<string, unknown>,
  ): Promise<unknown>;
  // ---- extended SDK APIs (groups, profile, business, media store, extras, e2ee) ----
  createGroup?(opts: {
    name?: string;
    members: string[];
    avatarPath?: string;
  }): Promise<{ groupId: string; raw?: unknown }>;
  renameGroup?(groupId: string, name: string): Promise<void>;
  changeGroupAvatar?(groupId: string, file: OutgoingFile): Promise<void>;
  addGroupMembers?(groupId: string, memberIds: string[]): Promise<unknown>;
  inviteUserToGroups?(userId: string, groupIds: string[]): Promise<unknown>;
  removeGroupMembers?(groupId: string, memberIds: string[]): Promise<unknown>;
  leaveGroup?(groupId: string, silent?: boolean): Promise<void>;
  disperseGroup?(groupId: string): Promise<void>;
  changeGroupOwner?(groupId: string, newOwnerId: string): Promise<void>;
  addGroupDeputy?(groupId: string, memberIds: string[]): Promise<void>;
  removeGroupDeputy?(groupId: string, memberIds: string[]): Promise<void>;
  updateGroupSettings?(
    groupId: string,
    settings: Record<string, unknown>,
  ): Promise<void>;
  pendingGroupMembers?(groupId: string): Promise<unknown>;
  reviewPendingGroupMembers?(
    groupId: string,
    members: string[],
    isApprove: boolean,
  ): Promise<unknown>;
  blockedGroupMembers?(
    groupId: string,
    page?: number,
    count?: number,
  ): Promise<unknown>;
  addBlockedGroupMembers?(groupId: string, memberIds: string[]): Promise<void>;
  removeBlockedGroupMembers?(groupId: string, memberIds: string[]): Promise<void>;
  groupLinkDetail?(
    groupId: string,
  ): Promise<{ link?: string; expirationDate?: number; enabled: boolean }>;
  enableGroupLink?(groupId: string): Promise<unknown>;
  disableGroupLink?(groupId: string): Promise<void>;
  groupLinkInfo?(link: string, memberPage?: number): Promise<unknown>;
  joinGroupLink?(link: string): Promise<unknown>;
  groupInviteBoxList?(opts?: {
    page?: number;
    mpage?: number;
    invPerPage?: number;
    mcount?: number;
    lastGroupId?: string | null;
  }): Promise<unknown>;
  groupInviteBoxInfo?(
    groupId: string,
    mcount?: number,
    mpage?: number,
  ): Promise<unknown>;
  joinGroupInviteBox?(groupId: string): Promise<unknown>;
  deleteGroupInviteBox?(groupIds: string[]): Promise<unknown>;
  upgradeGroupToCommunity?(groupId: string): Promise<void>;
  relatedFriendGroups?(friendIds: string[]): Promise<unknown>;

  fetchAccountInfo?(): Promise<Record<string, unknown>>;
  updateProfile?(opts: {
    name: string;
    dob: string;
    gender: number;
    language?: string;
  }): Promise<unknown>;
  updateProfileBio?(bio: string): Promise<void>;
  changeAccountAvatar?(file: OutgoingFile): Promise<unknown>;
  avatarList?(albumId?: string): Promise<unknown>;
  reuseAvatar?(photoId: string, isPostSocial?: boolean): Promise<unknown>;
  deleteAvatar?(photoIds: string[]): Promise<unknown>;
  zaloSettings?(): Promise<Record<string, unknown>>;
  updateZaloSetting?(type: string, value: number): Promise<unknown>;
  updateActiveStatus?(active: boolean): Promise<void>;
  updateLang?(language: string): Promise<void>;
  lostFocus?(): Promise<void>;

  setCloseFriend?(uids: string[], add: boolean): Promise<void>;
  findUsersByPhones?(phones: string[]): Promise<unknown>;
  blockList?(page?: number, count?: number): Promise<unknown>;
  blockViewFeed?(uid: string, blocked: boolean): Promise<void>;
  userQr?(uids: string[]): Promise<Record<string, string>>;

  removeNote?(groupId: string, topicId: string): Promise<void>;
  reminderDetail?(reminderId: string): Promise<unknown>;
  reminderResponses?(reminderId: string): Promise<unknown>;
  reorderPins?(
    threadId: string,
    threadType: ThreadType,
    topics: unknown[],
    version?: number,
  ): Promise<unknown>;
  multiUnpinGroup?(
    groupId: string,
    topics: Record<string, unknown>[],
    version?: number,
  ): Promise<unknown>;

  bizAccount?(uid?: string): Promise<unknown>;
  catalogList?(opts?: {
    versionListCatalog?: number;
    limit?: number;
    lastProductId?: number;
    page?: number;
  }): Promise<unknown>;
  createCatalog?(catalogName: string, catalogPhoto?: string): Promise<unknown>;
  updateCatalog?(opts: {
    catalogId: string;
    catalogName: string;
    catalogPhoto?: string;
  }): Promise<unknown>;
  deleteCatalog?(catalogId: string): Promise<void>;
  registerCatalog?(enable: boolean): Promise<unknown>;
  productCatalogList?(opts: {
    catalogId: string;
    limit?: number;
    versionCatalog?: number;
    lastProductId?: number;
    page?: number;
  }): Promise<unknown>;
  createProductCatalog?(opts: {
    catalogId: string;
    productName: string;
    price: string | number;
    description: string;
    productPhotos?: string[];
    currencyUnit?: string;
  }): Promise<unknown>;
  updateProductCatalog?(opts: {
    catalogId: string;
    productId: string;
    productName: string;
    price: string | number;
    description: string;
    productPhotos?: string[];
    currencyUnit?: string;
  }): Promise<unknown>;
  deleteProductCatalog?(
    catalogId: string,
    productIds: string[],
  ): Promise<unknown>;
  uploadProductPhoto?(file: OutgoingFile): Promise<unknown>;
  autoReplyList?(): Promise<unknown>;
  createAutoReply?(opts: {
    isEnable: boolean;
    content: string;
    startTime: number;
    endTime: number;
    scope: number;
    uids?: string[];
  }): Promise<unknown>;
  updateAutoReply?(opts: {
    id: number;
    isEnable: boolean;
    content: string;
    startTime: number;
    endTime: number;
    scope: number;
    uids?: string[];
  }): Promise<unknown>;
  deleteAutoReply?(id: number): Promise<void>;
  createBankAccount?(opts: {
    binBank: number | string;
    numAccBank: string;
    nameAccBank: string;
  }): Promise<unknown>;
  updateBankAccount?(opts: {
    accountId: string;
    binBank: number | string;
    numAccBank: string;
    nameAccBank: string;
  }): Promise<unknown>;
  deleteBankAccount?(accountId: string, isDefault: boolean): Promise<void>;

  unreadMarks?(): Promise<unknown>;
  scanUrl?(url: string): Promise<unknown>;
  cloudMessages?(opts: {
    groupId: string;
    globalMsgId?: string;
    count?: number;
    msgIds?: string[];
    isOA?: boolean;
    src?: number;
  }): Promise<unknown>;
  preloadLastMessages?(
    threadIdLocalMsgId: Record<string, unknown>,
  ): Promise<unknown>;
  preloadLastSeen?(group?: unknown[], oneone?: unknown[]): Promise<unknown>;
  lastDeliverSeen?(oneone?: unknown[], group?: unknown[]): Promise<unknown>;
  emojiStatusFriends?(): Promise<unknown>;
  emojiStatusConfig?(): Promise<unknown>;

  mediaStoreList?(
    groupId: string,
    mediaType: string,
    opts?: { limit?: number; lastId?: string | number; lastFetchId?: number },
  ): Promise<unknown>;
  mediaStorePreview?(groupId: string, limit?: number): Promise<unknown>;
  mediaStoreRemove?(
    groupId: string,
    mediaType: string,
    mediaId: string | string[],
  ): Promise<unknown>;
  oneOneMediaList?(
    mediaType: string,
    opts?: { limit?: number; lastId?: string | number; lastFetchId?: number },
  ): Promise<unknown>;
  oneOneMediaPreview?(limit?: number): Promise<unknown>;
  oneOneMediaRemove?(
    mediaType: string,
    mediaId: string | string[],
  ): Promise<unknown>;
  cloudViewerKey?(): Promise<unknown>;
  familyViewerKey?(): Promise<unknown>;
  recentSearch?(version?: number): Promise<unknown>;
  updateRecentSearch?(
    listRecent: unknown[],
    version: number,
    listKeyword?: string[],
  ): Promise<unknown>;
  encryptGroupId?(noiseUids: string[]): Promise<unknown>;
  decryptGroupId?(globalUids: string[]): Promise<unknown>;
  extrasCommand?(
    command: string,
    payload?: Record<string, unknown>,
  ): Promise<unknown>;
  e2eeCommand?(
    command: string,
    payload?: Record<string, unknown>,
  ): Promise<unknown>;
}

export type ZaloExtendedGateway = Required<
  Pick<
    ZaloGateway,
    | "createGroup"
    | "renameGroup"
    | "changeGroupAvatar"
    | "addGroupMembers"
    | "inviteUserToGroups"
    | "removeGroupMembers"
    | "leaveGroup"
    | "disperseGroup"
    | "changeGroupOwner"
    | "addGroupDeputy"
    | "removeGroupDeputy"
    | "updateGroupSettings"
    | "pendingGroupMembers"
    | "reviewPendingGroupMembers"
    | "blockedGroupMembers"
    | "addBlockedGroupMembers"
    | "removeBlockedGroupMembers"
    | "groupLinkDetail"
    | "enableGroupLink"
    | "disableGroupLink"
    | "groupLinkInfo"
    | "joinGroupLink"
    | "groupInviteBoxList"
    | "groupInviteBoxInfo"
    | "joinGroupInviteBox"
    | "deleteGroupInviteBox"
    | "upgradeGroupToCommunity"
    | "relatedFriendGroups"
    | "fetchAccountInfo"
    | "updateProfile"
    | "updateProfileBio"
    | "changeAccountAvatar"
    | "avatarList"
    | "reuseAvatar"
    | "deleteAvatar"
    | "zaloSettings"
    | "updateZaloSetting"
    | "updateActiveStatus"
    | "updateLang"
    | "lostFocus"
    | "setCloseFriend"
    | "findUsersByPhones"
    | "blockList"
    | "blockViewFeed"
    | "userQr"
    | "removeNote"
    | "reminderDetail"
    | "reminderResponses"
    | "reorderPins"
    | "multiUnpinGroup"
    | "bizAccount"
    | "catalogList"
    | "createCatalog"
    | "updateCatalog"
    | "deleteCatalog"
    | "registerCatalog"
    | "productCatalogList"
    | "createProductCatalog"
    | "updateProductCatalog"
    | "deleteProductCatalog"
    | "uploadProductPhoto"
    | "autoReplyList"
    | "createAutoReply"
    | "updateAutoReply"
    | "deleteAutoReply"
    | "createBankAccount"
    | "updateBankAccount"
    | "deleteBankAccount"
    | "unreadMarks"
    | "scanUrl"
    | "cloudMessages"
    | "preloadLastMessages"
    | "preloadLastSeen"
    | "lastDeliverSeen"
    | "emojiStatusFriends"
    | "emojiStatusConfig"
    | "mediaStoreList"
    | "mediaStorePreview"
    | "mediaStoreRemove"
    | "oneOneMediaList"
    | "oneOneMediaPreview"
    | "oneOneMediaRemove"
    | "cloudViewerKey"
    | "familyViewerKey"
    | "recentSearch"
    | "updateRecentSearch"
    | "encryptGroupId"
    | "decryptGroupId"
    | "extrasCommand"
    | "e2eeCommand"
  >
>;

export type LoginQrCallbacks = {
  onQr(pngBytes: Uint8Array): void;
  onScanned(info: { displayName: string; avatarUrl: string }): void;
};

export interface GatewayFactory {
  fromCredentials(creds: Credentials, self: GatewaySelf): ZaloGateway;
  // kind "oa": Official Account gateway over the OpenAPI.
  fromOaCredentials?(
    creds: OaCredentials,
    self: GatewaySelf,
    hooks: OaHooks,
  ): ZaloGateway;
  loginQr(
    callbacks: LoginQrCallbacks,
  ): Promise<{ credentials: Credentials; self: GatewaySelf } | null>;
}
