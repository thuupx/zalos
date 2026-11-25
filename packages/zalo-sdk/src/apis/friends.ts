import type { ZaloContext } from "../core/context.ts";
import { ZaloApiError } from "../core/errors.ts";
import type { ZaloHttpClient } from "../core/http.ts";
import type {
  GetAliasListResponse,
  GetFriendRecommendationsResponse,
  GetFriendRequestStatusResponse,
  GetSentFriendRequestResponse,
} from "../models/compat.ts";
import type { UserInfo } from "../models/entities.ts";
import { AvatarSize, ReportReason, ThreadType } from "../models/enums.ts";

export class FriendsApi {
  constructor(
    private readonly http: ZaloHttpClient,
    private readonly ctx: ZaloContext,
  ) {}

  /** GET `{profile[0]}/api/social/friend/getfriends`. */
  async getAllFriends(
    count = 20_000,
    page = 1,
    avatarSize = AvatarSize.Small,
  ): Promise<UserInfo[]> {
    const url = this.http.serviceUrl("profile", "/api/social/friend/getfriends");
    return this.http.getEncrypted<UserInfo[]>(url, {
      incInvalid: 1,
      page,
      count,
      avatar_size: avatarSize,
      actiontime: 0,
      imei: this.ctx.imei,
    });
  }

  /** GET `{profile[0]}/api/social/friend/onlines`. */
  async getFriendOnlines(): Promise<{ onlines: Array<{ userId: string; status: string }> }> {
    const url = this.http.serviceUrl("profile", "/api/social/friend/onlines");
    const data = await this.http.getEncrypted<{ onlines?: Array<{ userId: string; status: string }> }>(
      url,
      { imei: this.ctx.imei },
    );
    if (Array.isArray(data?.onlines)) {
      for (const online of data.onlines) {
        if (typeof online.status === "string" && online.status.startsWith("{")) {
          try {
            const parsed = JSON.parse(online.status) as { status?: unknown };
            if (typeof parsed?.status === "string") {
              online.status = parsed.status;
            }
          } catch {
            // Preserve raw status string when non-JSON.
          }
        }
      }
    }
    return { onlines: data?.onlines ?? [] };
  }

  /** GET `{profile[0]}/api/social/profile/lastOnline`. */
  async lastOnline(uid: string): Promise<{ settings?: Record<string, unknown>; lastOnline: number }> {
    const url = this.http.serviceUrl("profile", "/api/social/profile/lastOnline");
    return this.http.getEncrypted(url, { uid, conv_type: 1, imei: this.ctx.imei });
  }

  /** GET `{profile[0]}/api/social/friend/getclosedfriends`. */
  async getCloseFriends(): Promise<UserInfo[]> {
    const url = this.http.serviceUrl("profile", "/api/social/friend/getclosedfriends");
    return this.http.getEncrypted<UserInfo[]>(url, {});
  }

  /** POST `{friend[0]}/api/friend/closefr/update`. */
  async updateCloseFriend(fids: string | string[], add = true): Promise<unknown> {
    const ids = Array.isArray(fids) ? fids : [fids];
    const url = this.http.serviceUrl("friend", "/api/friend/closefr/update");
    return this.http.postEncrypted(url, { fids: ids, action: add ? 1 : 0 });
  }

  /** POST `{profile[0]}/api/social/friend/getprofiles/v2`. */
  async getUserInfo(userIds: string | string[]): Promise<{
    unchanged_profiles: Record<string, UserInfo>;
    changed_profiles: Record<string, UserInfo>;
  }> {
    const ids = Array.isArray(userIds) ? userIds : [userIds];
    const url = this.http.serviceUrl("profile", "/api/social/friend/getprofiles/v2");
    return this.http.postEncrypted(url, {
      phonebook_version: 0,
      friend_pversion_map: ids.map((id) => (id.includes("_") ? id : `${id}_0`)),
      avatar_size: AvatarSize.Large,
      language: this.ctx.language,
      show_online_status: 1,
      imei: this.ctx.imei,
    });
  }

  /** GET `{profile[0]}/api/social/profile/avatar-url`. */
  async getAvatarUrlProfile(
    userIds: string | string[],
    avatarSize = AvatarSize.Large,
  ): Promise<Record<string, { avatar?: string; [k: string]: unknown }>> {
    const ids = Array.isArray(userIds) ? userIds : [userIds];
    const url = this.http.serviceUrl("profile", "/api/social/profile/avatar-url");
    return this.http.getEncrypted(url, {
      friend_ids: ids,
      avatar_size: avatarSize,
      srcReq: 1,
    });
  }

  /** GET `{friend[0]}/api/friend/profile/get`. */
  async findUser(phoneNumber: string): Promise<UserInfo | null> {
    let normalized = phoneNumber;
    if (normalized.startsWith("0") && this.ctx.language === "vi") {
      normalized = `84${normalized.slice(1)}`;
    }
    const url = this.http.serviceUrl("friend", "/api/friend/profile/get");
    try {
      return await this.http.getEncrypted<UserInfo>(url, {
        phone: normalized,
        avatar_size: AvatarSize.Large,
        language: this.ctx.language,
        imei: this.ctx.imei,
        reqSrc: 40,
      });
    } catch (err) {
      if (err instanceof ZaloApiError && err.code === 216) return null;
      throw err;
    }
  }

  /** GET `{friend[0]}/api/friend/search/by-user-name`. */
  async findUserByUsername(username: string): Promise<UserInfo> {
    const url = this.http.serviceUrl("friend", "/api/friend/search/by-user-name");
    return this.http.getEncrypted<UserInfo>(url, {
      user_name: username,
      avatar_size: AvatarSize.Large,
    });
  }

  /** GET `{friend[0]}/api/friend/profile/multiget`. */
  async getMultiUsersByPhones(phones: string[]): Promise<unknown> {
    const url = this.http.serviceUrl("friend", "/api/friend/profile/multiget");
    return this.http.getEncrypted(url, {
      phones: phones.map((p) => (p.startsWith("0") && this.ctx.language === "vi" ? `84${p.slice(1)}` : p)),
      avatar_size: AvatarSize.Large,
      language: this.ctx.language,
    });
  }

  /** POST `{friend[0]}/api/friend/sendreq`. */
  async sendFriendRequest(msg: string, userId: string): Promise<unknown> {
    const url = this.http.serviceUrl("friend", "/api/friend/sendreq");
    return this.http.postEncrypted(url, {
      toid: userId,
      msg,
      reqsrc: 30,
      imei: this.ctx.imei,
      language: this.ctx.language,
      srcParams: JSON.stringify({ uidTo: userId }),
    });
  }

  /** POST `{friend[0]}/api/friend/accept`. */
  async acceptFriendRequest(userId: string): Promise<unknown> {
    const url = this.http.serviceUrl("friend", "/api/friend/accept");
    return this.http.postEncrypted(url, { fid: userId, language: this.ctx.language });
  }

  /** POST `{friend[0]}/api/friend/reject`. */
  async rejectFriendRequest(userId: string): Promise<unknown> {
    const url = this.http.serviceUrl("friend", "/api/friend/reject");
    return this.http.postEncrypted(url, { fid: userId });
  }

  /** POST `{friend[0]}/api/friend/undo`. */
  async undoFriendRequest(userId: string): Promise<unknown> {
    const url = this.http.serviceUrl("friend", "/api/friend/undo");
    return this.http.postEncrypted(url, { fid: userId });
  }

  /** GET `{friend[0]}/api/friend/requested/list`. */
  async getSentFriendRequest(): Promise<GetSentFriendRequestResponse> {
    const url = this.http.serviceUrl("friend", "/api/friend/requested/list");
    return this.http.getEncrypted(url, { imei: this.ctx.imei });
  }

  /** GET `{friend[0]}/api/friend/reqstatus`. */
  async getFriendRequestStatus(userId: string): Promise<GetFriendRequestStatusResponse> {
    const url = this.http.serviceUrl("friend", "/api/friend/reqstatus");
    return this.http.getEncrypted(url, { fid: userId, imei: this.ctx.imei });
  }

  /** GET `{friend[0]}/api/friend/recommendsv2/list`. */
  async getFriendRecommendations(): Promise<GetFriendRecommendationsResponse> {
    const url = this.http.serviceUrl("friend", "/api/friend/recommendsv2/list");
    return this.http.getEncrypted(url, { imei: this.ctx.imei });
  }

  /** POST `{friend[0]}/api/friend/remove`. */
  async removeFriend(userId: string): Promise<unknown> {
    const url = this.http.serviceUrl("friend", "/api/friend/remove");
    return this.http.postEncrypted(url, { fid: userId, imei: this.ctx.imei });
  }

  /** GET `{alias[0]}/api/alias/list`. */
  async getAliasList(count = 100, page = 1): Promise<GetAliasListResponse> {
    const url = this.http.serviceUrl("alias", "/api/alias/list");
    return this.http.getEncrypted(url, { page, count, imei: this.ctx.imei });
  }

  /** GET `{alias[0]}/api/alias/update`. */
  async changeFriendAlias(alias: string, friendId: string): Promise<unknown> {
    const url = this.http.serviceUrl("alias", "/api/alias/update");
    return this.http.getEncrypted(url, { friendId, alias, imei: this.ctx.imei });
  }

  /** GET `{alias[0]}/api/alias/remove`. */
  async removeFriendAlias(friendId: string): Promise<unknown> {
    const url = this.http.serviceUrl("alias", "/api/alias/remove");
    return this.http.getEncrypted(url, { friendId });
  }

  /** POST `{friend[0]}/api/friend/block`. */
  async blockUser(userId: string): Promise<unknown> {
    const url = this.http.serviceUrl("friend", "/api/friend/block");
    return this.http.postEncrypted(url, { fid: userId, imei: this.ctx.imei });
  }

  /** POST `{friend[0]}/api/friend/unblock`. */
  async unblockUser(userId: string): Promise<unknown> {
    const url = this.http.serviceUrl("friend", "/api/friend/unblock");
    return this.http.postEncrypted(url, { fid: userId, imei: this.ctx.imei });
  }

  /** GET `{friend[0]}/api/friend/blocklistv2`. */
  async getBlockList(page = 1, count = 50, avatar = 75): Promise<unknown> {
    const url = this.http.serviceUrl("friend", "/api/friend/blocklistv2");
    return this.http.getEncrypted(url, { page, count, avatar });
  }

  /** POST `{friend[0]}/api/friend/feed/block`. */
  async blockViewFeed(isBlockFeed: boolean, userId: string): Promise<unknown> {
    const url = this.http.serviceUrl("friend", "/api/friend/feed/block");
    return this.http.postEncrypted(url, {
      fid: userId,
      isBlockFeed: isBlockFeed ? 1 : 0,
      imei: this.ctx.imei,
    });
  }

  /** POST `{friend[0]}/api/friend/mget-qr`. */
  async getQR(userIds: string | string[]): Promise<Record<string, string>> {
    const fids = Array.isArray(userIds) ? userIds : [userIds];
    const url = this.http.serviceUrl("friend", "/api/friend/mget-qr");
    return this.http.postEncrypted(url, { fids });
  }

  /** POST report user (`/api/report/abuse-v2`) or group (`/api/social/profile/reportabuse`). */
  async sendReport(
    options: { reason: ReportReason; content?: string },
    threadId: string,
    type: ThreadType = ThreadType.User,
  ): Promise<{ reportId: string }> {
    if (type === ThreadType.Group) {
      const url = this.http.serviceUrl("profile", "/api/social/profile/reportabuse");
      return this.http.postEncrypted(url, {
        uidTo: threadId,
        type: 14,
        reason: options.reason,
        content: options.reason === ReportReason.Other ? options.content ?? "" : "",
        imei: this.ctx.imei,
      });
    }
    const url = this.http.serviceUrl("profile", "/api/report/abuse-v2");
    return this.http.postEncrypted(url, {
      idTo: threadId,
      objId: "person.profile",
      reason: String(options.reason),
      ...(options.reason === ReportReason.Other ? { content: options.content ?? "" } : {}),
    });
  }
}
