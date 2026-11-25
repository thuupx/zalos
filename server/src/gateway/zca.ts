// @zalos/zalo-sdk implementation of ZaloGateway; field names follow TMessage /
// TReaction / SendSeenEventMessageParams etc.
import { EventEmitter } from "node:events";
import {
  Zalo,
  AvatarSize,
  BinBankCard,
  ChatTTL,
  CloseReason,
  DestType,
  FriendRecommendationsType,
  LoginQRCallbackEventType,
  MuteAction,
  MuteDuration,
  Reactions,
  ReportReason as ZcaReportReason,
  TextStyle as ZcaTextStyle,
  ThreadType as ZThreadType,
  Urgency as ZcaUrgency,
  ZaloApiError,
  type API,
  type GetAliasListResponse,
  type GetCloseFriendsResponse,
  type GetFriendOnlinesResponse,
  type GetFriendRecommendationsResponse,
  type GetFriendRequestStatusResponse,
  type GetGroupLinkInfoResponse,
  type GetSentFriendRequestResponse,
  type GroupInfo as ZcaGroupInfo,
  type LabelData,
  type LastOnlineResponse,
  type LoginQRCallbackEvent,
  type Message as ZcaEventMessage,
  type Reaction,
  type SeenMessage,
  type DeliveredMessage,
  type SendMessageQuote,
  type SendReportOptions,
  type SendSeenEventMessageParams,
  type TMessage,
  type TQuote,
  type Typing,
  type Undo,
} from "@zalos/zalo-sdk";
import { imageSize } from "image-size";
import {
  createZcaExtendedMethods,
  dispatchExtendedCallSignal,
} from "./zca_extended.ts";
import {
  statSync,
  mkdtempSync,
  linkSync,
  copyFileSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, basename } from "node:path";
import { assertPublicUrl } from "../media.ts";
import { mockGatewayFetch } from "./mock.ts";
import { OaGateway } from "./oa.ts";
import { AUTO_DELETE_TTLS } from "./types.ts";
import type {
  AccountStatus,
  Album,
  ArchivedChatList,
  Attachment,
  AutoDeleteChat,
  AutoDeleteConversation,
  BankAccount,
  BankAccounts,
  BankCard,
  BankInfo,
  BoardItemKind,
  CallLog,
  Contact,
  ContactCard,
  ConversationRef,
  ConversationSyncState,
  Credentials,
  Doodle,
  FriendPresence,
  FriendRecommendation,
  FriendRequestStatus,
  GatewayEvents,
  GatewayFactory,
  GatewaySelf,
  GroupInfo,
  GroupMember,
  HiddenConversations,
  Label,
  LabelsState,
  LastSeen,
  LinkPreview,
  LinkedDeviceCompanion,
  LinkedDevices,
  Location,
  LoginQrCallbacks,
  Message,
  MessageKind,
  Note,
  PinBoardState,
  PinnedTopic,
  PollDetail,
  PollOptionDetail,
  ReminderItem,
  OaCredentials,
  OaHooks,
  Poll,
  PollOption,
  QuickMessage,
  QuickMessageDraft,
  QuickMessageMedia,
  QuickMessages,
  ReceivedFriendRequest,
  Reminder,
  ReportReason,
  SentFriendRequest,
  StickerRef,
  StyleRun,
  ThreadType,
  Todo,
  TodoItem,
  Urgency,
  UserInfo,
  UserProfile,
  ZaloGateway,
} from "./types.ts";
import { RpcError } from "../tunnel/rpc.ts";

const DEFAULT_UA =
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

// fetchMedia buffers the body in memory before it is sealed or cached, so
// it keeps the same 100 MB ceiling media.download() enforces.
const MAX_MEDIA_BYTES = 100 * 1024 * 1024;
const MAX_MEDIA_REDIRECTS = 5;
const MEDIA_REDIRECT_STATUS = new Set([301, 302, 303, 307, 308]);

// Group link info pages the roster; stop paging even if the server keeps
// reporting hasMoreMember so a bad payload cannot loop forever.
const GROUP_LINK_MAX_PAGES = 20;

const zType = (t: ThreadType): ZThreadType =>
  t === "group" ? ZThreadType.Group : ZThreadType.User;
const fromZType = (t: ZThreadType): ThreadType =>
  t === ZThreadType.Group ? "group" : "user";

// Validate the opaque stored `raw` back into TMessage before use.
function asTMessage(raw: unknown): TMessage | undefined {
  if (typeof raw !== "object" || raw === null) return undefined;
  const r = raw as Record<string, unknown>;
  if (typeof r.msgId !== "string" || typeof r.cliMsgId !== "string") {
    return undefined;
  }
  return raw as TMessage;
}

function quoteParam(d: TQuote): Message["quote"] {
  return {
    msgId: String(d.globalMsgId),
    senderId: String(d.ownerId),
    senderName: "",
    text: typeof d.msg === "string" ? d.msg : "",
  };
}

function str(v: unknown): string | undefined {
  return typeof v === "string" && v !== "" ? v : undefined;
}
// Zalo ids are numeric strings, but a few payloads send them as numbers.
function idOf(v: unknown): string | undefined {
  if (typeof v === "string" && v !== "") return v;
  if (typeof v === "number" && Number.isFinite(v)) return String(v);
  return undefined;
}
function num(v: unknown): number | undefined {
  const n = Number(v);
  return Number.isFinite(n) && n !== 0 ? n : undefined;
}
// Unlike num(), keeps 0 (gender, counts, timestamps).
function intOf(v: unknown): number | undefined {
  const n = Number(v);
  return Number.isFinite(n) ? n : undefined;
}
// Zalo returns some flags as 1/0 and others as booleans.
function flagOf(v: unknown): boolean {
  return v === true || intOf(v) === 1;
}
// Coordinates keep 0 and fractional values.
function floatOf(v: unknown): number | undefined {
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? n : undefined;
}
function objectOf(v: unknown): Record<string, unknown> | undefined {
  return v !== null && typeof v === "object" && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : undefined;
}
// Receipt events carry uid arrays; a malformed payload may omit them. A
// listener must never throw on one bad event, so a missing list is empty.
function uidList(v: unknown): string[] {
  return Array.isArray(v) ? v.map(String) : [];
}
// recommInfo arrives as an object on some payloads and as a JSON string on
// others; both shapes are read defensively, a bad string just means none.
function recommInfoOf(v: unknown): Record<string, unknown> | undefined {
  if (typeof v === "string") {
    try {
      return objectOf(JSON.parse(v));
    } catch {
      return undefined;
    }
  }
  return objectOf(v);
}
// chat.sticker carries its fields under detail, which real payloads send as
// an object or as a JSON string. Without detail the content itself holds the
// sticker fields (older shape).
function stickerDetailOf(c: Record<string, unknown>): Record<string, unknown> {
  const raw = c.detail;
  if (typeof raw === "string") {
    try {
      return objectOf(JSON.parse(raw)) ?? c;
    } catch {
      return c;
    }
  }
  return objectOf(raw) ?? c;
}
function canonicalStickerUrl(id: number): string {
  return `https://zalo-api.zadn.vn/api/emoticon/sticker/webpc?eid=${id}&size=130`;
}
function stickerUrlOf(d: Record<string, unknown>): string | undefined {
  return str(d.stickerUrl) ?? str(d.stickerWebpUrl) ?? str(d.uri);
}
function stickerAnimOf(d: Record<string, unknown>): {
  spriteUrl?: string;
  frames?: number;
  durationMs?: number;
  animatedWebp?: boolean;
} {
  const spriteUrl = str(d.stickerSpriteUrl);
  if (spriteUrl === undefined) return {};
  const ext = intOf(d.ext);
  // Zalo STICKER_EXT.WEBP = 2: stickerSpriteUrl is an animated WebP.
  if (ext === 2) {
    return { spriteUrl, animatedWebp: true };
  }
  const frames = intOf(d.totalFrames);
  if (frames !== undefined && frames >= 2 && frames <= 200) {
    const rawMs = intOf(d.duration);
    const durationMs =
      rawMs !== undefined && rawMs > 0
        ? Math.min(Math.max(rawMs, 30), 1000)
        : 200;
    return { spriteUrl, frames, durationMs };
  }
  return {};
}

// zca-js reduces each getFriendOnlines entry to its opaque status string.
// Only these values mean "online"; timestamps, "hidden"/"offline" and
// anything unrecognized must not light an online dot.
const ONLINE_PRESENCE = new Set(["online", "active"]);

const ZCA_URGENCY: Record<Urgency, ZcaUrgency> = {
  default: ZcaUrgency.Default,
  important: ZcaUrgency.Important,
  urgent: ZcaUrgency.Urgent,
};

function zcaStyles(styles: StyleRun[]): {
  start: number;
  len: number;
  st: ZcaTextStyle;
  indentSize?: number;
}[] {
  return styles.map((s) => ({
    start: s.start,
    len: s.len,
    st: s.st as ZcaTextStyle,
    ...(s.indentSize !== undefined ? { indentSize: s.indentSize } : {}),
  }));
}

// getArchivedChatList items are untyped in zca-js. The official PC client
// reads {id, type} with type 1 = group; older payloads use g/u prefixes
// or threadId/isGroup. Unknown entries are skipped, never guessed.
function archivedRefOf(v: unknown): ConversationRef[] {
  if (typeof v === "string") {
    if (v.startsWith("g") && v.length > 1) {
      return [{ threadId: v.slice(1), threadType: "group" }];
    }
    if (v.startsWith("u") && v.length > 1) {
      return [{ threadId: v.slice(1), threadType: "user" }];
    }
    return [];
  }
  if (v === null || typeof v !== "object" || Array.isArray(v)) return [];
  const o = v as Record<string, unknown>;
  const rawId = idOf(o.id) ?? idOf(o.threadId) ?? idOf(o.thread_id);
  if (rawId === undefined) return [];
  let id = rawId;
  let prefixed: ThreadType | null = null;
  if (id.startsWith("g") && id.length > 1) {
    prefixed = "group";
    id = id.slice(1);
  } else if (id.startsWith("u") && id.length > 1) {
    prefixed = "user";
    id = id.slice(1);
  }
  const rawType = o.type ?? o.threadType ?? o.isGroup ?? o.is_group;
  let threadType: ThreadType;
  if (
    rawType === "group" ||
    rawType === 1 ||
    rawType === true ||
    rawType === "1"
  ) {
    threadType = "group";
  } else if (
    rawType === "user" ||
    rawType === 0 ||
    rawType === false ||
    rawType === "0"
  ) {
    threadType = "user";
  } else if (prefixed !== null) {
    threadType = prefixed;
  } else {
    return [];
  }
  return [{ threadId: id, threadType }];
}

function labelOf(v: unknown): Label | null {
  if (v === null || typeof v !== "object" || Array.isArray(v)) return null;
  const o = v as Record<string, unknown>;
  const id = intOf(o.id);
  const text = str(o.text);
  if (id === undefined || text === undefined) return null;
  const conversations = Array.isArray(o.conversations)
    ? o.conversations.filter(
        (c): c is string => typeof c === "string" && c !== "",
      )
    : [];
  return {
    id,
    text,
    textKey: str(o.textKey) ?? "",
    conversations,
    color: str(o.color) ?? "",
    offset: intOf(o.offset) ?? 0,
    emoji: str(o.emoji) ?? "",
    createTime: intOf(o.createTime) ?? 0,
  };
}

function labelDataOf(l: Label): LabelData {
  return {
    id: l.id,
    text: l.text,
    textKey: l.textKey,
    conversations: l.conversations,
    color: l.color,
    offset: l.offset,
    emoji: l.emoji,
    createTime: l.createTime,
  };
}

// getLabels/updateLabels hand back labelData as a JSON string on the wire;
// zca-js parses it, but accept both so a shape change degrades to a clear
// error instead of an empty label set.
function labelsStateOf(res: {
  labelData?: unknown;
  version?: unknown;
  lastUpdateTime?: unknown;
}): LabelsState {
  let raw = res.labelData;
  if (typeof raw === "string") {
    try {
      raw = JSON.parse(raw) as unknown;
    } catch {
      raw = undefined;
    }
  }
  if (!Array.isArray(raw)) {
    throw new RpcError("error", "labels: malformed response");
  }
  return {
    labels: raw.map(labelOf).filter((l): l is Label => l !== null),
    version: intOf(res.version) ?? 0,
    lastUpdateTime: intOf(res.lastUpdateTime) ?? 0,
  };
}

function autoDeleteRefOf(v: unknown): AutoDeleteConversation[] {
  if (v === null || typeof v !== "object" || Array.isArray(v)) return [];
  const o = v as Record<string, unknown>;
  const rawId = idOf(o.destId) ?? idOf(o.threadId) ?? idOf(o.id);
  if (rawId === undefined) return [];
  let threadId = rawId;
  let prefixed: ThreadType | null = null;
  if (threadId.startsWith("g") && threadId.length > 1) {
    prefixed = "group";
    threadId = threadId.slice(1);
  } else if (threadId.startsWith("u") && threadId.length > 1) {
    prefixed = "user";
    threadId = threadId.slice(1);
  }
  const rawType = o.isGroup ?? o.is_group ?? o.threadType ?? o.type;
  const threadType: ThreadType =
    rawType === undefined
      ? (prefixed ?? "user")
      : rawType === "group" ||
          rawType === 1 ||
          rawType === true ||
          rawType === "1" ||
          rawType === "true"
        ? "group"
        : rawType === "user" ||
            rawType === 0 ||
            rawType === false ||
            rawType === "0" ||
            rawType === "false"
          ? "user"
          : (prefixed ?? "user");
  const rawTtl = intOf(o.ttl);
  // A TTL zalos does not support must not drive local deletion: treat it
  // as off rather than guess a different window.
  const ttl =
    rawTtl !== undefined &&
    (AUTO_DELETE_TTLS as readonly number[]).includes(rawTtl)
      ? rawTtl
      : 0;
  const createdAt = intOf(o.createdAt);
  return [
    {
      threadId,
      threadType,
      ttl,
      ...(createdAt !== undefined ? { createdAt } : {}),
    },
  ];
}

// Shape-only description for an unrecognized companion entry: container
// sizes and field names, never values (opaque keys and signatures are
// values).
function shapeSummary(v: unknown): string {
  if (v === null) return "null";
  if (Array.isArray(v)) return `array(${v.length})`;
  if (typeof v === "object") {
    const keys = Object.keys(v as Record<string, unknown>)
      .filter((k) => /^[A-Za-z0-9_.-]{1,32}$/.test(k))
      .slice(0, 8);
    return `object(${keys.join(",") || "empty"})`;
  }
  if (typeof v === "string") return `string(${v.length})`;
  return typeof v;
}

// Companions are untyped in zca-js. Only meaningful known fields are
// exposed; anything else becomes a value-free shape summary.
function companionOf(v: unknown): LinkedDeviceCompanion | null {
  if (v === undefined || v === null) return null;
  if (typeof v !== "object" || Array.isArray(v)) {
    return { summary: shapeSummary(v) };
  }
  const o = v as Record<string, unknown>;
  const inner =
    o.data !== null && typeof o.data === "object" && !Array.isArray(o.data)
      ? (o.data as Record<string, unknown>)
      : undefined;
  const pickString = (...keys: string[]) => {
    for (const k of keys) {
      const s = str(o[k]) ?? (inner !== undefined ? str(inner[k]) : undefined);
      if (s !== undefined) return s;
    }
    return undefined;
  };
  const pickNumber = (...keys: string[]) => {
    for (const k of keys) {
      const n =
        intOf(o[k]) ?? (inner !== undefined ? intOf(inner[k]) : undefined);
      if (n !== undefined) return n;
    }
    return undefined;
  };
  const pickBool = (...keys: string[]) => {
    for (const k of keys) {
      const raw = o[k] ?? (inner !== undefined ? inner[k] : undefined);
      if (raw !== undefined) return flagOf(raw);
    }
    return undefined;
  };
  const id = pickString("id", "deviceId", "device_id");
  const name = pickString(
    "name",
    "deviceName",
    "device_name",
    "clientName",
    "client_name",
  );
  const platform = pickString("platform", "os", "deviceType", "device_type");
  const lastUpdateTs = pickNumber(
    "lastUpdateTs",
    "lastUpdate",
    "lastActive",
    "last_active",
    "timestamp",
    "ts",
    "createdAt",
  );
  const current = pickBool(
    "current",
    "isCurrent",
    "is_current",
    "thisDevice",
    "isThisDevice",
  );
  const out: LinkedDeviceCompanion = {
    ...(id !== undefined ? { id } : {}),
    ...(name !== undefined ? { name } : {}),
    ...(platform !== undefined ? { platform } : {}),
    ...(lastUpdateTs !== undefined ? { lastUpdateTs } : {}),
    ...(current !== undefined ? { current } : {}),
  };
  if (Object.keys(out).length === 0) out.summary = shapeSummary(v);
  return out;
}

// getListDevice returns opaque identity/signature blobs alongside the
// companion list. Only the master id, timestamp and parsed companions
// leave this function; the blobs are never logged or returned.
function linkedDevicesOf(res: unknown): LinkedDevices {
  const r =
    res !== null && typeof res === "object" && !Array.isArray(res)
      ? (res as Record<string, unknown>)
      : {};
  const d =
    r.devices !== null &&
    typeof r.devices === "object" &&
    !Array.isArray(r.devices)
      ? (r.devices as Record<string, unknown>)
      : r;
  const lastUpdateTs = intOf(d.lastUpdateTs);
  const rawCompanions = Array.isArray(d.companions) ? d.companions : [];
  return {
    masterId: idOf(d.masterId) ?? "",
    ...(lastUpdateTs !== undefined ? { lastUpdateTs } : {}),
    companions: rawCompanions
      .map(companionOf)
      .filter((c): c is LinkedDeviceCompanion => c !== null),
  };
}

// Zalo numeric errors -> RpcError codes. Local zca-js validation errors
// (missing params, encryption) carry no code.
function zaloRpcError(e: unknown, what: string): RpcError {
  if (e instanceof RpcError) return e;
  const code = (e as { code?: number | null }).code;
  const message = e instanceof Error ? e.message : String(e);
  if (code === 216) return new RpcError("auth", "Zalo session expired");
  // Label version conflict: the caller retries with a fresh version.
  if (code === 1005) return new RpcError("conflict", `${what}: ${message}`);
  if (e instanceof ZaloApiError && (code === null || code === undefined)) {
    // zca-js local validation/encryption failure, before any request.
    return new RpcError("bad_request", message);
  }
  return new RpcError(
    "error",
    `${what}: ${message}${code === null || code === undefined ? "" : ` (${code})`}`,
  );
}

// UserBasic as returned by findUser/findUserByUsername. Field names follow
// zca-js models/User.d.ts (snake_case); a wrapped {data} shape is accepted
// because findByUsername's exact response wrapping is unverified.
function userProfileOf(v: unknown): UserProfile | null {
  if (v === null || typeof v !== "object") return null;
  const o = v as Record<string, unknown>;
  if (idOf(o.uid) === undefined && o.data !== undefined) {
    return userProfileOf(o.data);
  }
  const uid = idOf(o.uid);
  if (uid === undefined) return null;
  const zaloName = str(o.zalo_name) ?? str(o.zaloName);
  const gender = intOf(o.gender);
  const phoneNumber = str(o.phoneNumber);
  return {
    uid,
    displayName:
      str(o.display_name) ?? str(o.displayName) ?? zaloName ?? "",
    avatarUrl: str(o.avatar) ?? "",
    ...(zaloName !== undefined ? { zaloName } : {}),
    ...(gender === 0 ? { gender: "male" } : gender === 1 ? { gender: "female" } : {}),
    ...(phoneNumber !== undefined ? { phoneNumber } : {}),
  };
}

// chat.recommended is the contact card msgType: title is the name, thumb
// the avatar, description a JSON blob with phone/qrCodeUrl. Content that
// does not parse stays a link, so unknown shapes degrade safely.
function contactCardOf(c: {
  title?: string;
  description?: string;
  thumb?: string;
  href?: string;
  action?: string;
  [k: string]: unknown;
}): ContactCard | null {
  const raw = str(c.description);
  if (raw === undefined) return null;
  let d: Record<string, unknown>;
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (parsed === null || typeof parsed !== "object") return null;
    d = parsed as Record<string, unknown>;
  } catch {
    return null;
  }
  const phone = str(d.phone);
  const qrCodeUrl = str(d.qrCodeUrl);
  if (phone === undefined && qrCodeUrl === undefined) return null;
  const direct = idOf(d.contactUid) ?? idOf(d.uid);
  const link = /(\d{5,})/.exec(str(c.href) ?? str(c.action) ?? "");
  return {
    uid: direct ?? link?.[1] ?? "",
    displayName: str(c.title) ?? str(d.caption) ?? phone ?? "",
    avatarUrl: str(c.thumb) ?? "",
    ...(phone !== undefined ? { phone } : {}),
    ...(qrCodeUrl !== undefined ? { qrCodeUrl } : {}),
  };
}

// ---- structured inbound payloads ----
// zca-js does not enumerate most of these msgTypes, so each extractor is
// data-driven: it only returns a payload when the identifying fields are
// present. Anything unrecognized stays kind "other" and the raw object is
// still sealed with the record, so no data is dropped.

function bankCardOf(
  c: Record<string, unknown>,
  p: Record<string, unknown>,
): BankCard | null {
  const src = objectOf(p.card) ?? objectOf(c.card) ?? p;
  const bin = intOf(src.binBank ?? src.bin ?? c.binBank ?? c.bin);
  const accountNumber = str(
    src.numAccBank ??
      src.bankNumber ??
      src.accountNumber ??
      c.numAccBank ??
      c.accountNumber,
  );
  if (bin === undefined || bin <= 0 || accountNumber === undefined) {
    return null;
  }
  const holderName = str(
    src.nameAccBank ?? src.holderName ?? src.holder_name ?? c.nameAccBank,
  );
  const bankName = str(src.bankName ?? src.bank_name ?? c.bankName);
  const bankLogo = str(src.bankLogo ?? src.bank_logo ?? c.bankLogo);
  return {
    bin,
    accountNumber,
    ...(holderName !== undefined ? { holderName } : {}),
    ...(bankName !== undefined ? { bankName } : {}),
    ...(bankLogo !== undefined ? { bankLogo } : {}),
  };
}

function locationOf(
  c: Record<string, unknown>,
  p: Record<string, unknown>,
): Location | null {
  const src = objectOf(p.location) ?? objectOf(c.location) ?? p;
  const lat = floatOf(src.lat ?? src.latitude ?? c.lat ?? c.latitude);
  const lng = floatOf(
    src.lng ?? src.lon ?? src.longitude ?? c.lng ?? c.longitude,
  );
  if (lat === undefined || lng === undefined) return null;
  const name = str(src.name ?? src.title ?? c.title);
  const address = str(src.address ?? src.description ?? c.description);
  const thumbUrl = str(src.thumb ?? src.thumbUrl ?? c.thumb);
  return {
    lat,
    lng,
    ...(name !== undefined ? { name } : {}),
    ...(address !== undefined ? { address } : {}),
    ...(thumbUrl !== undefined ? { thumbUrl } : {}),
  };
}

function pollOf(
  c: Record<string, unknown>,
  p: Record<string, unknown>,
): Poll | null {
  const src = objectOf(p.poll) ?? objectOf(c.poll) ?? p;
  const question = str(src.question ?? c.question ?? c.title);
  const rawOptions = src.options ?? src.answers ?? c.options;
  if (question === undefined || !Array.isArray(rawOptions)) return null;
  const options: PollOption[] = [];
  rawOptions.forEach((o, i) => {
    if (typeof o === "string" && o !== "") {
      options.push({ id: i, text: o });
      return;
    }
    const r = objectOf(o);
    if (r === undefined) return;
    const text = str(r.content ?? r.text ?? r.title);
    if (text === undefined) return;
    const votes = intOf(r.votes);
    options.push({
      id: intOf(r.option_id ?? r.id) ?? i,
      text,
      ...(votes !== undefined ? { votes } : {}),
      ...(r.voted !== undefined ? { voted: flagOf(r.voted) } : {}),
    });
  });
  if (options.length === 0) return null;
  const id = intOf(src.poll_id ?? src.pollId ?? c.pollId);
  const totalVotes = intOf(src.num_vote ?? src.totalVotes);
  const expiredAt = intOf(src.expired_time ?? src.expiredTime);
  return {
    question,
    options,
    ...(id !== undefined ? { id } : {}),
    ...(src.allow_multi_choices !== undefined
      ? { multiple: flagOf(src.allow_multi_choices) }
      : {}),
    ...(src.closed !== undefined ? { closed: flagOf(src.closed) } : {}),
    ...(src.is_anonymous !== undefined
      ? { anonymous: flagOf(src.is_anonymous) }
      : {}),
    ...(totalVotes !== undefined ? { totalVotes } : {}),
    ...(expiredAt !== undefined ? { expiredAt } : {}),
  };
}

function noteOf(
  c: Record<string, unknown>,
  p: Record<string, unknown>,
): Note | null {
  const src = objectOf(p.note) ?? objectOf(c.note) ?? p;
  const title = str(src.title ?? c.title);
  if (title === undefined) return null;
  const id = idOf(src.noteId ?? src.id ?? c.noteId);
  const text = str(src.extra ?? src.text ?? src.content);
  return {
    title,
    ...(id !== undefined ? { id } : {}),
    ...(text !== undefined ? { text } : {}),
    ...(src.pinAct !== undefined ? { pinned: flagOf(src.pinAct) } : {}),
  };
}

function reminderOf(
  c: Record<string, unknown>,
  p: Record<string, unknown>,
): Reminder | null {
  const src = objectOf(p.reminder) ?? objectOf(c.reminder) ?? p;
  const title = str(
    src.title ?? objectOf(src.params)?.title ?? c.title ?? c.description,
  );
  if (title === undefined) return null;
  const id = idOf(src.reminderId ?? src.id ?? c.reminderId);
  const startTime = intOf(src.startTime ?? src.start_time);
  const repeat = intOf(src.repeat);
  const emoji = str(src.emoji);
  return {
    title,
    ...(id !== undefined ? { id } : {}),
    ...(startTime !== undefined ? { startTime } : {}),
    ...(repeat !== undefined ? { repeat } : {}),
    ...(emoji !== undefined ? { emoji } : {}),
  };
}

function callLogOf(
  c: Record<string, unknown>,
  p: Record<string, unknown>,
): CallLog | null {
  const src = objectOf(p.call) ?? objectOf(c.call) ?? p;
  const rawType = str(src.callType ?? c.callType);
  const state = str(src.callStatus ?? src.state ?? c.callStatus);
  const duration = intOf(
    src.duration ?? src.callDuration ?? src.durationMs ?? c.duration,
  );
  if (rawType === undefined && state === undefined && duration === undefined) {
    return null;
  }
  const t = (rawType ?? "").toLowerCase();
  const callType =
    t.includes("video")
      ? "video"
      : t.includes("voice") || t.includes("audio")
        ? "voice"
        : "unknown";
  const missed =
    src.missed !== undefined
      ? flagOf(src.missed)
      : state !== undefined
        ? /miss|declin|no_?answer/i.test(state)
        : undefined;
  return {
    callType,
    ...(duration !== undefined ? { durationMs: duration } : {}),
    ...(missed !== undefined ? { missed } : {}),
    ...(state !== undefined ? { state } : {}),
  };
}

function doodleOf(
  c: Record<string, unknown>,
  p: Record<string, unknown>,
): Doodle | null {
  const url =
    str(p.hdUrl) ??
    str(p.normalUrl) ??
    str(p.url) ??
    str(c.href) ??
    str(p.clientUrl);
  if (url === undefined) return null;
  const thumbUrl = str(p.thumbUrl) ?? str(p.thumb) ?? str(c.thumb);
  const width = intOf(p.width);
  const height = intOf(p.height);
  return {
    url,
    ...(thumbUrl !== undefined ? { thumbUrl } : {}),
    ...(width !== undefined ? { width } : {}),
    ...(height !== undefined ? { height } : {}),
  };
}

function albumOf(
  c: Record<string, unknown>,
  p: Record<string, unknown>,
): Album | null {
  const rawItems = Array.isArray(p.items)
    ? p.items
    : Array.isArray(c.items)
      ? c.items
      : undefined;
  if (rawItems === undefined) return null;
  const items: Attachment[] = [];
  for (const it of rawItems) {
    const r = objectOf(it);
    if (r === undefined) continue;
    const url = str(r.hdUrl ?? r.normalUrl ?? r.rawUrl ?? r.url);
    if (url === undefined) continue;
    items.push({
      kind: "image",
      url,
      thumbUrl: str(r.thumbUrl ?? r.previewThumb),
      width: intOf(r.width),
      height: intOf(r.height),
    });
  }
  if (items.length === 0) return null;
  const caption = str(p.msg ?? p.caption ?? c.title);
  return { items, ...(caption !== undefined ? { caption } : {}) };
}

function todoOf(
  c: Record<string, unknown>,
  p: Record<string, unknown>,
): Todo | null {
  const item = objectOf(p.item) ?? objectOf(c.item);
  const src = item ?? objectOf(p.todo) ?? p;
  const title = str(src.content ?? src.title ?? c.title);
  const rawItems = Array.isArray(src.items)
    ? src.items
    : Array.isArray(p.items)
      ? p.items
      : undefined;
  const items: TodoItem[] = [];
  if (rawItems !== undefined) {
    for (const it of rawItems) {
      if (typeof it === "string" && it !== "") {
        items.push({ text: it });
        continue;
      }
      const r = objectOf(it);
      if (r === undefined) continue;
      const text = str(r.text ?? r.content ?? r.title);
      if (text === undefined) continue;
      items.push({
        text,
        ...(r.done !== undefined || r.isDone !== undefined
          ? { done: flagOf(r.done ?? r.isDone) }
          : {}),
      });
    }
  }
  if (items.length === 0 && title !== undefined) {
    items.push({ text: title });
  }
  if (title === undefined && items.length === 0) return null;
  const id = idOf(src.todoId ?? src.id ?? p.todoId ?? c.todoId);
  const done = src.done ?? src.isDone;
  return {
    title: title ?? items[0].text,
    items,
    ...(id !== undefined ? { id } : {}),
    ...(done !== undefined ? { done: flagOf(done) } : {}),
  };
}

// parseLink's data is untyped in zca-js; keep only fields the composer
// renders and preserve the thumbnail url for the media proxy.
function linkPreviewOf(res: unknown): LinkPreview {
  const r = objectOf(res) ?? {};
  const data = objectOf(r.data) ?? r;
  const media = objectOf(data.media);
  const thumbUrl = str(data.thumb);
  const href = str(data.href) ?? "";
  return {
    title: str(data.title) ?? href,
    description: str(data.desc) ?? str(data.description) ?? "",
    srcUrl: str(data.src) ?? href,
    href,
    ...(thumbUrl !== undefined ? { thumbUrl } : {}),
    ...(intOf(media?.type) !== undefined
      ? { mediaType: intOf(media?.type) }
      : {}),
    ...(intOf(media?.count) !== undefined
      ? { mediaCount: intOf(media?.count) }
      : {}),
    ...(str(media?.mediaTitle) !== undefined
      ? { mediaTitle: str(media?.mediaTitle) }
      : {}),
    ...(str(media?.artist) !== undefined
      ? { mediaArtist: str(media?.artist) }
      : {}),
    ...(str(media?.streamUrl) !== undefined
      ? { streamUrl: str(media?.streamUrl) }
      : {}),
  };
}

function bankInfoOf(v: unknown): BankInfo | null {
  const o = objectOf(v);
  if (o === undefined) return null;
  const bin = intOf(o.bin);
  const name = str(o.name);
  if (bin === undefined || bin <= 0 || name === undefined) return null;
  return {
    bin,
    logo: str(o.logo) ?? "",
    name,
    nameEn: str(o.name_eng ?? o.nameEn) ?? "",
    shortName: str(o.short_name ?? o.shortName) ?? "",
    searchKeyword: str(o.search_key_word ?? o.searchKeyword) ?? "",
  };
}

function bankAccountOf(v: unknown): BankAccount | null {
  const o = objectOf(v);
  if (o === undefined) return null;
  const id = idOf(o.id);
  const bin = intOf(o.bin);
  const accountNumber = str(o.bank_number ?? o.bankNumber ?? o.accountNumber);
  if (id === undefined || bin === undefined || accountNumber === undefined) {
    return null;
  }
  const accountId = intOf(o.account_id ?? o.accountId) ?? 0;
  return {
    id,
    bin,
    accountNumber,
    holderName: str(o.holder_name ?? o.holderName) ?? "",
    isDefault: flagOf(o.is_default ?? o.default),
    accountId,
    ...(str(o.bank_name ?? o.bankName) !== undefined
      ? { bankName: str(o.bank_name ?? o.bankName) }
      : {}),
    ...(str(o.bank_logo ?? o.bankLogo) !== undefined
      ? { bankLogo: str(o.bank_logo ?? o.bankLogo) }
      : {}),
    createdAt: intOf(o.created_at ?? o.createdAt) ?? 0,
    updatedAt: intOf(o.updated_at ?? o.updatedAt) ?? 0,
  };
}

function quickMessageMediaOf(v: unknown): QuickMessageMedia | null {
  const o = objectOf(v);
  if (o === undefined) return null;
  return {
    type: intOf(o.type) ?? 0,
    photoId: intOf(o.photoId ?? o.photo_id) ?? 0,
    title: str(o.title) ?? "",
    width: intOf(o.width) ?? 0,
    height: intOf(o.height) ?? 0,
    previewThumb: str(o.previewThumb) ?? "",
    rawUrl: str(o.rawUrl) ?? "",
    thumbUrl: str(o.thumbUrl) ?? "",
    normalUrl: str(o.normalUrl) ?? "",
    hdUrl: str(o.hdUrl) ?? "",
  };
}

// zca-js's QuickMessage nests the text under message.title and media
// under media.items; flatten it into the composer's flat shape.
function quickMessageOf(v: unknown): QuickMessage | null {
  const o = objectOf(v);
  if (o === undefined) return null;
  const id = intOf(o.id);
  const keyword = str(o.keyword);
  if (id === undefined || keyword === undefined) return null;
  const message = objectOf(o.message);
  const media = objectOf(o.media);
  const rawItems = Array.isArray(media?.items) ? media.items : [];
  return {
    id,
    keyword,
    title: str(message?.title) ?? str(o.title) ?? "",
    type: intOf(o.type) ?? 0,
    createdTime: intOf(o.createdTime ?? o.created_time) ?? 0,
    lastModified: intOf(o.lastModified ?? o.last_modified) ?? 0,
    media: rawItems
      .map(quickMessageMediaOf)
      .filter((m): m is QuickMessageMedia => m !== null),
  };
}

function quickMessagesOf(res: unknown): QuickMessages {
  const r = objectOf(res) ?? {};
  const items = Array.isArray(r.items) ? r.items : [];
  return {
    items: items
      .map(quickMessageOf)
      .filter((m): m is QuickMessage => m !== null),
    version: intOf(r.version) ?? 0,
    cursor: intOf(r.cursor) ?? 0,
  };
}

const REPORT_REASON: Record<
  Exclude<ReportReason, "other">,
  Exclude<ZcaReportReason, ZcaReportReason.Other>
> = {
  sensitive: ZcaReportReason.Sensitive,
  annoy: ZcaReportReason.Annoy,
  fraud: ZcaReportReason.Fraud,
};

// Real accounts often return memberIds empty and only ship a page of
// currentMems; normalize both shapes once so list and info agree. currentMems
// also carries display names/avatars, kept as seeds so a failed profile
// lookup still shows a member.
export function normalizeZcaGroupInfo(
  id: string,
  g: ZcaGroupInfo,
): GroupInfo {
  const explicit = (g.memberIds ?? []).map(String).filter((uid) => uid !== "");
  const currentIds = [
    ...new Set(
      (g.currentMems ?? [])
        .map((m) => idOf(m?.id))
        .filter((uid): uid is string => uid !== undefined),
    ),
  ];
  // Real Zalo getmg-v2 responses often omit memberIds and currentMems on
  // private groups while still shipping member UIDs in memVerList as "uid_0".
  const rawMemVer = (g as { memVerList?: unknown }).memVerList;
  const memVerIds = Array.isArray(rawMemVer)
    ? [
        ...new Set(
          rawMemVer
            .map((entry) => {
              const s = str(entry);
              return s === undefined ? undefined : s.replace(/_0$/, "");
            })
            .filter((uid): uid is string => uid !== undefined && uid !== ""),
        ),
      ]
    : [];
  const memberIds =
    explicit.length > 0
      ? explicit
      : currentIds.length > 0
        ? currentIds
        : memVerIds;
  const ownerId = g.creatorId;
  const adminIds = (g.adminIds ?? []).map(String);
  const roleOf = (uid: string): GroupMember["role"] =>
    uid === ownerId ? "owner" : adminIds.includes(uid) ? "deputy" : "member";
  const known = new Set(memberIds);
  const seeds = new Map<string, GroupMember>();
  for (const m of g.currentMems ?? []) {
    const uid = idOf(m?.id);
    if (uid === undefined || !known.has(uid) || seeds.has(uid)) continue;
    seeds.set(uid, {
      uid,
      displayName: str(m.dName) ?? str(m.zaloName) ?? "",
      avatarUrl: str(m.avatar) ?? str(m.avatar_25) ?? "",
      role: roleOf(uid),
    });
  }
  const total = intOf(g.totalMember);
  return {
    id,
    name: g.name,
    avatarUrl: g.avt,
    memberIds,
    memberCount: total !== undefined && total > 0 ? total : memberIds.length,
    ownerId,
    adminIds,
    ...(seeds.size > 0 ? { members: [...seeds.values()] } : {}),
  };
}

export function normalizeZcaMessage(m: ZcaEventMessage): Message {
  const d: TMessage = m.data;
  const ts = Number(d.ts) || Date.now();
  // Per-message TTL rides on the raw payload; 0 means no self-destruct.
  const ttl = intOf(d.ttl);
  const base = {
    id: String(d.msgId),
    cliId: str(d.cliMsgId) ?? null,
    threadId: m.threadId,
    threadType: fromZType(m.type),
    senderId: String(d.uidFrom),
    senderName: str(d.dName) ?? "",
    ts,
    isSelf: m.isSelf,
    reactions: {},
    recalled: false,
    ...(ttl !== undefined && ttl > 0 ? { ttl, expiresAt: ts + ttl } : {}),
    raw: d,
  } satisfies Omit<Message, "kind"> & { raw: unknown };
  const quote = d.quote !== undefined ? quoteParam(d.quote) : undefined;
  const mentions =
    "mentions" in d && Array.isArray(d.mentions)
      ? d.mentions.map((x) => ({ uid: String(x.uid), pos: x.pos, len: x.len }))
      : undefined;
  const msgType = str(d.msgType) ?? "";
  const type = msgType.toLowerCase();
  const has = (s: string) => type.includes(s);
  const content = d.content;

  if (typeof content === "string") {
    // "webchat" text messages arrive with plain string content.
    return { ...base, kind: "text", text: content, quote, mentions };
  }
  const c = (content ?? {}) as {
    title?: string;
    description?: string;
    href?: string;
    thumb?: string;
    action?: string;
    params?: string;
    detail?: { id?: number; catId?: number; type?: number };
    [k: string]: unknown;
  };
  let params: Record<string, unknown> = {};
  if (typeof c.params === "string") {
    try {
      const parsed = JSON.parse(c.params) as unknown;
      params = objectOf(parsed) ?? {};
    } catch {
      params = {};
    }
  }
  const url =
    str(params.hdUrl) ??
    str(params.clientUrl) ??
    str(params.url) ??
    str(c.href) ??
    "";
  const withMeta = (m2: Partial<Message>): Message => ({
    ...base,
    kind: "other",
    quote,
    mentions,
    ...m2,
  });
  const raw = c as Record<string, unknown>;

  if (msgType === "chat.photo") {
    return withMeta({
      kind: "image",
      attachments: [
        {
          kind: "image",
          url,
          thumbUrl: str(params.thumbUrl) ?? str(params.thumbnail),
          width: num(params.width),
          height: num(params.height),
        },
      ],
    });
  }
  if (msgType === "chat.video.msg") {
    return withMeta({
      kind: "video",
      attachments: [
        {
          kind: "video",
          url,
          thumbUrl: str(params.thumbUrl) ?? str(params.thumb) ?? str(c.thumb),
          durationMs: num(params.duration),
        },
      ],
      text: str(c.title),
    });
  }
  if (msgType === "chat.voice") {
    return withMeta({
      kind: "voice",
      attachments: [{ kind: "voice", url }],
    });
  }
  if (msgType === "share.file" || msgType.startsWith("chat.file")) {
    return withMeta({
      kind: "file",
      attachments: [
        {
          kind: "file",
          url,
          name: str(c.title),
          size: num(params.fileSize),
        },
      ],
    });
  }
  if (msgType === "chat.sticker") {
    const detail = stickerDetailOf(c as Record<string, unknown>);
    return withMeta({
      kind: "sticker",
      sticker: {
        id: intOf(detail.id) ?? 0,
        cateId: intOf(detail.cateId ?? detail.catId) ?? 0,
        type: intOf(detail.type) ?? 0,
        url: stickerUrlOf(detail) ?? (url || undefined),
      },
    });
  }
  // A distinct gif kind lets animated UIs render it inline; the
  // attachment stays an image so the existing media pipeline applies.
  if (msgType === "chat.gif") {
    return withMeta({
      kind: "gif",
      attachments: [
        { kind: "image", url, thumbUrl: str(params.thumbUrl) ?? str(params.thumb) },
      ],
    });
  }
  if (msgType === "chat.doodle" || has("doodle")) {
    const doodle = doodleOf(raw, params);
    if (doodle !== null) {
      return withMeta({ kind: "doodle", doodle, text: "Doodle" });
    }
  }

  // Data-driven kinds: zca-js does not enumerate these msgTypes, so the
  // payload fields decide. The raw object is preserved either way.
  const bank = bankCardOf(raw, params);
  if (bank !== null) {
    return withMeta({
      kind: "bank",
      bankCard: bank,
      text: bank.bankName ?? "Bank card",
    });
  }
  const location = locationOf(raw, params);
  if (location !== null) {
    return withMeta({
      kind: "location",
      location,
      text: location.name ?? location.address ?? "Location",
    });
  }
  if (has("todo") || objectOf(params.item)?.content !== undefined) {
    const todo = todoOf(raw, params);
    if (todo !== null) {
      return withMeta({ kind: "todo", todo, text: todo.title });
    }
  }
  if (has("poll") || params.question !== undefined) {
    const poll = pollOf(raw, params);
    if (poll !== null) {
      return withMeta({ kind: "poll", poll, text: poll.question });
    }
  }
  if (has("note") || params.noteId !== undefined) {
    const note = noteOf(raw, params);
    if (note !== null) {
      return withMeta({ kind: "note", note, text: note.title });
    }
  }
  if (has("reminder") || params.reminderId !== undefined) {
    const reminder = reminderOf(raw, params);
    if (reminder !== null) {
      return withMeta({ kind: "reminder", reminder, text: reminder.title });
    }
  }
  if (has("call") || params.callType !== undefined || params.callStatus !== undefined) {
    const callLog = callLogOf(raw, params);
    if (callLog !== null) {
      const label =
        callLog.callType === "video"
          ? "Video call"
          : callLog.callType === "voice"
            ? "Voice call"
            : "Call";
      return withMeta({
        kind: "call",
        callLog,
        text: callLog.missed === true ? `Missed ${label.toLowerCase()}` : label,
      });
    }
  }
  if (has("album") || params.albumId !== undefined) {
    const album = albumOf(raw, params);
    if (album !== null) {
      return withMeta({
        kind: "album",
        album,
        text: album.caption ?? `${album.items.length} photos`,
      });
    }
  }
  // A structured msgType whose payload did not parse must not be
  // reclassified as a link or system bubble: keep it "other" and leave
  // the raw payload sealed for a future reader.
  if (
    msgType === "chat.doodle" ||
    msgType === "chat.location.new" ||
    msgType === "chat.bankcard" ||
    has("doodle") ||
    has("todo") ||
    has("poll") ||
    has("note") ||
    has("reminder") ||
    has("call") ||
    has("album")
  ) {
    return withMeta({ kind: "other", text: `[${msgType}]` });
  }

  if (msgType === "chat.recommended") {
    const card = contactCardOf(c);
    if (card !== null) {
      return withMeta({ kind: "card", card, text: card.displayName });
    }
  }
  if (
    msgType === "chat.link" ||
    msgType === "chat.recommended" ||
    str(c.href) !== undefined
  ) {
    return withMeta({
      kind: "link",
      text: str(c.title) ?? str(c.description) ?? url,
      attachments: [
        {
          kind: "link",
          url: str(c.href) ?? url,
          thumbUrl: str(c.thumb),
          name: str(c.title),
        },
      ],
    });
  }
  if (
    msgType.startsWith("group.") ||
    msgType.startsWith("friend.") ||
    msgType.includes("system")
  ) {
    return withMeta({ kind: "system", text: str(c.title) ?? msgType });
  }
  return withMeta({ kind: "other", text: `[${msgType || "unknown"}]` });
}

type StickerDetailLookup = {
  getStickersDetail(ids: number[]): Promise<
    {
      id?: unknown;
      stickerUrl?: unknown;
      stickerWebpUrl?: unknown;
      uri?: unknown;
    }[]
  >;
};

// Inbound sticker payloads sometimes omit the renderable url. Fill it from
// the sticker service on a best-effort basis: a failed lookup keeps the
// id-only sticker, so the message is never dropped.
export async function enrichStickerUrl(
  api: StickerDetailLookup,
  m: Message,
): Promise<Message> {
  const sticker = m.sticker;
  if (
    m.kind !== "sticker" ||
    sticker === undefined ||
    sticker.url !== undefined ||
    sticker.id <= 0
  ) {
    return m;
  }
  try {
    const details = await api.getStickersDetail([sticker.id]);
    // Only take the detail that matches the requested id; a mismatched
    // response must not put another sticker's url on this message.
    const d = details.find((x) => intOf(x.id) === sticker.id);
    if (d === undefined) return m;
    const raw = d as Record<string, unknown>;
    const url = stickerUrlOf(raw);
    if (url !== undefined) sticker.url = url;
    const anim = stickerAnimOf(raw);
    if (anim.spriteUrl !== undefined) sticker.spriteUrl = anim.spriteUrl;
    if (anim.frames !== undefined) sticker.frames = anim.frames;
    if (anim.durationMs !== undefined) sticker.durationMs = anim.durationMs;
    if (anim.animatedWebp !== undefined) sticker.animatedWebp = anim.animatedWebp;
  } catch {
    // keep the original sticker
  }
  return m;
}

// Serialize outgoing Zalo calls: one at a time, >= 300 ms apart.
class CallQueue {
  private tail: Promise<unknown> = Promise.resolve();
  private last = 0;
  enqueue<T>(fn: () => Promise<T>): Promise<T> {
    const p = this.tail.then(async () => {
      const wait = 300 - (Date.now() - this.last);
      if (wait > 0) await Bun.sleep(wait);
      this.last = Date.now();
      return fn();
    });
    this.tail = p.catch(() => {});
    return p;
  }
}

function receiptParams(d: TMessage): SendSeenEventMessageParams {
  return {
    msgId: String(d.msgId),
    cliMsgId: String(d.cliMsgId),
    uidFrom: String(d.uidFrom),
    idTo: String(d.idTo),
    msgType: String(d.msgType),
    st: Number(d.st ?? 0),
    at: Number(d.at ?? 0),
    cmd: Number(d.cmd ?? 0),
    ts: d.ts,
  };
}

type StageIo = {
  link: (source: string, target: string) => void;
  copy: (source: string, target: string) => void;
};

const stageIo: StageIo = { link: linkSync, copy: copyFileSync };

// Stage an outgoing upload under its sanitized client-supplied name in a
// unique temp dir. A hard link is the cheap path and keeps the exact
// bytes, but it cannot cross filesystem boundaries: the framer writes
// uploads to a mounted volume while tmpdir() is often tmpfs, so EXDEV
// falls back to a byte copy. Every other error propagates unchanged.
export function stageUploadFile(
  file: { name: string; path: string },
  io: StageIo = stageIo,
): { path: string; dir: string } {
  const dir = mkdtempSync(join(tmpdir(), "zalos-up-"));
  const safe =
    basename(file.name).replace(/[^\w. ()\-\u00C0-\u1EF9]/g, "_") ||
    "file";
  const target = join(dir, safe);
  try {
    io.link(file.path, target);
  } catch (e) {
    if ((e as { code?: string }).code !== "EXDEV") {
      rmSync(dir, { recursive: true, force: true });
      throw e;
    }
    try {
      io.copy(file.path, target);
    } catch (copyErr) {
      rmSync(dir, { recursive: true, force: true });
      throw copyErr;
    }
  }
  return { path: target, dir };
}

export class ZcaGateway implements ZaloGateway {
  status: AccountStatus = "starting";
  readonly self: GatewaySelf;
  private emitter = new EventEmitter();
  private api: API | null = null;
  private queue = new CallQueue();
  private stopped = false;
  private backoffMs = 5000;
  // Guards against two APIs/listeners ever being live at once: a stale
  // connect that finishes after a newer one started must be closed, and a
  // stale listener's close must not detach the live api or double-schedule.
  private connectEpoch = 0;

  // Personal accounts expose the full feature set.
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
  private retryTimer: ReturnType<typeof setTimeout> | null = null;
  private creds: Credentials;
  private factory: (creds: Credentials) => Promise<API>;
  private requestOldOnConnect = true;
  // Serialized cookie jar last handed to the manager; a differing live
  // jar means Zalo rotated a cookie.
  private cookieSnapshot = "";

  private http: typeof fetch;

  constructor(
    creds: Credentials,
    self: GatewaySelf,
    login: (creds: Credentials) => Promise<API>,
    http?: typeof fetch,
  ) {
    this.creds = creds;
    this.self = self;
    this.factory = login;
    this.http = http ?? fetch;
    Object.assign(
      this,
      createZcaExtendedMethods(
        (fn) => this.call(() => fn(this.requireApi())),
        (patch) => {
          if (patch.displayName !== undefined) {
            (this.self as { displayName: string }).displayName =
              patch.displayName;
          }
          if (patch.avatarUrl !== undefined) {
            (this.self as { avatarUrl: string }).avatarUrl = patch.avatarUrl;
          }
          this.emit("self", this.self);
        },
      ),
    );
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
    this.status = s;
    this.emit("status", s);
  }

  async start(): Promise<void> {
    this.stopped = false;
    await this.connect();
  }

  private async resolveSelf(api: API): Promise<void> {
    let changed = false;
    try {
      const uid = api.getOwnId();
      if (uid !== "" && uid !== this.self.uid) {
        (this.self as { uid: string }).uid = uid;
        changed = true;
      }
    } catch {}
    try {
      const info = await api.fetchAccountInfo();
      const p = info.profile as Record<string, unknown>;
      const name =
        (p.displayName as string | undefined) ??
        (p.display_name as string | undefined) ??
        (p.zalo_name as string | undefined);
      const avatar = p.avatar as string | undefined;
      if (name !== undefined && name !== this.self.displayName) {
        (this.self as { displayName: string }).displayName = name;
        changed = true;
      }
      if (avatar !== undefined && avatar !== this.self.avatarUrl) {
        (this.self as { avatarUrl: string }).avatarUrl = avatar;
        changed = true;
      }
    } catch {}
    if (changed) this.emit("self", this.self);
  }

  private async connect(): Promise<void> {
    if (this.stopped) return;
    const epoch = ++this.connectEpoch;
    try {
      const api = await this.factory(this.creds);
      // A newer connect finished first (or we were stopped mid-login):
      // close this api's listener and drop it before it can emit.
      if (this.stopped || epoch !== this.connectEpoch) {
        try {
          api.listener.stop();
        } catch {
          // never bound/opened
        }
        return;
      }
      // Register before the listener opens its socket: the mock (and real
      // Zalo) kicks the previous session the moment the new one connects,
      // and the old listener's close must see it no longer owns this.api.
      // Also kill the previous api's listener here if one is still bound:
      // one account, one live socket, no exceptions.
      const prev = this.api;
      this.api = api;
      if (prev !== null && prev !== api) {
        try {
          prev.listener.stop();
        } catch {
          // already closed
        }
      }
      this.bindListener(api);
      this.backoffMs = 5000;
      this.checkCookies(api);
      this.setStatus("online");
      // Credentials from QR login carry no uid; resolve the real
      // identity every connect so own-sends and the manifest see it.
      void this.resolveSelf(api).catch(() => {});
    } catch (e) {
      this.api = null;
      console.error(`[zca] login failed:`, e);
      this.setStatus("needs_login");
    }
  }

  private scheduleReconnect(ms: number, displaced: boolean) {
    if (this.retryTimer !== null) clearTimeout(this.retryTimer);
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      void this.connect();
    }, ms + Math.floor(Math.random() * ms * 0.2));
    this.setStatus(displaced ? "displaced" : "reconnecting");
  }

  // Best-effort sticker url enrichment for inbound and echoed messages.
  // Detached from the listener so a slow sticker service never blocks later messages.
  private async enrichInboundStickers(
    api: API,
    msgs: Message[],
  ): Promise<void> {
    await Promise.all(
      msgs
        .filter((m) => m.kind === "sticker" && m.sticker?.url === undefined)
        .map((m) => enrichStickerUrl(api, m)),
    );
  }

  private bindListener(api: API) {
    const l = api.listener;
    // listener.start({retryOnClose: false}) is the default: the built-in
    // retry is off, so our own backoff owns reconnect timing entirely.
    l.on("connected", () => {
      this.setStatus("online");
      if (this.requestOldOnConnect) {
        // old_messages/old_reactions are only emitted on request.
        this.requestOldOnConnect = false;
        l.requestOldMessages(ZThreadType.User);
        l.requestOldMessages(ZThreadType.Group);
        l.requestOldReactions(ZThreadType.User);
        l.requestOldReactions(ZThreadType.Group);
      }
    });
    const onDown = (code: CloseReason) => {
      try {
        l.stop();
      } catch {
        // already stopped
      }
      // A newer api replaced this one: its listener owns reconnect now.
      if (this.api !== api) return;
      this.api = null;
      if (this.stopped) return;
      if (
        code === CloseReason.DuplicateConnection ||
        code === CloseReason.KickConnection
      ) {
        // Another web session took over: retry slowly.
        this.scheduleReconnect(
          Number(process.env.ZALOS_ZCA_DISPLACED_MS) || 5 * 60 * 1000,
          true,
        );
      } else {
        const ms = this.backoffMs;
        this.backoffMs = Math.min(this.backoffMs * 2, 5 * 60 * 1000);
        this.scheduleReconnect(ms, false);
      }
    };
    l.on("disconnected", (code, _reason) => onDown(code));
    l.on("closed", (code, _reason) => onDown(code));
    l.on("error", (e) => console.error(`[zca] listener error:`, e));
    l.on("typing", (t: Typing) =>
      this.emit("typing", {
        threadId: t.threadId,
        threadType: fromZType(t.type),
        userId: t.data.uid,
      }),
    );
    l.on("message", (m: ZcaEventMessage) => {
      const msg = normalizeZcaMessage(m);
      // Resolve a missing sticker url before emitting so both inbound and
      // self-listen echoed records keep a renderable url. A failed lookup
      // still emits the id-only sticker.
      if (msg.kind === "sticker" && msg.sticker?.url === undefined) {
        void enrichStickerUrl(api, msg).then(
          (out) => this.emit("message", out),
          () => this.emit("message", msg),
        );
      } else {
        this.emit("message", msg);
      }
      // Best-effort delivered receipt for incoming messages.
      if (!m.isSelf) {
        void this.call(() =>
          api.sendDeliveredEvent(
            false,
            [receiptParams(m.data)],
            m.type,
          ),
        ).catch(() => {});
      }
    });
    l.on("old_messages", (msgs: ZcaEventMessage[]) => {
      const out = msgs.map(normalizeZcaMessage);
      void this.enrichInboundStickers(api, out).then(() =>
        this.emit("history", out),
      );
    });
    l.on("seen_messages", (msgs: SeenMessage[]) => {
      for (const s of msgs) {
        if (s.type === ZThreadType.Group) {
          const d = s.data;
          this.emit("receipt", {
            threadId: s.threadId,
            threadType: "group",
            kind: "seen",
            userIds: uidList(d.seenUids),
            msgId: String(d.msgId),
          });
        } else {
          const d = s.data;
          this.emit("receipt", {
            threadId: s.threadId,
            threadType: "user",
            kind: "seen",
            userIds: [String(d.idTo)],
            msgId: String(d.msgId),
          });
        }
      }
    });
    l.on("delivered_messages", (msgs: DeliveredMessage[]) => {
      for (const s of msgs) {
        const d = s.data;
        const threadType = fromZType(s.type);
        // A user-thread delivered event with seen=1 means the recipient
        // opened the message: that is a seen receipt, not delivered.
        const seen = threadType === "user" && d.seen === 1;
        const seenUids = uidList(d.seenUids);
        const uids =
          seen && seenUids.length > 0 ? seenUids : uidList(d.deliveredUids);
        this.emit("receipt", {
          threadId: s.threadId,
          threadType,
          kind: seen ? "seen" : "delivered",
          // A user thread has no separate recipient id in the event.
          userIds:
            uids.length > 0 ? uids : threadType === "user" ? [s.threadId] : [],
          msgId: String(d.msgId),
        });
      }
    });
    const onReaction = (r: Reaction) => {
      const content = r.data?.content;
      if (content === undefined || content === null) return;
      // The target message ids live in content.rMsg, not data.msgId.
      const target = Array.isArray(content.rMsg) ? content.rMsg[0] : undefined;
      this.emit("reaction", {
        threadId: r.threadId,
        threadType: r.isGroup ? "group" : "user",
        msgId: String(target?.gMsgID ?? r.data.msgId),
        // Reactions.NONE is ""; removal of a reaction.
        icon: String(content.rIcon ?? ""),
        userId: String(r.data.uidFrom),
        isSelf: r.isSelf,
      });
    };
    l.on("reaction", onReaction);
    l.on("old_reactions", (rs: Reaction[]) => {
      for (const r of rs) onReaction(r);
    });
    l.on("undo", (u: Undo) => {
      const c = u.data.content;
      this.emit("recall", {
        threadId: u.threadId,
        threadType: u.isGroup ? "group" : "user",
        msgId: String(c.globalMsgId || u.data.msgId),
        isSelf: u.isSelf,
      });
    });
    l.on("friend_event", (e) => this.emit("friendEvent", e));
    l.on("group_event", (e) => this.emit("groupEvent", e));
    l.on("voip_control", (evt) =>
      this.emit("voip", {
        act: evt.act,
        ts: evt.ts,
        conversationId: evt.conversationId,
        callerId: evt.callerId,
        groupId: evt.groupId,
        inCallStatus: evt.inCallStatus,
        data: evt.data,
      }),
    );
    l.start();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    this.connectEpoch++;
    if (this.retryTimer !== null) {
      clearTimeout(this.retryTimer);
      this.retryTimer = null;
    }
    try {
      this.api?.listener.stop();
    } catch {
      // ignore
    }
    this.api = null;
    this.setStatus("offline");
  }

  private call<T>(
    fn: () => Promise<T>,
    opts?: { sessionExpiry?: "expire" | "ignore" },
  ): Promise<T> {
    return this.queue.enqueue(async () => {
      try {
        return await fn();
      } catch (e) {
        // Zalo session expiry arrives as error_code 216 on any API; the
        // account can only be recovered by logging in again. findUser is
        // the exception: there 216 is also "no such user".
        if (
          (e as { code?: number }).code === 216 &&
          opts?.sessionExpiry !== "ignore"
        ) {
          this.setStatus("needs_login");
        }
        throw e;
      } finally {
        // Any response may carry Set-Cookie; keepAlive makes this run at
        // least every five minutes while online.
        if (this.api !== null) this.checkCookies(this.api);
      }
    });
  }

  // zca-js applies Set-Cookie headers to its jar on every request. Hand a
  // changed jar to the manager in the same serialized form QR login
  // produces (`CookieJar.toJSON().cookies`), which `login` accepts back.
  private checkCookies(api: API) {
    const cookies = api.getCookie().toJSON()?.cookies;
    if (cookies === undefined) return;
    const snapshot = JSON.stringify(cookies);
    if (snapshot === this.cookieSnapshot) return;
    this.cookieSnapshot = snapshot;
    this.creds = { ...this.creds, cookie: cookies };
    this.emit("credentials", this.creds);
  }

  private requireApi(): API {
    if (this.api === null) throw new RpcError("error", "gateway offline");
    return this.api;
  }

  // SendMessageQuote mirrors a subset of TMessage verbatim.
  private quoteOf(raw: unknown): SendMessageQuote | undefined {
    const d = asTMessage(raw);
    if (d === undefined) return undefined;
    return {
      content: d.content,
      msgType: d.msgType,
      propertyExt: d.propertyExt,
      uidFrom: d.uidFrom,
      msgId: d.msgId,
      cliMsgId: d.cliMsgId,
      ts: d.ts,
      ttl: d.ttl,
    };
  }

  sendText(
    threadId: string,
    threadType: ThreadType,
    text: string,
    opts?: {
      quote?: { raw?: unknown };
      mentions?: { uid: string; pos: number; len: number }[];
      styles?: StyleRun[];
      urgency?: Urgency;
      ttl?: number;
    },
  ) {
    const api = this.requireApi();
    return this.call(async () => {
      const res = await api.sendMessage(
        {
          msg: text,
          quote: opts?.quote?.raw !== undefined
            ? this.quoteOf(opts.quote.raw)
            : undefined,
          mentions: opts?.mentions,
          styles: opts?.styles !== undefined && opts.styles.length > 0
            ? zcaStyles(opts.styles)
            : undefined,
          urgency:
            opts?.urgency !== undefined
              ? ZCA_URGENCY[opts.urgency]
              : undefined,
          ttl: opts?.ttl !== undefined && opts.ttl > 0 ? opts.ttl : undefined,
        },
        threadId,
        zType(threadType),
      );
      return {
        msgId: String(res.message?.msgId ?? res.attachment[0]?.msgId ?? ""),
        cliId: "",
      };
    });
  }

  async sendMedia(
    threadId: string,
    threadType: ThreadType,
    kind: "image" | "video" | "file" | "voice" | "gif",
    file: {
      name: string;
      path: string;
      contentType?: string;
      thumbnailUrl?: string;
    },
    caption?: string,
    cliId?: string,
    opts?: { ttl?: number; urgency?: Urgency },
  ) {
    const api = this.requireApi();
    return this.call(async () => {
      // zca-js picks the dedicated gif upload from the staged file's
      // extension, so a gif send must keep a real `.gif` name. A caller
      // that asked for a plain file must stay a file, so its final `.gif`
      // extension is swapped for `.bin`; the caller's original name is
      // left untouched and is what the local message record keeps.
      const isGifName = /\.gif$/i.test(file.name);
      const stagedFile =
        kind === "gif"
          ? { ...file, name: isGifName ? file.name : `${file.name}.gif` }
          : kind === "file" && isGifName
            ? { ...file, name: file.name.replace(/\.gif$/i, ".bin") }
            : file;
      const ttl = opts?.ttl !== undefined && opts.ttl > 0 ? opts.ttl : undefined;
      const urgency =
        opts?.urgency !== undefined
          ? ZCA_URGENCY[opts.urgency]
          : undefined;
      // sendVoice/sendVideo carry ttl only; their payload has no urgency
      // field, so a caller that asks for it is rejected by the RPC layer.
      const staged = stageUploadFile(stagedFile);
      try {
        if (kind === "voice") {
          // sendVoice needs an uploaded fileUrl.
          const up = await api.uploadAttachment(
            staged.path,
            threadId,
            zType(threadType),
          );
          const f = up[0];
          if (f.fileType === "image") {
            throw new RpcError("error", "voice upload returned image type");
          }
          const res = await api.sendVoice(
            {
              voiceUrl: f.fileUrl,
              ...(ttl !== undefined ? { ttl } : {}),
            },
            threadId,
            zType(threadType),
          );
          return { msgId: String(res.msgId ?? ""), cliId: cliId ?? "" };
        }
        if (kind === "video") {
          const up = await api.uploadAttachment(
            staged.path,
            threadId,
            zType(threadType),
          );
          const f = up[0];
          if (f.fileType === "image") {
            throw new RpcError("error", "video upload returned image type");
          }
          const res = await api.sendVideo(
            {
              videoUrl: f.fileUrl,
              // A video url is not a valid thumbnail; an empty thumb is
              // better than a wrong one. Clients may pass a real
              // thumbnail url.
              thumbnailUrl: file.thumbnailUrl ?? "",
              msg: caption,
              ...(ttl !== undefined ? { ttl } : {}),
            },
            threadId,
            zType(threadType),
          );
          return { msgId: String(res.msgId ?? ""), cliId: cliId ?? "" };
        }
        // image, gif and file go through sendMessage attachments by path;
        // zca-js routes a `.gif` name to the dedicated gif upload.
        const res = await api.sendMessage(
          {
            msg: caption ?? "",
            attachments: [staged.path],
            ...(ttl !== undefined ? { ttl } : {}),
            ...(urgency !== undefined ? { urgency } : {}),
          },
          threadId,
          zType(threadType),
        );
        return {
          msgId: String(res.message?.msgId ?? res.attachment[0]?.msgId ?? ""),
          cliId: cliId ?? "",
        };
      } finally {
        rmSync(staged.dir, { recursive: true, force: true });
      }
    });
  }

  sendSticker(threadId: string, threadType: ThreadType, sticker: StickerRef) {
    const api = this.requireApi();
    return this.call(async () => {
      const res = await api.sendSticker(
        { id: sticker.id, cateId: sticker.cateId, type: sticker.type },
        threadId,
        zType(threadType),
      );
      return { msgId: String(res.msgId), cliId: "" };
    });
  }

  // sendCard fetches the target's QR via getQR, then forwards a msgType 6
  // payload through the file host (zca-js sendCard.js). Inbound cards
  // arrive as chat.recommended and are normalized to kind "card".
  sendCard(
    threadId: string,
    threadType: ThreadType,
    card: { userId: string; phoneNumber?: string; ttl?: number },
  ) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        const res = await api.sendCard(
          {
            userId: card.userId,
            ...(card.phoneNumber !== undefined
              ? { phoneNumber: card.phoneNumber }
              : {}),
            ...(card.ttl !== undefined ? { ttl: card.ttl } : {}),
          },
          threadId,
          zType(threadType),
        );
        const msgId = String(res?.msgId ?? "");
        if (msgId === "") {
          throw new RpcError("error", "send card returned no message id");
        }
        return { msgId, cliId: "" };
      } catch (e) {
        throw zaloRpcError(e, "send card");
      }
    });
  }

  parseLink(link: string) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        return linkPreviewOf(await api.parseLink(link));
      } catch (e) {
        throw zaloRpcError(e, "parse link");
      }
    });
  }

  // zca-js parses the link again inside sendLink and only returns a msgId;
  // the manager builds the optimistic bubble from parseLink.
  sendLink(
    threadId: string,
    threadType: ThreadType,
    opts: { link: string; msg?: string; ttl?: number },
  ) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        const res = await api.sendLink(
          {
            link: opts.link,
            ...(opts.msg !== undefined && opts.msg !== ""
              ? { msg: opts.msg }
              : {}),
            ...(opts.ttl !== undefined && opts.ttl > 0
              ? { ttl: opts.ttl }
              : {}),
          },
          threadId,
          zType(threadType),
        );
        const msgId = String(res?.msgId ?? "");
        if (msgId === "") {
          throw new RpcError("error", "send link returned no message id");
        }
        return { msgId };
      } catch (e) {
        throw zaloRpcError(e, "send link");
      }
    });
  }

  // Real Zalo answers sendBankCard with an empty body; the listener echo
  // carries the persisted message. Returning "" keeps that honest.
  sendBankCard(
    threadId: string,
    threadType: ThreadType,
    card: { bin: number; accountNumber: string; holderName?: string },
  ) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        const res = await api.sendBankCard(
          {
            binBank: card.bin as BinBankCard,
            numAccBank: card.accountNumber,
            ...(card.holderName !== undefined && card.holderName !== ""
              ? { nameAccBank: card.holderName }
              : {}),
          },
          threadId,
          zType(threadType),
        );
        // The shipped API answers "", but tolerate a future {msgId} shape.
        const msgId =
          typeof res === "string"
            ? res
            : String((res as { msgId?: unknown } | null)?.msgId ?? "");
        return { msgId };
      } catch (e) {
        throw zaloRpcError(e, "send bank card");
      }
    });
  }

  bankList() {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        const res = (await api.getListBank()) as { banks?: unknown };
        if (!Array.isArray(res?.banks)) {
          throw new RpcError("error", "bank list: malformed response");
        }
        return res.banks
          .map(bankInfoOf)
          .filter((b): b is BankInfo => b !== null);
      } catch (e) {
        throw zaloRpcError(e, "bank list");
      }
    });
  }

  bankAccounts(page: number, limit: number) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        const res = (await api.getListBankAccount(page, limit)) as {
          hasMore?: unknown;
          total?: unknown;
          myBanks?: unknown;
        };
        if (!Array.isArray(res?.myBanks)) {
          throw new RpcError("error", "bank accounts: malformed response");
        }
        return {
          accounts: res.myBanks
            .map(bankAccountOf)
            .filter((a): a is BankAccount => a !== null),
          total: intOf(res.total) ?? 0,
          hasMore: flagOf(res.hasMore),
        };
      } catch (e) {
        throw zaloRpcError(e, "bank accounts");
      }
    });
  }

  quickMessages() {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        return quickMessagesOf(await api.getQuickMessageList());
      } catch (e) {
        throw zaloRpcError(e, "quick messages");
      }
    });
  }

  addQuickMessage(draft: QuickMessageDraft) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        const res = await api.addQuickMessage({
          keyword: draft.keyword,
          title: draft.title,
          ...(draft.media !== undefined ? { media: draft.media.path } : {}),
        });
        const item = quickMessageOf(res?.item);
        if (item === null) {
          throw new RpcError("error", "quick message: malformed response");
        }
        return { item, version: intOf(res?.version) ?? 0 };
      } catch (e) {
        throw zaloRpcError(e, "quick message");
      }
    });
  }

  updateQuickMessage(id: number, draft: QuickMessageDraft) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        let res: { item?: unknown; version?: number };
        let keptMedia: QuickMessageMedia[] | undefined;
        if (draft.media !== undefined) {
          res = await api.updateQuickMessage(
            {
              keyword: draft.keyword,
              title: draft.title,
              media: draft.media.path,
            },
            id,
          );
        } else {
          // A text-only edit must not clear a stored photo, and zca-js
          // cannot carry the existing photoId through its payload. Look up
          // the item and replay its media through the raw update instead.
          const existing = quickMessagesOf(
            await api.getQuickMessageList(),
          ).items.find((i) => i.id === id);
          if (existing !== undefined && existing.media.length > 0) {
            keptMedia = existing.media;
            res = await api.updateQuickMessage(
              {
                keyword: draft.keyword,
                title: draft.title,
                media: existing.media,
              },
              id,
            );
          } else {
            res = await api.updateQuickMessage(
              { keyword: draft.keyword, title: draft.title },
              id,
            );
          }
        }
        const item = quickMessageOf(res?.item);
        if (item === null) {
          throw new RpcError("error", "quick message: malformed response");
        }
        // The update was told to keep the media; never let a sparse
        // response hand the client an item without it.
        if (keptMedia !== undefined && item.media.length === 0) {
          item.media = keptMedia;
          item.type = 1;
        }
        return { item, version: intOf(res?.version) ?? 0 };
      } catch (e) {
        throw zaloRpcError(e, "quick message");
      }
    });
  }

  removeQuickMessages(ids: number[]) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        const res = await api.removeQuickMessage(ids);
        return {
          itemIds: Array.isArray(res?.itemIds)
            ? res.itemIds
                .map((v) => intOf(v))
                .filter((v): v is number => v !== undefined)
            : ids,
          version: intOf(res?.version) ?? 0,
        };
      } catch (e) {
        throw zaloRpcError(e, "quick message");
      }
    });
  }

  sendReport(
    threadId: string,
    threadType: ThreadType,
    opts: { reason: ReportReason; content?: string },
  ) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        // zca-js only sends content for reason Other; the RPC enforces
        // that content is present in exactly that case.
        const options: SendReportOptions = opts.reason === "other"
          ? {
              reason: ZcaReportReason.Other,
              content: opts.content ?? "",
            }
          : { reason: REPORT_REASON[opts.reason] };
        const res = await api.sendReport(
          options,
          threadId,
          zType(threadType),
        );
        return { reportId: String(res?.reportId ?? "") };
      } catch (e) {
        throw zaloRpcError(e, "report");
      }
    });
  }

  // searchSticker returns StickerBasic[] (or {searchData: StickerBasic[]} on
  // some Zalo responses). Zalo rejects an empty keyword, so default browse
  // falls back to a popular keyword and also falls back to getStickers if
  // searchSticker returns empty or fails.
  searchStickers(query: string) {
    const api = this.requireApi();
    return this.call(async () => {
      const q = query.trim() || "hi";
      const extractBasics = (
        raw: unknown,
      ): Array<{ sticker_id: number; cate_id: number; type: number }> => {
        const list = Array.isArray(raw)
          ? raw
          : Array.isArray((raw as { searchData?: unknown } | null)?.searchData)
            ? ((raw as { searchData: unknown[] }).searchData)
            : [];
        const out: Array<{ sticker_id: number; cate_id: number; type: number }> =
          [];
        const seen = new Set<number>();
        for (const item of list) {
          const o = objectOf(item);
          if (o === undefined) continue;
          const sid = intOf(o.sticker_id ?? o.id);
          if (sid === undefined || sid <= 0 || seen.has(sid)) continue;
          seen.add(sid);
          out.push({
            sticker_id: sid,
            cate_id: intOf(o.cate_id ?? o.cateId ?? o.catId) ?? 0,
            type: intOf(o.type) ?? 1,
          });
        }
        return out;
      };
      const toStickerRef = (
        d: Record<string, unknown>,
        fallback?: { sticker_id: number; cate_id: number; type: number },
      ): StickerRef => {
        const id = intOf(d.id) ?? fallback?.sticker_id ?? 0;
        const cateId =
          intOf(d.cateId ?? d.catId) ?? fallback?.cate_id ?? 0;
        const type = intOf(d.type) ?? fallback?.type ?? 1;
        const url =
          stickerUrlOf(d) ?? (id > 0 ? canonicalStickerUrl(id) : undefined);
        return {
          id,
          cateId,
          type,
          ...(url !== undefined ? { url } : {}),
          ...stickerAnimOf(d),
        };
      };

      let basics: Array<{ sticker_id: number; cate_id: number; type: number }> =
        [];
      try {
        basics = extractBasics(await api.searchSticker(q, 32));
      } catch {
        basics = [];
      }
      if (basics.length === 0) {
        try {
          const ids = await api.getStickers(q);
          const details =
            ids.length > 0 ? await api.getStickersDetail(ids.slice(0, 32)) : [];
          return details.map((d) =>
            toStickerRef(d as unknown as Record<string, unknown>),
          );
        } catch {
          // If both endpoints fail on an explicit query, rethrow below via searchSticker.
          basics = extractBasics(await api.searchSticker(q, 32));
        }
      }
      // searchSticker returns ids only; getStickersDetail resolves the
      // urls and animation metadata the client needs to render the picker.
      let details: Array<Record<string, unknown>> = [];
      if (basics.length > 0) {
        try {
          details = (await api.getStickersDetail(
            basics.map((s) => s.sticker_id),
          )) as unknown as Array<Record<string, unknown>>;
        } catch {
          details = [];
        }
      }
      const byId = new Map<number, Record<string, unknown>>();
      for (const d of details) {
        const id = intOf(d.id);
        if (id !== undefined) byId.set(id, d);
      }
      return basics.map((s) => {
        const d = byId.get(s.sticker_id);
        if (d !== undefined) return toStickerRef(d, s);
        return {
          id: s.sticker_id,
          cateId: s.cate_id,
          type: s.type,
          url: canonicalStickerUrl(s.sticker_id),
        };
      });
    });
  }

  // Loads all stickers in a single Zalo sticker pack by category id.
  stickerCategory(cateId: number) {
    const api = this.requireApi();
    return this.call(async () => {
      if (!Number.isInteger(cateId) || cateId <= 0) return [];
      const raw = await api.getStickerCategoryDetail(cateId);
      const list = Array.isArray(raw) ? raw : [];
      const out: StickerRef[] = [];
      const seen = new Set<number>();
      for (const item of list) {
        const d = objectOf(item);
        if (d === undefined) continue;
        const id = intOf(d.id);
        if (id === undefined || id <= 0 || seen.has(id)) continue;
        seen.add(id);
        const url = stickerUrlOf(d) ?? canonicalStickerUrl(id);
        out.push({
          id,
          cateId: intOf(d.cateId ?? d.catId) ?? cateId,
          type: intOf(d.type) ?? 1,
          url,
          ...stickerAnimOf(d),
        });
      }
      return out;
    });
  }

  // ---- Zalo Board, Pin Message, Polls, Notes & Reminders ----
  private requireBoard(api: API) {
    if (!api.board) {
      throw new RpcError("not_supported", "board API unavailable");
    }
    return api.board;
  }

  private cliMsgTypeOf(kind: MessageKind): number {
    switch (kind) {
      case "voice":
        return 31;
      case "image":
      case "album":
        return 32;
      case "sticker":
        return 36;
      case "doodle":
        return 37;
      case "card":
      case "link":
        return 38;
      case "location":
        return 43;
      case "video":
        return 44;
      case "file":
        return 46;
      case "gif":
        return 49;
      default:
        return 1; // CLI_MSG_TYPE_TEXT
    }
  }

  private normalizePinnedTopic(
    raw: unknown,
    defaultPinned = true,
  ): PinnedTopic | null {
    const o = objectOf(raw);
    if (o === undefined) return null;
    // Group board items can be wrapped as { boardType, data: { ... } }
    const inner = objectOf(o.data) ?? o;
    const boardType = intOf(o.boardType);
    let rawParams = inner.params;
    if (typeof rawParams === "string") {
      try {
        rawParams = JSON.parse(rawParams);
      } catch {
        rawParams = undefined;
      }
    }
    const p = objectOf(rawParams) ?? {};
    const rawType =
      intOf(inner.type ?? inner.topicType ?? o.type) ??
      (boardType === 3
        ? 3
        : boardType === 2
          ? 2
          : boardType === 1
            ? 0
            : 2);
    const startTime = intOf(inner.startTime ?? inner.start_time) ?? -1;
    let kind: BoardItemKind;
    let topicType = rawType;
    if (rawType === 3 || inner.poll_id !== undefined || inner.pollId !== undefined) {
      kind = "poll";
      topicType = 3;
    } else if (rawType === 4 || (rawType === 0 && startTime > 0)) {
      kind = "reminder";
      topicType = rawType === 4 ? 4 : 0;
    } else if (rawType === 2) {
      kind = "message";
    } else if (rawType === 1) {
      kind = "link";
    } else {
      kind = "note";
    }
    const pollId = intOf(inner.poll_id ?? inner.pollId ?? p.poll_id);
    const id =
      idOf(inner.id ?? inner.topicId ?? inner.poll_id ?? inner.pollId ?? o.id) ??
      (pollId !== undefined ? String(pollId) : undefined);
    if (id === undefined) return null;
    const title =
      str(inner.question) ??
      str(p.question) ??
      str(p.linkCaption) ??
      str(p.title) ??
      str(inner.title) ??
      str(p.text) ??
      str(p.msg) ??
      str(p.message) ??
      str(p.content) ??
      "";
    const msgId = idOf(p.global_msg_id ?? p.msgId ?? inner.globalMsgId);
    const cliMsgId = idOf(p.client_msg_id ?? p.cliMsgId ?? inner.cliMsgId);
    const senderId = idOf(
      p.senderUid ?? p.senderId ?? inner.creatorId ?? inner.creator,
    );
    const senderName = str(p.senderName ?? inner.creatorName);
    const thumbUrl = str(p.thumb ?? p.thumbUrl);
    const createdAt = intOf(
      inner.createTime ?? inner.created_time ?? inner.createdTime,
    );
    return {
      id,
      topicType,
      kind,
      title,
      ...(senderId !== undefined ? { senderId } : {}),
      ...(senderName !== undefined ? { senderName } : {}),
      ...(msgId !== undefined ? { msgId } : {}),
      ...(cliMsgId !== undefined ? { cliMsgId } : {}),
      ...(pollId !== undefined ? { pollId } : {}),
      ...(thumbUrl !== undefined ? { thumbUrl } : {}),
      ...(createdAt !== undefined ? { createdAt } : {}),
      pinned: defaultPinned,
    };
  }

  private normalizePollDetail(raw: unknown, groupId = ""): PollDetail {
    const o = objectOf(raw) ?? {};
    const me = this.self.uid;
    const rawOpts = Array.isArray(o.options) ? o.options : [];
    const options: PollOptionDetail[] = [];
    const voterSet = new Set<string>();
    for (const item of rawOpts) {
      const opt = objectOf(item);
      if (opt === undefined) continue;
      const oid = intOf(opt.option_id ?? opt.optionId ?? opt.id);
      if (oid === undefined) continue;
      const voters = Array.isArray(opt.voters)
        ? opt.voters.map(String).filter((u) => u.length > 0)
        : [];
      for (const u of voters) voterSet.add(u);
      const votes = Math.max(0, intOf(opt.votes) ?? voters.length);
      const voted =
        opt.voted === true ||
        opt.voted === 1 ||
        (me !== "" && voters.includes(me));
      options.push({
        id: oid,
        content: str(opt.content ?? opt.text) ?? "",
        votes,
        voted,
        voters,
      });
    }
    const createdRaw = intOf(o.created_time ?? o.createdTime) ?? 0;
    const expiredRaw = intOf(o.expired_time ?? o.expiredTime) ?? 0;
    const toMs = (v: number) => (v > 0 && v < 1e11 ? v * 1000 : v);
    const id = intOf(o.poll_id ?? o.pollId ?? o.id) ?? 0;
    const numVote = intOf(o.num_vote ?? o.total_votes ?? o.totalVotes);
    return {
      id,
      groupId: idOf(o.group_id ?? o.groupId) ?? groupId,
      question: str(o.question) ?? "",
      creatorId: idOf(o.creator ?? o.creatorId) ?? "",
      createdAt: toMs(createdRaw),
      expiredAt: toMs(expiredRaw),
      closed: Boolean(o.closed),
      multiple: Boolean(o.allow_multi_choices ?? o.allowMultiChoices),
      allowAdd: Boolean(o.allow_add_new_option ?? o.allowAddNewOption),
      hidePreview: Boolean(o.is_hide_vote_preview ?? o.hideVotePreview),
      anonymous: Boolean(o.is_anonymous ?? o.isAnonymous),
      totalVotes:
        numVote !== undefined
          ? numVote
          : voterSet.size > 0
            ? voterSet.size
            : options.reduce((sum, x) => sum + x.votes, 0),
      options,
    };
  }

  private normalizeReminderItem(raw: unknown): ReminderItem | null {
    const o = objectOf(raw);
    if (o === undefined) return null;
    const id = idOf(o.id ?? o.reminderId ?? o.topicId);
    if (id === undefined) return null;
    let rawParams = o.params;
    if (typeof rawParams === "string") {
      try {
        rawParams = JSON.parse(rawParams);
      } catch {
        rawParams = undefined;
      }
    }
    const p = objectOf(rawParams) ?? {};
    const title = str(p.title ?? o.title) ?? "";
    const startRaw = intOf(o.startTime ?? o.start_time) ?? 0;
    const createdRaw = intOf(o.createTime ?? o.createdTime) ?? 0;
    return {
      id,
      title,
      emoji: str(o.emoji) ?? "⏰",
      startTime: startRaw > 0 && startRaw < 1e11 ? startRaw * 1000 : startRaw,
      repeat: intOf(o.repeat) ?? 0,
      ...(idOf(o.creatorUid ?? o.creatorId) !== undefined
        ? { creatorId: idOf(o.creatorUid ?? o.creatorId) }
        : {}),
      ...(createdRaw > 0
        ? {
            createdAt:
              createdRaw < 1e11 ? createdRaw * 1000 : createdRaw,
          }
        : {}),
    };
  }

  listPins(threadId: string, threadType: ThreadType): Promise<PinBoardState> {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        if (threadType === "group") {
          const res = (await this.requireBoard(api).listGroupPins(
            threadId,
            0,
          )) as Record<string, unknown>;
          const rawList = Array.isArray(res?.topics)
            ? res.topics
            : Array.isArray(res?.items)
              ? res.items
              : [];
          const items = rawList
            .map((t) => this.normalizePinnedTopic(t, true))
            .filter((t): t is PinnedTopic => t !== null);
          return {
            items,
            version: intOf(res?.boardVersion ?? res?.version) ?? 0,
          };
        }
        const res = (await api.getFriendBoardList(threadId)) as unknown as Record<
          string,
          unknown
        >;
        const rawList = Array.isArray(res?.data)
          ? res.data
          : Array.isArray(res?.topics)
            ? res.topics
            : [];
        const items = rawList
          .map((t) => this.normalizePinnedTopic(t, true))
          .filter((t): t is PinnedTopic => t !== null);
        return {
          items,
          version: intOf(res?.version) ?? 0,
        };
      } catch (e) {
        throw zaloRpcError(e, "pins");
      }
    });
  }

  listBoard(
    groupId: string,
    page = 1,
    count = 20,
  ): Promise<PinnedTopic[]> {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        const res = await api.getListBoard({ page, count }, groupId);
        const rawItems = Array.isArray(res?.items) ? res.items : [];
        return rawItems
          .map((t) => this.normalizePinnedTopic(t, false))
          .filter((t): t is PinnedTopic => t !== null);
      } catch (e) {
        throw zaloRpcError(e, "board");
      }
    });
  }

  pinMessage(
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
  ): Promise<PinBoardState> {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        const rawMsg = asTMessage(payload.raw);
        const topicParams: Record<string, unknown> = {
          client_msg_id: payload.cliMsgId || rawMsg?.cliMsgId || payload.msgId,
          global_msg_id: payload.msgId,
          senderUid: payload.senderId || this.self.uid,
          senderName: payload.senderName || this.self.displayName,
          title: payload.title,
          msg_type: this.cliMsgTypeOf(payload.kind),
          ...(payload.thumbUrl ? { thumb: payload.thumbUrl } : {}),
          ...(payload.href ? { href: payload.href } : {}),
        };
        if (threadType === "group") {
          const board = this.requireBoard(api);
          await board.pinGroupMessage(threadId, topicParams);
          const refreshed = (await board.listGroupPins(
            threadId,
            0,
          )) as Record<string, unknown>;
          const rawList = Array.isArray(refreshed?.topics)
            ? refreshed.topics
            : [];
          return {
            items: rawList
              .map((t) => this.normalizePinnedTopic(t, true))
              .filter((t): t is PinnedTopic => t !== null),
            version: intOf(refreshed?.boardVersion ?? refreshed?.version) ?? 0,
          };
        }
        const current = (await api.getFriendBoardList(
          threadId,
        )) as unknown as Record<string, unknown>;
        const version = intOf(current?.version) ?? 0;
        const created = (await this.requireBoard(api).createFriendPin(
          threadId,
          topicParams,
          version,
        )) as Record<string, unknown>;
        const rawList = Array.isArray(created?.topics)
          ? created.topics
          : Array.isArray(created?.data)
            ? created.data
            : null;
        if (rawList !== null) {
          return {
            items: rawList
              .map((t) => this.normalizePinnedTopic(t, true))
              .filter((t): t is PinnedTopic => t !== null),
            version: intOf(created?.version) ?? version,
          };
        }
        const refreshed = (await api.getFriendBoardList(
          threadId,
        )) as unknown as Record<string, unknown>;
        const list = Array.isArray(refreshed?.data) ? refreshed.data : [];
        return {
          items: list
            .map((t) => this.normalizePinnedTopic(t, true))
            .filter((t): t is PinnedTopic => t !== null),
          version: intOf(refreshed?.version) ?? version,
        };
      } catch (e) {
        throw zaloRpcError(e, "pin message");
      }
    });
  }

  pinBoardItem(
    groupId: string,
    topicId: string,
    topicType: number,
  ): Promise<void> {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        const parsedId = /^\d+$/.test(topicId) ? Number(topicId) : topicId;
        await this.requireBoard(api).pinGroupBoardItem(
          groupId,
          parsedId,
          topicType,
        );
      } catch (e) {
        throw zaloRpcError(e, "pin item");
      }
    });
  }

  unpinTopic(
    threadId: string,
    threadType: ThreadType,
    topicId: string,
    topicType: number,
  ): Promise<PinBoardState> {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        const parsedId = /^\d+$/.test(topicId) ? Number(topicId) : topicId;
        if (threadType === "group") {
          const board = this.requireBoard(api);
          const cur = (await board.listGroupPins(
            threadId,
            0,
          )) as Record<string, unknown>;
          const boardVersion = intOf(cur?.boardVersion ?? cur?.version) ?? 0;
          await board.unpinGroupTopic(
            threadId,
            parsedId,
            topicType,
            boardVersion,
          );
          const next = (await board.listGroupPins(
            threadId,
            0,
          )) as Record<string, unknown>;
          const rawList = Array.isArray(next?.topics) ? next.topics : [];
          return {
            items: rawList
              .map((t) => this.normalizePinnedTopic(t, true))
              .filter((t): t is PinnedTopic => t !== null),
            version: intOf(next?.boardVersion ?? next?.version) ?? boardVersion,
          };
        }
        const cur = (await api.getFriendBoardList(
          threadId,
        )) as unknown as Record<string, unknown>;
        const version = intOf(cur?.version) ?? 0;
        await this.requireBoard(api).unpinFriendTopics(
          threadId,
          [{ topicId: parsedId, topicType }],
          version,
        );
        const next = (await api.getFriendBoardList(
          threadId,
        )) as unknown as Record<string, unknown>;
        const rawList = Array.isArray(next?.data) ? next.data : [];
        return {
          items: rawList
            .map((t) => this.normalizePinnedTopic(t, true))
            .filter((t): t is PinnedTopic => t !== null),
          version: intOf(next?.version) ?? version,
        };
      } catch (e) {
        throw zaloRpcError(e, "unpin");
      }
    });
  }

  createPoll(
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
  ): Promise<PollDetail> {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        const res = await api.createPoll(
          {
            question: opts.question,
            options: opts.options,
            expiredTime: opts.expiredTime ?? 0,
            allowMultiChoices: opts.allowMultiChoices ?? true,
            allowAddNewOption: opts.allowAddNewOption ?? true,
            hideVotePreview: opts.hideVotePreview ?? false,
            isAnonymous: opts.isAnonymous ?? false,
          },
          groupId,
        );
        const detail = this.normalizePollDetail(res, groupId);
        if (opts.pin && detail.id > 0) {
          try {
            await this.requireBoard(api).pinGroupBoardItem(
              groupId,
              detail.id,
              3, // POLL_TOPIC
            );
          } catch {
            // Poll was already created; pin failure shouldn't fail creation.
          }
        }
        return detail;
      } catch (e) {
        throw zaloRpcError(e, "poll");
      }
    });
  }

  pollDetail(pollId: number, groupId = ""): Promise<PollDetail> {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        const res = await api.getPollDetail(pollId);
        return this.normalizePollDetail(res, groupId);
      } catch (e) {
        throw zaloRpcError(e, "poll");
      }
    });
  }

  votePoll(
    pollId: number,
    optionIds: number[],
    groupId = "",
  ): Promise<PollDetail> {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        await api.votePoll(pollId, optionIds);
        const res = await api.getPollDetail(pollId);
        return this.normalizePollDetail(res, groupId);
      } catch (e) {
        throw zaloRpcError(e, "vote poll");
      }
    });
  }

  addPollOption(
    pollId: number,
    content: string,
    votedOptionIds: number[],
    voteNew = true,
    groupId = "",
  ): Promise<PollDetail> {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        await api.addPollOptions({
          pollId,
          options: [{ content, voted: voteNew }],
          votedOptionIds,
        });
        const res = await api.getPollDetail(pollId);
        return this.normalizePollDetail(res, groupId);
      } catch (e) {
        throw zaloRpcError(e, "add poll option");
      }
    });
  }

  lockPoll(pollId: number, groupId = ""): Promise<PollDetail> {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        await api.lockPoll(pollId);
        const res = await api.getPollDetail(pollId);
        return this.normalizePollDetail(res, groupId);
      } catch (e) {
        throw zaloRpcError(e, "lock poll");
      }
    });
  }

  sharePoll(pollId: number): Promise<void> {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        await api.sharePoll(pollId);
      } catch (e) {
        throw zaloRpcError(e, "share poll");
      }
    });
  }

  createNote(groupId: string, title: string, pin = false): Promise<PinnedTopic> {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        const res = await api.createNote({ title, pinAct: pin }, groupId);
        return (
          this.normalizePinnedTopic(res, pin) ?? {
            id: idOf((res as { id?: unknown })?.id) ?? String(Date.now()),
            topicType: 0,
            kind: "note",
            title,
            pinned: pin,
          }
        );
      } catch (e) {
        throw zaloRpcError(e, "note");
      }
    });
  }

  editNote(
    groupId: string,
    topicId: string,
    title: string,
    pin = false,
  ): Promise<PinnedTopic> {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        const res = await api.editNote(
          { topicId, title, pinAct: pin },
          groupId,
        );
        return (
          this.normalizePinnedTopic(res, pin) ?? {
            id: topicId,
            topicType: 0,
            kind: "note",
            title,
            pinned: pin,
          }
        );
      } catch (e) {
        throw zaloRpcError(e, "note");
      }
    });
  }

  listReminders(
    threadId: string,
    threadType: ThreadType,
    page = 1,
    count = 20,
  ): Promise<ReminderItem[]> {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        const res = await api.getListReminder(
          { page, count },
          threadId,
          zType(threadType),
        );
        const list = Array.isArray(res) ? res : [];
        return list
          .map((item) => this.normalizeReminderItem(item))
          .filter((item): item is ReminderItem => item !== null);
      } catch (e) {
        throw zaloRpcError(e, "reminders");
      }
    });
  }

  createReminder(
    threadId: string,
    threadType: ThreadType,
    opts: {
      title: string;
      emoji?: string;
      startTime: number;
      repeat?: number;
    },
  ): Promise<ReminderItem> {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        const res = await api.createReminder(
          {
            title: opts.title,
            emoji: opts.emoji ?? "⏰",
            startTime: opts.startTime,
            repeat: opts.repeat ?? 0,
          },
          threadId,
          zType(threadType),
        );
        return (
          this.normalizeReminderItem(res) ?? {
            id: idOf((res as { id?: unknown })?.id) ?? String(Date.now()),
            title: opts.title,
            emoji: opts.emoji ?? "⏰",
            startTime: opts.startTime,
            repeat: opts.repeat ?? 0,
          }
        );
      } catch (e) {
        throw zaloRpcError(e, "reminder");
      }
    });
  }

  editReminder(
    threadId: string,
    threadType: ThreadType,
    opts: {
      id: string;
      title: string;
      emoji?: string;
      startTime: number;
      repeat?: number;
    },
  ): Promise<ReminderItem> {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        const res = await api.editReminder(
          {
            topicId: opts.id,
            title: opts.title,
            emoji: opts.emoji ?? "⏰",
            startTime: opts.startTime,
            repeat: opts.repeat ?? 0,
          },
          threadId,
          zType(threadType),
        );
        return (
          this.normalizeReminderItem(res) ?? {
            id: opts.id,
            title: opts.title,
            emoji: opts.emoji ?? "⏰",
            startTime: opts.startTime,
            repeat: opts.repeat ?? 0,
          }
        );
      } catch (e) {
        throw zaloRpcError(e, "reminder");
      }
    });
  }

  removeReminder(
    threadId: string,
    threadType: ThreadType,
    id: string,
  ): Promise<void> {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        await api.removeReminder(id, threadId, zType(threadType));
      } catch (e) {
        throw zaloRpcError(e, "reminder");
      }
    });
  }

  react(
    msgId: string,
    threadId: string,
    threadType: ThreadType,
    icon: string,
    raw?: unknown,
  ) {
    const api = this.requireApi();
    const d = asTMessage(raw);
    return this.call(async () => {
      await api.addReaction(icon as Reactions, {
        data: { msgId, cliMsgId: d?.cliMsgId ?? "" },
        threadId,
        type: zType(threadType),
      });
    });
  }

  recall(
    msgId: string,
    threadId: string,
    threadType: ThreadType,
    raw?: unknown,
  ) {
    const api = this.requireApi();
    const d = asTMessage(raw);
    return this.call(async () => {
      await api.undo(
        { msgId, cliMsgId: d?.cliMsgId ?? "" },
        threadId,
        zType(threadType),
      );
    });
  }

  // deleteMessage(dest, onlyMe): zca-js refuses onlyMe=false for own
  // messages ("use undo") and for any message in a private chat, so this
  // maps to delete-for-me.
  deleteMessage(
    msgId: string,
    threadId: string,
    threadType: ThreadType,
    raw?: unknown,
  ) {
    const api = this.requireApi();
    const d = asTMessage(raw);
    return this.call(async () => {
      await api.deleteMessage(
        {
          data: {
            msgId,
            cliMsgId: d?.cliMsgId ?? "",
            uidFrom: d?.uidFrom ?? "",
          },
          threadId,
          type: zType(threadType),
        },
        true,
      );
    });
  }

  // Group admins can delete another member's message for everyone
  // (zca deleteMessage with onlyMe=false). zca-js itself rejects own
  // messages and one-to-one threads; the manager enforces the same rules
  // before this is reached.
  deleteMessageForAll(
    msgId: string,
    threadId: string,
    threadType: ThreadType,
    raw?: unknown,
  ) {
    const api = this.requireApi();
    const d = asTMessage(raw);
    return this.call(async () => {
      try {
        await api.deleteMessage(
          {
            data: {
              msgId,
              cliMsgId: d?.cliMsgId ?? "",
              uidFrom: d?.uidFrom ?? "",
            },
            threadId,
            type: zType(threadType),
          },
          false,
        );
      } catch (e) {
        throw zaloRpcError(e, "delete for everyone");
      }
    });
  }

  markSeen(threadId: string, threadType: ThreadType, raw?: unknown) {
    const api = this.requireApi();
    const d = asTMessage(raw);
    // Without a stored message reference the event cannot be sent. Failing
    // here keeps the manager from clearing local unread state for a seen
    // receipt Zalo never received.
    if (d === undefined) {
      return Promise.reject(
        new RpcError("not_found", "mark seen: no incoming message reference"),
      );
    }
    return this.call(async () => {
      await api.sendSeenEvent([receiptParams(d)], zType(threadType));
    });
  }

  setPinned(threadId: string, threadType: ThreadType, pinned: boolean) {
    const api = this.requireApi();
    return this.call(async () => {
      await api.setPinnedConversations(pinned, threadId, zType(threadType));
    });
  }

  setMuted(threadId: string, threadType: ThreadType, muted: boolean) {
    const api = this.requireApi();
    return this.call(async () => {
      // The contract is a boolean: mute "forever" (-1), unmute action 2.
      await api.setMute(
        muted
          ? { duration: MuteDuration.FOREVER, action: MuteAction.MUTE }
          : { action: MuteAction.UNMUTE },
        threadId,
        zType(threadType),
      );
    });
  }

  markUnread(threadId: string, threadType: ThreadType) {
    const api = this.requireApi();
    return this.call(async () => {
      await api.addUnreadMark(threadId, zType(threadType));
    });
  }

  removeUnreadMark(threadId: string, threadType: ThreadType) {
    const api = this.requireApi();
    return this.call(async () => {
      await api.removeUnreadMark(threadId, zType(threadType));
    });
  }

  deleteConversation(
    threadId: string,
    threadType: ThreadType,
    lastRef: unknown,
  ) {
    const api = this.requireApi();
    return this.call(async () => {
      // deleteChat only needs the last message's id triple from the ref.
      const ref = (lastRef ?? {}) as Record<string, unknown>;
      await api.deleteChat(
        {
          ownerId: String(ref.uidFrom ?? this.self.uid),
          cliMsgId: String(ref.cliMsgId ?? ""),
          globalMsgId: String(ref.msgId ?? ""),
        },
        threadId,
        zType(threadType),
      );
    });
  }

  forward(
    payload: {
      message: string;
      reference?: { ts: number; id: string; fwLvl?: number };
    },
    to: { threadId: string; threadType: ThreadType }[],
  ) {
    const api = this.requireApi();
    return this.call(async () => {
      const users = to.filter((t) => t.threadType === "user");
      const groups = to.filter((t) => t.threadType === "group");
      const fwd = payload as Parameters<typeof api.forwardMessage>[0];
      if (users.length > 0) {
        await api.forwardMessage(
          fwd,
          users.map((t) => t.threadId),
          ZThreadType.User,
        );
      }
      if (groups.length > 0) {
        await api.forwardMessage(
          fwd,
          groups.map((t) => t.threadId),
          ZThreadType.Group,
        );
      }
    });
  }

  syncConversationState() {
    const api = this.requireApi();
    return this.call(async (): Promise<ConversationSyncState> => {
      // Each section is only written once its endpoint answered: an absent
      // section means "unknown" and keeps the local flags.
      const out: ConversationSyncState = {};
      try {
        const pins = await api.getPinConversations();
        const convs = (pins as { conversations?: unknown }).conversations;
        const pinned: ConversationRef[] = [];
        if (Array.isArray(convs)) {
          for (const c of convs) {
            const id = String(c);
            if (id.startsWith("g")) {
              pinned.push({ threadId: id.slice(1), threadType: "group" });
            } else if (id.startsWith("u")) {
              pinned.push({ threadId: id.slice(1), threadType: "user" });
            }
          }
        }
        out.pinned = pinned;
      } catch {}
      try {
        // getMute splits user and group threads into separate entry lists,
        // each keyed by the thread id.
        const mute = await api.getMute();
        const muted: ConversationRef[] = [];
        const add = (entries: unknown, threadType: ThreadType) => {
          if (!Array.isArray(entries)) return;
          for (const e of entries) {
            const id = idOf((e as Record<string, unknown>).id);
            if (id !== undefined) muted.push({ threadId: id, threadType });
          }
        };
        add(mute.chatEntries, "user");
        add(mute.groupChatEntries, "group");
        out.muted = muted;
      } catch {}
      // Each extra endpoint is independent: a failure leaves that part of
      // the local state untouched instead of clearing it.
      try {
        out.hidden = (await this.hiddenState(api)).threads;
      } catch {}
      try {
        out.archived = (await this.archivedState(api)).threads;
      } catch {}
      try {
        out.autoDelete = (await this.autoDeleteState(api)).conversations;
      } catch {}
      return out;
    });
  }

  // ---- hidden, archived, labels, auto-delete, linked devices ----

  // Private state readers run inside an existing queued call; the public
  // methods below wrap them once so syncConversationState never nests
  // queue entries (which would deadlock).
  private async hiddenState(api: API): Promise<HiddenConversations> {
    const res = await api.getHiddenConversations();
    const threads = (res as { threads?: unknown } | null)?.threads;
    if (!Array.isArray(threads)) {
      throw new RpcError("error", "hidden conversations: malformed response");
    }
    const out: ConversationRef[] = [];
    for (const t of threads) {
      if (t === null || typeof t !== "object") continue;
      const r = t as Record<string, unknown>;
      const id = idOf(r.thread_id) ?? idOf(r.threadId);
      if (id === undefined) continue;
      out.push({
        threadId: id,
        threadType: flagOf(r.is_group ?? r.isGroup) ? "group" : "user",
      });
    }
    return {
      // The pin value is a hash and never leaves the gateway.
      pinSet: str((res as { pin?: unknown } | null)?.pin) !== undefined,
      threads: out,
    };
  }

  hiddenConversations() {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        return await this.hiddenState(api);
      } catch (e) {
        throw zaloRpcError(e, "hidden conversations");
      }
    });
  }

  setHiddenConversations(threads: ConversationRef[], hidden: boolean) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        // zca-js takes one thread type per call.
        for (const type of ["user", "group"] as const) {
          const ids = threads
            .filter((t) => t.threadType === type)
            .map((t) => t.threadId);
          if (ids.length > 0) {
            await api.setHiddenConversations(hidden, ids, zType(type));
          }
        }
      } catch (e) {
        throw zaloRpcError(e, "hidden conversations");
      }
    });
  }

  setHiddenPin(pin: string) {
    if (!/^\d{4}$/.test(pin)) {
      return Promise.reject(new RpcError("bad_request", "pin must be 4 digits"));
    }
    const api = this.requireApi();
    return this.call(async () => {
      try {
        await api.updateHiddenConversPin(pin);
      } catch (e) {
        throw zaloRpcError(e, "hidden pin");
      }
    });
  }

  resetHiddenPin() {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        await api.resetHiddenConversPin();
      } catch (e) {
        throw zaloRpcError(e, "hidden pin");
      }
    });
  }

  private async archivedState(api: API): Promise<ArchivedChatList> {
    const res = await api.getArchivedChatList();
    const items = (res as { items?: unknown } | null)?.items;
    if (!Array.isArray(items)) {
      throw new RpcError("error", "archived chats: malformed response");
    }
    return {
      threads: items.flatMap(archivedRefOf),
      version: intOf((res as { version?: unknown }).version) ?? 0,
    };
  }

  archivedChatList() {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        return await this.archivedState(api);
      } catch (e) {
        throw zaloRpcError(e, "archived chats");
      }
    });
  }

  updateArchivedChatList(archived: boolean, threads: ConversationRef[]) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        const res = await api.updateArchivedChatList(
          archived,
          threads.map((t) => ({
            id: t.threadId,
            type: zType(t.threadType),
          })),
        );
        const r = res as unknown as Record<string, unknown>;
        return {
          // The PC client reads needSync; zca-js types it needResync.
          needResync: flagOf(r.needSync ?? r.needResync),
          version: intOf(r.version) ?? 0,
        };
      } catch (e) {
        throw zaloRpcError(e, "archived chats");
      }
    });
  }

  private async labelsState(api: API): Promise<LabelsState> {
    return labelsStateOf(await api.getLabels());
  }

  labels() {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        return await this.labelsState(api);
      } catch (e) {
        throw zaloRpcError(e, "labels");
      }
    });
  }

  updateLabels(labels: Label[], version: number) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        const res = await api.updateLabels({
          labelData: labels.map(labelDataOf),
          version,
        });
        return labelsStateOf(res);
      } catch (e) {
        throw zaloRpcError(e, "labels");
      }
    });
  }

  private async autoDeleteState(api: API): Promise<AutoDeleteChat> {
    const res = await api.getAutoDeleteChat();
    const convers = (res as { convers?: unknown } | null)?.convers;
    if (!Array.isArray(convers)) {
      throw new RpcError("error", "auto-delete: malformed response");
    }
    return { conversations: convers.flatMap(autoDeleteRefOf) };
  }

  autoDeleteChat() {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        return await this.autoDeleteState(api);
      } catch (e) {
        throw zaloRpcError(e, "auto-delete");
      }
    });
  }

  updateAutoDeleteChat(
    threadId: string,
    threadType: ThreadType,
    ttl: number,
  ) {
    if (!(AUTO_DELETE_TTLS as readonly number[]).includes(ttl)) {
      return Promise.reject(
        new RpcError("bad_request", "unsupported auto-delete ttl"),
      );
    }
    const api = this.requireApi();
    return this.call(async () => {
      try {
        await api.updateAutoDeleteChat(
          ttl as ChatTTL,
          threadId,
          zType(threadType),
        );
      } catch (e) {
        throw zaloRpcError(e, "auto-delete");
      }
    });
  }

  private async linkedDevicesState(api: API): Promise<LinkedDevices> {
    return linkedDevicesOf(await api.getListDevice());
  }

  linkedDevices() {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        return await this.linkedDevicesState(api);
      } catch (e) {
        throw zaloRpcError(e, "linked devices");
      }
    });
  }

  groupMembersInfo(uids: string[]) {
    const api = this.requireApi();
    return this.call(async (): Promise<UserInfo[]> => {
      const res = await api.getGroupMembersInfo(uids);
      const profiles =
        (res as { profiles?: Record<string, Record<string, unknown>> })
          .profiles ??
        (res as { data?: { profiles?: Record<string, Record<string, unknown>> } })
          .data?.profiles ??
        {};
      return Object.entries(profiles).map(([k, u]) => ({
        uid: k.replace(/_0$/, ""),
        displayName: String(u.displayName ?? u.zaloName ?? ""),
        avatarUrl: String(u.avatar ?? ""),
      }));
    });
  }

  keepAlive() {
    const api = this.requireApi();
    return this.call(async () => {
      await api.keepAlive();
    });
  }

  logout() {
    const api = this.requireApi();
    return this.call(async () => {
      await api.logout();
    });
  }

  sendTyping(threadId: string, threadType: ThreadType) {
    const api = this.requireApi();
    return this.call(() =>
      api.sendTypingEvent(threadId, zType(threadType), DestType.User).then(
        () => {},
      ),
    );
  }

  // getAllFriends is the friend list; aliases and close friends are two
  // extra endpoints merged here so the client gets one Contact shape.
  listFriends() {
    const api = this.requireApi();
    return this.call(async (): Promise<Contact[]> => {
      try {
        const res = await api.getAllFriends(20000, 1);
        // Sequential, like listGroups: one queued task must not fire two
        // Zalo requests at once.
        const aliases = await this.friendAliases(api);
        const close = await this.closeFriendIds(api);
        return res.map((u) => {
          const uid = String(u.userId);
          const alias = aliases.get(uid);
          return {
            uid,
            displayName: u.displayName,
            avatarUrl: u.avatar,
            ...(alias !== undefined ? { alias } : {}),
            ...(close.has(uid) ? { closeFriend: true } : {}),
          };
        });
      } catch (e) {
        throw zaloRpcError(e, "friend list");
      }
    });
  }

  // Alias and close-friend lists are secondary: a failure must not take
  // the friend list down with it.
  private async friendAliases(api: API): Promise<Map<string, string>> {
    const out = new Map<string, string>();
    try {
      for (let page = 1; page <= 100; page++) {
        const res: GetAliasListResponse = await api.getAliasList(100, page);
        const items = res.items ?? [];
        for (const it of items) {
          const alias = str(it.alias);
          if (alias !== undefined) out.set(String(it.userId), alias);
        }
        if (items.length < 100) break;
      }
    } catch {
      // Partial pages are still useful; the next contacts.list retries.
      return out;
    }
    return out;
  }

  private async closeFriendIds(api: API): Promise<Set<string>> {
    try {
      const res: GetCloseFriendsResponse = await api.getCloseFriends();
      return new Set((res ?? []).map((u) => String(u.userId)));
    } catch {
      return new Set();
    }
  }

  findUserByPhone(phone: string) {
    const api = this.requireApi();
    return this.call(
      async (): Promise<UserProfile | null> => {
        try {
          return userProfileOf(await api.findUser(phone));
        } catch (e) {
          // zca-js's own findUser treats 216 as "no such user"; a dead
          // session still surfaces on every other call.
          if ((e as { code?: number | null }).code === 216) return null;
          throw zaloRpcError(e, "find user");
        }
      },
      { sessionExpiry: "ignore" },
    );
  }

  findUserByUsername(username: string) {
    const api = this.requireApi();
    return this.call(
      async (): Promise<UserProfile | null> => {
        try {
          return userProfileOf(await api.findUserByUsername(username));
        } catch (e) {
          if ((e as { code?: number | null }).code === 216) return null;
          throw zaloRpcError(e, "find user");
        }
      },
      { sessionExpiry: "ignore" },
    );
  }

  friendRequestStatus(uid: string) {
    const api = this.requireApi();
    return this.call(async (): Promise<FriendRequestStatus> => {
      try {
        const r: GetFriendRequestStatusResponse =
          await api.getFriendRequestStatus(uid);
        return {
          isFriend: flagOf(r.is_friend),
          isRequested: flagOf(r.is_requested),
          isRequesting: flagOf(r.is_requesting),
          addFriendPrivacy: intOf(r.addFriendPrivacy) ?? 0,
          isSeen: flagOf(r.isSeenFriendReq),
        };
      } catch (e) {
        throw zaloRpcError(e, "friend request status");
      }
    });
  }

  sendFriendRequest(uid: string, message: string) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        await api.sendFriendRequest(message, uid);
      } catch (e) {
        const code = (e as { code?: number | null }).code;
        // 222: the other side already asked first, so Zalo accepts this
        // request instead; that is success for the caller.
        if (code === 222) return;
        if (code === 225) {
          throw new RpcError("conflict", "already friends");
        }
        if (code === 215) {
          throw new RpcError("forbidden", "the user may have blocked you");
        }
        throw zaloRpcError(e, "friend request");
      }
    });
  }

  // RecommType 2 of getFriendRecommendations is the received-request inbox.
  receivedFriendRequests() {
    const api = this.requireApi();
    return this.call(async (): Promise<ReceivedFriendRequest[]> => {
      try {
        const res: GetFriendRecommendationsResponse =
          await api.getFriendRecommendations();
        return (res.recommItems ?? [])
          .filter(
            (i) =>
              intOf(i.dataInfo?.recommType) ===
              FriendRecommendationsType.ReceivedFriendRequest,
          )
          .flatMap((i) => {
            const d = i.dataInfo;
            const uid = idOf(d.userId);
            if (uid === undefined) return [];
            const info = recommInfoOf(d.recommInfo);
            const message =
              str(info?.message) ?? str(info?.customText);
            const ts = intOf(d.recommTime);
            return [
              {
                uid,
                displayName: str(d.displayName) ?? str(d.zaloName) ?? "",
                avatarUrl: str(d.avatar) ?? "",
                ...(message !== undefined ? { message } : {}),
                ...(ts !== undefined ? { ts } : {}),
              },
            ];
          });
      } catch (e) {
        throw zaloRpcError(e, "friend requests");
      }
    });
  }

  // RecommType 1 of getFriendRecommendations is the suggested-friends list.
  friendRecommendations() {
    const api = this.requireApi();
    return this.call(async (): Promise<FriendRecommendation[]> => {
      try {
        const res: GetFriendRecommendationsResponse =
          await api.getFriendRecommendations();
        return (res.recommItems ?? [])
          .filter(
            (i) =>
              intOf(i.dataInfo?.recommType) ===
              FriendRecommendationsType.RecommendedFriend,
          )
          .flatMap((i) => {
            const d = i.dataInfo;
            const uid = idOf(d.userId);
            if (uid === undefined) return [];
            const phoneNumber = str(d.phoneNumber);
            const gender = intOf(d.gender);
            const message = str(recommInfoOf(d.recommInfo)?.message);
            return [
              {
                uid,
                displayName: str(d.displayName) ?? str(d.zaloName) ?? "",
                avatarUrl: str(d.avatar) ?? "",
                ...(phoneNumber !== undefined ? { phoneNumber } : {}),
                ...(gender === 0
                  ? { gender: "male" }
                  : gender === 1
                    ? { gender: "female" }
                    : {}),
                ...(message !== undefined ? { message } : {}),
              },
            ];
          });
      } catch (e) {
        throw zaloRpcError(e, "friend recommendations");
      }
    });
  }

  sentFriendRequests() {
    const api = this.requireApi();
    return this.call(async (): Promise<SentFriendRequest[]> => {
      let res: GetSentFriendRequestResponse;
      try {
        res = await api.getSentFriendRequest();
      } catch (e) {
        // 112: nothing has been sent.
        if ((e as { code?: number | null }).code === 112) return [];
        throw zaloRpcError(e, "sent friend requests");
      }
      return Object.values(res ?? {}).flatMap((r) => {
        const uid = idOf(r.userId);
        if (uid === undefined) return [];
        const message = str(r.fReqInfo?.message);
        const ts = intOf(r.fReqInfo?.time);
        return [
          {
            uid,
            displayName: str(r.displayName) ?? str(r.zaloName) ?? "",
            avatarUrl: str(r.avatar) ?? "",
            ...(message !== undefined ? { message } : {}),
            ...(ts !== undefined ? { ts } : {}),
          },
        ];
      });
    });
  }

  acceptFriendRequest(uid: string) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        await api.acceptFriendRequest(uid);
      } catch (e) {
        throw zaloRpcError(e, "accept friend request");
      }
    });
  }

  rejectFriendRequest(uid: string) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        await api.rejectFriendRequest(uid);
      } catch (e) {
        throw zaloRpcError(e, "reject friend request");
      }
    });
  }

  undoFriendRequest(uid: string) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        await api.undoFriendRequest(uid);
      } catch (e) {
        throw zaloRpcError(e, "cancel friend request");
      }
    });
  }

  setFriendAlias(uid: string, alias: string) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        await api.changeFriendAlias(alias, uid);
      } catch (e) {
        throw zaloRpcError(e, "set alias");
      }
    });
  }

  removeFriendAlias(uid: string) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        await api.removeFriendAlias(uid);
      } catch (e) {
        throw zaloRpcError(e, "remove alias");
      }
    });
  }

  removeFriend(uid: string) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        await api.removeFriend(uid);
      } catch (e) {
        throw zaloRpcError(e, "unfriend");
      }
    });
  }

  blockUser(uid: string) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        await api.blockUser(uid);
      } catch (e) {
        throw zaloRpcError(e, "block");
      }
    });
  }

  unblockUser(uid: string) {
    const api = this.requireApi();
    return this.call(async () => {
      try {
        await api.unblockUser(uid);
      } catch (e) {
        throw zaloRpcError(e, "unblock");
      }
    });
  }

  // zca-js parses the per-friend status JSON down to its status string.
  friendOnlines() {
    const api = this.requireApi();
    return this.call(async (): Promise<FriendPresence[]> => {
      try {
        const res: GetFriendOnlinesResponse = await api.getFriendOnlines();
        return (res.onlines ?? []).map((o) => {
          const status = String(o.status ?? "");
          return {
            uid: String(o.userId),
            status,
            online: ONLINE_PRESENCE.has(status.trim().toLowerCase()),
          };
        });
      } catch (e) {
        throw zaloRpcError(e, "presence");
      }
    });
  }

  lastOnline(uid: string) {
    const api = this.requireApi();
    return this.call(async (): Promise<LastSeen> => {
      try {
        const res: LastOnlineResponse = await api.lastOnline(uid);
        return {
          showOnlineStatus: flagOf(res.settings?.show_online_status),
          lastOnline: intOf(res.lastOnline) ?? 0,
        };
      } catch (e) {
        throw zaloRpcError(e, "last online");
      }
    });
  }

  // getGroupInfo often returns an empty memberIds with only a page of
  // currentMems, so the group link endpoints page the rest of the roster.
  // Any failure keeps the normalized metadata the base call produced, and a
  // member is only ever added from a page the server sent.
  private async groupRoster(
    api: API,
    base: GroupInfo,
    hasMoreMember: number,
  ): Promise<GroupInfo> {
    const incomplete =
      (base.memberIds.length === 0 && (base.memberCount ?? 0) > 0) ||
      hasMoreMember > 0;
    if (!incomplete) return base;
    let link: string | undefined;
    try {
      const detail = await api.getGroupLinkDetail(base.id);
      // enabled 0 means the group link is off; there is nothing to page.
      if (intOf(detail?.enabled) !== 0) link = str(detail?.link);
    } catch {
      return base;
    }
    if (link === undefined) return base;
    const memberIds = [...base.memberIds];
    const known = new Set(memberIds);
    const seeds = new Map<string, GroupMember>(
      (base.members ?? []).map((m) => [m.uid, m]),
    );
    const adminIds = base.adminIds ?? [];
    const roleOf = (uid: string): GroupMember["role"] =>
      uid === base.ownerId
        ? "owner"
        : adminIds.includes(uid)
          ? "deputy"
          : "member";
    let more = true;
    for (let page = 1; more && page <= GROUP_LINK_MAX_PAGES; page++) {
      let res: GetGroupLinkInfoResponse;
      try {
        res = await api.getGroupLinkInfo({ link, memberPage: page });
      } catch {
        // Partial pages are still useful; the base metadata stays intact.
        break;
      }
      for (const m of res?.currentMems ?? []) {
        const uid = idOf(m?.id);
        if (uid === undefined) continue;
        if (!known.has(uid)) {
          known.add(uid);
          memberIds.push(uid);
        }
        // A page can name a member the base list only counted.
        if (!seeds.has(uid)) {
          seeds.set(uid, {
            uid,
            displayName: str(m.dName) ?? str(m.zaloName) ?? "",
            avatarUrl: str(m.avatar) ?? str(m.avatar_25) ?? "",
            role: roleOf(uid),
          });
        }
      }
      more = flagOf(res?.hasMoreMember);
    }
    return {
      ...base,
      memberIds,
      // totalMember from the base call is authoritative; a page count is not.
      memberCount:
        (base.memberCount ?? 0) > 0 ? base.memberCount : memberIds.length,
      ...(seeds.size > 0 ? { members: [...seeds.values()] } : {}),
    };
  }

  listGroups() {
    const api = this.requireApi();
    return this.call(async (): Promise<GroupInfo[]> => {
      const res = await api.getAllGroups();
      const ids = Object.keys(res.gridVerMap);
      const infos = await api.getGroupInfo(ids);
      const out: GroupInfo[] = [];
      // Sequential: one queued task must not fire two Zalo requests at once.
      for (const [id, g] of Object.entries(infos.gridInfoMap)) {
        out.push(
          await this.groupRoster(
            api,
            normalizeZcaGroupInfo(id, g),
            intOf(g.hasMoreMember) ?? 0,
          ),
        );
      }
      return out;
    });
  }

  groupInfo(groupId: string) {
    const api = this.requireApi();
    return this.call(async (): Promise<GroupInfo> => {
      const res = await api.getGroupInfo(groupId);
      // The map is keyed by group id; never take an arbitrary entry.
      const g = res.gridInfoMap[groupId];
      if (g === undefined) throw new RpcError("not_found", groupId);
      return this.groupRoster(
        api,
        normalizeZcaGroupInfo(groupId, g),
        intOf(g.hasMoreMember) ?? 0,
      );
    });
  }

  // zca-js marks getGroupChatHistory deprecated (upstream removed the
  // endpoint); it is the only group-history surface we have, so it is
  // used on demand and mock-stubbed.
  groupHistory(groupId: string, count: number) {
    const api = this.requireApi();
    return this.call(async () => {
      const res = await api.getGroupChatHistory(groupId, count);
      const messages = (res.groupMsgs ?? []).map((m) => normalizeZcaMessage(m));
      await this.enrichInboundStickers(api, messages);
      return {
        messages,
        more: Number(res.more) === 1,
      };
    });
  }

  // getFullAvatar is the original upload; getAvatarUrlProfile (240 px) is
  // the fallback when Zalo has no full-size copy.
  fullAvatar(uid: string) {
    const api = this.requireApi();
    return this.call(async (): Promise<string> => {
      const full = await api.getFullAvatar(uid);
      if (full.full_avatar !== "") return full.full_avatar;
      const sized = await api.getAvatarUrlProfile(uid, AvatarSize.Large);
      return sized[uid]?.avatar ?? "";
    });
  }

  userInfo(uids: string[]) {
    const api = this.requireApi();
    return this.call(async (): Promise<UserInfo[]> => {
      const res = await api.getUserInfo(uids);
      return Object.entries(res.changed_profiles).map(([uid, u]) => ({
        uid: uid.replace(/_0$/, ""),
        displayName: u.displayName,
        avatarUrl: u.avatar,
        gender: u.gender === 0 ? "male" : u.gender === 1 ? "female" : undefined,
      }));
    });
  }

  private zaloHost(host: string): boolean {
    const h = host.toLowerCase();
    return ["zalo.me", "zaloapp.com", "zdn.vn", "zadn.vn"].some(
      (d) => h === d || h.endsWith(`.${d}`),
    );
  }

  // Stored credentials hold serialized cookies; the live jar is the only
  // source of a correct Cookie header for a url.
  private cookieHeader(url: string): string {
    return this.api?.getCookie().getCookieStringSync(url) ?? "";
  }

  private async openMediaResponse(url: string): Promise<Response> {
    const ua = this.creds.userAgent;
    const CONNECT_TIMEOUT_MS = 20_000;
    const OVERALL_TIMEOUT_MS = 120_000;
    const overall = AbortSignal.timeout(OVERALL_TIMEOUT_MS);
    // Every hop, including each redirect target, passes the SSRF guard
    // before it is requested.
    let target = await assertPublicUrl(url);
    let sawHttps = target.protocol === "https:";
    for (let hop = 0; hop <= MAX_MEDIA_REDIRECTS; hop++) {
      const fetchHop = async (headers: Record<string, string>) => {
        const hopCtl = new AbortController();
        const hopTimer = setTimeout(() => hopCtl.abort(), CONNECT_TIMEOUT_MS);
        hopTimer.unref?.();
        try {
          return await this.http(target, {
            redirect: "manual",
            headers,
            signal: AbortSignal.any([hopCtl.signal, overall]),
          });
        } catch (e) {
          const name = (e as { name?: string }).name;
          if (name === "AbortError" || name === "TimeoutError") {
            throw new RpcError("timeout", "fetch timed out");
          }
          throw new RpcError("error", `fetch failed: ${(e as Error).message}`);
        } finally {
          clearTimeout(hopTimer);
        }
      };
      let res = await fetchHop({ "user-agent": ua });
      if (
        (res.status === 401 || res.status === 403) &&
        this.zaloHost(target.hostname)
      ) {
        res.body?.cancel();
        res = await fetchHop({
          "user-agent": ua,
          cookie: this.cookieHeader(target.toString()),
        });
      }
      if (MEDIA_REDIRECT_STATUS.has(res.status)) {
        const loc = res.headers.get("location");
        res.body?.cancel();
        if (loc === null) {
          throw new RpcError("error", "redirect without location");
        }
        const nextUrl = new URL(loc, target);
        if (sawHttps && nextUrl.protocol === "http:") {
          throw new RpcError("forbidden", "https downgrade refused");
        }
        target = await assertPublicUrl(nextUrl.toString(), {
          allowHttp: !sawHttps,
        });
        if (target.protocol === "https:") sawHttps = true;
        continue;
      }
      if (!res.ok) {
        res.body?.cancel();
        throw new RpcError("error", `fetch failed: ${res.status}`);
      }
      // Content-Length is a fast reject; the streaming check below covers
      // chunked bodies and a lying header.
      const declared = Number(res.headers.get("content-length") ?? "");
      if (Number.isFinite(declared) && declared > MAX_MEDIA_BYTES) {
        res.body?.cancel();
        throw new RpcError("error", "too large");
      }
      return res;
    }
    throw new RpcError("error", "too many redirects");
  }

  async fetchMediaToFile(
    url: string,
    outPath: string,
  ): Promise<{ size: number; contentType: string }> {
    const res = await this.openMediaResponse(url);
    const writer = Bun.file(outPath).writer();
    let size = 0;
    try {
      if (res.body !== null) {
        for await (const chunk of res.body as unknown as AsyncIterable<Uint8Array>) {
          size += chunk.length;
          if (size > MAX_MEDIA_BYTES) {
            throw new RpcError("error", "too large");
          }
          writer.write(chunk);
        }
      }
    } catch (e) {
      res.body?.cancel();
      const name = (e as { name?: string }).name;
      if (name === "AbortError" || name === "TimeoutError") {
        throw new RpcError("timeout", "fetch timed out");
      }
      throw e;
    } finally {
      await writer.end();
    }
    return {
      size,
      contentType:
        res.headers.get("content-type") ?? "application/octet-stream",
    };
  }

  async fetchMedia(
    url: string,
  ): Promise<{ data: Uint8Array; contentType: string }> {
    const res = await this.openMediaResponse(url);
    const chunks: Uint8Array[] = [];
    let size = 0;
    try {
      if (res.body !== null) {
        for await (const chunk of res.body as unknown as AsyncIterable<Uint8Array>) {
          size += chunk.length;
          if (size > MAX_MEDIA_BYTES) {
            throw new RpcError("error", "too large");
          }
          chunks.push(chunk);
        }
      }
    } catch (e) {
      res.body?.cancel();
      const name = (e as { name?: string }).name;
      if (name === "AbortError" || name === "TimeoutError") {
        throw new RpcError("timeout", "fetch timed out");
      }
      throw e;
    }
    const data = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      data.set(chunk, offset);
      offset += chunk.length;
    }
    return {
      data,
      contentType:
        res.headers.get("content-type") ?? "application/octet-stream",
    };
  }

  // ---- Voice & Video Calls ----

  startCall(
    threadId: string,
    threadType: ThreadType,
    media: "voice" | "video",
  ): Promise<{
    callId: string;
    serverConfig?: Record<string, unknown>;
    groupCallId?: string;
  }> {
    const api = this.requireApi();
    return this.call(async () => {
      const callId = String(Date.now());
      if (threadType === "group") {
        const res = (await api.call.groupRequestCall({
          groupId: threadId,
          callId,
          typeRequest: media === "video" ? 6 : 5,
        })) as Record<string, unknown>;
        return {
          callId,
          groupCallId: String(res?.groupCallId ?? callId),
          serverConfig: res,
        };
      }
      const res = await api.call.requestCall({
        calleeId: threadId,
        callId,
        typeRequest: media === "video" ? 3 : 1,
      });
      return {
        callId: String(res?.sessId ?? callId),
        serverConfig: res as Record<string, unknown>,
      };
    });
  }

  answerCall(
    callId: string,
    opts: { callerId?: string; groupId?: string; media: "voice" | "video" },
  ): Promise<{ serverConfig?: Record<string, unknown> }> {
    const api = this.requireApi();
    return this.call(async () => {
      if (opts.groupId) {
        const res = (await api.call.groupAnswer({
          callId,
          callType: opts.media === "video" ? 6 : 5,
          groupId: opts.groupId,
          hostCall: opts.callerId,
        })) as Record<string, unknown>;
        return { serverConfig: res };
      }
      const res = (await api.call.answerCall({
        callerId: opts.callerId ?? "",
        callId,
        status: 1,
        rtcpAddress: "",
        rtpAddress: "",
        session_id: callId,
      })) as Record<string, unknown>;
      return { serverConfig: res };
    });
  }

  rejectCall(
    callId: string,
    opts: { callerId?: string; groupId?: string; reason?: number },
  ): Promise<void> {
    const api = this.requireApi();
    return this.call(async () => {
      if (opts.groupId) {
        await api.call.groupCancel({
          callId,
          callType: 5,
          groupId: opts.groupId,
          hostCall: opts.callerId,
        });
        return;
      }
      await api.call.answerCall({
        callerId: opts.callerId ?? "",
        callId,
        status: opts.reason ?? 3,
        rtcpAddress: "",
        rtpAddress: "",
        session_id: callId,
      });
    });
  }

  endCall(
    callId: string,
    opts: {
      peerId?: string;
      groupId?: string;
      durationSec?: number;
      reason?: number;
    },
  ): Promise<void> {
    const api = this.requireApi();
    return this.call(async () => {
      if (opts.groupId) {
        await api.call.groupEndCall({
          callId,
          callType: 5,
          groupId: opts.groupId,
          hostCall: opts.peerId,
        });
        return;
      }
      await api.call.endCall(opts.peerId ?? "", callId, opts.reason ?? 3);
    });
  }

  getGroupCallState(groupId: string): Promise<Record<string, unknown>> {
    const api = this.requireApi();
    return this.call(async () => {
      const res = (await api.call.groupState({
        callId: groupId,
        hostCall: this.self.uid,
        callType: 5,
      })) as Record<string, unknown>;
      return res ?? {};
    });
  }

  sendCallSignal(
    action: string,
    payload: Record<string, unknown>,
  ): Promise<unknown> {
    const api = this.requireApi();
    return this.call(async () => {
      if (/^\d+$/.test(action)) {
        return api.call.dispatchNativeSignal(Number(action), payload);
      }
      if (action === "conf") {
        return api.call.updateCallConfig({
          calleeId: String(payload.calleeId ?? ""),
          callId: String(payload.callId ?? ""),
          isOnCam: payload.isOnCam ? 1 : 0,
          isOnMic: payload.isOnMic ? 1 : 0,
          data: payload.data,
        });
      }
      if (action === "ringring") {
        return api.call.sendRingRing(
          String(payload.callerId ?? ""),
          String(payload.callId ?? ""),
          Number(payload.status ?? 0),
        );
      }
      const ext = dispatchExtendedCallSignal(api, action, payload);
      if (ext !== null) return ext;
      throw new RpcError("bad_request", `unknown call signal action: ${action}`);
    });
  }
}

export function createZaloFactory(
  opts: { mockUrl?: string } = {},
): GatewayFactory {
  // ZALOS_ZALO_MOCK_URL is accepted only in --dev/--local modes; cli.ts
  // and server.ts enforce that before passing mockUrl here.
  const http =
    opts.mockUrl !== undefined ? mockGatewayFetch(opts.mockUrl) : undefined;
  if (opts.mockUrl !== undefined) {
    console.error(
      `warning: ZALOS_ZALO_MOCK_URL is set; all Zalo traffic goes to the mock gateway at ${opts.mockUrl}`,
    );
  }
  const zalo = new Zalo({
    selfListen: true,
    checkUpdate: false,
    logging: false,
    ...(http !== undefined ? { polyfill: http } : {}),
    // ImageMetadataGetter takes a file path and returns {width,height,size}.
    imageMetadataGetter: async (filePath: string) => {
      const data = new Uint8Array(await Bun.file(filePath).arrayBuffer());
      const s = imageSize(data);
      return {
        width: s.width ?? 0,
        height: s.height ?? 0,
        size: statSync(filePath).size,
      };
    },
  });

  const login = async (creds: Credentials): Promise<API> =>
    zalo.login({
      imei: creds.imei,
      cookie: creds.cookie as Parameters<typeof zalo.login>[0]["cookie"],
      userAgent: creds.userAgent,
    });

  return {
    fromCredentials(creds: Credentials, self: GatewaySelf) {
      return new ZcaGateway(creds, self, login, http);
    },

    fromOaCredentials(creds: OaCredentials, self: GatewaySelf, hooks: OaHooks) {
      return new OaGateway(creds, self, hooks, http);
    },

    loginQr(callbacks: LoginQrCallbacks) {
      let credentials: Credentials | null = null;
      let scanned = { displayName: "", avatarUrl: "" };
      return new Promise((resolve, reject) => {
        void zalo
          .loginQR({ userAgent: DEFAULT_UA }, (event: LoginQRCallbackEvent) => {
            switch (event.type) {
              case LoginQRCallbackEventType.QRCodeGenerated: {
                // loginQR already strips a data: prefix; guard anyway.
                const b64 = String(event.data.image).replace(
                  /^data:image\/\w+;base64,/,
                  "",
                );
                callbacks.onQr(new Uint8Array(Buffer.from(b64, "base64")));
                break;
              }
              case LoginQRCallbackEventType.QRCodeExpired:
                void event.actions.retry();
                break;
              case LoginQRCallbackEventType.QRCodeScanned:
                scanned = {
                  displayName: event.data.display_name,
                  avatarUrl: event.data.avatar,
                };
                callbacks.onScanned(scanned);
                break;
              case LoginQRCallbackEventType.QRCodeDeclined:
                resolve(null);
                break;
              case LoginQRCallbackEventType.GotLoginInfo:
                credentials = {
                  imei: event.data.imei,
                  cookie: event.data.cookie,
                  userAgent: event.data.userAgent,
                };
                break;
            }
          })
          .then((res) => {
            if (res === null || credentials === null) {
              resolve(null);
              return;
            }
            let uid = "";
            try {
              uid = res.getOwnId();
            } catch {}
            resolve({
              credentials,
              self: {
                uid,
                displayName: scanned.displayName,
                avatarUrl: scanned.avatarUrl,
              },
            });
          })
          .catch(reject);
      });
    },
  };
}
