// Official Account gateway over the Zalo OA OpenAPI (docs.zaloplatforms.com).
// Plain fetch, no SDK: the OA API is unencrypted JSON with an access_token header.
//
// Receive is by polling listrecentchat/conversation because zalos has no
// public webhook endpoint. Sends go to /v3.0/oa/message/cs. Token refresh
// is single-flight and the rotated pair is persisted via onCredentials
// BEFORE it is used - refresh tokens are single use.

import { EventEmitter } from "node:events";
import { RpcError } from "../tunnel/rpc.ts";
import type {
  AccountStatus,
  ArchivedChatList,
  Attachment,
  AutoDeleteChat,
  Contact,
  ConversationRef,
  ConversationSyncState,
  FriendPresence,
  FriendRecommendation,
  FriendRequestStatus,
  GatewayEvents,
  GatewaySelf,
  GroupInfo,
  HiddenConversations,
  Label,
  LabelsState,
  LastSeen,
  LinkedDevices,
  Message,
  OaCredentials,
  OaHooks,
  OutgoingFile,
  ReceivedFriendRequest,
  SentFriendRequest,
  StickerRef,
  ThreadType,
  UserInfo,
  UserProfile,
  ZaloGateway,
} from "./types.js";

const OPENAPI = "https://openapi.zalo.me";
const OAUTH = "https://oauth.zaloapp.com";
// Read at call time so tests can override before the first poll.
const pollActiveMs = () => Number(process.env.ZALOS_OA_POLL_MS) || 5_000;
const pollIdleMs = () => Number(process.env.ZALOS_OA_POLL_IDLE_MS) || 30_000;
const POLL_MAX_BACKOFF_MS = 120_000;
const REFRESH_AHEAD_MS = 10 * 60 * 1000;
const TEXT_LIMIT = 2000;

// OA error codes -> wire codes the client can localize.
function oaError(code: number, message: string): RpcError {
  switch (code) {
    case -230:
    case -232:
      return new RpcError(
        "window_expired",
        "the user has not interacted within the allowed window",
      );
    case -211:
      return new RpcError("quota_exceeded", "OA message quota exceeded");
    case -32:
      return new RpcError("rate_limited", "OA API rate limit");
    case -100:
      return new RpcError("bad_request", "attachment id expired");
    case -216:
    case -220:
      return new RpcError("auth", "OA access token invalid or expired");
    default:
      return new RpcError("error", `OA error ${code}: ${message}`);
  }
}

function unsupported(feature: string): never {
  throw new RpcError(
    "not_supported",
    `${feature} is not supported for Official Accounts`,
  );
}

type OaInboxItem = {
  message_id: string;
  user_id: string;
  display_name?: string;
  type?: string;
  text?: string;
  url?: string;
  thumb?: string;
  file_name?: string;
  time?: number | string;
  src?: number;
};

export class OaGateway implements ZaloGateway {
  readonly self: GatewaySelf;
  private emitter = new EventEmitter();
  private statusValue: AccountStatus = "starting";
  private creds: OaCredentials;
  private hooks: OaHooks;
  private fetchImpl: typeof fetch;
  private stopped = false;
  private pollTimer: ReturnType<typeof setTimeout> | null = null;
  private pollBackoffMs = 0;
  private refreshInFlight: Promise<string | null> | null = null;
  private seen = new Set<string>();
  private knownThreads = new Set<string>();
  private firstPoll = true;

  constructor(
    creds: OaCredentials,
    self: GatewaySelf,
    hooks: OaHooks,
    fetchImpl?: typeof fetch,
  ) {
    this.creds = { ...creds };
    this.self = self;
    this.hooks = hooks;
    this.fetchImpl = fetchImpl ?? fetch;
  }

  get status(): AccountStatus {
    return this.statusValue;
  }

  on<E extends keyof GatewayEvents>(
    event: E,
    cb: (...args: GatewayEvents[E]) => void,
  ): void {
    this.emitter.on(event, cb as (...a: unknown[]) => void);
  }

  private emit<E extends keyof GatewayEvents>(
    event: E,
    ...args: GatewayEvents[E]
  ) {
    this.emitter.emit(event, ...args);
  }

  private setStatus(s: AccountStatus) {
    if (this.statusValue === s) return;
    this.statusValue = s;
    this.emit("status", s);
  }

  // ---- http ----

  private async api(
    method: string,
    path: string,
    opts: { query?: Record<string, string>; body?: unknown } = {},
    depth = 0,
  ): Promise<unknown> {
    const token = await this.ensureToken();
    const url = new URL(`${OPENAPI}${path}`);
    for (const [k, v] of Object.entries(opts.query ?? {})) {
      url.searchParams.set(k, v);
    }
    // Carry the access token strictly in the header (ASVS 14.2.1): never put
    // session tokens in the URL query string.
    const res = await this.fetchImpl(url.toString(), {
      method,
      headers: {
        access_token: token,
        ...(opts.body !== undefined
          ? { "content-type": "application/json" }
          : {}),
      },
      body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
    });
    const data = (await res.json().catch(() => null)) as {
      error?: number;
      message?: string;
      data?: unknown;
    } | null;
    if (data !== null && typeof data.error === "number" && data.error !== 0) {
      // A token invalidated mid-flight gets one forced refresh + retry.
      if ((data.error === -216 || data.error === -220) && depth === 0) {
        const fresh = await this.refresh(true);
        if (fresh !== null) {
          return await this.api(method, path, opts, depth + 1);
        }
      }
      throw oaError(data.error, data.message ?? "");
    }
    return data?.data ?? data;
  }

  // ---- token manager ----

  private async ensureToken(): Promise<string> {
    const expiresAt = this.creds.accessTokenExpiresAt ?? 0;
    if (Date.now() < expiresAt - REFRESH_AHEAD_MS) {
      return this.creds.accessToken;
    }
    const fresh = await this.refresh();
    if (fresh === null) {
      throw new RpcError("auth", "OA session expired; re-enter tokens");
    }
    return fresh;
  }

  // Single-flight refresh; on invalid refresh token the account goes to
  // needs_login and stays there until updateOaTokens supplies new ones.
  private refresh(force = false): Promise<string | null> {
    if (this.refreshInFlight !== null) return this.refreshInFlight;
    const run = (async () => {
      try {
        const body = new URLSearchParams({
          app_id: this.creds.appId,
          grant_type: "refresh_token",
          refresh_token: this.creds.refreshToken,
        });
        const res = await this.fetchImpl(`${OAUTH}/v4/oa/access_token`, {
          method: "POST",
          headers: {
            secret_key: this.creds.appSecret,
            "content-type": "application/x-www-form-urlencoded",
          },
          body,
        });
        const data = (await res.json().catch(() => null)) as {
          access_token?: string;
          refresh_token?: string;
          expires_in?: string | number;
          error?: number;
          error_name?: string;
        } | null;
        if (
          data === null ||
          typeof data.access_token !== "string" ||
          data.access_token === ""
        ) {
          if (!force) this.setStatus("needs_login");
          return null;
        }
        const next: OaCredentials = {
          ...this.creds,
          accessToken: data.access_token,
          refreshToken: data.refresh_token ?? this.creds.refreshToken,
          accessTokenExpiresAt:
            Date.now() +
            (Number(data.expires_in) || 25 * 3600) * 1000,
        };
        // Persist BEFORE using: the old refresh token is now burned.
        this.hooks.onCredentials(next);
        this.creds = next;
        return next.accessToken;
      } finally {
        this.refreshInFlight = null;
      }
    })();
    this.refreshInFlight = run;
    return run;
  }

  // ---- lifecycle ----

  async start(): Promise<void> {
    this.stopped = false;
    try {
      const oa = (await this.api("GET", "/v3.0/oa/getoa")) as {
        name?: string;
        oa_id?: string;
        avatar?: string;
      };
      if (oa.oa_id !== undefined && oa.oa_id !== this.self.uid) {
        (this.self as { uid: string }).uid = String(oa.oa_id);
      }
      if (oa.name !== undefined && oa.name !== this.self.displayName) {
        (this.self as { displayName: string }).displayName = oa.name;
      }
      if (oa.avatar !== undefined && oa.avatar !== this.self.avatarUrl) {
        (this.self as { avatarUrl: string }).avatarUrl = oa.avatar;
      }
      this.emit("self", this.self);
      this.setStatus("online");
      this.schedulePoll(0);
    } catch (e) {
      if ((e as RpcError).code === "auth") {
        this.setStatus("needs_login");
      } else {
        this.setStatus("reconnecting");
        this.schedulePoll(pollIdleMs());
      }
    }
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.pollTimer !== null) {
      clearTimeout(this.pollTimer);
      this.pollTimer = null;
    }
    this.setStatus("offline");
  }

  oaCredentials(): OaCredentials {
    return { ...this.creds };
  }

  // Called by the account manager after accounts.updateOaTokens.
  setTokens(accessToken: string, refreshToken: string): void {
    this.creds = {
      ...this.creds,
      accessToken,
      refreshToken,
      accessTokenExpiresAt: Date.now() + 25 * 3600 * 1000,
    };
  }

  // ---- polling ----

  private schedulePoll(ms: number) {
    if (this.stopped) return;
    if (this.pollTimer !== null) clearTimeout(this.pollTimer);
    this.pollTimer = setTimeout(() => {
      this.pollTimer = null;
      void this.pollOnce();
    }, ms);
    this.pollTimer.unref?.();
  }

  private nextPollMs(): number {
    if (this.pollBackoffMs > 0) return this.pollBackoffMs;
    return this.hooks.clientConnected() ? pollActiveMs() : pollIdleMs();
  }

  private async pollOnce() {
    if (this.stopped) return;
    try {
      const fresh = await this.fetchRecent();
      const backfillUsers = new Set<string>();
      for (const item of fresh) {
        const uid = String(item.user_id ?? "");
        if (uid !== "" && !this.knownThreads.has(uid)) {
          this.knownThreads.add(uid);
          backfillUsers.add(uid);
        }
      }
      // First sight of a user backfills their conversation, then the new
      // items are emitted live.
      for (const uid of backfillUsers) {
        try {
          const convo = await this.fetchConversation(uid);
          const msgs = convo
            .map((i) => this.toMessage(i, uid))
            .filter((m): m is Message => m !== null);
          if (msgs.length > 0) this.emit("history", msgs);
        } catch {
          // Backfill is best effort; the live items still go out.
        }
      }
      for (const item of fresh) {
        const m = this.toMessage(item, String(item.user_id ?? ""));
        if (m !== null) this.emit("message", m);
      }
      this.pollBackoffMs = 0;
      this.firstPoll = false;
      if (this.statusValue !== "online") this.setStatus("online");
    } catch (e) {
      if ((e as RpcError).code === "auth") {
        this.setStatus("needs_login");
        return;
      }
      this.pollBackoffMs = Math.min(
        this.pollBackoffMs === 0 ? pollActiveMs() : this.pollBackoffMs * 2,
        POLL_MAX_BACKOFF_MS,
      );
      this.setStatus("reconnecting");
    }
    this.schedulePoll(this.nextPollMs());
  }

  // listrecentchat pages newest-first; page until an already-seen id or
  // the first poll's full page. Dedup is by message_id in `seen`.
  private async fetchRecent(): Promise<OaInboxItem[]> {
    const out: OaInboxItem[] = [];
    for (let offset = 0; offset < 200; offset += 10) {
      const data = (await this.api("GET", "/v2.0/oa/listrecentchat", {
        query: { data: JSON.stringify({ offset, count: 10 }) },
      })) as { data?: OaInboxItem[] } | OaInboxItem[];
      const items = Array.isArray(data)
        ? data
        : ((data as { data?: OaInboxItem[] }).data ?? []);
      let hitKnown = false;
      for (const item of items) {
        const id = String(item.message_id ?? "");
        if (id === "") continue;
        if (this.seen.has(id)) {
          hitKnown = true;
          continue;
        }
        this.remember(id);
        out.push(item);
      }
      if (items.length < 10 || hitKnown) break;
    }
    // Emit oldest first so threads order correctly.
    out.sort(
      (a, b) => Number(a.time ?? 0) - Number(b.time ?? 0),
    );
    return out;
  }

  private async fetchConversation(uid: string): Promise<OaInboxItem[]> {
    const data = (await this.api("GET", "/v2.0/oa/conversation", {
      query: {
        data: JSON.stringify({ user_id: uid, offset: 0, count: 10 }),
      },
    })) as { data?: OaInboxItem[] } | OaInboxItem[];
    const items = Array.isArray(data)
      ? data
      : ((data as { data?: OaInboxItem[] }).data ?? []);
    for (const item of items) {
      const id = String(item.message_id ?? "");
      if (id !== "") this.remember(id);
    }
    return items.sort((a, b) => Number(a.time ?? 0) - Number(b.time ?? 0));
  }

  private remember(id: string) {
    this.seen.add(id);
    if (this.seen.size > 5000) {
      const first = this.seen.values().next().value;
      if (first !== undefined) this.seen.delete(first);
    }
  }

  // ---- normalization ----

  private toMessage(item: OaInboxItem, uid: string): Message | null {
    const id = String(item.message_id ?? "");
    if (id === "") return null;
    const isSelf = Number(item.src) === 1;
    const attachments: Attachment[] = [];
    let kind: Message["kind"] = "text";
    let text = item.text;
    switch (item.type ?? "text") {
      case "text":
        kind = "text";
        break;
      case "photo":
      case "image":
        kind = "image";
        attachments.push({ kind: "image", url: String(item.url ?? "") });
        break;
      case "file":
        kind = "file";
        attachments.push({
          kind: "file",
          url: String(item.url ?? ""),
          name: item.file_name,
        });
        break;
      case "sticker":
      case "gif":
        kind = "sticker";
        break;
      case "link":
        kind = "link";
        attachments.push({ kind: "link", url: String(item.url ?? "") });
        break;
      case "audio":
      case "voice":
        kind = "voice";
        attachments.push({ kind: "voice", url: String(item.url ?? "") });
        break;
      case "video":
        kind = "video";
        attachments.push({ kind: "video", url: String(item.url ?? "") });
        break;
      default:
        // location, business_card and anything unmapped show as other.
        kind = "other";
    }
    const sticker =
      kind === "sticker"
        ? { id: 0, cateId: 0, type: 0, url: String(item.url ?? "") }
        : undefined;
    return {
      id,
      cliId: null,
      threadId: uid,
      threadType: "user",
      senderId: isSelf ? this.self.uid : uid,
      senderName: isSelf
        ? this.self.displayName
        : String(item.display_name ?? ""),
      ts: Number(item.time ?? Date.now()),
      isSelf,
      kind,
      ...(text !== undefined ? { text: String(text) } : {}),
      ...(attachments.length > 0 ? { attachments } : {}),
      ...(sticker !== undefined ? { sticker } : {}),
      reactions: {},
      recalled: false,
      raw: item,
    };
  }

  // ---- sends ----

  async sendText(
    threadId: string,
    threadType: ThreadType,
    text: string,
    opts?: { quote?: { raw?: unknown } },
  ): Promise<{ msgId: string; cliId: string }> {
    if (threadType !== "user") unsupported("group threads");
    if (text.length > TEXT_LIMIT) {
      throw new RpcError(
        "bad_request",
        `OA text messages are limited to ${TEXT_LIMIT} characters`,
      );
    }
    const raw = opts?.quote?.raw as { message_id?: unknown } | undefined;
    const data = (await this.api("POST", "/v3.0/oa/message/cs", {
      body: {
        recipient: { user_id: threadId },
        message: {
          text,
          ...(raw?.message_id !== undefined
            ? { quote_message_id: String(raw.message_id) }
            : {}),
        },
      },
    })) as { message_id?: string };
    const msgId = String(data.message_id ?? `oa-${Date.now()}`);
    this.remember(msgId);
    const item: OaInboxItem = {
      message_id: msgId,
      user_id: threadId,
      type: "text",
      text,
      time: Date.now(),
      src: 1,
    };
    const m = this.toMessage(item, threadId);
    if (m !== null) this.emit("message", m);
    return { msgId, cliId: msgId };
  }

  async sendMedia(
    threadId: string,
    threadType: ThreadType,
    kind: "image" | "video" | "file" | "voice",
    file: OutgoingFile,
    caption?: string,
    cliId?: string,
  ): Promise<{ msgId: string; cliId: string }> {
    if (threadType !== "user") unsupported("group threads");
    if (kind !== "image" && kind !== "file") {
      unsupported(`${kind} messages`);
    }
    const token = await this.ensureToken();
    const form = new FormData();
    const blob = await Bun.file(file.path).arrayBuffer();
    form.append(
      "file",
      new Blob([blob], { type: file.contentType ?? "application/octet-stream" }),
      file.name,
    );
    const up = await this.fetchImpl(
      `${OPENAPI}/v2.0/oa/upload/${kind === "image" ? "image" : "file"}`,
      {
        method: "POST",
        headers: { access_token: token },
        body: form,
      },
    );
    const upData = (await up.json().catch(() => null)) as {
      error?: number;
      message?: string;
      data?: { attachment_id?: string; url?: string };
    } | null;
    if (
      upData === null ||
      (typeof upData.error === "number" && upData.error !== 0)
    ) {
      throw oaError(upData?.error ?? -1, upData?.message ?? "upload failed");
    }
    const attachmentId =
      upData.data?.attachment_id ?? upData.data?.url ?? "";
    if (attachmentId === "") {
      throw new RpcError("error", "OA upload returned no attachment id");
    }
    const data = (await this.api("POST", "/v3.0/oa/message/cs", {
      body: {
        recipient: { user_id: threadId },
        message: {
          attachment: {
            type: "template",
            payload: {
              template_type: "media",
              elements: [
                {
                  media_type: kind === "image" ? "image" : "file",
                  attachment_id: attachmentId,
                  ...(caption !== undefined && caption !== ""
                    ? { name: caption }
                    : {}),
                },
              ],
            },
          },
        },
      },
    })) as { message_id?: string };
    const msgId = String(data.message_id ?? `oa-${Date.now()}`);
    this.remember(msgId);
    const item: OaInboxItem = {
      message_id: msgId,
      user_id: threadId,
      type: kind,
      url: attachmentId,
      file_name: file.name,
      time: Date.now(),
      src: 1,
    };
    const m = this.toMessage(item, threadId);
    if (m !== null) this.emit("message", m);
    return { msgId, cliId: cliId ?? msgId };
  }

  // ---- social ----

  async listFriends(): Promise<Contact[]> {
    const out: Contact[] = [];
    for (let offset = 0; offset < 500; offset += 50) {
      const data = (await this.api("GET", "/v2.0/oa/getfollowers", {
        query: { data: JSON.stringify({ offset, count: 50 }) },
      })) as { followers?: { user_id: string; display_name?: string; avatar?: string }[] };
      const items = data.followers ?? [];
      for (const f of items) {
        out.push({
          uid: String(f.user_id),
          displayName: String(f.display_name ?? ""),
          avatarUrl: String(f.avatar ?? ""),
        });
      }
      if (items.length < 50) break;
    }
    return out;
  }

  async userInfo(uids: string[]): Promise<UserInfo[]> {
    const out: UserInfo[] = [];
    for (const uid of uids) {
      try {
        const data = (await this.api("GET", "/v3.0/oa/user/detail", {
          query: { data: JSON.stringify({ user_id: uid }) },
        })) as { display_name?: string; avatar?: string; user_gender?: number };
        out.push({
          uid,
          displayName: String(data.display_name ?? ""),
          avatarUrl: String(data.avatar ?? ""),
        });
      } catch {
        out.push({ uid, displayName: "", avatarUrl: "" });
      }
    }
    return out;
  }

  async fetchMedia(url: string): Promise<{ data: Uint8Array; contentType: string }> {
    const res = await this.fetchImpl(url, {
      headers: { access_token: this.creds.accessToken },
    });
    if (!res.ok) throw new RpcError("error", `media fetch ${res.status}`);
    return {
      data: new Uint8Array(await res.arrayBuffer()),
      contentType: res.headers.get("content-type") ?? "application/octet-stream",
    };
  }

  async keepAlive(): Promise<void> {
    // The poll loop itself keeps the session warm.
  }

  async logout(): Promise<void> {
    await this.stop();
  }

  // ---- friends (personal accounts only) ----

  findUserByPhone(): Promise<UserProfile | null> {
    unsupported("contact discovery");
  }

  findUserByUsername(): Promise<UserProfile | null> {
    unsupported("contact discovery");
  }

  friendRequestStatus(): Promise<FriendRequestStatus> {
    unsupported("friend requests");
  }

  sendFriendRequest(): Promise<void> {
    unsupported("friend requests");
  }

  receivedFriendRequests(): Promise<ReceivedFriendRequest[]> {
    unsupported("friend requests");
  }

  sentFriendRequests(): Promise<SentFriendRequest[]> {
    unsupported("friend requests");
  }

  acceptFriendRequest(): Promise<void> {
    unsupported("friend requests");
  }

  rejectFriendRequest(): Promise<void> {
    unsupported("friend requests");
  }

  undoFriendRequest(): Promise<void> {
    unsupported("friend requests");
  }

  friendRecommendations(): Promise<FriendRecommendation[]> {
    unsupported("friend recommendations");
  }

  setFriendAlias(): Promise<void> {
    unsupported("friend alias");
  }

  removeFriendAlias(): Promise<void> {
    unsupported("friend alias");
  }

  removeFriend(): Promise<void> {
    unsupported("unfriend");
  }

  blockUser(): Promise<void> {
    unsupported("block");
  }

  unblockUser(): Promise<void> {
    unsupported("block");
  }

  friendOnlines(): Promise<FriendPresence[]> {
    unsupported("presence");
  }

  lastOnline(): Promise<LastSeen> {
    unsupported("presence");
  }

  sendCard(): Promise<{ msgId: string; cliId: string }> {
    unsupported("contact cards");
  }

  parseLink(): Promise<never> {
    unsupported("link previews");
  }

  sendLink(): Promise<{ msgId: string }> {
    unsupported("link messages");
  }

  sendBankCard(): Promise<{ msgId: string }> {
    unsupported("bank cards");
  }

  bankList(): Promise<never> {
    unsupported("bank accounts");
  }

  bankAccounts(): Promise<never> {
    unsupported("bank accounts");
  }

  quickMessages(): Promise<never> {
    unsupported("quick messages");
  }

  addQuickMessage(): Promise<never> {
    unsupported("quick messages");
  }

  updateQuickMessage(): Promise<never> {
    unsupported("quick messages");
  }

  removeQuickMessages(): Promise<never> {
    unsupported("quick messages");
  }

  sendReport(): Promise<{ reportId: string }> {
    unsupported("report");
  }

  deleteMessageForAll(): Promise<void> {
    unsupported("delete for everyone");
  }

  // ---- capabilities ----

  capabilities(): string[] {
    // OA implements baseline text/image/file sends, quotes, contacts and
    // polling; nothing from the capability enum applies.
    return [];
  }

  listGroups(): Promise<GroupInfo[]> {
    return Promise.reject(
      new RpcError("not_supported", "groups are not supported for OA accounts"),
    );
  }

  groupInfo(_groupId: string): Promise<GroupInfo> {
    return Promise.reject(
      new RpcError("not_supported", "groups are not supported for OA accounts"),
    );
  }

  groupMembersInfo(_uids: string[]): Promise<UserInfo[]> {
    return Promise.reject(
      new RpcError("not_supported", "groups are not supported for OA accounts"),
    );
  }

  sendSticker(): Promise<{ msgId: string; cliId: string }> {
    unsupported("stickers");
  }

  searchStickers(_query: string): Promise<StickerRef[]> {
    return Promise.resolve([]);
  }

  stickerCategory(_cateId: number): Promise<StickerRef[]> {
    return Promise.resolve([]);
  }

  react(): Promise<void> {
    unsupported("reactions");
  }

  recall(): Promise<void> {
    unsupported("recall");
  }

  deleteMessage(): Promise<void> {
    unsupported("delete for me");
  }

  markSeen(): Promise<void> {
    unsupported("mark seen");
  }

  sendTyping(): Promise<void> {
    unsupported("typing");
  }

  setPinned(): Promise<void> {
    unsupported("pin");
  }

  setMuted(): Promise<void> {
    unsupported("mute");
  }

  markUnread(): Promise<void> {
    unsupported("mark unread");
  }

  removeUnreadMark(): Promise<void> {
    unsupported("mark unread");
  }

  deleteConversation(): Promise<void> {
    unsupported("delete conversation");
  }

  forward(): Promise<void> {
    unsupported("forward");
  }

  syncConversationState(): Promise<ConversationSyncState> {
    return Promise.resolve({
      pinned: [],
      muted: [],
      hidden: [],
      archived: [],
      autoDelete: [],
    });
  }

  hiddenConversations(): Promise<HiddenConversations> {
    unsupported("hidden conversations");
  }

  setHiddenConversations(): Promise<void> {
    unsupported("hidden conversations");
  }

  setHiddenPin(): Promise<void> {
    unsupported("hidden pin");
  }

  resetHiddenPin(): Promise<void> {
    unsupported("hidden pin");
  }

  archivedChatList(): Promise<ArchivedChatList> {
    unsupported("archived chats");
  }

  updateArchivedChatList(): Promise<{ needResync: boolean; version: number }> {
    unsupported("archived chats");
  }

  labels(): Promise<LabelsState> {
    unsupported("labels");
  }

  updateLabels(): Promise<LabelsState> {
    unsupported("labels");
  }

  autoDeleteChat(): Promise<AutoDeleteChat> {
    unsupported("auto-delete");
  }

  updateAutoDeleteChat(): Promise<void> {
    unsupported("auto-delete");
  }

  linkedDevices(): Promise<LinkedDevices> {
    unsupported("linked devices");
  }
}
