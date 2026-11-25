import { readFile } from "node:fs/promises";
import { basename } from "node:path";
import type { ZaloContext } from "../core/context.ts";
import type { ZaloHttpClient } from "../core/http.ts";
import type { AttachmentSource, AutoReplyItem, BankAccount, BankInfo, QuickMessage } from "../models/entities.ts";
import { BinBankCard } from "../models/enums.ts";

export interface QuickMessageMediaItem {
  type?: number;
  photoId: string | number;
  title?: string;
  width?: number | string;
  height?: number | string;
  previewThumb?: string;
  rawUrl?: string;
  thumbUrl?: string;
  normalUrl?: string;
  hdUrl?: string;
  [key: string]: unknown;
}

export interface QuickMessageWritePayload {
  keyword: string;
  title: string;
  media?: AttachmentSource | QuickMessageMediaItem[];
}

export interface ProductPhotoUploadResult {
  photoId: string;
  thumbUrl?: string;
  normalUrl?: string;
  hdUrl?: string;
  [key: string]: unknown;
}

export class BusinessApi {
  constructor(
    private readonly http: ZaloHttpClient,
    private readonly ctx: ZaloContext,
  ) {}

  /** POST `{profile[0]}/api/social/friend/get-bizacc`. */
  async getBizAccount(userId = this.ctx.uid): Promise<unknown> {
    const url = this.http.serviceUrl("profile", "/api/social/friend/get-bizacc");
    return this.http.postEncrypted(url, { fid: userId });
  }

  // ---- Catalogs & Products ----

  async getCatalogList(payload: { versionListCatalog?: number; limit?: number; lastProductId?: number; page?: number } = {}): Promise<unknown> {
    const url = this.http.serviceUrl("catalog", "/api/prodcatalog/catalog/list");
    return this.http.postEncrypted(url, {
      version_list_catalog: payload.versionListCatalog ?? 0,
      limit: payload.limit ?? 20,
      last_product_id: payload.lastProductId ?? -1,
      page: payload.page ?? 0,
    });
  }

  async createCatalog(catalogName: string, catalogPhoto = ""): Promise<unknown> {
    const url = this.http.serviceUrl("catalog", "/api/prodcatalog/catalog/create");
    return this.http.postEncrypted(url, {
      catalog_name: catalogName,
      catalog_photo: catalogPhoto,
    });
  }

  async updateCatalog(payload: { catalogId: string; catalogName: string; catalogPhoto?: string }): Promise<unknown> {
    const url = this.http.serviceUrl("catalog", "/api/prodcatalog/catalog/update");
    return this.http.postEncrypted(url, {
      catalog_id: payload.catalogId,
      catalog_name: payload.catalogName,
      catalog_photo: payload.catalogPhoto ?? "",
    });
  }

  async deleteCatalog(catalogId: string): Promise<unknown> {
    const url = this.http.serviceUrl("catalog", "/api/prodcatalog/catalog/delete");
    return this.http.postEncrypted(url, { catalog_id: catalogId });
  }

  async registerCatalog(enable = true): Promise<unknown> {
    const url = this.http.serviceUrl("catalog", "/api/prodcatalog/catalog/register");
    return this.http.postEncrypted(url, { enable: enable ? 1 : 0 });
  }

  async getProductCatalogList(payload: { catalogId: string; limit?: number; versionCatalog?: number; lastProductId?: number; page?: number }): Promise<unknown> {
    const url = this.http.serviceUrl("catalog", "/api/prodcatalog/product/list");
    return this.http.postEncrypted(url, {
      catalog_id: payload.catalogId,
      limit: payload.limit ?? 20,
      version_catalog: payload.versionCatalog ?? 0,
      last_product_id: payload.lastProductId ?? -1,
      page: payload.page ?? 0,
    });
  }

  async createProductCatalog(payload: {
    productName: string;
    price: string | number;
    description: string;
    productPhotos?: string[];
    catalogId: string;
    currencyUnit?: string;
    createTime?: number;
  }): Promise<unknown> {
    const url = this.http.serviceUrl("catalog", "/api/prodcatalog/product/create");
    return this.http.postEncrypted(url, {
      product_name: payload.productName,
      price: payload.price,
      description: payload.description,
      product_photos: payload.productPhotos ?? [],
      catalog_id: payload.catalogId,
      currency_unit: payload.currencyUnit ?? "₫",
      create_time: payload.createTime ?? Date.now(),
    });
  }

  async updateProductCatalog(payload: {
    productId: string;
    productName: string;
    price: string | number;
    description: string;
    productPhotos?: string[];
    catalogId: string;
    currencyUnit?: string;
    createTime?: number;
  }): Promise<unknown> {
    const url = this.http.serviceUrl("catalog", "/api/prodcatalog/product/update");
    return this.http.postEncrypted(url, {
      product_id: payload.productId,
      product_name: payload.productName,
      price: payload.price,
      description: payload.description,
      product_photos: payload.productPhotos ?? [],
      catalog_id: payload.catalogId,
      currency_unit: payload.currencyUnit ?? "₫",
      create_time: payload.createTime ?? Date.now(),
    });
  }

  async deleteProductCatalog(payload: { productIds: string | string[]; catalogId: string }): Promise<unknown> {
    const ids = Array.isArray(payload.productIds) ? payload.productIds : [payload.productIds];
    const url = this.http.serviceUrl("catalog", "/api/prodcatalog/product/mdelete");
    return this.http.postEncrypted(url, {
      product_ids: ids,
      catalog_id: payload.catalogId,
    });
  }

  async uploadProductPhoto(
    sourceOrPayload: AttachmentSource | { file: AttachmentSource },
  ): Promise<ProductPhotoUploadResult> {
    const source =
      typeof sourceOrPayload === "object" && "file" in sourceOrPayload
        ? sourceOrPayload.file
        : sourceOrPayload;
    const buf = typeof source === "string" ? await readFile(source) : Buffer.from(source.data);
    const filename = typeof source === "string" ? basename(source) : source.filename;
    const url = this.http.serviceUrl("file", "/api/product/upload/photo");
    const form = new FormData();
    form.append("chunkContent", new Blob([buf], { type: "application/octet-stream" }), filename);
    return this.http.postMultipart<ProductPhotoUploadResult>(
      url,
      {
        totalChunk: 1,
        fileName: filename,
        clientId: Date.now(),
        totalSize: buf.length,
        imei: this.ctx.imei,
        chunkId: 1,
        toid: this.ctx.uid,
        featureId: 1,
      },
      form,
    );
  }

  // ---- Quick Messages (includes fixed photoId-preserving update & zca-js file upload compatibility) ----

  async getQuickMessageList(version = 0): Promise<{ items: QuickMessage[]; version: number; cursor?: number }> {
    const url = this.http.serviceUrl("quick_message", "/api/quickmessage/list");
    return this.http.getEncrypted(url, { version, lang: 0, imei: this.ctx.imei });
  }

  private async buildQuickMessageMedia(
    media: QuickMessageWritePayload["media"],
  ): Promise<{ items: QuickMessageMediaItem[] } | undefined> {
    if (!media) return undefined;
    if (Array.isArray(media)) {
      return media.length > 0 ? { items: media } : undefined;
    }
    const uploaded = await this.uploadProductPhoto(media);
    const normalUrl = uploaded.normalUrl || uploaded.hdUrl;
    const hdUrl = uploaded.hdUrl || uploaded.normalUrl;
    return {
      items: [
        {
          type: 0,
          photoId: uploaded.photoId,
          title: "",
          width: "",
          height: "",
          previewThumb: uploaded.thumbUrl,
          rawUrl: normalUrl,
          thumbUrl: uploaded.thumbUrl,
          normalUrl,
          hdUrl,
        },
      ],
    };
  }

  async addQuickMessage(
    payload: QuickMessageWritePayload,
  ): Promise<{ item?: unknown; version?: number }> {
    const url = this.http.serviceUrl("quick_message", "/api/quickmessage/create");
    const mediaBlock = await this.buildQuickMessageMedia(payload.media);
    return this.http.getEncrypted(url, {
      keyword: payload.keyword,
      message: { title: payload.title, params: "" },
      type: mediaBlock ? 1 : 0,
      ...(mediaBlock ? { media: mediaBlock } : {}),
      imei: this.ctx.imei,
    });
  }

  /** Preserves existing media `items` / `photoId` properly OR uploads a new `AttachmentSource` image. */
  async updateQuickMessage(
    itemId: number,
    payload: QuickMessageWritePayload,
  ): Promise<{ item?: unknown; version?: number }>;
  async updateQuickMessage(
    payload: QuickMessageWritePayload,
    itemId: number,
  ): Promise<{ item?: unknown; version?: number }>;
  async updateQuickMessage(
    idOrPayload: number | QuickMessageWritePayload,
    payloadOrId: QuickMessageWritePayload | number,
  ): Promise<{ item?: unknown; version?: number }> {
    const itemId = typeof idOrPayload === "number" ? idOrPayload : (payloadOrId as number);
    const payload = typeof idOrPayload === "number" ? (payloadOrId as QuickMessageWritePayload) : idOrPayload;
    const url = this.http.serviceUrl("quick_message", "/api/quickmessage/update");
    const mediaBlock = await this.buildQuickMessageMedia(payload.media);
    return this.http.getEncrypted(url, {
      itemId,
      keyword: payload.keyword,
      message: { title: payload.title, params: "" },
      type: mediaBlock ? 1 : 0,
      ...(mediaBlock ? { media: mediaBlock } : {}),
    });
  }

  async removeQuickMessage(
    itemIds: number | number[],
  ): Promise<{ itemIds: number[]; version: number }> {
    const ids = Array.isArray(itemIds) ? itemIds : [itemIds];
    const url = this.http.serviceUrl("quick_message", "/api/quickmessage/delete");
    return this.http.getEncrypted(url, { itemIds: ids });
  }

  // ---- Auto-Reply ----

  async getAutoReplyList(): Promise<{ item: AutoReplyItem[]; version: number }> {
    const url = this.http.serviceUrl("auto_reply", "/api/autoreply/list");
    return this.http.getEncrypted(url, { version: 0, cliLang: this.ctx.language });
  }

  async createAutoReply(payload: {
    isEnable: boolean;
    content: string;
    startTime: number;
    endTime: number;
    scope: number;
    uids?: string | string[];
  }): Promise<unknown> {
    const rawUids = payload.uids ? (Array.isArray(payload.uids) ? payload.uids : [payload.uids]) : [];
    const resultUids = payload.scope === 2 || payload.scope === 3 ? rawUids : [];
    const url = this.http.serviceUrl("auto_reply", "/api/autoreply/create");
    return this.http.postEncrypted(url, {
      cliLang: this.ctx.language,
      enable: payload.isEnable,
      content: payload.content,
      startTime: payload.startTime,
      endTime: payload.endTime,
      recurrence: ["RRULE:FREQ=DAILY;"],
      scope: payload.scope,
      uids: resultUids,
    });
  }

  async updateAutoReply(payload: {
    id: number;
    isEnable: boolean;
    content: string;
    startTime: number;
    endTime: number;
    scope: number;
    uids?: string | string[];
  }): Promise<unknown> {
    const rawUids = payload.uids ? (Array.isArray(payload.uids) ? payload.uids : [payload.uids]) : [];
    const resultUids = payload.scope === 2 || payload.scope === 3 ? rawUids : [];
    const url = this.http.serviceUrl("auto_reply", "/api/autoreply/update");
    return this.http.postEncrypted(url, {
      cliLang: this.ctx.language,
      id: payload.id,
      enable: payload.isEnable,
      content: payload.content,
      startTime: payload.startTime,
      endTime: payload.endTime,
      recurrence: ["RRULE:FREQ=DAILY;"],
      scope: payload.scope,
      uids: resultUids,
    });
  }

  async deleteAutoReply(id: number): Promise<unknown> {
    const url = this.http.serviceUrl("auto_reply", "/api/autoreply/delete");
    return this.http.postEncrypted(url, { cliLang: this.ctx.language, id });
  }

  // ---- Bank Accounts ----

  async getListBank(): Promise<{ banks?: BankInfo[]; [k: string]: unknown }> {
    const url = this.http.serviceUrl("zimsg", "/api/transfer/conf");
    return this.http.getEncrypted(url, {});
  }

  async getListBankAccount(
    page = 0,
    limit = 20,
  ): Promise<{ hasMore?: unknown; total?: unknown; myBanks?: BankAccount[]; [k: string]: unknown }> {
    const url = this.http.serviceUrl("zimsg", "/api/transfer/list");
    return this.http.getEncrypted(url, { page, limit });
  }

  async createBankAccount(payload: {
    binBank: BinBankCard | string;
    numAccBank: string;
    nameAccBank: string;
  }): Promise<unknown> {
    const url = this.http.serviceUrl("zimsg", "/api/transfer/create");
    return this.http.postEncrypted(url, {
      bin: payload.binBank,
      bank_number: payload.numAccBank,
      holder_name: payload.nameAccBank.toUpperCase(),
      language: this.ctx.language,
    });
  }

  async updateBankAccount(payload: {
    accountId: string;
    binBank: BinBankCard | string;
    numAccBank: string;
    nameAccBank: string;
  }): Promise<unknown> {
    const url = this.http.serviceUrl("zimsg", "/api/transfer/update");
    return this.http.postEncrypted(url, {
      account_id: payload.accountId,
      bin: payload.binBank,
      bank_number: payload.numAccBank,
      holder_name: payload.nameAccBank.toUpperCase(),
      language: this.ctx.language,
    });
  }

  async deleteBankAccount(payload: { accountId: string; isDefault: boolean }): Promise<unknown> {
    const url = this.http.serviceUrl("zimsg", "/api/transfer/delete");
    return this.http.postEncrypted(url, {
      account_id: payload.accountId,
      is_default: payload.isDefault,
      language: this.ctx.language,
    });
  }
}
