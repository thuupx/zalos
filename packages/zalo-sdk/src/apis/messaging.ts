import { existsSync } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { basename, extname } from "node:path";
import imageSize from "image-size";
import { WS_CMD, WS_SUB_CMD } from "../core/constants.ts";
import type { ZaloContext } from "../core/context.ts";
import { md5Hex } from "../core/crypto.ts";
import { ZaloApiError } from "../core/errors.ts";
import type { ZaloHttpClient } from "../core/http.ts";
import type { SendSeenEventMessageParams } from "../models/compat.ts";
import type { AttachmentSource, AttachmentUploadResult, MessageContentInput } from "../models/entities.ts";
import { BinBankCard, CloudMessageSource, DestType, Reactions, TextStyle, ThreadType, Urgency } from "../models/enums.ts";
import type { GroupMessage, TMessage } from "../models/events.ts";
import type { ZaloListener } from "../ws/listener.ts";

const REACTION_RTYPE_MAP: Record<string, number> = {
  [Reactions.HAHA]: 0,
  [Reactions.LIKE]: 3,
  [Reactions.HEART]: 5,
  [Reactions.WOW]: 32,
  [Reactions.CRY]: 2,
  [Reactions.ANGRY]: 20,
  [Reactions.KISS]: 8,
  [Reactions.TEARS_OF_JOY]: 7,
  [Reactions.SHIT]: 66,
  [Reactions.ROSE]: 120,
  [Reactions.BROKEN_HEART]: 65,
  [Reactions.DISLIKE]: 4,
  [Reactions.LOVE]: 29,
  [Reactions.CONFUSED]: 51,
  [Reactions.WINK]: 45,
  [Reactions.FADE]: 121,
  [Reactions.SUN]: 67,
  [Reactions.BIRTHDAY]: 126,
  [Reactions.BOMB]: 127,
  [Reactions.OK]: 68,
  [Reactions.PEACE]: 69,
  [Reactions.THANKS]: 70,
  [Reactions.PUNCH]: 71,
  [Reactions.SHARE]: 72,
  [Reactions.PRAY]: 73,
  [Reactions.NO]: 131,
  [Reactions.BAD]: 132,
  [Reactions.LOVE_YOU]: 133,
  [Reactions.SAD]: 1,
  [Reactions.VERY_SAD]: 16,
  [Reactions.COOL]: 21,
  [Reactions.NERD]: 22,
  [Reactions.BIG_SMILE]: 23,
  [Reactions.SUNGLASSES]: 26,
  [Reactions.NEUTRAL]: 30,
  [Reactions.SAD_FACE]: 35,
  [Reactions.BYE]: 36,
  [Reactions.SLEEPY]: 38,
  [Reactions.WIPE]: 39,
  [Reactions.DIG]: 42,
  [Reactions.ANGUISH]: 44,
  [Reactions.HANDCLAP]: 46,
  [Reactions.ANGRY_FACE]: 47,
  [Reactions.F_CHAIR]: 48,
  [Reactions.L_CHAIR]: 49,
  [Reactions.R_CHAIR]: 50,
  [Reactions.SILENT]: 52,
  [Reactions.SURPRISE]: 53,
  [Reactions.EMBARRASSED]: 54,
  [Reactions.AFRAID]: 60,
  [Reactions.SAD2]: 61,
  [Reactions.BIG_LAUGH]: 62,
  [Reactions.RICH]: 63,
  [Reactions.BEER]: 99,
};

export function getClientMessageType(msgType: string): number {
  switch (msgType) {
    case "webchat":
      return 1;
    case "chat.voice":
      return 31;
    case "chat.photo":
      return 32;
    case "chat.sticker":
      return 36;
    case "chat.doodle":
      return 37;
    case "chat.recommended":
    case "chat.link":
      return 38;
    case "chat.location.new":
      return 43;
    case "chat.video.msg":
      return 44;
    case "share.file":
      return 46;
    case "chat.gif":
      return 49;
    default:
      return 1;
  }
}

function getExt(pathOrName: string): string {
  const e = extname(pathOrName).toLowerCase();
  return e.startsWith(".") ? e.slice(1) : e;
}

function stripUndefined<T extends Record<string, unknown>>(obj: T): T {
  for (const k of Object.keys(obj)) {
    if (obj[k] === undefined) delete obj[k];
  }
  return obj;
}

export class MessagingApi {
  constructor(
    private readonly http: ZaloHttpClient,
    private readonly ctx: ZaloContext,
    private readonly getListener?: () => ZaloListener,
  ) {}

  private sharefileSettings(): {
    max_file: number;
    max_size_share_file_v3: number;
    chunk_size_file: number;
    restricted_ext_file: string[];
  } {
    const features = (this.ctx.settings.features as Record<string, unknown> | undefined) ?? {};
    const sf = (features.sharefile as Record<string, unknown> | undefined) ?? {};
    return {
      max_file: Number(sf.max_file ?? 9),
      max_size_share_file_v3: Number(sf.max_size_share_file_v3 ?? 100),
      chunk_size_file: Number(sf.chunk_size_file ?? 5 * 1024 * 1024),
      restricted_ext_file: Array.isArray(sf.restricted_ext_file) ? (sf.restricted_ext_file as string[]) : [],
    };
  }

  private async readImageDimensions(
    source: AttachmentSource,
    bytes: Buffer,
  ): Promise<{ width: number; height: number; totalSize: number }> {
    if (typeof source === "string" && this.ctx.imageMetadataGetter) {
      const meta = await this.ctx.imageMetadataGetter(source);
      if (meta) {
        return {
          width: meta.width,
          height: meta.height,
          totalSize: meta.size ?? bytes.length,
        };
      }
    }
    if (typeof source === "object" && source.metadata) {
      return {
        width: source.metadata.width ?? 0,
        height: source.metadata.height ?? 0,
        totalSize: source.metadata.totalSize ?? bytes.length,
      };
    }
    try {
      const dims = imageSize(bytes);
      return {
        width: dims.width ?? 0,
        height: dims.height ?? 0,
        totalSize: bytes.length,
      };
    } catch {
      return { width: 0, height: 0, totalSize: bytes.length };
    }
  }

  /**
   * Chunked multipart attachment uploader (`photo_original/upload` for images,
   * `asyncfile/upload` + WebSocket `file_done`/`video_done` callback for videos/files).
   */
  async uploadAttachment(
    sources: AttachmentSource | AttachmentSource[],
    threadId: string,
    type: ThreadType = ThreadType.User,
  ): Promise<AttachmentUploadResult[]> {
    const list = Array.isArray(sources) ? sources : [sources];
    if (!list.length) throw new ZaloApiError("Missing sources");
    if (!threadId) throw new ZaloApiError("Missing threadId");

    const sf = this.sharefileSettings();
    if (list.length > sf.max_file) {
      throw new ZaloApiError(`Exceed maximum file count of ${sf.max_file}`);
    }

    const isGroup = type === ThreadType.Group;
    const typeParam = isGroup ? "11" : "2";
    const scopePrefix = isGroup ? "/api/group" : "/api/message";
    const chunkSize = sf.chunk_size_file;
    let clientId = Date.now();

    const results: AttachmentUploadResult[] = [];
    for (const source of list) {
      const isPath = typeof source === "string";
      if (isPath && !existsSync(source)) {
        throw new ZaloApiError(`File not found: ${source}`);
      }
      const fileName = isPath ? basename(source) : source.filename;
      const ext = getExt(fileName);
      if (sf.restricted_ext_file.includes(ext)) {
        throw new ZaloApiError(`File extension "${ext}" is not allowed`);
      }

      const buf = isPath ? await readFile(source) : Buffer.from(source.data);
      const totalSize = isPath ? (await stat(source)).size : (source.metadata?.totalSize ?? buf.length);
      if (totalSize > sf.max_size_share_file_v3 * 1024 * 1024) {
        throw new ZaloApiError(`File ${fileName} exceeds maximum size of ${sf.max_size_share_file_v3}MB`);
      }

      const fileType: "image" | "video" | "others" = ["jpg", "jpeg", "png", "webp"].includes(ext)
        ? "image"
        : ext === "mp4"
          ? "video"
          : "others";
      const uploadPath =
        fileType === "image"
          ? `${scopePrefix}/photo_original/upload`
          : `${scopePrefix}/asyncfile/upload`;
      const url = this.http.serviceUrl("file", uploadPath);

      const totalChunk = Math.max(1, Math.ceil(buf.length / chunkSize));
      const thisClientId = clientId++;
      const dims = fileType === "image" ? await this.readImageDimensions(source, buf) : undefined;
      const checksum = fileType === "image" ? undefined : md5Hex(buf);

      let uploadRes: AttachmentUploadResult | undefined;
      for (let chunkIdx = 0; chunkIdx < totalChunk; chunkIdx++) {
        const slice = buf.subarray(chunkIdx * chunkSize, (chunkIdx + 1) * chunkSize);
        const form = new FormData();
        form.append("chunkContent", new Blob([slice], { type: "application/octet-stream" }), fileName);

        const chunkParams: Record<string, unknown> = {
          ...(isGroup ? { grid: threadId } : { toid: threadId }),
          totalChunk,
          chunkId: chunkIdx + 1,
          fileName,
          clientId: thisClientId,
          totalSize,
          imei: this.ctx.imei,
          isE2EE: 0,
          jxl: 0,
        };

        const resData = await this.http.postMultipart<Record<string, unknown>>(
          url,
          chunkParams,
          form,
          { extraQuery: { type: typeParam } },
        );

        if (resData && String(resData.fileId ?? "") !== "-1" && String(resData.photoId ?? "") !== "-1") {
          if (fileType === "image" && resData.finished !== 0) {
            uploadRes = {
              fileType: "image",
              width: dims?.width ?? 0,
              height: dims?.height ?? 0,
              totalSize,
              finished: Number(resData.finished ?? 1),
              normalUrl: resData.normalUrl as string | undefined,
              hdUrl: resData.hdUrl as string | undefined,
              thumbUrl: resData.thumbUrl as string | undefined,
              photoId: String(resData.photoId ?? ""),
              fileName,
              clientFileId: Number(resData.clientFileId ?? thisClientId),
            };
          } else if ((fileType === "video" || fileType === "others") && resData.fileId) {
            const fileId = String(resData.fileId);
            if (typeof resData.url === "string") {
              uploadRes = {
                fileType,
                fileId,
                fileUrl: resData.url,
                totalSize,
                fileName,
                checksum,
                clientFileId: Number(resData.clientFileId ?? thisClientId),
              };
            } else {
              const wsData = await new Promise<Record<string, unknown>>((resolve) => {
                this.ctx.uploadCallbacks.set(fileId, resolve);
              });
              uploadRes = {
                fileType,
                fileId,
                fileUrl: String(wsData.url ?? ""),
                totalSize,
                fileName,
                checksum,
                clientFileId: Number(resData.clientFileId ?? thisClientId),
              };
            }
          }
        }
      }
      if (uploadRes) results.push(uploadRes);
    }
    return results;
  }

  /**
   * Sends text (with styles, mentions, urgency, quote, ttl) and/or attachments
   * (images, GIFs with upthumb, videos, files).
   */
  async sendMessage(
    message: string | MessageContentInput,
    threadId: string,
    type: ThreadType = ThreadType.User,
  ): Promise<{ message: { msgId: number | string } | null; attachment: Array<{ msgId: number | string }> }> {
    if (!threadId) throw new ZaloApiError("Missing threadId");
    const input: MessageContentInput = typeof message === "string" ? { msg: message } : { ...message };
    const attachments = input.attachments
      ? Array.isArray(input.attachments)
        ? input.attachments
        : [input.attachments]
      : [];

    if (!input.msg && attachments.length === 0) {
      throw new ZaloApiError("Missing message content");
    }

    const isGroup = type === ThreadType.Group;
    const out = {
      message: null as { msgId: number | string } | null,
      attachment: [] as Array<{ msgId: number | string }>,
    };

    const sendTextBody = async (text: string): Promise<{ msgId: number | string }> => {
      const mentionsFinal =
        isGroup && Array.isArray(input.mentions)
          ? input.mentions
              .filter((m) => m.pos >= 0 && m.uid && m.len > 0)
              .map((m) => ({
                pos: m.pos,
                uid: m.uid,
                len: m.len,
                type: m.uid === "-1" ? 1 : 0,
              }))
          : [];

      const q = input.quote;
      const basePath = isGroup ? "/api/group" : "/api/message";
      const serviceKey = isGroup ? "group" : "chat";
      const hasMentions = mentionsFinal.length > 0 && isGroup;
      const suffix = q ? "/quote" : isGroup ? (hasMentions ? "/mention" : "/sendmsg") : "/sms";
      const url = this.http.serviceUrl(serviceKey, `${basePath}${suffix}`);

      const params: Record<string, unknown> = q
        ? stripUndefined({
            toid: isGroup ? undefined : threadId,
            grid: isGroup ? threadId : undefined,
            message: text,
            clientId: Date.now(),
            mentionInfo: hasMentions ? JSON.stringify(mentionsFinal) : undefined,
            qmsgOwner: q.uidFrom,
            qmsgId: q.msgId,
            qmsgCliId: q.cliMsgId,
            qmsgType: getClientMessageType(String(q.msgType ?? "webchat")),
            qmsgTs: q.ts,
            qmsg: typeof q.content === "string" ? q.content : "",
            imei: isGroup ? undefined : this.ctx.imei,
            visibility: isGroup ? 0 : undefined,
            qmsgAttach: isGroup ? JSON.stringify(q.propertyExt ?? q.content ?? {}) : undefined,
            qmsgTTL: q.ttl,
            ttl: input.ttl ?? 0,
          })
        : stripUndefined({
            message: text,
            clientId: Date.now(),
            mentionInfo: hasMentions ? JSON.stringify(mentionsFinal) : undefined,
            imei: isGroup ? undefined : this.ctx.imei,
            ttl: input.ttl ?? 0,
            visibility: isGroup ? 0 : undefined,
            toid: isGroup ? undefined : threadId,
            grid: isGroup ? threadId : undefined,
          });

      if (input.styles?.length) {
        params.textProperties = JSON.stringify({
          styles: input.styles.map((s) =>
            stripUndefined({
              start: s.start,
              len: s.len,
              st:
                s.st === TextStyle.Indent
                  ? TextStyle.Indent.replace(/\$/g, `${s.indentSize ?? 1}0`)
                  : s.st,
            }),
          ),
          ver: 0,
        });
      }
      if (input.urgency === Urgency.Important || input.urgency === Urgency.Urgent) {
        params.metaData = { urgency: input.urgency };
      }
      return this.http.postEncrypted<{ msgId: number | string }>(url, params, { nretry: true });
    };

    if (attachments.length > 0) {
      const firstName =
        typeof attachments[0] === "string" ? attachments[0] : attachments[0]!.filename;
      const canBeCaption =
        attachments.length === 1 &&
        ["jpg", "jpeg", "png", "webp"].includes(getExt(firstName)) &&
        !input.quote;

      let caption = input.msg ?? "";
      if (!canBeCaption && caption.length > 0) {
        out.message = await sendTextBody(caption);
        caption = "";
      }

      const gifSources = attachments.filter(
        (s) => getExt(typeof s === "string" ? s : s.filename) === "gif",
      );
      const nonGifSources = attachments.filter(
        (s) => getExt(typeof s === "string" ? s : s.filename) !== "gif",
      );

      if (nonGifSources.length > 0) {
        const uploaded = await this.uploadAttachment(nonGifSources, threadId, type);
        const groupLayoutId = String(Date.now());
        const isMulti = uploaded.length > 1;
        let idx = 0;
        let cid = Date.now();
        for (const u of uploaded) {
          const scope = isGroup ? "/api/group" : "/api/message";
          if (u.fileType === "image") {
            const sendUrl = this.http.serviceUrl("file", `${scope}/photo_original/send`);
            const p = stripUndefined({
              photoId: u.photoId,
              clientId: String(cid++),
              desc: caption,
              width: u.width,
              height: u.height,
              toid: isGroup ? undefined : threadId,
              grid: isGroup ? threadId : undefined,
              rawUrl: u.normalUrl,
              hdUrl: u.hdUrl,
              thumbUrl: u.thumbUrl,
              oriUrl: isGroup ? u.normalUrl : undefined,
              normalUrl: isGroup ? undefined : u.normalUrl,
              hdSize: String(u.totalSize),
              zsource: -1,
              ttl: input.ttl ?? 0,
              jcp: '{"convertible":"jxl"}',
              groupLayoutId: isMulti ? groupLayoutId : undefined,
              isGroupLayout: isMulti ? 1 : undefined,
              idInGroup: isMulti ? idx++ : undefined,
              totalItemInGroup: isMulti ? uploaded.length : undefined,
              extMsgProp: isMulti
                ? `{"groupMediaMsg":{"groupLayoutId":"${groupLayoutId}"}}`
                : undefined,
              ...(input.urgency ? { metaData: { urgency: input.urgency } } : {}),
            });
            out.attachment.push(
              await this.http.postEncrypted<{ msgId: number | string }>(sendUrl, p, { nretry: true }),
            );
          } else {
            const sendUrl = this.http.serviceUrl("file", `${scope}/asyncfile/msg`);
            const p = stripUndefined({
              fileId: u.fileId,
              checksum: u.checksum,
              checksumSha: "",
              extention: getExt(u.fileName),
              totalSize: u.totalSize,
              fileName: u.fileName,
              clientId: u.clientFileId,
              fType: 1,
              fileCount: 0,
              fdata: "{}",
              toid: isGroup ? undefined : threadId,
              grid: isGroup ? threadId : undefined,
              fileUrl: u.fileUrl,
              zsource: -1,
              ttl: input.ttl ?? 0,
              ...(input.urgency ? { metaData: { urgency: input.urgency } } : {}),
            });
            out.attachment.push(
              await this.http.postEncrypted<{ msgId: number | string }>(sendUrl, p, { nretry: true }),
            );
          }
        }
      }

      for (const gif of gifSources) {
        const isPath = typeof gif === "string";
        const fileName = isPath ? basename(gif) : gif.filename;
        const buf = isPath ? await readFile(gif) : Buffer.from(gif.data);
        const dims = await this.readImageDimensions(gif, buf);

        const upthumbUrl = this.http.serviceUrl("file", "/api/message/upthumb");
        const thumbForm = new FormData();
        thumbForm.append("fileContent", new Blob([buf], { type: "image/png" }), "blob");
        const thumbRes = await this.http.postMultipart<{ url?: string }>(
          upthumbUrl,
          { clientId: Date.now(), imei: this.ctx.imei },
          thumbForm,
        );

        const gifForm = new FormData();
        gifForm.append("chunkContent", new Blob([buf], { type: "application/octet-stream" }), fileName);
        const gifUrl = this.http.serviceUrl("file", isGroup ? "/api/group/gif" : "/api/message/gif");
        const gifRes = await this.http.postMultipart<{ msgId: number | string }>(
          gifUrl,
          stripUndefined({
            clientId: String(Date.now()),
            fileName,
            totalSize: dims.totalSize,
            width: dims.width,
            height: dims.height,
            msg: caption,
            type: 1,
            ttl: input.ttl ?? 0,
            visibility: isGroup ? 0 : undefined,
            toid: isGroup ? undefined : threadId,
            grid: isGroup ? threadId : undefined,
            thumb: thumbRes?.url ?? "",
            checksum: md5Hex(buf),
            totalChunk: 1,
            chunkId: 1,
            ...(input.urgency ? { metaData: { urgency: input.urgency } } : {}),
          }),
          gifForm,
          { nretry: true, extraQuery: { type: "1" } },
        );
        out.attachment.push(gifRes);
      }

      return out;
    }

    out.message = await sendTextBody(input.msg);
    return out;
  }

  /** POST `{file[0]}/api/{message|group}/forward` with `msgType: 5`. */
  async sendVideo(
    options: {
      videoUrl: string;
      thumbnailUrl: string;
      duration?: number;
      width?: number;
      height?: number;
      msg?: string;
      ttl?: number;
      fileSize?: number;
    },
    threadId: string,
    type: ThreadType = ThreadType.User,
  ): Promise<{ msgId: number | string }> {
    let fileSize = options.fileSize ?? 0;
    if (!fileSize) {
      try {
        const head = await this.http.requestRaw(options.videoUrl, { method: "HEAD" });
        fileSize = Number(head.headers.get("content-length") ?? 0);
      } catch {
        fileSize = 0;
      }
    }
    const isGroup = type === ThreadType.Group;
    const url = this.http.serviceUrl("file", isGroup ? "/api/group/forward" : "/api/message/forward");
    return this.http.postEncrypted(
      url,
      stripUndefined({
        ...(isGroup ? { grid: threadId, visibility: 0 } : { toId: threadId }),
        clientId: String(Date.now()),
        ttl: options.ttl ?? 0,
        zsource: 704,
        msgType: 5,
        msgInfo: JSON.stringify({
          videoUrl: options.videoUrl,
          thumbUrl: options.thumbnailUrl,
          duration: options.duration ?? 0,
          width: options.width ?? 1280,
          height: options.height ?? 720,
          fileSize,
          properties: {
            color: -1,
            size: -1,
            type: 1003,
            subType: 0,
            ext: { sSrcType: -1, sSrcStr: "", msg_warning_type: 0 },
          },
          title: options.msg ?? "",
        }),
        imei: this.ctx.imei,
      }),
    );
  }

  /** POST `{file[0]}/api/{message|group}/forward` with `msgType: 3`. */
  async sendVoice(
    options: { voiceUrl: string; ttl?: number; fileSize?: number },
    threadId: string,
    type: ThreadType = ThreadType.User,
  ): Promise<{ msgId: number | string }> {
    let fileSize = options.fileSize ?? 0;
    if (!fileSize) {
      try {
        const head = await this.http.requestRaw(options.voiceUrl, { method: "HEAD" });
        fileSize = Number(head.headers.get("content-length") ?? 0);
      } catch {
        fileSize = 0;
      }
    }
    const isGroup = type === ThreadType.Group;
    const url = this.http.serviceUrl("file", isGroup ? "/api/group/forward" : "/api/message/forward");
    return this.http.postEncrypted(
      url,
      stripUndefined({
        ...(isGroup ? { grid: threadId, visibility: 0 } : { toId: threadId }),
        ttl: options.ttl ?? 0,
        zsource: -1,
        msgType: 3,
        clientId: String(Date.now()),
        msgInfo: JSON.stringify({
          voiceUrl: options.voiceUrl,
          m4aUrl: options.voiceUrl,
          fileSize,
        }),
        imei: this.ctx.imei,
      }),
    );
  }

  /** POST `{file[0]}/api/{message|group}/forward` with `msgType: 6`. */
  async sendCard(
    options: { userId: string; phoneNumber?: string; ttl?: number; qrCodeUrl?: string },
    threadId: string,
    type: ThreadType = ThreadType.User,
  ): Promise<{ msgId: number | string }> {
    let qrCodeUrl = options.qrCodeUrl;
    if (!qrCodeUrl) {
      try {
        const qrUrl = this.http.serviceUrl("friend", "/api/friend/mget-qr");
        const qrs = await this.http.postEncrypted<Record<string, string>>(qrUrl, {
          fids: [options.userId],
        });
        qrCodeUrl = qrs?.[options.userId] ?? "";
      } catch {
        qrCodeUrl = "";
      }
    }
    const isGroup = type === ThreadType.Group;
    const url = this.http.serviceUrl("file", isGroup ? "/api/group/forward" : "/api/message/forward");
    return this.http.postEncrypted(
      url,
      stripUndefined({
        ttl: options.ttl ?? 0,
        msgType: 6,
        clientId: String(Date.now()),
        msgInfo: JSON.stringify(
          stripUndefined({
            contactUid: options.userId,
            qrCodeUrl: qrCodeUrl ?? "",
            phone: options.phoneNumber,
          }),
        ),
        ...(isGroup ? { grid: threadId, visibility: 0 } : { toId: threadId }),
        imei: this.ctx.imei,
      }),
    );
  }

  /** GET `{file[0]}/api/message/parselink`. */
  async parseLink(
    link: string,
  ): Promise<{ data: Record<string, unknown>; error_maps?: Record<string, unknown> }> {
    const url = this.http.serviceUrl("file", "/api/message/parselink");
    return this.http.getEncrypted(url, { link, version: 1, imei: this.ctx.imei });
  }

  /** POST `{file[0]}/api/message/scanurl`. */
  async scanURL(urlToScan: string): Promise<unknown> {
    const url = this.http.serviceUrl("file", "/api/message/scanurl");
    return this.http.postEncrypted(url, { url: urlToScan });
  }

  /** POST `{chat[0]}/api/message/link` or `{group[0]}/api/group/sendlink`. */
  async sendLink(
    options: {
      link: string;
      msg?: string;
      title?: string;
      desc?: string;
      thumb?: string;
      ttl?: number;
      mentions?: Array<{ pos: number; uid: string; len: number }>;
    },
    threadId: string,
    type: ThreadType = ThreadType.User,
  ): Promise<{ msgId: number | string }> {
    const isGroup = type === ThreadType.Group;
    const url = this.http.serviceUrl(
      isGroup ? "group" : "chat",
      isGroup ? "/api/group/sendlink" : "/api/message/link",
    );
    const domain = (() => {
      try {
        return new URL(options.link).hostname;
      } catch {
        return "";
      }
    })();
    return this.http.postEncrypted(
      url,
      stripUndefined({
        msg: options.msg ?? options.link,
        href: options.link,
        src: domain,
        title: options.title ?? "",
        desc: options.desc ?? "",
        thumb: options.thumb ?? "",
        type: 2,
        media: JSON.stringify({
          type: 0,
          count: 0,
          mediaTitle: "",
          artist: "",
          streamUrl: "",
          stream_icon: "",
        }),
        ttl: options.ttl ?? 0,
        clientId: Date.now(),
        ...(isGroup
          ? {
              grid: threadId,
              mentionInfo: options.mentions?.length ? JSON.stringify(options.mentions) : undefined,
            }
          : { toId: threadId }),
        imei: this.ctx.imei,
      }),
      { nretry: true },
    );
  }

  /** POST `{chat[0]}/api/message/sticker` or `{group[0]}/api/group/sticker`. */
  async sendSticker(
    sticker: { id: number; cateId: number; type: number },
    threadId: string,
    type: ThreadType = ThreadType.User,
  ): Promise<{ msgId: number | string }> {
    const isGroup = type === ThreadType.Group;
    const url = this.http.serviceUrl(
      isGroup ? "group" : "chat",
      isGroup ? "/api/group/sticker" : "/api/message/sticker",
    );
    return this.http.postEncrypted(
      url,
      {
        stickerId: sticker.id,
        cateId: sticker.cateId,
        type: sticker.type,
        clientId: Date.now(),
        imei: this.ctx.imei,
        zsource: 101,
        ...(isGroup ? { grid: threadId } : { toid: threadId }),
      },
      { nretry: true },
    );
  }

  /** POST `{zimsg[0]}/api/transfer/card`. */
  async sendBankCard(
    payload: { binBank: BinBankCard | number | string; numAccBank: string; nameAccBank?: string },
    threadId: string,
    type: ThreadType = ThreadType.User,
  ): Promise<string | { msgId?: number | string }> {
    const url = this.http.serviceUrl("zimsg", "/api/transfer/card");
    return this.http.postEncrypted(
      url,
      stripUndefined({
        binBank: payload.binBank,
        numAccBank: payload.numAccBank,
        nameAccBank: payload.nameAccBank?.toUpperCase(),
        cliMsgId: Date.now().toString(),
        tsMsg: Date.now(),
        destUid: threadId,
        destType: type === ThreadType.Group ? 1 : 0,
      }),
    );
  }

  /** POST `{file[0]}/api/{message|group}/mforward`. */
  async forwardMessage(
    payload: { message: string; ttl?: number; reference?: Record<string, unknown> },
    threadIds: string[],
    type: ThreadType = ThreadType.User,
  ): Promise<unknown> {
    const isGroup = type === ThreadType.Group;
    const url = this.http.serviceUrl(
      "file",
      isGroup ? "/api/group/mforward" : "/api/message/mforward",
    );
    const clientId = Date.now();
    const msgInfo = payload.reference
      ? {
          message: payload.message,
          rMsg: [
            {
              gMsgID: payload.reference.id,
              cMsgID: payload.reference.cliMsgId,
              msgType: 1,
            },
          ],
        }
      : { message: payload.message };

    return this.http.postEncrypted(
      url,
      stripUndefined({
        ...(isGroup
          ? {
              grids: threadIds.map((id, i) => ({
                clientId: String(clientId + i),
                grid: id,
                ttl: payload.ttl ?? 0,
              })),
            }
          : {
              toIds: threadIds.map((id, i) => ({
                clientId: String(clientId + i),
                toUid: id,
                ttl: payload.ttl ?? 0,
              })),
              imei: this.ctx.imei,
            }),
        ttl: payload.ttl ?? 0,
        msgType: "1",
        totalIds: threadIds.length,
        msgInfo: JSON.stringify(msgInfo),
        decorLog: JSON.stringify({ fw: { lvl: payload.reference?.fwLvl ?? 1 } }),
      }),
    );
  }

  /** POST `{chat[0]}/api/message/undo` or `{group[0]}/api/group/undomsg`. */
  async undo(
    options: { msgId: string; cliMsgId: string },
    threadId: string,
    type: ThreadType = ThreadType.User,
  ): Promise<unknown> {
    const isGroup = type === ThreadType.Group;
    const url = this.http.serviceUrl(
      isGroup ? "group" : "chat",
      isGroup ? "/api/group/undomsg" : "/api/message/undo",
    );
    return this.http.postEncrypted(
      url,
      stripUndefined({
        msgId: options.msgId,
        clientId: Date.now(),
        cliMsgIdUndo: options.cliMsgId,
        ...(isGroup
          ? { grid: threadId, visibility: 0, imei: this.ctx.imei }
          : { toid: threadId }),
      }),
    );
  }

  /** POST `{chat[0]}/api/message/delete` or `{group[0]}/api/group/deletemsg`. */
  async deleteMessage(
    dest: {
      data: { cliMsgId: string; msgId: string; uidFrom: string };
      threadId: string;
      type?: ThreadType;
    },
    onlyMe = false,
  ): Promise<unknown> {
    const isGroup = dest.type === ThreadType.Group;
    const url = this.http.serviceUrl(
      isGroup ? "group" : "chat",
      isGroup ? "/api/group/deletemsg" : "/api/message/delete",
    );
    return this.http.postEncrypted(url, {
      [isGroup ? "grid" : "toid"]: dest.threadId,
      cliMsgId: Date.now(),
      msgs: [
        {
          cliMsgId: dest.data.cliMsgId,
          globalMsgId: dest.data.msgId,
          ownerId: dest.data.uidFrom === "0" ? this.ctx.uid : dest.data.uidFrom,
          destId: dest.threadId,
        },
      ],
      onlyMe: onlyMe ? 1 : 0,
      imei: this.ctx.imei,
    });
  }

  /** POST `{chat[0]}/api/message/seenv2` or `{group[0]}/api/group/seenv2`. */
  async sendSeenEvent(
    messages:
      | SendSeenEventMessageParams
      | Record<string, unknown>
      | Array<SendSeenEventMessageParams | Record<string, unknown>>,
    type: ThreadType = ThreadType.User,
  ): Promise<{ status: number }> {
    const list = Array.isArray(messages) ? messages : [messages];
    if (!list.length) throw new ZaloApiError("messages must not be empty");
    const isGroup = type === ThreadType.Group;
    const first = list[0]!;
    const msgInfos = {
      data: list.map((m) => ({
        cmi: m.cliMsgId,
        gmi: m.msgId,
        si: m.uidFrom,
        di: m.idTo === this.ctx.uid ? "0" : m.idTo,
        mt: m.msgType,
        st: m.st ?? 0,
        at: m.at ?? 0,
        cmd: m.cmd ?? 0,
        ts: m.ts,
      })),
      ...(isGroup ? { grid: first.idTo } : { senderId: first.uidFrom }),
    };
    const url = this.http.serviceUrl(
      isGroup ? "group" : "chat",
      isGroup ? "/api/group/seenv2" : "/api/message/seenv2",
    );
    return this.http.postEncrypted(
      url,
      {
        msgInfos: JSON.stringify(msgInfos),
        ...(isGroup ? { imei: this.ctx.imei } : {}),
      },
      { nretry: true },
    );
  }

  /** POST `{chat[0]}/api/message/deliveredv2` or `{group[0]}/api/group/deliveredv2`. */
  async sendDeliveredEvent(
    isSeen: boolean,
    messages:
      | SendSeenEventMessageParams
      | Record<string, unknown>
      | Array<SendSeenEventMessageParams | Record<string, unknown>>,
    type: ThreadType = ThreadType.User,
  ): Promise<{ status: number }> {
    const list = Array.isArray(messages) ? messages : [messages];
    if (!list.length) throw new ZaloApiError("messages must not be empty");
    const isGroup = type === ThreadType.Group;
    const first = list[0]!;
    const msgInfos = {
      seen: isSeen ? 1 : 0,
      data: list.map((m) => ({
        cmi: m.cliMsgId,
        gmi: m.msgId,
        si: m.uidFrom,
        di: m.idTo === this.ctx.uid ? "0" : m.idTo,
        mt: m.msgType,
        st: m.st ?? 0,
        at: m.at ?? 0,
        cmd: m.cmd ?? 0,
        ts: m.ts,
      })),
      ...(isGroup ? { grid: first.idTo } : {}),
    };
    const url = this.http.serviceUrl(
      isGroup ? "group" : "chat",
      isGroup ? "/api/group/deliveredv2" : "/api/message/deliveredv2",
    );
    return this.http.postEncrypted(url, {
      msgInfos: JSON.stringify(msgInfos),
      ...(isGroup ? { imei: this.ctx.imei } : {}),
    });
  }

  /** POST `{chat[0]}/api/message/typing` or `{group[0]}/api/group/typing`. */
  async sendTypingEvent(
    threadId: string,
    type: ThreadType = ThreadType.User,
    destType: DestType = DestType.User,
  ): Promise<unknown> {
    const isGroup = type === ThreadType.Group;
    const url = this.http.serviceUrl(
      isGroup ? "group" : "chat",
      isGroup ? "/api/group/typing" : "/api/message/typing",
    );
    return this.http.postEncrypted(url, {
      [isGroup ? "grid" : "toid"]: threadId,
      ...(isGroup ? {} : { destType }),
      imei: this.ctx.imei,
    });
  }

  /** POST `{reaction[0]}/api/{message|group}/reaction`. */
  async addReaction(
    icon: Reactions | { rType: number; source: number; icon: string },
    dest: {
      data: { msgId: string; cliMsgId: string };
      threadId: string;
      type: ThreadType;
    },
  ): Promise<unknown> {
    const isGroup = dest.type === ThreadType.Group;
    const rIcon = typeof icon === "object" ? icon.icon : icon;
    const rType = typeof icon === "object" ? icon.rType : (REACTION_RTYPE_MAP[icon] ?? -1);
    const source = typeof icon === "object" ? icon.source : 6;

    const url = this.http.serviceUrl(
      "reaction",
      isGroup ? "/api/group/reaction" : "/api/message/reaction",
    );
    const res = await this.http.postEncrypted<Record<string, unknown>>(url, {
      react_list: [
        {
          message: JSON.stringify({
            rMsg: [
              {
                gMsgID: Number.parseInt(dest.data.msgId, 10),
                cMsgID: Number.parseInt(dest.data.cliMsgId, 10),
                msgType: 1,
              },
            ],
            rIcon,
            rType,
            source,
          }),
          clientId: Date.now(),
        },
      ],
      ...(isGroup ? { grid: dest.threadId, imei: this.ctx.imei } : { toid: dest.threadId }),
    });
    if (res && typeof res.msgIds === "string") {
      return { ...res, msgIds: JSON.parse(res.msgIds) };
    }
    return res;
  }

  /** GET `{group_cloud_message[0]}/api/cm/{getrecentv2|getoldv2}`. */
  async getCloudMessage(options: {
    groupId: string;
    globalMsgId?: string;
    count?: number;
    msgIds?: string[];
    isOA?: boolean;
    src?: CloudMessageSource;
  }): Promise<unknown> {
    const cleanGroupId = options.groupId.startsWith("g") ? options.groupId.slice(1) : options.groupId;
    const globalMsgId = options.globalMsgId ?? "0";
    const isInitial = globalMsgId === "0";
    const url = this.http.serviceUrl(
      "group_cloud_message",
      isInitial ? "/api/cm/getrecentv2" : "/api/cm/getoldv2",
    );
    try {
      const data = await this.http.getEncrypted<unknown>(
        url,
        stripUndefined({
          groupId: cleanGroupId,
          globalMsgId,
          count: options.count ?? 50,
          msgIds: options.msgIds ?? [],
          imei: this.ctx.imei,
          isOA: options.isOA ? 1 : undefined,
          src: options.src ?? (isInitial ? CloudMessageSource.Overflow : CloudMessageSource.LoadMore),
        }),
        { nretry: true },
      );
      return typeof data === "string" ? JSON.parse(data) : data;
    } catch (err) {
      if (err instanceof ZaloApiError && err.code === -69) return { msgs: [], hasMore: false };
      throw err;
    }
  }

  /** GET `{group[0]}/api/group/history`. */
  async getGroupChatHistory(groupId: string, count = 50): Promise<{
    lastActionId?: string;
    lastActionIdOther?: string;
    more?: number;
    groupMsgs: GroupMessage[];
  }> {
    const url = this.http.serviceUrl("group", "/api/group/history");
    const raw = await this.http.getEncrypted<unknown>(url, { grid: groupId, count });
    const parsed = (typeof raw === "string" ? JSON.parse(raw) : raw) as {
      lastActionId?: string;
      lastActionIdOther?: string;
      more?: number;
      groupMsgs?: Array<TMessage>;
    };
    const msgs = Array.isArray(parsed?.groupMsgs) ? parsed.groupMsgs : [];
    return {
      ...parsed,
      groupMsgs: msgs.map((m) => {
        const msg = { ...m };
        const isSelf = msg.uidFrom === "0" || msg.uidFrom === this.ctx.uid;
        if (msg.uidFrom === "0") msg.uidFrom = this.ctx.uid;
        if (msg.idTo === "0") msg.idTo = this.ctx.uid;
        return {
          type: ThreadType.Group,
          threadId: groupId,
          isSelf,
          data: msg,
        };
      }),
    };
  }

  /** GET `{conversation[0]}/api/preloadconvers/get-last-msgs`. */
  async preloadLastMessages(threadIdLocalMsgId: Record<string, unknown>): Promise<unknown> {
    const url = this.http.serviceUrl("conversation", "/api/preloadconvers/get-last-msgs");
    return this.http.getEncrypted(url, {
      threadIdLocalMsgId: JSON.stringify(threadIdLocalMsgId),
      imei: this.ctx.imei,
    });
  }

  /** GET `{chat[0]}/api/preloadconvers/get-last-seen`. */
  async preloadLastSeen(group: unknown[] = [], oneone: unknown[] = []): Promise<unknown> {
    const url = this.http.serviceUrl("chat", "/api/preloadconvers/get-last-seen");
    return this.http.getEncrypted(url, {
      param: JSON.stringify({ group, oneone }),
    });
  }

  /** WS `cmd=577` — fetches last delivered/seen pointers. */
  getLastDeliverSeen(oneone: unknown[] = [], group: unknown[] = []): Promise<unknown> {
    if (!this.getListener) {
      return Promise.reject(new ZaloApiError("Listener unavailable"));
    }
    return this.getListener().requestCommand(WS_CMD.GET_LAST_DELIVER_SEEN, WS_SUB_CMD.DEFAULT, {
      oneone,
      group,
    });
  }
}
