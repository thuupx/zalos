import { RpcError } from "../tunnel/rpc.ts";
import type { ChannelContext, TunnelServer } from "../tunnel/server.ts";
import {
  AUTO_DELETE_TTLS,
  MAX_MESSAGE_TTL_MS,
  TEXT_STYLE_CODES,
  URGENCIES,
} from "../gateway/types.ts";
import type {
  AutoDeleteTtl,
  Label,
  QuickMessageDraft,
  ReportReason,
  StyleRun,
  TextStyleCode,
  ThreadType,
  Urgency,
} from "../gateway/types.ts";
import { fetchAndCache } from "../media.ts";
import { isZaloHost } from "../gateway/mock.ts";
import { extendedAccountMethods } from "./account_extended.ts";

function slotOf(ctx: ChannelContext): string {
  const kind = ctx.channel.kind;
  if (kind.kind !== "account") throw new RpcError("error", "wrong channel");
  return kind.slot;
}

function tt(v: unknown): ThreadType {
  if (v !== "user" && v !== "group") {
    throw new RpcError("bad_request", "threadType must be user|group");
  }
  return v;
}

function requiredString(v: unknown, name: string): string {
  if (typeof v !== "string" || v.trim() === "") {
    throw new RpcError("bad_request", `${name} required`);
  }
  return v.trim();
}

function optionalString(v: unknown): string | undefined {
  return typeof v === "string" && v.trim() !== "" ? v.trim() : undefined;
}

// Users type phone numbers with spaces and dashes; zca-js only strips the
// leading 0 for Vietnamese numbers.
function phoneNumber(v: unknown): string {
  const cleaned = requiredString(v, "phone").replace(/[\s-]/g, "");
  if (cleaned === "") throw new RpcError("bad_request", "phone required");
  return cleaned;
}

const REPORT_REASONS: ReportReason[] = [
  "sensitive",
  "annoy",
  "fraud",
  "other",
];

function reportReason(v: unknown): ReportReason {
  if (typeof v !== "string" || !REPORT_REASONS.includes(v as ReportReason)) {
    throw new RpcError(
      "bad_request",
      "reason must be sensitive|annoy|fraud|other",
    );
  }
  return v as ReportReason;
}

function requiredBool(v: unknown, name: string): boolean {
  if (typeof v !== "boolean") {
    throw new RpcError("bad_request", `${name} must be a boolean`);
  }
  return v;
}

function labelVersion(v: unknown): number {
  if (typeof v !== "number" || !Number.isInteger(v) || v < 0) {
    throw new RpcError("bad_request", "version must be an integer >= 0");
  }
  return v;
}

const MAX_LABELS = 100;
const MAX_LABEL_CONVERSATIONS = 5000;

// Whole-set label payload. Labels are clear metadata, so the values are
// validated here and persisted unsealed.
function labelSet(v: unknown): Label[] {
  if (!Array.isArray(v)) {
    throw new RpcError("bad_request", "labels must be an array");
  }
  if (v.length > MAX_LABELS) {
    throw new RpcError("bad_request", `at most ${MAX_LABELS} labels`);
  }
  const seen = new Set<number>();
  return v.map((raw, i) => {
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
      throw new RpcError("bad_request", `labels[${i}] must be an object`);
    }
    const o = raw as Record<string, unknown>;
    if (typeof o.id !== "number" || !Number.isInteger(o.id) || o.id < 0) {
      throw new RpcError(
        "bad_request",
        `labels[${i}].id must be a non-negative integer`,
      );
    }
    if (seen.has(o.id)) {
      throw new RpcError("bad_request", `duplicate label id ${o.id}`);
    }
    seen.add(o.id);
    if (
      typeof o.text !== "string" ||
      o.text.trim() === "" ||
      o.text.length > 200
    ) {
      throw new RpcError(
        "bad_request",
        `labels[${i}].text must be a non-empty string`,
      );
    }
    const conversations = o.conversations ?? [];
    if (
      !Array.isArray(conversations) ||
      conversations.length > MAX_LABEL_CONVERSATIONS ||
      conversations.some(
        (c) => typeof c !== "string" || c === "" || c.length > 128,
      )
    ) {
      throw new RpcError(
        "bad_request",
        `labels[${i}].conversations must be a string array`,
      );
    }
    const offset = o.offset === undefined ? 0 : Number(o.offset);
    const createTime = o.createTime === undefined ? 0 : Number(o.createTime);
    if (!Number.isFinite(offset) || !Number.isFinite(createTime)) {
      throw new RpcError(
        "bad_request",
        `labels[${i}] has an invalid offset or createTime`,
      );
    }
    return {
      id: o.id,
      text: o.text,
      textKey: optionalString(o.textKey) ?? "",
      conversations: conversations as string[],
      color: optionalString(o.color) ?? "",
      offset,
      emoji: optionalString(o.emoji) ?? "",
      createTime,
    };
  });
}

function autoDeleteTtl(v: unknown): AutoDeleteTtl {
  if (
    typeof v !== "number" ||
    !Number.isInteger(v) ||
    !(AUTO_DELETE_TTLS as readonly number[]).includes(v)
  ) {
    throw new RpcError(
      "bad_request",
      "ttl must be 0, 86400000, 604800000 or 1209600000",
    );
  }
  return v as AutoDeleteTtl;
}

const MAX_STYLE_RUNS = 200;
const MAX_QUICK_MESSAGE_KEYWORD = 50;
const MAX_QUICK_MESSAGE_TITLE = 2000;

// Styled text runs. The payload is passed to zca-js as-is after shape
// validation; an unknown style code is a client bug, not a silent drop.
function styleRuns(v: unknown): StyleRun[] | undefined {
  if (v === undefined) return undefined;
  if (!Array.isArray(v)) {
    throw new RpcError("bad_request", "styles must be an array");
  }
  if (v.length > MAX_STYLE_RUNS) {
    throw new RpcError("bad_request", `at most ${MAX_STYLE_RUNS} style runs`);
  }
  return v.map((raw, i) => {
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
      throw new RpcError("bad_request", `styles[${i}] must be an object`);
    }
    const o = raw as Record<string, unknown>;
    if (typeof o.start !== "number" || !Number.isInteger(o.start) || o.start < 0) {
      throw new RpcError(
        "bad_request",
        `styles[${i}].start must be a non-negative integer`,
      );
    }
    if (typeof o.len !== "number" || !Number.isInteger(o.len) || o.len <= 0) {
      throw new RpcError(
        "bad_request",
        `styles[${i}].len must be a positive integer`,
      );
    }
    if (
      typeof o.st !== "string" ||
      !(TEXT_STYLE_CODES as readonly string[]).includes(o.st)
    ) {
      throw new RpcError("bad_request", `styles[${i}].st is not a text style`);
    }
    const indent =
      o.indentSize === undefined ? undefined : Number(o.indentSize);
    if (
      indent !== undefined &&
      (!Number.isInteger(indent) || indent < 1 || indent > 10)
    ) {
      throw new RpcError(
        "bad_request",
        `styles[${i}].indentSize must be an integer 1..10`,
      );
    }
    return {
      start: o.start,
      len: o.len,
      st: o.st as TextStyleCode,
      ...(o.st === "ind_$" && indent !== undefined
        ? { indentSize: indent }
        : {}),
    };
  });
}

function urgencyOf(v: unknown): Urgency | undefined {
  if (v === undefined) return undefined;
  if (typeof v !== "string" || !(URGENCIES as readonly string[]).includes(v)) {
    throw new RpcError(
      "bad_request",
      "urgency must be default|important|urgent",
    );
  }
  return v as Urgency;
}

// Per-message TTL in ms; 0/absent means no self-destruct. This is not the
// per-conversation auto-delete TTL (see autoDeleteTtl).
function messageTtl(v: unknown): number | undefined {
  if (v === undefined || v === 0) return undefined;
  if (
    typeof v !== "number" ||
    !Number.isInteger(v) ||
    v < 0 ||
    v > MAX_MESSAGE_TTL_MS
  ) {
    throw new RpcError(
      "bad_request",
      `ttl must be an integer 0..${MAX_MESSAGE_TTL_MS}`,
    );
  }
  return v;
}

function httpUrl(v: unknown, name: string): string {
  const value = requiredString(v, name);
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new RpcError("bad_request", `${name} must be a URL`);
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new RpcError("bad_request", `${name} must be http(s)`);
  }
  return value;
}

function positiveInt(v: unknown, name: string, max = Number.MAX_SAFE_INTEGER): number {
  if (
    typeof v !== "number" ||
    !Number.isInteger(v) ||
    v <= 0 ||
    v > max
  ) {
    throw new RpcError("bad_request", `${name} must be a positive integer`);
  }
  return v;
}

function quickMessageDraft(
  params: Record<string, unknown>,
  media?: { name: string; path: string },
): QuickMessageDraft {
  const keyword = requiredString(params.keyword, "keyword");
  const title = requiredString(params.title, "title");
  if (keyword.length > MAX_QUICK_MESSAGE_KEYWORD) {
    throw new RpcError(
      "bad_request",
      `keyword must be at most ${MAX_QUICK_MESSAGE_KEYWORD} characters`,
    );
  }
  if (title.length > MAX_QUICK_MESSAGE_TITLE) {
    throw new RpcError(
      "bad_request",
      `title must be at most ${MAX_QUICK_MESSAGE_TITLE} characters`,
    );
  }
  return {
    keyword,
    title,
    ...(media !== undefined ? { media } : {}),
  };
}

// Quick-message media is optional: a mediaStream upload is taken only when
// the caller sent one, and the upload is discarded by the handler.
async function takeQuickMedia(
  ctx: ChannelContext,
  params: Record<string, unknown>,
): Promise<
  { name: string; path: string; upload: { filePath: string } } | undefined
> {
  if (params.mediaStream === undefined) return undefined;
  const stream = Number(params.mediaStream);
  if (!Number.isInteger(stream) || stream <= 0) {
    throw new RpcError("bad_request", "mediaStream must be a positive integer");
  }
  const upload = await ctx.channel.takeUpload(stream);
  return {
    name: optionalString(params.mediaName) ?? "quick-message.jpg",
    path: upload.filePath,
    upload,
  };
}

export function registerAccountMethods(
  server: TunnelServer,
  opts: { fake: boolean },
) {
  server.registerMethods("account", {
    sync: async (ctx: ChannelContext, params) => {
      const slot = slotOf(ctx);
      if (
        params.sinceSeq !== undefined &&
        (typeof params.sinceSeq !== "number" ||
          !Number.isInteger(params.sinceSeq) ||
          params.sinceSeq < 0)
      ) {
        throw new RpcError("bad_request", "sinceSeq must be an integer >= 0");
      }
      const sinceSeq = Number(params.sinceSeq ?? 0);
      const latestSeq = ctx.store.latestSeq(slot);
      const minSeq = ctx.store.minSeq(slot);
      const reset =
        sinceSeq <= 0 ||
        sinceSeq > latestSeq ||
        (minSeq > 0 && sinceSeq < minSeq - 1);
      // Cap each page at 500 events; the client loops while `more`.
      let events = reset
        ? ctx.store.eventsSince(slot, 0)
        : ctx.store.eventsSince(slot, sinceSeq);
      let more = false;
      if (events.length > 500) {
        events = events.slice(0, 500);
        more = true;
      }
      return {
        events: events.map((e) => ({
          event: e.type,
          seq: e.seq,
          data: JSON.parse(e.data_json),
        })),
        latestSeq,
        reset,
        more,
      };
    },

    "threads.list": async (ctx: ChannelContext, params) => {
      const slot = slotOf(ctx);
      const rows = ctx.store.listThreads(slot);
      return {
        threads: rows.map(
          (r) =>
            ctx.accounts.threadWithLast(
              slot,
              r.thread_id as string,
              r.type as ThreadType,
            )!,
        ),
      };
    },

    "messages.list": async (ctx: ChannelContext, params) => {
      const slot = slotOf(ctx);
      const limit = Math.min(Number(params.limit ?? 50), 100);
      const before = params.before as { ts?: unknown; id?: unknown } | undefined;
      const cursor =
        before !== undefined && before.ts !== undefined && before.id !== undefined
          ? { ts: Number(before.ts), id: String(before.id) }
          : undefined;
      // Fetch one extra row to compute hasMore; page stays newest-first.
      const rows = ctx.store.listMessages(
        slot,
        String(params.threadId),
        String(params.threadType),
        limit + 1,
        cursor,
      );
      const { rowToRecord } = await import("../accounts/manager.ts");
      let hasMore = rows.length > limit;
      if (!hasMore && String(params.threadType) === "group") {
        // Past local history: pull older group messages from Zalo, then
        // re-read (the fetched rows may fill this page's tail too).
        const more = await ctx.accounts.maybeFetchGroupHistory(
          slot,
          String(params.threadId),
          limit,
        );
        const again = ctx.store.listMessages(
          slot,
          String(params.threadId),
          String(params.threadType),
          limit + 1,
          cursor,
        );
        hasMore = again.length > limit || more;
        return {
          messages: again.slice(0, limit).map((r) => rowToRecord(r)),
          hasMore,
        };
      }
      return {
        messages: rows.slice(0, limit).map((r) => rowToRecord(r)),
        hasMore,
      };
    },

    "messages.sendText": async (ctx: ChannelContext, params) => {
      return ctx.accounts.sendText(
        slotOf(ctx),
        String(params.threadId),
        tt(params.threadType),
        optionalString(params.cliId) ?? "",
        String(params.text),
        // quote is {raw}: the decrypted raw object of the quoted message.
        {
          // quote is {raw} when the caller already holds the decrypted
          // wire object, or {msgId} to resolve it from the store
          // (sealed records cannot hand raw back to the client).
          quote:
            params.quote !== undefined
              ? {
                  raw:
                    (params.quote as { raw?: unknown }).raw ??
                    ctx.store.messageRef(
                      slotOf(ctx),
                      String((params.quote as { msgId?: string }).msgId),
                    ),
                }
              : undefined,
          mentions: params.mentions as never,
          styles: styleRuns(params.styles),
          urgency: urgencyOf(params.urgency),
          ttl: messageTtl(params.ttl),
        },
      );
    },

    "messages.sendMedia": async (ctx: ChannelContext, params) => {
      const stream = Number(params.stream);
      const slot = slotOf(ctx);
      const upload = await ctx.channel.takeUpload(stream);
      try {
        const kind = String(params.kind);
        if (!["image", "video", "file", "voice", "gif"].includes(kind)) {
          throw new RpcError("bad_request", "invalid kind");
        }
        const urgency = urgencyOf(params.urgency);
        // zca-js sendVoice/sendVideo have no urgency field; refuse it
        // rather than silently sending a normal-priority message.
        if (
          urgency !== undefined &&
          (kind === "voice" || kind === "video")
        ) {
          throw new RpcError(
            "not_supported",
            `urgency is not supported for ${kind} attachments`,
          );
        }
        const ttl = messageTtl(params.ttl);
        return await ctx.accounts.sendMedia(
          slot,
          String(params.threadId),
          tt(params.threadType),
          optionalString(params.cliId) ?? "",
          kind as "image" | "video" | "file" | "voice" | "gif",
          {
            name: String(params.name ?? "file"),
            path: upload.filePath,
          },
          params.caption === undefined
            ? undefined
            : String(params.caption),
          ttl !== undefined || urgency !== undefined
            ? {
                ...(ttl !== undefined ? { ttl } : {}),
                ...(urgency !== undefined ? { urgency } : {}),
              }
            : undefined,
        );
      } finally {
        ctx.server.discardUpload(upload);
      }
    },

    "messages.sendSticker": async (ctx: ChannelContext, params) => {
      return ctx.accounts.sendSticker(
        slotOf(ctx),
        String(params.threadId),
        tt(params.threadType),
        optionalString(params.cliId) ?? "",
        params.sticker as never,
      );
    },

    "messages.sendCard": async (ctx: ChannelContext, params) => {
      const ttl = params.ttl;
      if (
        ttl !== undefined &&
        (typeof ttl !== "number" || !Number.isFinite(ttl) || ttl < 0)
      ) {
        throw new RpcError("bad_request", "ttl must be a number >= 0");
      }
      const phoneNumber = optionalString(params.phoneNumber);
      return ctx.accounts.sendCard(
        slotOf(ctx),
        requiredString(params.threadId, "threadId"),
        tt(params.threadType),
        String(params.cliId ?? ""),
        {
          userId: requiredString(params.userId, "userId"),
          ...(phoneNumber !== undefined ? { phoneNumber } : {}),
          ...(ttl !== undefined ? { ttl } : {}),
        },
      );
    },

    // ---- link preview and link messages ----

    "messages.parseLink": async (ctx: ChannelContext, params) => {
      return {
        preview: await ctx.accounts.parseLink(
          slotOf(ctx),
          httpUrl(params.link, "link"),
        ),
      };
    },

    "messages.sendLink": async (ctx: ChannelContext, params) => {
      const msg = optionalString(params.msg);
      const ttl = messageTtl(params.ttl);
      return ctx.accounts.sendLink(
        slotOf(ctx),
        requiredString(params.threadId, "threadId"),
        tt(params.threadType),
        optionalString(params.cliId) ?? "",
        {
          link: httpUrl(params.link, "link"),
          ...(msg !== undefined ? { msg } : {}),
          ...(ttl !== undefined ? { ttl } : {}),
        },
      );
    },

    // ---- bank cards and accounts ----

    "messages.sendBankCard": async (ctx: ChannelContext, params) => {
      const holderName = optionalString(params.holderName);
      return ctx.accounts.sendBankCard(
        slotOf(ctx),
        requiredString(params.threadId, "threadId"),
        tt(params.threadType),
        optionalString(params.cliId) ?? "",
        {
          bin: positiveInt(params.bin, "bin"),
          accountNumber: requiredString(params.accountNumber, "accountNumber"),
          ...(holderName !== undefined ? { holderName } : {}),
        },
      );
    },

    "banks.list": async (ctx: ChannelContext) => {
      return { banks: await ctx.accounts.bankList(slotOf(ctx)) };
    },

    "banks.accounts": async (ctx: ChannelContext, params) => {
      const page = params.page === undefined ? 0 : Number(params.page);
      if (!Number.isInteger(page) || page < 0) {
        throw new RpcError("bad_request", "page must be an integer >= 0");
      }
      const limit = params.limit === undefined ? 20 : Number(params.limit);
      if (!Number.isInteger(limit) || limit < 1 || limit > 50) {
        throw new RpcError("bad_request", "limit must be an integer 1..50");
      }
      return ctx.accounts.bankAccounts(slotOf(ctx), page, limit);
    },

    // ---- quick messages ----

    "quickMessages.list": async (ctx: ChannelContext) => {
      return ctx.accounts.quickMessages(slotOf(ctx));
    },

    "quickMessages.add": async (ctx: ChannelContext, params) => {
      const media = await takeQuickMedia(ctx, params);
      try {
        return await ctx.accounts.addQuickMessage(
          slotOf(ctx),
          quickMessageDraft(params, media),
        );
      } finally {
        if (media !== undefined) ctx.server.discardUpload(media.upload);
      }
    },

    "quickMessages.update": async (ctx: ChannelContext, params) => {
      const media = await takeQuickMedia(ctx, params);
      try {
        return await ctx.accounts.updateQuickMessage(
          slotOf(ctx),
          positiveInt(params.id, "id"),
          quickMessageDraft(params, media),
        );
      } finally {
        if (media !== undefined) ctx.server.discardUpload(media.upload);
      }
    },

    "quickMessages.remove": async (ctx: ChannelContext, params) => {
      if (!Array.isArray(params.ids) || params.ids.length === 0) {
        throw new RpcError("bad_request", "ids must be a non-empty array");
      }
      if (params.ids.length > 100) {
        throw new RpcError("bad_request", "at most 100 ids");
      }
      const ids = [
        ...new Set(params.ids.map((id, i) => positiveInt(id, `ids[${i}]`))),
      ];
      return ctx.accounts.removeQuickMessages(slotOf(ctx), ids);
    },

    "stickers.search": async (ctx: ChannelContext, params) => {
      return {
        stickers: await ctx.accounts
          .gateway(slotOf(ctx))
          .searchStickers(String(params.query ?? "")),
      };
    },

    "stickers.category": async (ctx: ChannelContext, params) => {
      const cateId = positiveInt(params.cateId, "cateId");
      const gw = ctx.accounts.gateway(slotOf(ctx));
      return {
        stickers: gw.stickerCategory ? await gw.stickerCategory(cateId) : [],
      };
    },

    // ---- Pins, Group Board, Polls, Notes & Reminders ----
    "pins.list": async (ctx: ChannelContext, params) => {
      const gw = ctx.accounts.gateway(slotOf(ctx));
      if (!gw.listPins) throw new RpcError("not_supported", "pins not supported");
      return gw.listPins(
        requiredString(params.threadId, "threadId"),
        tt(params.threadType),
      );
    },

    "board.list": async (ctx: ChannelContext, params) => {
      const gw = ctx.accounts.gateway(slotOf(ctx));
      if (!gw.listBoard) throw new RpcError("not_supported", "board not supported");
      const page =
        params.page === undefined ? 1 : positiveInt(params.page, "page");
      const count =
        params.count === undefined
          ? 20
          : Math.min(50, positiveInt(params.count, "count"));
      return {
        items: await gw.listBoard(
          requiredString(params.groupId, "groupId"),
          page,
          count,
        ),
      };
    },

    "pins.pinMessage": async (ctx: ChannelContext, params) => {
      const slot = slotOf(ctx);
      const gw = ctx.accounts.gateway(slot);
      if (!gw.pinMessage) {
        throw new RpcError("not_supported", "pin message not supported");
      }
      const threadId = requiredString(params.threadId, "threadId");
      const threadType = tt(params.threadType);
      const msgId = requiredString(params.msgId, "msgId");
      const res = await gw.pinMessage(threadId, threadType, {
        msgId,
        cliMsgId:
          typeof params.cliMsgId === "string" ? params.cliMsgId : undefined,
        senderId: String(params.senderId ?? ""),
        senderName: String(params.senderName ?? ""),
        title: String(params.title ?? ""),
        kind: (typeof params.kind === "string" ? params.kind : "text") as never,
        thumbUrl:
          typeof params.thumbUrl === "string" ? params.thumbUrl : undefined,
        href: typeof params.href === "string" ? params.href : undefined,
        raw: ctx.store.messageRef(slot, msgId),
      });
      ctx.server.broadcastAccount(slot, "board.updated", {
        threadId,
        threadType,
      });
      return res;
    },

    "pins.pinItem": async (ctx: ChannelContext, params) => {
      const slot = slotOf(ctx);
      const gw = ctx.accounts.gateway(slot);
      if (!gw.pinBoardItem) {
        throw new RpcError("not_supported", "pin item not supported");
      }
      const groupId = requiredString(params.groupId, "groupId");
      const topicId = requiredString(params.topicId, "topicId");
      const topicType = Number(params.topicType ?? 3);
      await gw.pinBoardItem(groupId, topicId, topicType);
      ctx.server.broadcastAccount(slot, "board.updated", {
        threadId: groupId,
        threadType: "group",
      });
      return { ok: true };
    },

    "pins.unpin": async (ctx: ChannelContext, params) => {
      const slot = slotOf(ctx);
      const gw = ctx.accounts.gateway(slot);
      if (!gw.unpinTopic) {
        throw new RpcError("not_supported", "unpin not supported");
      }
      const threadId = requiredString(params.threadId, "threadId");
      const threadType = tt(params.threadType);
      const topicId = requiredString(params.topicId, "topicId");
      const topicType = Number(params.topicType ?? 2);
      const res = await gw.unpinTopic(threadId, threadType, topicId, topicType);
      ctx.server.broadcastAccount(slot, "board.updated", {
        threadId,
        threadType,
      });
      return res;
    },

    "polls.create": async (ctx: ChannelContext, params) => {
      const slot = slotOf(ctx);
      const gw = ctx.accounts.gateway(slot);
      if (!gw.createPoll) {
        throw new RpcError("not_supported", "polls not supported");
      }
      const groupId = requiredString(params.groupId, "groupId");
      const question = requiredString(params.question, "question").trim();
      const rawOpts = Array.isArray(params.options) ? params.options : [];
      const options = [
        ...new Set(
          rawOpts.map((o) => String(o ?? "").trim()).filter((o) => o.length > 0),
        ),
      ];
      if (question.length === 0 || question.length > 200) {
        throw new RpcError("bad_request", "question must be 1..200 chars");
      }
      if (options.length < 2 || options.length > 30) {
        throw new RpcError("bad_request", "poll requires 2..30 unique options");
      }
      const poll = await gw.createPoll(groupId, {
        question,
        options,
        expiredTime:
          typeof params.expiredTime === "number" ? params.expiredTime : 0,
        allowMultiChoices: params.allowMultiChoices !== false,
        allowAddNewOption: params.allowAddNewOption !== false,
        hideVotePreview: params.hideVotePreview === true,
        isAnonymous: params.isAnonymous === true,
        pin: params.pin === true,
      });
      if (params.pin === true) {
        ctx.server.broadcastAccount(slot, "board.updated", {
          threadId: groupId,
          threadType: "group",
        });
      }
      return { poll };
    },

    "polls.detail": async (ctx: ChannelContext, params) => {
      const gw = ctx.accounts.gateway(slotOf(ctx));
      if (!gw.pollDetail) {
        throw new RpcError("not_supported", "polls not supported");
      }
      const pollId = positiveInt(params.pollId, "pollId");
      const groupId =
        typeof params.groupId === "string" ? params.groupId : undefined;
      return { poll: await gw.pollDetail(pollId, groupId) };
    },

    "polls.vote": async (ctx: ChannelContext, params) => {
      const gw = ctx.accounts.gateway(slotOf(ctx));
      if (!gw.votePoll) {
        throw new RpcError("not_supported", "polls not supported");
      }
      const pollId = positiveInt(params.pollId, "pollId");
      const rawIds = Array.isArray(params.optionIds) ? params.optionIds : [];
      const optionIds = rawIds
        .map((x) => Number(x))
        .filter((x) => Number.isSafeInteger(x) && x >= 0);
      const groupId =
        typeof params.groupId === "string" ? params.groupId : undefined;
      return { poll: await gw.votePoll(pollId, optionIds, groupId) };
    },

    "polls.addOption": async (ctx: ChannelContext, params) => {
      const gw = ctx.accounts.gateway(slotOf(ctx));
      if (!gw.addPollOption) {
        throw new RpcError("not_supported", "polls not supported");
      }
      const pollId = positiveInt(params.pollId, "pollId");
      const content = requiredString(params.content, "content").trim();
      const rawIds = Array.isArray(params.votedOptionIds)
        ? params.votedOptionIds
        : [];
      const votedOptionIds = rawIds
        .map((x) => Number(x))
        .filter((x) => Number.isSafeInteger(x) && x >= 0);
      const voteNew = params.voteNew !== false;
      const groupId =
        typeof params.groupId === "string" ? params.groupId : undefined;
      return {
        poll: await gw.addPollOption(
          pollId,
          content,
          votedOptionIds,
          voteNew,
          groupId,
        ),
      };
    },

    "polls.lock": async (ctx: ChannelContext, params) => {
      const gw = ctx.accounts.gateway(slotOf(ctx));
      if (!gw.lockPoll) {
        throw new RpcError("not_supported", "polls not supported");
      }
      const pollId = positiveInt(params.pollId, "pollId");
      const groupId =
        typeof params.groupId === "string" ? params.groupId : undefined;
      return { poll: await gw.lockPoll(pollId, groupId) };
    },

    "polls.share": async (ctx: ChannelContext, params) => {
      const gw = ctx.accounts.gateway(slotOf(ctx));
      if (!gw.sharePoll) {
        throw new RpcError("not_supported", "polls not supported");
      }
      await gw.sharePoll(positiveInt(params.pollId, "pollId"));
      return { ok: true };
    },

    "notes.create": async (ctx: ChannelContext, params) => {
      const slot = slotOf(ctx);
      const gw = ctx.accounts.gateway(slot);
      if (!gw.createNote) {
        throw new RpcError("not_supported", "notes not supported");
      }
      const groupId = requiredString(params.groupId, "groupId");
      const title = requiredString(params.title, "title").trim();
      const pin = params.pin === true;
      const note = await gw.createNote(groupId, title, pin);
      if (pin) {
        ctx.server.broadcastAccount(slot, "board.updated", {
          threadId: groupId,
          threadType: "group",
        });
      }
      return { note };
    },

    "notes.edit": async (ctx: ChannelContext, params) => {
      const slot = slotOf(ctx);
      const gw = ctx.accounts.gateway(slot);
      if (!gw.editNote) {
        throw new RpcError("not_supported", "notes not supported");
      }
      const groupId = requiredString(params.groupId, "groupId");
      const topicId = requiredString(params.topicId, "topicId");
      const title = requiredString(params.title, "title").trim();
      const pin = params.pin === true;
      const note = await gw.editNote(groupId, topicId, title, pin);
      ctx.server.broadcastAccount(slot, "board.updated", {
        threadId: groupId,
        threadType: "group",
      });
      return { note };
    },

    "reminders.list": async (ctx: ChannelContext, params) => {
      const gw = ctx.accounts.gateway(slotOf(ctx));
      if (!gw.listReminders) {
        throw new RpcError("not_supported", "reminders not supported");
      }
      const page =
        params.page === undefined ? 1 : positiveInt(params.page, "page");
      const count =
        params.count === undefined
          ? 20
          : Math.min(50, positiveInt(params.count, "count"));
      return {
        reminders: await gw.listReminders(
          requiredString(params.threadId, "threadId"),
          tt(params.threadType),
          page,
          count,
        ),
      };
    },

    "reminders.create": async (ctx: ChannelContext, params) => {
      const slot = slotOf(ctx);
      const gw = ctx.accounts.gateway(slot);
      if (!gw.createReminder) {
        throw new RpcError("not_supported", "reminders not supported");
      }
      const threadId = requiredString(params.threadId, "threadId");
      const threadType = tt(params.threadType);
      const title = requiredString(params.title, "title").trim();
      const startTime =
        typeof params.startTime === "number" && Number.isFinite(params.startTime)
          ? params.startTime
          : Date.now() + 3600_000;
      const repeat =
        typeof params.repeat === "number" && params.repeat >= 0 && params.repeat <= 3
          ? params.repeat
          : 0;
      const emoji = typeof params.emoji === "string" ? params.emoji : "⏰";
      const reminder = await gw.createReminder(threadId, threadType, {
        title,
        emoji,
        startTime,
        repeat,
      });
      ctx.server.broadcastAccount(slot, "board.updated", {
        threadId,
        threadType,
      });
      return { reminder };
    },

    "reminders.edit": async (ctx: ChannelContext, params) => {
      const slot = slotOf(ctx);
      const gw = ctx.accounts.gateway(slot);
      if (!gw.editReminder) {
        throw new RpcError("not_supported", "reminders not supported");
      }
      const threadId = requiredString(params.threadId, "threadId");
      const threadType = tt(params.threadType);
      const id = requiredString(params.id, "id");
      const title = requiredString(params.title, "title").trim();
      const startTime =
        typeof params.startTime === "number" && Number.isFinite(params.startTime)
          ? params.startTime
          : Date.now() + 3600_000;
      const repeat =
        typeof params.repeat === "number" && params.repeat >= 0 && params.repeat <= 3
          ? params.repeat
          : 0;
      const emoji = typeof params.emoji === "string" ? params.emoji : "⏰";
      const reminder = await gw.editReminder(threadId, threadType, {
        id,
        title,
        emoji,
        startTime,
        repeat,
      });
      ctx.server.broadcastAccount(slot, "board.updated", {
        threadId,
        threadType,
      });
      return { reminder };
    },

    "reminders.remove": async (ctx: ChannelContext, params) => {
      const slot = slotOf(ctx);
      const gw = ctx.accounts.gateway(slot);
      if (!gw.removeReminder) {
        throw new RpcError("not_supported", "reminders not supported");
      }
      const threadId = requiredString(params.threadId, "threadId");
      const threadType = tt(params.threadType);
      const id = requiredString(params.id, "id");
      await gw.removeReminder(threadId, threadType, id);
      ctx.server.broadcastAccount(slot, "board.updated", {
        threadId,
        threadType,
      });
      return { ok: true };
    },

    "messages.react": async (ctx: ChannelContext, params) => {
      await ctx.accounts.react(
        slotOf(ctx),
        String(params.msgId),
        String(params.threadId),
        tt(params.threadType),
        String(params.icon),
      );
      return { ok: true };
    },

    "messages.recall": async (ctx: ChannelContext, params) => {
      await ctx.accounts
        .gateway(slotOf(ctx))
        .recall(
          String(params.msgId),
          String(params.threadId),
          tt(params.threadType),
          ctx.store.messageRef(slotOf(ctx), String(params.msgId)),
        );
      return { ok: true };
    },

    "messages.delete": async (ctx: ChannelContext, params) => {
      await ctx.accounts.deleteMessage(
        slotOf(ctx),
        String(params.msgId),
        String(params.threadId),
        tt(params.threadType),
      );
      return { ok: true };
    },

    "messages.deleteForAll": async (ctx: ChannelContext, params) => {
      const threadType = tt(params.threadType);
      if (threadType !== "group") {
        throw new RpcError(
          "bad_request",
          "delete for everyone is group-only",
        );
      }
      await ctx.accounts.deleteForAll(
        slotOf(ctx),
        requiredString(params.msgId, "msgId"),
        requiredString(params.threadId, "threadId"),
        threadType,
      );
      return { ok: true };
    },

    "threads.markSeen": async (ctx: ChannelContext, params) => {
      const slot = slotOf(ctx);
      await ctx.accounts.markSeen(
        slot,
        String(params.threadId),
        tt(params.threadType),
      );
      return { ok: true };
    },

    "threads.setPinned": async (ctx: ChannelContext, params) => {
      await ctx.accounts.setPinned(
        slotOf(ctx),
        String(params.threadId),
        tt(params.threadType),
        params.pinned === true,
      );
      return { ok: true };
    },

    "threads.setMuted": async (ctx: ChannelContext, params) => {
      await ctx.accounts.setMuted(
        slotOf(ctx),
        String(params.threadId),
        tt(params.threadType),
        params.muted === true,
      );
      return { ok: true };
    },

    "threads.markUnread": async (ctx: ChannelContext, params) => {
      await ctx.accounts.markUnreadThread(
        slotOf(ctx),
        String(params.threadId),
        tt(params.threadType),
      );
      return { ok: true };
    },

    "threads.delete": async (ctx: ChannelContext, params) => {
      await ctx.accounts.deleteThread(
        slotOf(ctx),
        String(params.threadId),
        tt(params.threadType),
      );
      return { ok: true };
    },

    // ---- hidden conversations ----

    "hidden.list": async (ctx: ChannelContext) => {
      return ctx.accounts.hiddenList(slotOf(ctx));
    },

    "threads.setHidden": async (ctx: ChannelContext, params) => {
      await ctx.accounts.setHidden(
        slotOf(ctx),
        requiredString(params.threadId, "threadId"),
        tt(params.threadType),
        requiredBool(params.hidden, "hidden"),
      );
      return { ok: true };
    },

    // The PIN is forwarded to Zalo and never echoed, stored or logged.
    "hidden.setPin": async (ctx: ChannelContext, params) => {
      if (typeof params.pin !== "string" || !/^\d{4}$/.test(params.pin)) {
        throw new RpcError("bad_request", "pin must be 4 digits");
      }
      await ctx.accounts.setHiddenPin(slotOf(ctx), params.pin);
      return { ok: true };
    },

    "hidden.resetPin": async (ctx: ChannelContext) => {
      await ctx.accounts.resetHiddenPin(slotOf(ctx));
      return { ok: true };
    },

    // ---- archived conversations ----

    "archive.list": async (ctx: ChannelContext) => {
      return ctx.accounts.archiveList(slotOf(ctx));
    },

    "threads.setArchived": async (ctx: ChannelContext, params) => {
      const res = await ctx.accounts.setArchived(
        slotOf(ctx),
        requiredString(params.threadId, "threadId"),
        tt(params.threadType),
        requiredBool(params.archived, "archived"),
      );
      return { ok: true, ...res };
    },

    // ---- labels ----

    "labels.list": async (ctx: ChannelContext) => {
      return ctx.accounts.labelsList(slotOf(ctx));
    },

    "labels.update": async (ctx: ChannelContext, params) => {
      return ctx.accounts.updateLabels(
        slotOf(ctx),
        labelSet(params.labels),
        labelVersion(params.version),
      );
    },

    // ---- auto-delete ----

    "threads.autoDelete": async (ctx: ChannelContext) => {
      return ctx.accounts.autoDeleteChat(slotOf(ctx));
    },

    "threads.setAutoDelete": async (ctx: ChannelContext, params) => {
      await ctx.accounts.setAutoDelete(
        slotOf(ctx),
        requiredString(params.threadId, "threadId"),
        tt(params.threadType),
        autoDeleteTtl(params.ttl),
      );
      return { ok: true };
    },

    // ---- linked Zalo devices (read only) ----

    "account.linkedDevices": async (ctx: ChannelContext) => {
      return { devices: await ctx.accounts.linkedDevices(slotOf(ctx)) };
    },

    "threads.report": async (ctx: ChannelContext, params) => {
      const reason = reportReason(params.reason);
      const threadId = requiredString(params.threadId, "threadId");
      const threadType = tt(params.threadType);
      const gw = ctx.accounts.gateway(slotOf(ctx));
      if (reason === "other") {
        const content = optionalString(params.content);
        if (content === undefined) {
          throw new RpcError("bad_request", "content required for other");
        }
        return gw.sendReport(threadId, threadType, { reason, content });
      }
      return gw.sendReport(threadId, threadType, { reason });
    },

    "messages.forward": async (ctx: ChannelContext, params) => {
      const to = ((params.to as Record<string, unknown>[] | undefined) ?? []).map(
        (t) => ({
          threadId: String(t.threadId),
          threadType: tt(t.threadType),
        }),
      );
      await ctx.accounts.forwardMessage(
        slotOf(ctx),
        String(params.msgId),
        String(params.threadId),
        tt(params.threadType),
        to,
        params.raw === undefined ? undefined : String(params.raw),
      );
      return { ok: true };
    },

    "threads.typing": async (ctx: ChannelContext, params) => {
      await ctx.accounts
        .gateway(slotOf(ctx))
        .sendTyping(String(params.threadId), tt(params.threadType));
      return { ok: true };
    },

    "contacts.list": async (ctx: ChannelContext) => {
      return { contacts: await ctx.accounts.gateway(slotOf(ctx)).listFriends() };
    },

    "contacts.findPhone": async (ctx: ChannelContext, params) => {
      return {
        user: await ctx.accounts
          .gateway(slotOf(ctx))
          .findUserByPhone(phoneNumber(params.phone)),
      };
    },

    "contacts.findUsername": async (ctx: ChannelContext, params) => {
      return {
        user: await ctx.accounts
          .gateway(slotOf(ctx))
          .findUserByUsername(requiredString(params.username, "username")),
      };
    },

    "contacts.request.send": async (ctx: ChannelContext, params) => {
      await ctx.accounts.sendFriendRequest(
        slotOf(ctx),
        requiredString(params.uid, "uid"),
        optionalString(params.message) ?? "",
      );
      return { ok: true };
    },

    "contacts.request.status": async (ctx: ChannelContext, params) => {
      return {
        status: await ctx.accounts
          .gateway(slotOf(ctx))
          .friendRequestStatus(requiredString(params.uid, "uid")),
      };
    },

    "contacts.request.accept": async (ctx: ChannelContext, params) => {
      await ctx.accounts.acceptFriendRequest(
        slotOf(ctx),
        requiredString(params.uid, "uid"),
      );
      return { ok: true };
    },

    "contacts.request.reject": async (ctx: ChannelContext, params) => {
      await ctx.accounts.rejectFriendRequest(
        slotOf(ctx),
        requiredString(params.uid, "uid"),
      );
      return { ok: true };
    },

    "contacts.request.cancel": async (ctx: ChannelContext, params) => {
      await ctx.accounts.cancelFriendRequest(
        slotOf(ctx),
        requiredString(params.uid, "uid"),
      );
      return { ok: true };
    },

    "contacts.requests": async (ctx: ChannelContext) => {
      const gw = ctx.accounts.gateway(slotOf(ctx));
      const [received, sent] = await Promise.all([
        gw.receivedFriendRequests(),
        gw.sentFriendRequests(),
      ]);
      return { received, sent };
    },

    "contacts.recommendations": async (ctx: ChannelContext) => {
      return {
        users: await ctx.accounts
          .gateway(slotOf(ctx))
          .friendRecommendations(),
      };
    },

    "contacts.setAlias": async (ctx: ChannelContext, params) => {
      await ctx.accounts.setFriendAlias(
        slotOf(ctx),
        requiredString(params.uid, "uid"),
        requiredString(params.alias, "alias"),
      );
      return { ok: true };
    },

    "contacts.removeAlias": async (ctx: ChannelContext, params) => {
      await ctx.accounts.removeFriendAlias(
        slotOf(ctx),
        requiredString(params.uid, "uid"),
      );
      return { ok: true };
    },

    "contacts.remove": async (ctx: ChannelContext, params) => {
      await ctx.accounts.removeFriend(
        slotOf(ctx),
        requiredString(params.uid, "uid"),
      );
      return { ok: true };
    },

    "contacts.block": async (ctx: ChannelContext, params) => {
      await ctx.accounts.blockUser(
        slotOf(ctx),
        requiredString(params.uid, "uid"),
      );
      return { ok: true };
    },

    "contacts.unblock": async (ctx: ChannelContext, params) => {
      await ctx.accounts.unblockUser(
        slotOf(ctx),
        requiredString(params.uid, "uid"),
      );
      return { ok: true };
    },

    "contacts.online": async (ctx: ChannelContext) => {
      return {
        presence: await ctx.accounts.gateway(slotOf(ctx)).friendOnlines(),
      };
    },

    "contacts.lastOnline": async (ctx: ChannelContext, params) => {
      return ctx.accounts
        .gateway(slotOf(ctx))
        .lastOnline(requiredString(params.uid, "uid"));
    },

    "groups.list": async (ctx: ChannelContext) => {
      return { groups: await ctx.accounts.gateway(slotOf(ctx)).listGroups() };
    },

    "groups.info": async (ctx: ChannelContext, params) => {
      return {
        group: await ctx.accounts.groupInfoMembers(
          slotOf(ctx),
          String(params.groupId),
        ),
      };
    },

    "users.info": async (ctx: ChannelContext, params) => {
      const uids = (params.uids as string[] | undefined) ?? [];
      return { users: await ctx.accounts.usersGet(slotOf(ctx), uids) };
    },

    // Full-size avatar for the profile sheet: {uid} -> {url} ("" when Zalo
    // has none).
    "users.avatar": async (ctx: ChannelContext, params) => {
      if (typeof params.uid !== "string" || params.uid === "") {
        throw new RpcError("bad_request", "uid required");
      }
      return { url: await ctx.accounts.userAvatar(slotOf(ctx), params.uid) };
    },

    "media.fetch": async (ctx: ChannelContext, params) => {
      const url = String(params.url ?? "");
      const slot = slotOf(ctx);
      // Zalo-hosted media needs the account's cookies and browser UA, which
      // only the gateway holds. Public/CDN urls keep download() because they
      // may redirect and the gateway fetch uses redirect: "manual".
      let host: string | undefined;
      try {
        host = new URL(url).hostname;
      } catch {
        host = undefined;
      }
      const gatewayBacked =
        opts.fake || (host !== undefined && isZaloHost(host));
      const gw = gatewayBacked ? ctx.accounts.gateway(slot) : undefined;
      const hit = await fetchAndCache(ctx.store.dir, url, {
        slot,
        getVaultKey: () => ctx.accounts.vaultKey(slot),
        // fetchAndCache's gateway branch is gated on this flag; a real Zalo
        // host has to take it too, not just the fake gateway.
        fake: gatewayBacked,
        gatewayFetchToFile:
          gw !== undefined && gw.fetchMediaToFile !== undefined
            ? (u, outPath) => gw.fetchMediaToFile!(u, outPath)
            : undefined,
        gatewayFetch:
          gw !== undefined && gw.fetchMediaToFile === undefined
            ? (u) => gw.fetchMedia(u)
            : undefined,
      });
      const stream = await ctx.channel.sendBlob({ filePath: hit.path });
      return {
        stream,
        size: hit.size,
        contentType: hit.contentType,
        sealed: hit.sealed,
      };
    },

    // ---- voice & video calls ----

    "calls.active": async (ctx: ChannelContext) => {
      return { calls: ctx.accounts.calls.activeCalls(slotOf(ctx)) };
    },

    "calls.start": async (ctx: ChannelContext, params) => {
      const media = params.media;
      if (media !== "voice" && media !== "video") {
        throw new RpcError("bad_request", "media must be voice|video");
      }
      return ctx.accounts.calls.start(
        slotOf(ctx),
        requiredString(params.threadId, "threadId"),
        tt(params.threadType),
        media,
        ctx.channel.deviceId ?? "",
      );
    },

    "calls.accept": async (ctx: ChannelContext, params) => {
      return ctx.accounts.calls.accept(
        slotOf(ctx),
        requiredString(params.callId, "callId"),
        ctx.channel.deviceId ?? "",
      );
    },

    "calls.reject": async (ctx: ChannelContext, params) => {
      const scope = params.scope ?? "global";
      if (scope !== "local" && scope !== "global") {
        throw new RpcError("bad_request", "scope must be local|global");
      }
      return ctx.accounts.calls.reject(
        slotOf(ctx),
        requiredString(params.callId, "callId"),
        ctx.channel.deviceId ?? "",
        scope,
      );
    },

    "calls.hangup": async (ctx: ChannelContext, params) => {
      return ctx.accounts.calls.hangup(
        slotOf(ctx),
        requiredString(params.callId, "callId"),
        optionalString(params.reason),
      );
    },

    "calls.media.config": async (ctx: ChannelContext) => {
      slotOf(ctx);
      return ctx.accounts.calls.mediaConfig();
    },

    "calls.media.offer": async (ctx: ChannelContext, params) => {
      return ctx.accounts.calls.handleMediaOffer(
        slotOf(ctx),
        requiredString(params.callId, "callId"),
        ctx.channel.deviceId ?? "",
        requiredString(params.sdp, "sdp"),
      );
    },

    "calls.media.ice": async (ctx: ChannelContext, params) => {
      const candidate =
        params.candidate !== null &&
        typeof params.candidate === "object" &&
        !Array.isArray(params.candidate)
          ? (params.candidate as {
              candidate: string;
              sdpMid?: string | null;
              sdpMLineIndex?: number | null;
            })
          : null;
      if (!candidate || typeof candidate.candidate !== "string") {
        throw new RpcError("bad_request", "candidate.candidate is required");
      }
      return ctx.accounts.calls.handleMediaIce(
        slotOf(ctx),
        requiredString(params.callId, "callId"),
        candidate,
      );
    },

    "calls.groupState": async (ctx: ChannelContext, params) => {
      return ctx.accounts.calls.groupState(
        slotOf(ctx),
        requiredString(params.groupId, "groupId"),
      );
    },

    "calls.zaloSignal": async (ctx: ChannelContext, params) => {
      const payload =
        params.payload !== null &&
        typeof params.payload === "object" &&
        !Array.isArray(params.payload)
          ? (params.payload as Record<string, unknown>)
          : {};
      return ctx.accounts.calls.zaloSignal(
        slotOf(ctx),
        requiredString(params.callId, "callId"),
        requiredString(params.action, "action"),
        payload,
      );
    },

    ...extendedAccountMethods(),
  });
}
