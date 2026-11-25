import type { ZaloContext } from "../core/context.ts";
import type { ZaloHttpClient } from "../core/http.ts";
import type { StickerDetail } from "../models/entities.ts";

export class StickersApi {
  constructor(
    private readonly http: ZaloHttpClient,
    private readonly ctx: ZaloContext,
  ) {}

  /** GET `{sticker[0]}/api/message/sticker/suggest/stickers`. */
  async getStickers(keyword: string): Promise<number[]> {
    const url = this.http.serviceUrl("sticker", "/api/message/sticker/suggest/stickers");
    const suggestions = await this.http.getEncrypted<{
      sugg_sticker?: Array<{ sticker_id: number }>;
    }>(url, {
      keyword,
      gif: 1,
      guggy: 0,
      imei: this.ctx.imei,
    });
    const stickerIds: number[] = [];
    if (Array.isArray(suggestions?.sugg_sticker)) {
      for (const s of suggestions.sugg_sticker) {
        if (typeof s?.sticker_id === "number") stickerIds.push(s.sticker_id);
      }
    }
    return stickerIds;
  }

  /** GET `{sticker[0]}/api/message/sticker/sticker_detail`. */
  async getStickersDetail(stickerIds: number | number[]): Promise<StickerDetail[]> {
    const ids = Array.isArray(stickerIds) ? stickerIds : [stickerIds];
    const url = this.http.serviceUrl("sticker", "/api/message/sticker/sticker_detail");
    const settled = await Promise.allSettled(
      ids.map((sid) => this.http.getEncrypted<StickerDetail>(url, { sid })),
    );
    const out: StickerDetail[] = [];
    for (const r of settled) {
      if (r.status === "fulfilled" && r.value) out.push(r.value);
    }
    return out;
  }

  /** GET `{sticker[0]}/api/message/sticker/category/sticker_detail`. */
  async getStickerCategoryDetail(categoryId: number): Promise<unknown> {
    const url = this.http.serviceUrl("sticker", "/api/message/sticker/category/sticker_detail");
    return this.http.getEncrypted(url, { cid: categoryId });
  }

  /** GET `{sticker[0]}/api/message/sticker/search`. */
  async searchSticker(keyword: string, limit = 50): Promise<unknown> {
    const url = this.http.serviceUrl("sticker", "/api/message/sticker/search");
    return this.http.getEncrypted(url, {
      keyword,
      limit,
      srcType: 0,
      imei: this.ctx.imei,
    });
  }

  /** GET `{emoji_stt[0]}/api/v1/emoji-status/friends`. */
  async getEmojiStatusFriends(): Promise<unknown> {
    const url = this.http.serviceUrl("emoji_stt", "/api/v1/emoji-status/friends");
    return this.http.getEncrypted(url, { imei: this.ctx.imei });
  }

  /** GET `{emoji_stt[0]}/api/v1/emoji-status/resource-config`. */
  async getEmojiStatusConfig(): Promise<unknown> {
    const url = this.http.serviceUrl("emoji_stt", "/api/v1/emoji-status/resource-config");
    return this.http.getEncrypted(url, {});
  }
}
