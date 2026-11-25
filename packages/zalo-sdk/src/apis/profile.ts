import { readFile } from "node:fs/promises";
import { basename } from "node:path";
import type { ZaloContext } from "../core/context.ts";
import type { ZaloHttpClient } from "../core/http.ts";
import type { UserInfo } from "../models/entities.ts";
import { AvatarSize, Gender, UpdateSettingsType } from "../models/enums.ts";

export interface UpdateProfileOptions {
  name: string;
  dob: `${number}-${number}-${number}`;
  gender: Gender;
  language?: string;
}

export class ProfileApi {
  constructor(
    private readonly http: ZaloHttpClient,
    private readonly ctx: ZaloContext,
  ) {}

  /** GET `{profile[0]}/api/social/profile/me-v2`. */
  async fetchAccountInfo(): Promise<{ profile: UserInfo }> {
    const url = this.http.serviceUrl("profile", "/api/social/profile/me-v2");
    return this.http.getEncrypted(url, {});
  }

  /** POST `{profile[0]}/api/social/profile/update`. */
  async updateProfile(options: UpdateProfileOptions): Promise<unknown> {
    const url = this.http.serviceUrl("profile", "/api/social/profile/update");
    return this.http.postEncrypted(url, {
      profile: JSON.stringify({
        name: options.name,
        dob: options.dob,
        gender: options.gender,
      }),
      biz: JSON.stringify({}),
      language: options.language ?? this.ctx.language,
    });
  }

  /** POST `{profile[0]}/api/social/profile/status`. */
  async updateProfileBio(bio: string): Promise<unknown> {
    const url = this.http.serviceUrl("profile", "/api/social/profile/status");
    return this.http.postEncrypted(url, { status: bio });
  }

  /** POST `{file[0]}/api/profile/upavatar` (multipart `fileContent`). */
  async changeAccountAvatar(
    source: string | { data: Buffer | Uint8Array; filename: string; width?: number; height?: number },
  ): Promise<unknown> {
    const buf = typeof source === "string" ? await readFile(source) : Buffer.from(source.data);
    const filename = typeof source === "string" ? basename(source) : source.filename;
    const width = typeof source === "object" ? source.width ?? 1080 : 1080;
    const height = typeof source === "object" ? source.height ?? 1080 : 1080;
    const url = this.http.serviceUrl("file", "/api/profile/upavatar");
    const form = new FormData();
    form.append("fileContent", new Blob([buf], { type: "image/jpeg" }), filename);
    return this.http.postMultipart(
      url,
      {
        avatarSize: 120,
        clientId: `${this.ctx.uid}${Date.now()}`,
        language: this.ctx.language,
        metaData: JSON.stringify({
          origin: { width, height },
          processed: { width, height, size: buf.length },
        }),
      },
      form,
    );
  }

  /** GET `{profile[0]}/api/social/del-avatars`. */
  async deleteAvatar(photoIds: string | string[]): Promise<unknown> {
    const ids = Array.isArray(photoIds) ? photoIds : [photoIds];
    const url = this.http.serviceUrl("profile", "/api/social/del-avatars");
    return this.http.getEncrypted(url, {
      delPhotos: JSON.stringify(ids.map((id) => ({ photoId: id }))),
      imei: this.ctx.imei,
    });
  }

  /** GET `{profile[0]}/api/social/avatar-list`. */
  async getAvatarList(albumId = "0"): Promise<unknown> {
    const url = this.http.serviceUrl("profile", "/api/social/avatar-list");
    return this.http.getEncrypted(url, { albumId, imei: this.ctx.imei });
  }

  /** GET `{profile[0]}/api/social/reuse-avatar`. */
  async reuseAvatar(photoId: string, isPostSocial = false): Promise<unknown> {
    const url = this.http.serviceUrl("profile", "/api/social/reuse-avatar");
    return this.http.getEncrypted(url, {
      photoId,
      isPostSocial: isPostSocial ? 1 : 0,
      imei: this.ctx.imei,
    });
  }

  /** GET `{profile[0]}/api/social/profile/avatar`. */
  async getFullAvatar(
    userId: string,
  ): Promise<{ bk_full_avatar?: string; full_avatar: string; [k: string]: unknown }> {
    const url = this.http.serviceUrl("profile", "/api/social/profile/avatar");
    return this.http.getEncrypted(url, {
      fid: userId,
      imei: this.ctx.imei,
      avatar_size: AvatarSize.ExtraLarge,
    });
  }

  /** GET `https://wpa.chat.zalo.me/api/setting/me`. */
  async getSettings(): Promise<Record<string, unknown>> {
    const url = this.http.makeURL(`${this.ctx.profile.authDomain}/api/setting/me`);
    return this.http.getEncrypted(url, {});
  }

  /** GET `https://wpa.chat.zalo.me/api/setting/update`. */
  async updateSettings(type: UpdateSettingsType | string, value: number): Promise<unknown> {
    const url = this.http.makeURL(`${this.ctx.profile.authDomain}/api/setting/update`);
    return this.http.getEncrypted(url, { [type]: value });
  }

  /** GET `{profile[0]}/api/social/profile/ping` or `deactive`. */
  async updateActiveStatus(active: boolean): Promise<unknown> {
    const path = active ? "/api/social/profile/ping" : "/api/social/profile/deactive";
    const url = this.http.serviceUrl("profile", path);
    return this.http.getEncrypted(url, {
      status: active ? 1 : 0,
      imei: this.ctx.imei,
    });
  }

  /** GET `{profile[0]}/api/social/profile/updatelang`. */
  async updateLang(language: string): Promise<unknown> {
    const url = this.http.serviceUrl("profile", "/api/social/profile/updatelang");
    return this.http.getEncrypted(url, { language });
  }

  /** POST `{profile[0]}/api/social/profile/changefgtobg`. */
  async lostFocus(): Promise<unknown> {
    const url = this.http.serviceUrl("profile", "/api/social/profile/changefgtobg");
    return this.http.postEncrypted(url, {});
  }
}
