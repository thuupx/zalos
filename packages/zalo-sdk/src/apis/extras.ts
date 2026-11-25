import { WS_CMD, WS_SUB_CMD } from "../core/constants.ts";
import type { ZaloContext } from "../core/context.ts";
import type { ZaloHttpClient } from "../core/http.ts";
import type { MediaStoreItem } from "../models/entities.ts";
import type { ZaloListener } from "../ws/listener.ts";

export class ExtrasApi {
  constructor(
    private readonly http: ZaloHttpClient,
    private readonly ctx: ZaloContext,
    private readonly getListener: () => ZaloListener,
  ) {}

  // ---- Media Store & My Cloud ("Send to Me") ----

  listMediaStore(
    groupId: string,
    mediaType: string,
    opts: { limit?: number; lastId?: string | number; lastFetchId?: number } = {},
  ): Promise<MediaStoreItem[]> {
    const url = this.http.serviceUrl("media_store", "/api/mediastore/list");
    return this.http.getEncrypted<MediaStoreItem[]>(url, {
      media_type: mediaType,
      group_id: groupId,
      imei: this.ctx.imei,
      ...(opts.limit !== undefined ? { limit: opts.limit } : {}),
      ...(opts.lastId !== undefined ? { last_id: opts.lastId } : {}),
      ...(opts.lastFetchId !== undefined ? { lastFetchId: opts.lastFetchId } : {}),
    });
  }

  previewMediaStore(groupId: string, limit = 50): Promise<unknown> {
    const url = this.http.serviceUrl("media_store", "/api/mediastore/preview");
    return this.http.postEncrypted(
      url,
      { group_id: groupId, limit, imei: this.ctx.imei },
      { paramsInQuery: true },
    );
  }

  removeMediaStore(groupId: string, mediaType: string, mediaId: string | string[]): Promise<unknown> {
    const url = this.http.serviceUrl("media_store", "/api/mediastore/remove");
    return this.http.postEncrypted(
      url,
      { group_id: groupId, media_type: mediaType, media_id: mediaId },
      { paramsInQuery: true },
    );
  }

  listOneOneMedia(
    mediaType: string,
    opts: { limit?: number; lastId?: string | number; lastFetchId?: number } = {},
  ): Promise<MediaStoreItem[]> {
    const url = this.http.serviceUrl("media_store_send2me", "/api/media/oneone/list");
    return this.http.getEncrypted<MediaStoreItem[]>(url, {
      media_type: mediaType,
      ...(opts.limit !== undefined ? { limit: opts.limit } : {}),
      ...(opts.lastId !== undefined ? { last_id: opts.lastId } : {}),
      ...(opts.lastFetchId !== undefined ? { lastFetchId: opts.lastFetchId } : {}),
    });
  }

  previewOneOneMedia(limit = 50): Promise<unknown> {
    const url = this.http.serviceUrl("media_store_send2me", "/api/media/oneone/preview");
    return this.http.postEncrypted(url, { limit }, { paramsInQuery: true });
  }

  removeOneOneMedia(mediaType: string, mediaId: string | string[]): Promise<unknown> {
    const url = this.http.serviceUrl("media_store_send2me", "/api/media/oneone/remove");
    return this.http.postEncrypted(
      url,
      { media_type: mediaType, media_id: mediaId },
      { paramsInQuery: true },
    );
  }

  // ---- ZCloud & ZFamily Viewer Keys ----

  getCloudViewerKey(): Promise<unknown> {
    const url = this.http.serviceUrl("zcloud", "/api/getCloudViewerKey");
    return this.http.getEncrypted(url, { imei: this.ctx.imei });
  }

  getFamilyViewerKey(): Promise<unknown> {
    const url = this.http.serviceUrl("zcloud", "/api/getFamilyViewerKey");
    return this.http.getEncrypted(url, { imei: this.ctx.imei });
  }

  // ---- Recent Search ----

  getRecentSearch(version = 0): Promise<unknown> {
    const url = this.http.serviceUrl("recent_search", "/api/recentsearch/list");
    return this.http.getEncrypted(url, { version, imei: this.ctx.imei });
  }

  updateRecentSearch(
    listRecent: unknown[],
    version: number,
    listKeyword: string[] = [],
  ): Promise<unknown> {
    const url = this.http.serviceUrl("recent_search", "/api/recentsearch/update");
    return this.http.postEncrypted(url, {
      list_recent: listRecent,
      version,
      list_keyword: listKeyword,
      imei: this.ctx.imei,
    });
  }

  // ---- Group ID / Noise Encryption Helpers ----

  encryptGroupId(noiseUids: string[]): Promise<unknown> {
    const url = this.http.serviceUrl("profile", "/api/gid/encrypt");
    return this.http.getEncrypted(url, { noiseUids });
  }

  decryptGroupId(globalUids: string[]): Promise<unknown> {
    const url = this.http.serviceUrl("profile", "/api/gid/decrypt");
    return this.http.getEncrypted(url, { globalUids: JSON.stringify(globalUids) });
  }

  // ---- Sync, Backup, Interactive Files & Payment WebSocket Commands ----

  requestMobileSync(data: Record<string, unknown> = {}): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.SYNC_REQUEST, WS_SUB_CMD.DEFAULT, { data });
  }

  ackDeleteSyncSession(data: Record<string, unknown> = {}): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.SYNC_ACK_DELETE, WS_SUB_CMD.DEFAULT, { data });
  }

  wakeMobileForSync(data: Record<string, unknown> = {}): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.SYNC_WAKE_MOBILE, WS_SUB_CMD.DEFAULT, data);
  }

  backupInit(data: Record<string, unknown> = {}): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.BACKUP_INIT, WS_SUB_CMD.DEFAULT, { data });
  }

  backupCreateSession(): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.BACKUP_CREATE_SESSION, WS_SUB_CMD.DEFAULT, {});
  }

  backupGetMetadata(): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.BACKUP_GET_METADATA, WS_SUB_CMD.DEFAULT, {});
  }

  backupSignalRestore(): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.BACKUP_SIGNAL_RESTORE, WS_SUB_CMD.DEFAULT, {});
  }

  backupGetConfigs(): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.BACKUP_GET_CONFIGS, WS_SUB_CMD.DEFAULT, {});
  }

  submitInteractiveFile(payload: Record<string, unknown>): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.SUBMIT_INTERACTIVE_FILE, WS_SUB_CMD.DEFAULT, payload);
  }

  pullInteractiveFiles(lastId = 0, maxItem = 50): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.PULL_INTERACTIVE_FILE, WS_SUB_CMD.DEFAULT, {
      lastId,
      maxItem,
    });
  }

  getInAppPaymentLink(domain: string): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.GET_IN_APP_PAYMENT_LINK, WS_SUB_CMD.DEFAULT, {
      data: { domain },
    });
  }

  getMediaUploadUrl(params: Record<string, unknown> = {}): Promise<unknown> {
    return this.getListener().requestCommand(WS_CMD.GET_MEDIA_UPLOAD_URL, WS_SUB_CMD.DEFAULT, params);
  }
}
