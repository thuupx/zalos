import { readFile } from "node:fs/promises";
import { basename } from "node:path";
import type { ZaloContext } from "../core/context.ts";
import type { ZaloHttpClient } from "../core/http.ts";
import type { GetGroupLinkInfoResponse } from "../models/compat.ts";
import type { GroupInfo } from "../models/entities.ts";

export interface CreateGroupOptions {
  name?: string;
  members: string[];
  avatarSource?: string | { data: Buffer; filename: string };
}

export interface UpdateGroupSettingsOptions {
  blockName?: boolean;
  signAdminMsg?: boolean;
  setTopicOnly?: boolean;
  enableMsgHistory?: boolean;
  joinAppr?: boolean;
  lockCreatePost?: boolean;
  lockCreatePoll?: boolean;
  lockSendMsg?: boolean;
  lockViewMember?: boolean;
  bannFeature?: boolean;
  dirtyMedia?: boolean;
  banDuration?: number;
  blockedMembers?: string[];
}

export class GroupsApi {
  constructor(
    private readonly http: ZaloHttpClient,
    private readonly ctx: ZaloContext,
  ) {}

  /** GET `{group_poll[0]}/api/group/getlg/v4` (no encrypted params). */
  async getAllGroups(): Promise<{ version: string; gridVerMap: Record<string, string> }> {
    const url = this.http.serviceUrl("group_poll", "/api/group/getlg/v4");
    return this.http.getPlain(url);
  }

  /** POST `{group[0]}/api/group/create/v2` (Zalo quirk: encrypted `params` sent in query string). */
  async createGroup(options: CreateGroupOptions): Promise<{ groupId: string; [k: string]: unknown }> {
    const url = this.http.serviceUrl("group", "/api/group/create/v2");
    const params = {
      clientId: Date.now(),
      gname: String(Date.now()),
      gdesc: null,
      members: options.members,
      membersTypes: options.members.map(() => -1),
      nameChanged: 0,
      createLink: 1,
      clientLang: this.ctx.language,
      imei: this.ctx.imei,
      zsource: 601,
      ...(options.name ? { gname: options.name, nameChanged: 1 } : {}),
    };
    const created = await this.http.postEncrypted<{ groupId: string; [k: string]: unknown }>(
      url,
      params,
      { paramsInQuery: true },
    );
    if (options.avatarSource && created?.groupId) {
      await this.changeGroupAvatar(options.avatarSource, created.groupId);
    }
    return created;
  }

  /** POST `{group[0]}/api/group/getmg-v2`. */
  async getGroupInfo(groupIds: string | string[]): Promise<{ gridInfoMap: Record<string, GroupInfo> }> {
    const ids = Array.isArray(groupIds) ? groupIds : [groupIds];
    const gridVerMap: Record<string, number> = {};
    for (const id of ids) gridVerMap[id] = 0;
    const url = this.http.serviceUrl("group", "/api/group/getmg-v2");
    return this.http.postEncrypted(url, { gridVerMap: JSON.stringify(gridVerMap) });
  }

  /** GET `{profile[0]}/api/social/group/members`. */
  async getGroupMembersInfo(
    memberIds: string | string[],
  ): Promise<{ profiles: Record<string, Record<string, unknown>>; unchangeds_profile?: unknown[] }> {
    const ids = Array.isArray(memberIds) ? memberIds : [memberIds];
    const url = this.http.serviceUrl("profile", "/api/social/group/members");
    return this.http.getEncrypted(url, {
      friend_pversion_map: ids.map((id) => (id.includes("_") ? id : `${id}_0`)),
    });
  }

  /** POST `{group[0]}/api/group/invite/v2`. */
  async addUserToGroup(memberIds: string | string[], groupId: string): Promise<unknown> {
    const members = Array.isArray(memberIds) ? memberIds : [memberIds];
    const url = this.http.serviceUrl("group", "/api/group/invite/v2");
    return this.http.postEncrypted(url, {
      grid: groupId,
      members,
      memberTypes: members.map(() => -1),
      imei: this.ctx.imei,
      clientLang: this.ctx.language,
    });
  }

  /** GET `{group[0]}/api/group/invite/multi`. */
  async inviteUserToGroups(userId: string, groupIds: string | string[]): Promise<unknown> {
    const grids = Array.isArray(groupIds) ? groupIds : [groupIds];
    const url = this.http.serviceUrl("group", "/api/group/invite/multi");
    return this.http.getEncrypted(url, {
      grids,
      member: userId,
      memberType: -1,
      srcInteraction: 2,
      clientLang: this.ctx.language,
    });
  }

  /** POST `{group[0]}/api/group/kickout`. */
  async removeUserFromGroup(memberIds: string | string[], groupId: string): Promise<unknown> {
    const members = Array.isArray(memberIds) ? memberIds : [memberIds];
    const url = this.http.serviceUrl("group", "/api/group/kickout");
    return this.http.postEncrypted(url, {
      grid: groupId,
      members,
      imei: this.ctx.imei,
    });
  }

  /** POST `{group[0]}/api/group/leave`. */
  async leaveGroup(groupId: string, silent = false): Promise<unknown> {
    const url = this.http.serviceUrl("group", "/api/group/leave");
    return this.http.postEncrypted(url, {
      grids: [groupId],
      imei: this.ctx.imei,
      silent: silent ? 1 : 0,
      language: this.ctx.language,
    });
  }

  /** POST `{group[0]}/api/group/disperse`. */
  async disperseGroup(groupId: string): Promise<unknown> {
    const url = this.http.serviceUrl("group", "/api/group/disperse");
    return this.http.postEncrypted(url, { grid: groupId, imei: this.ctx.imei });
  }

  /** POST `{group[0]}/api/group/updateinfo`. */
  async changeGroupName(name: string, groupId: string): Promise<unknown> {
    const url = this.http.serviceUrl("group", "/api/group/updateinfo");
    return this.http.postEncrypted(url, { grid: groupId, gname: name, imei: this.ctx.imei });
  }

  /** POST `{file[0]}/api/group/upavatar` (multipart `fileContent`). */
  async changeGroupAvatar(
    source: string | { data: Buffer | Uint8Array; filename: string },
    groupId: string,
  ): Promise<unknown> {
    const buf = typeof source === "string" ? await readFile(source) : Buffer.from(source.data);
    const name = typeof source === "string" ? basename(source) : source.filename;
    const url = this.http.serviceUrl("file", "/api/group/upavatar");
    const form = new FormData();
    form.append("fileContent", new Blob([buf], { type: "image/jpeg" }), name);
    return this.http.postMultipart(
      url,
      {
        grid: groupId,
        avatarSize: 120,
        clientId: `g${groupId}${Date.now()}`,
        imei: this.ctx.imei,
        originWidth: 1080,
        originHeight: 1080,
      },
      form,
    );
  }

  /** GET `{group[0]}/api/group/change-owner`. */
  async changeGroupOwner(newOwnerId: string, groupId: string): Promise<unknown> {
    const url = this.http.serviceUrl("group", "/api/group/change-owner");
    return this.http.getEncrypted(url, {
      grid: groupId,
      newAdminId: newOwnerId,
      imei: this.ctx.imei,
      language: this.ctx.language,
    });
  }

  /** GET `{group[0]}/api/group/admins/add`. */
  async addGroupDeputy(memberIds: string | string[], groupId: string): Promise<unknown> {
    const members = Array.isArray(memberIds) ? memberIds : [memberIds];
    const url = this.http.serviceUrl("group", "/api/group/admins/add");
    return this.http.getEncrypted(url, { grid: groupId, members, imei: this.ctx.imei });
  }

  /** GET `{group[0]}/api/group/admins/remove`. */
  async removeGroupDeputy(memberIds: string | string[], groupId: string): Promise<unknown> {
    const members = Array.isArray(memberIds) ? memberIds : [memberIds];
    const url = this.http.serviceUrl("group", "/api/group/admins/remove");
    return this.http.getEncrypted(url, { grid: groupId, members, imei: this.ctx.imei });
  }

  /** GET `{group[0]}/api/group/setting/update`. */
  async updateGroupSettings(options: UpdateGroupSettingsOptions, groupId: string): Promise<unknown> {
    const flag = (v: boolean | undefined) => (v === undefined ? undefined : v ? 1 : 0);
    const url = this.http.serviceUrl("group", "/api/group/setting/update");
    return this.http.getEncrypted(url, {
      grid: groupId,
      imei: this.ctx.imei,
      blockName: flag(options.blockName),
      signAdminMsg: flag(options.signAdminMsg),
      setTopicOnly: flag(options.setTopicOnly),
      enableMsgHistory: flag(options.enableMsgHistory),
      joinAppr: flag(options.joinAppr),
      lockCreatePost: flag(options.lockCreatePost),
      lockCreatePoll: flag(options.lockCreatePoll),
      lockSendMsg: flag(options.lockSendMsg),
      lockViewMember: flag(options.lockViewMember),
      bannFeature: flag(options.bannFeature),
      dirtyMedia: flag(options.dirtyMedia),
      banDuration: options.banDuration,
      blocked_members: options.blockedMembers,
    });
  }

  /** GET `{group[0]}/api/group/pending-mems/list`. */
  async getPendingGroupMembers(groupId: string): Promise<unknown> {
    const url = this.http.serviceUrl("group", "/api/group/pending-mems/list");
    return this.http.getEncrypted(url, { grid: groupId, imei: this.ctx.imei });
  }

  /** GET `{group[0]}/api/group/pending-mems/review`. */
  async reviewPendingMemberRequest(
    payload: { members: string | string[]; isApprove: boolean },
    groupId: string,
  ): Promise<unknown> {
    const members = Array.isArray(payload.members) ? payload.members : [payload.members];
    const url = this.http.serviceUrl("group", "/api/group/pending-mems/review");
    return this.http.getEncrypted(url, {
      grid: groupId,
      members,
      isApprove: payload.isApprove ? 1 : 0,
    });
  }

  /** GET `{group[0]}/api/group/blockedmems/list`. */
  async getGroupBlockedMember(
    payload: { page?: number; count?: number } = {},
    groupId: string,
  ): Promise<unknown> {
    const url = this.http.serviceUrl("group", "/api/group/blockedmems/list");
    return this.http.getEncrypted(url, {
      grid: groupId,
      page: payload.page ?? 1,
      count: payload.count ?? 50,
      imei: this.ctx.imei,
    });
  }

  /** GET `{group[0]}/api/group/blockedmems/add`. */
  async addGroupBlockedMember(memberIds: string | string[], groupId: string): Promise<unknown> {
    const members = Array.isArray(memberIds) ? memberIds : [memberIds];
    const url = this.http.serviceUrl("group", "/api/group/blockedmems/add");
    return this.http.getEncrypted(url, { grid: groupId, members });
  }

  /** GET `{group[0]}/api/group/blockedmems/remove`. */
  async removeGroupBlockedMember(memberIds: string | string[], groupId: string): Promise<unknown> {
    const members = Array.isArray(memberIds) ? memberIds : [memberIds];
    const url = this.http.serviceUrl("group", "/api/group/blockedmems/remove");
    return this.http.getEncrypted(url, { grid: groupId, members });
  }

  /** GET `{group[0]}/api/group/link/detail`. */
  async getGroupLinkDetail(
    groupId: string,
  ): Promise<{ link?: string; expiration_date?: number; enabled: number }> {
    const url = this.http.serviceUrl("group", "/api/group/link/detail");
    return this.http.getEncrypted(url, { grid: groupId, imei: this.ctx.imei });
  }

  /** GET `{group[0]}/api/group/link/new`. */
  async enableGroupLink(groupId: string): Promise<unknown> {
    const url = this.http.serviceUrl("group", "/api/group/link/new");
    return this.http.getEncrypted(url, { grid: groupId, imei: this.ctx.imei });
  }

  /** GET `{group[0]}/api/group/link/disable`. */
  async disableGroupLink(groupId: string): Promise<unknown> {
    const url = this.http.serviceUrl("group", "/api/group/link/disable");
    return this.http.getEncrypted(url, { grid: groupId });
  }

  /** GET `{group[0]}/api/group/link/ginfo`. */
  async getGroupLinkInfo(
    payload: { link: string; memberPage?: number },
  ): Promise<GetGroupLinkInfoResponse> {
    const url = this.http.serviceUrl("group", "/api/group/link/ginfo");
    return this.http.getEncrypted(url, {
      link: payload.link,
      avatar_size: 120,
      member_avatar_size: 120,
      mpage: payload.memberPage ?? 1,
    });
  }

  /** GET `{group[0]}/api/group/link/join`. */
  async joinGroupLink(link: string): Promise<unknown> {
    const url = this.http.serviceUrl("group", "/api/group/link/join");
    return this.http.getEncrypted(url, { link, clientLang: this.ctx.language });
  }

  /** GET `{group[0]}/api/group/inv-box/list`. */
  async getGroupInviteBoxList(
    payload: { mpage?: number; page?: number; invPerPage?: number; mcount?: number; lastGroupId?: string | null } = {},
  ): Promise<unknown> {
    const url = this.http.serviceUrl("group", "/api/group/inv-box/list");
    return this.http.getEncrypted(url, {
      mpage: payload.mpage ?? 1,
      page: payload.page ?? 0,
      invPerPage: payload.invPerPage ?? 12,
      mcount: payload.mcount ?? 10,
      lastGroupId: payload.lastGroupId ?? null,
      avatar_size: 120,
      member_avatar_size: 120,
    });
  }

  /** GET `{group[0]}/api/group/inv-box/inv-info`. */
  async getGroupInviteBoxInfo(payload: { groupId: string; mcount?: number; mpage?: number }): Promise<unknown> {
    const url = this.http.serviceUrl("group", "/api/group/inv-box/inv-info");
    return this.http.getEncrypted(url, {
      grId: payload.groupId,
      mcount: payload.mcount ?? 10,
      mpage: payload.mpage ?? 1,
    });
  }

  /** GET `{group[0]}/api/group/inv-box/join`. */
  async joinGroupInviteBox(groupId: string): Promise<unknown> {
    const url = this.http.serviceUrl("group", "/api/group/inv-box/join");
    return this.http.getEncrypted(url, { grid: groupId, lang: this.ctx.language });
  }

  /** GET `{group[0]}/api/group/inv-box/mdel-inv`. */
  async deleteGroupInviteBox(groupIds: string | string[]): Promise<unknown> {
    const ids = Array.isArray(groupIds) ? groupIds : [groupIds];
    const url = this.http.serviceUrl("group", "/api/group/inv-box/mdel-inv");
    return this.http.getEncrypted(url, {
      invitations: JSON.stringify(ids.map((id) => ({ grid: id }))),
    });
  }

  /** GET `{group[0]}/api/group/upgrade/community`. */
  async upgradeGroupToCommunity(groupId: string): Promise<unknown> {
    const url = this.http.serviceUrl("group", "/api/group/upgrade/community");
    return this.http.getEncrypted(url, { grId: groupId, language: this.ctx.language });
  }

  /** POST `{friend[0]}/api/friend/group/related`. */
  async getRelatedFriendGroup(friendIds: string | string[]): Promise<unknown> {
    const ids = Array.isArray(friendIds) ? friendIds : [friendIds];
    const url = this.http.serviceUrl("friend", "/api/friend/group/related");
    return this.http.postEncrypted(url, { friend_ids: ids, imei: this.ctx.imei });
  }
}
