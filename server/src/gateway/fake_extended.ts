import { RpcError } from "../tunnel/rpc.ts";
import type {
  BankAccount,
  GroupInfo,
  ThreadType,
  ZaloExtendedGateway,
} from "./types.ts";

export interface FakeExtendedHost {
  readonly self: { uid: string; displayName: string; avatarUrl: string };
  readonly calls: { method: string; args: unknown[] }[];
  capabilities(): string[];
  closeFriendIds: Set<string>;
  groupsValue?: GroupInfo[];
  bankAccountsValue: BankAccount[];
  addBankAccount?: (item: BankAccount) => void;
}

export function createFakeExtendedMethods(
  host: FakeExtendedHost,
): ZaloExtendedGateway {
  const ensurePersonal = () => {
    if (host.capabilities().length === 0) {
      throw new RpcError("not_supported", "not supported for OA accounts");
    }
  };
  const record = (method: string, ...args: unknown[]) => {
    ensurePersonal();
    host.calls.push({ method, args });
  };

  let groupSeq = 100;
  let catalogSeq = 1;
  let productSeq = 1;
  let autoReplySeq = 1;
  let bankSeq = 100;

  const groupSettingsMap = new Map<string, Record<string, unknown>>();
  const groupDeputiesMap = new Map<string, Set<string>>();
  const groupOwnersMap = new Map<string, string>();
  const groupPendingMap = new Map<
    string,
    Array<{ uid: string; displayName: string }>
  >();
  const groupBlockedMap = new Map<string, Set<string>>();
  const groupLinksMap = new Map<
    string,
    { enabled: boolean; link?: string; expirationDate?: number }
  >();
  const inviteBox = new Map<string, { groupId: string; name: string }>([
    ["inv-g-1", { groupId: "inv-g-1", name: "Nhóm Mời Test" }],
  ]);

  let profileData: Record<string, unknown> = {
    uid: host.self.uid,
    displayName: host.self.displayName,
    zaloName: host.self.displayName,
    avatar: host.self.avatarUrl,
    dob: "1996-05-15",
    gender: 0,
    bio: "Chào mừng đến với Zalos",
  };
  const avatars = [
    { photoId: "av-1", url: host.self.avatarUrl, ts: 1_700_000_000_000 },
  ];
  const zaloSettingsState: Record<string, unknown> = {
    show_online_status: 1,
    allow_find_phone: 1,
    receive_stranger_msg: 1,
    display_seen_status: 1,
  };
  let activeStatus = true;
  let language = "vi";

  const blockedUsers = new Set<string>(["u-blocked-1"]);
  const blockedFeedUsers = new Set<string>();

  const catalogs: Array<{
    catalogId: string;
    catalogName: string;
    catalogPhoto: string;
  }> = [
    { catalogId: "cat-1", catalogName: "Sản phẩm nổi bật", catalogPhoto: "" },
  ];
  const products = new Map<
    string,
    Array<{
      productId: string;
      catalogId: string;
      productName: string;
      price: string | number;
      description: string;
      currencyUnit: string;
      productPhotos: string[];
    }>
  >([
    [
      "cat-1",
      [
        {
          productId: "prod-1",
          catalogId: "cat-1",
          productName: "Bó hoa hồng",
          price: 250000,
          description: "Hoa tươi mỗi ngày",
          currencyUnit: "₫",
          productPhotos: [],
        },
      ],
    ],
  ]);

  const autoReplies: Array<{
    id: number;
    enable: boolean;
    content: string;
    startTime: number;
    endTime: number;
    scope: number;
    uids: string[];
  }> = [
    {
      id: 1,
      enable: true,
      content: "Cảm ơn bạn đã nhắn tin!",
      startTime: 0,
      endTime: 86_400_000,
      scope: 0,
      uids: [],
    },
  ];
  autoReplySeq = 2;

  const groupMediaStore = new Map<
    string,
    Array<{
      id: string;
      mediaType: string;
      url: string;
      thumbUrl: string;
      name: string;
      ts: number;
    }>
  >();
  const oneOneMedia: Array<{
    id: string;
    mediaType: string;
    url: string;
    thumbUrl: string;
    name: string;
    ts: number;
  }> = [
    {
      id: "m-oneone-1",
      mediaType: "image",
      url: "https://example.com/cloud-1.jpg",
      thumbUrl: "https://example.com/cloud-1-thumb.jpg",
      name: "cloud-1.jpg",
      ts: 1_700_000_000_000,
    },
  ];

  let recentSearchState: {
    items: unknown[];
    version: number;
    keywords: string[];
  } = {
    items: [],
    version: 1,
    keywords: ["hoa", "ship"],
  };

  const e2eeEnabled = new Set<string>();

  return {
    // ---- Groups ----
    async createGroup(opts) {
      record("createGroup", opts);
      const groupId = `g-new-${++groupSeq}`;
      groupOwnersMap.set(groupId, host.self.uid);
      groupLinksMap.set(groupId, {
        enabled: true,
        link: `https://zalo.me/g/${groupId}`,
      });
      return {
        groupId,
        raw: {
          groupId,
          name: opts.name ?? `Group ${groupSeq}`,
          members: opts.members,
        },
      };
    },
    async renameGroup(groupId, name) {
      record("renameGroup", groupId, name);
    },
    async changeGroupAvatar(groupId, file) {
      record("changeGroupAvatar", groupId, file.name);
    },
    async addGroupMembers(groupId, memberIds) {
      record("addGroupMembers", groupId, memberIds);
      return { added: memberIds };
    },
    async inviteUserToGroups(userId, groupIds) {
      record("inviteUserToGroups", userId, groupIds);
      return { invited: groupIds };
    },
    async removeGroupMembers(groupId, memberIds) {
      record("removeGroupMembers", groupId, memberIds);
      return { removed: memberIds };
    },
    async leaveGroup(groupId, silent = false) {
      record("leaveGroup", groupId, silent);
    },
    async disperseGroup(groupId) {
      record("disperseGroup", groupId);
    },
    async changeGroupOwner(groupId, newOwnerId) {
      record("changeGroupOwner", groupId, newOwnerId);
      groupOwnersMap.set(groupId, newOwnerId);
    },
    async addGroupDeputy(groupId, memberIds) {
      record("addGroupDeputy", groupId, memberIds);
      const set = groupDeputiesMap.get(groupId) ?? new Set<string>();
      for (const m of memberIds) set.add(m);
      groupDeputiesMap.set(groupId, set);
    },
    async removeGroupDeputy(groupId, memberIds) {
      record("removeGroupDeputy", groupId, memberIds);
      const set = groupDeputiesMap.get(groupId);
      if (set) {
        for (const m of memberIds) set.delete(m);
      }
    },
    async updateGroupSettings(groupId, settings) {
      record("updateGroupSettings", groupId, settings);
      groupSettingsMap.set(groupId, {
        ...(groupSettingsMap.get(groupId) ?? {}),
        ...settings,
      });
    },
    async pendingGroupMembers(groupId) {
      record("pendingGroupMembers", groupId);
      return { users: groupPendingMap.get(groupId) ?? [] };
    },
    async reviewPendingGroupMembers(groupId, members, isApprove) {
      record("reviewPendingGroupMembers", groupId, members, isApprove);
      const list = groupPendingMap.get(groupId) ?? [];
      groupPendingMap.set(
        groupId,
        list.filter((u) => !members.includes(u.uid)),
      );
      return { ok: true, reviewed: members.length, isApprove };
    },
    async blockedGroupMembers(groupId, page = 1, count = 50) {
      record("blockedGroupMembers", groupId, page, count);
      return {
        blocked_members: [...(groupBlockedMap.get(groupId) ?? [])].map(
          (uid) => ({ id: uid, dName: uid }),
        ),
      };
    },
    async addBlockedGroupMembers(groupId, memberIds) {
      record("addBlockedGroupMembers", groupId, memberIds);
      const set = groupBlockedMap.get(groupId) ?? new Set<string>();
      for (const m of memberIds) set.add(m);
      groupBlockedMap.set(groupId, set);
    },
    async removeBlockedGroupMembers(groupId, memberIds) {
      record("removeBlockedGroupMembers", groupId, memberIds);
      const set = groupBlockedMap.get(groupId);
      if (set) {
        for (const m of memberIds) set.delete(m);
      }
    },
    async groupLinkDetail(groupId) {
      record("groupLinkDetail", groupId);
      return (
        groupLinksMap.get(groupId) ?? {
          enabled: false,
        }
      );
    },
    async enableGroupLink(groupId) {
      record("enableGroupLink", groupId);
      const link = `https://zalo.me/g/${groupId}`;
      groupLinksMap.set(groupId, { enabled: true, link });
      return { link, enabled: 1 };
    },
    async disableGroupLink(groupId) {
      record("disableGroupLink", groupId);
      groupLinksMap.set(groupId, { enabled: false });
    },
    async groupLinkInfo(link, memberPage = 1) {
      record("groupLinkInfo", link, memberPage);
      return {
        groupId: "g-link-preview",
        name: "Nhóm từ liên kết",
        link,
        totalMember: 5,
      };
    },
    async joinGroupLink(link) {
      record("joinGroupLink", link);
      return { ok: true, link };
    },
    async groupInviteBoxList(opts = {}) {
      record("groupInviteBoxList", opts);
      return {
        invitations: [...inviteBox.values()],
        hasMore: false,
      };
    },
    async groupInviteBoxInfo(groupId, mcount = 10, mpage = 1) {
      record("groupInviteBoxInfo", groupId, mcount, mpage);
      return (
        inviteBox.get(groupId) ?? { groupId, name: "Lời mời nhóm", total: 1 }
      );
    },
    async joinGroupInviteBox(groupId) {
      record("joinGroupInviteBox", groupId);
      inviteBox.delete(groupId);
      return { ok: true, groupId };
    },
    async deleteGroupInviteBox(groupIds) {
      record("deleteGroupInviteBox", groupIds);
      for (const id of groupIds) inviteBox.delete(id);
      return { ok: true, deleted: groupIds };
    },
    async upgradeGroupToCommunity(groupId) {
      record("upgradeGroupToCommunity", groupId);
    },
    async relatedFriendGroups(friendIds) {
      record("relatedFriendGroups", friendIds);
      return { groupRelateds: {} };
    },

    // ---- Profile & Settings ----
    async fetchAccountInfo() {
      record("fetchAccountInfo");
      return { profile: { ...profileData, activeStatus, language } };
    },
    async updateProfile(opts) {
      record("updateProfile", opts);
      profileData = {
        ...profileData,
        displayName: opts.name,
        zaloName: opts.name,
        dob: opts.dob,
        gender: opts.gender,
      };
      host.self.displayName = opts.name;
      return { ok: true, profile: profileData };
    },
    async updateProfileBio(bio) {
      record("updateProfileBio", bio);
      profileData.bio = bio;
    },
    async changeAccountAvatar(file) {
      record("changeAccountAvatar", file.name);
      const id = `av-${avatars.length + 1}`;
      const url = `https://example.com/${id}.jpg`;
      avatars.unshift({ photoId: id, url, ts: Date.now() });
      host.self.avatarUrl = url;
      profileData.avatar = url;
      return { photoId: id, url };
    },
    async avatarList(albumId = "0") {
      record("avatarList", albumId);
      return { photos: [...avatars] };
    },
    async reuseAvatar(photoId, isPostSocial = false) {
      record("reuseAvatar", photoId, isPostSocial);
      const found = avatars.find((a) => a.photoId === photoId);
      if (found) {
        host.self.avatarUrl = found.url;
        profileData.avatar = found.url;
      }
      return { ok: true, photoId };
    },
    async deleteAvatar(photoIds) {
      record("deleteAvatar", photoIds);
      for (let i = avatars.length - 1; i >= 0; i--) {
        if (photoIds.includes(avatars[i]!.photoId)) avatars.splice(i, 1);
      }
      return { ok: true, deleted: photoIds };
    },
    async zaloSettings() {
      record("zaloSettings");
      return { ...zaloSettingsState, activeStatus, language };
    },
    async updateZaloSetting(type, value) {
      record("updateZaloSetting", type, value);
      zaloSettingsState[type] = value;
      return { ok: true, [type]: value };
    },
    async updateActiveStatus(active) {
      record("updateActiveStatus", active);
      activeStatus = active;
    },
    async updateLang(lang) {
      record("updateLang", lang);
      language = lang;
    },
    async lostFocus() {
      record("lostFocus");
    },

    // ---- Friends Extras ----
    async setCloseFriend(uids, add) {
      record("setCloseFriend", uids, add);
      for (const u of uids) {
        if (add) host.closeFriendIds.add(u);
        else host.closeFriendIds.delete(u);
      }
    },
    async findUsersByPhones(phones) {
      record("findUsersByPhones", phones);
      return {
        users: phones.map((p) => ({ phone: p, uid: `u-${p}`, displayName: p })),
      };
    },
    async blockList(page = 1, count = 50) {
      record("blockList", page, count);
      return {
        users: [...blockedUsers].map((uid) => ({
          userId: uid,
          displayName: uid,
          avatar: "",
        })),
      };
    },
    async blockViewFeed(uid, blocked) {
      record("blockViewFeed", uid, blocked);
      if (blocked) blockedFeedUsers.add(uid);
      else blockedFeedUsers.delete(uid);
    },
    async userQr(uids) {
      record("userQr", uids);
      const out: Record<string, string> = {};
      for (const u of uids) out[u] = `https://zalo.me/qr/${u}`;
      return out;
    },

    // ---- Board Extras ----
    async removeNote(groupId, topicId) {
      record("removeNote", groupId, topicId);
    },
    async reminderDetail(reminderId) {
      record("reminderDetail", reminderId);
      return { id: reminderId, title: "Nhắc hẹn", repeat: 0 };
    },
    async reminderResponses(reminderId) {
      record("reminderResponses", reminderId);
      return { accept: [host.self.uid], decline: [] };
    },
    async reorderPins(threadId, threadType: ThreadType, topics, version = 0) {
      record("reorderPins", threadId, threadType, topics, version);
      return { ok: true, version: version + 1 };
    },
    async multiUnpinGroup(groupId, topics, version = 0) {
      record("multiUnpinGroup", groupId, topics, version);
      return { ok: true, version: version + 1 };
    },

    // ---- Business ----
    async bizAccount(uid) {
      record("bizAccount", uid);
      return { uid: uid ?? host.self.uid, isBiz: true, bizName: "Tiệm Hoa" };
    },
    async catalogList(opts = {}) {
      record("catalogList", opts);
      return { catalogs: [...catalogs], version: catalogs.length };
    },
    async createCatalog(catalogName, catalogPhoto = "") {
      record("createCatalog", catalogName, catalogPhoto);
      const item = {
        catalogId: `cat-${++catalogSeq}`,
        catalogName,
        catalogPhoto,
      };
      catalogs.push(item);
      products.set(item.catalogId, []);
      return { catalog: item };
    },
    async updateCatalog(opts) {
      record("updateCatalog", opts);
      const hit = catalogs.find((c) => c.catalogId === opts.catalogId);
      if (hit) {
        hit.catalogName = opts.catalogName;
        if (opts.catalogPhoto !== undefined) {
          hit.catalogPhoto = opts.catalogPhoto;
        }
      }
      return { catalog: hit ?? opts };
    },
    async deleteCatalog(catalogId) {
      record("deleteCatalog", catalogId);
      const idx = catalogs.findIndex((c) => c.catalogId === catalogId);
      if (idx >= 0) catalogs.splice(idx, 1);
      products.delete(catalogId);
    },
    async registerCatalog(enable = true) {
      record("registerCatalog", enable);
      return { enabled: enable };
    },
    async productCatalogList(opts) {
      record("productCatalogList", opts);
      return {
        products: [...(products.get(opts.catalogId) ?? [])],
        hasMore: false,
      };
    },
    async createProductCatalog(opts) {
      record("createProductCatalog", opts);
      const item = {
        productId: `prod-${++productSeq}`,
        catalogId: opts.catalogId,
        productName: opts.productName,
        price: opts.price,
        description: opts.description,
        currencyUnit: opts.currencyUnit ?? "₫",
        productPhotos: opts.productPhotos ?? [],
      };
      const list = products.get(opts.catalogId) ?? [];
      list.push(item);
      products.set(opts.catalogId, list);
      return { product: item };
    },
    async updateProductCatalog(opts) {
      record("updateProductCatalog", opts);
      const list = products.get(opts.catalogId) ?? [];
      const hit = list.find((p) => p.productId === opts.productId);
      if (hit) {
        hit.productName = opts.productName;
        hit.price = opts.price;
        hit.description = opts.description;
        if (opts.currencyUnit) hit.currencyUnit = opts.currencyUnit;
        if (opts.productPhotos) hit.productPhotos = opts.productPhotos;
      }
      return { product: hit ?? opts };
    },
    async deleteProductCatalog(catalogId, productIds) {
      record("deleteProductCatalog", catalogId, productIds);
      const list = products.get(catalogId) ?? [];
      products.set(
        catalogId,
        list.filter((p) => !productIds.includes(p.productId)),
      );
      return { ok: true, deleted: productIds };
    },
    async uploadProductPhoto(file) {
      record("uploadProductPhoto", file.name);
      return {
        photoId: `pp-${Date.now()}`,
        thumbUrl: "https://example.com/product-thumb.jpg",
        normalUrl: "https://example.com/product.jpg",
        hdUrl: "https://example.com/product-hd.jpg",
      };
    },
    async autoReplyList() {
      record("autoReplyList");
      return { item: [...autoReplies], version: autoReplies.length };
    },
    async createAutoReply(opts) {
      record("createAutoReply", opts);
      const item = {
        id: autoReplySeq++,
        enable: opts.isEnable,
        content: opts.content,
        startTime: opts.startTime,
        endTime: opts.endTime,
        scope: opts.scope,
        uids: opts.uids ?? [],
      };
      autoReplies.push(item);
      return { item };
    },
    async updateAutoReply(opts) {
      record("updateAutoReply", opts);
      const hit = autoReplies.find((a) => a.id === opts.id);
      if (hit) {
        hit.enable = opts.isEnable;
        hit.content = opts.content;
        hit.startTime = opts.startTime;
        hit.endTime = opts.endTime;
        hit.scope = opts.scope;
        hit.uids = opts.uids ?? [];
      }
      return { item: hit ?? opts };
    },
    async deleteAutoReply(id) {
      record("deleteAutoReply", id);
      const idx = autoReplies.findIndex((a) => a.id === id);
      if (idx >= 0) autoReplies.splice(idx, 1);
    },
    async createBankAccount(opts) {
      record("createBankAccount", opts);
      const item: BankAccount = {
        id: `ba-${++bankSeq}`,
        bin: Number(opts.binBank),
        accountNumber: opts.numAccBank,
        holderName: opts.nameAccBank.toUpperCase(),
        isDefault: false,
        accountId: bankSeq,
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };
      host.bankAccountsValue.push(item);
      return { account: item };
    },
    async updateBankAccount(opts) {
      record("updateBankAccount", opts);
      const hit = host.bankAccountsValue.find((b) => b.id === opts.accountId);
      if (hit) {
        hit.bin = Number(opts.binBank);
        hit.accountNumber = opts.numAccBank;
        hit.holderName = opts.nameAccBank.toUpperCase();
        hit.updatedAt = Date.now();
      }
      return { account: hit ?? opts };
    },
    async deleteBankAccount(accountId, isDefault) {
      record("deleteBankAccount", accountId, isDefault);
      const idx = host.bankAccountsValue.findIndex((b) => b.id === accountId);
      if (idx >= 0) host.bankAccountsValue.splice(idx, 1);
    },

    // ---- Messaging / Conversations / Stickers Extras ----
    async unreadMarks() {
      record("unreadMarks");
      return { data: { convsUser: [], convsGroup: [] }, status: 1 };
    },
    async scanUrl(url) {
      record("scanUrl", url);
      return { url, safe: true, riskLevel: 0 };
    },
    async cloudMessages(opts) {
      record("cloudMessages", opts);
      return { msgs: [], hasMore: false };
    },
    async preloadLastMessages(threadIdLocalMsgId) {
      record("preloadLastMessages", threadIdLocalMsgId);
      return { data: {} };
    },
    async preloadLastSeen(group = [], oneone = []) {
      record("preloadLastSeen", group, oneone);
      return { group, oneone };
    },
    async lastDeliverSeen(oneone = [], group = []) {
      record("lastDeliverSeen", oneone, group);
      return { oneone, group };
    },
    async emojiStatusFriends() {
      record("emojiStatusFriends");
      return { friends: [] };
    },
    async emojiStatusConfig() {
      record("emojiStatusConfig");
      return { items: [] };
    },

    // ---- Extras ----
    async mediaStoreList(groupId, mediaType, opts = {}) {
      record("mediaStoreList", groupId, mediaType, opts);
      const list = groupMediaStore.get(groupId) ?? [
        {
          id: "gm-media-1",
          mediaType,
          url: "https://example.com/group-photo.jpg",
          thumbUrl: "https://example.com/group-photo-thumb.jpg",
          name: "group-photo.jpg",
          ts: 1_700_000_000_000,
        },
      ];
      return { items: list.filter((i) => i.mediaType === mediaType) };
    },
    async mediaStorePreview(groupId, limit = 50) {
      record("mediaStorePreview", groupId, limit);
      return { items: groupMediaStore.get(groupId) ?? [] };
    },
    async mediaStoreRemove(groupId, mediaType, mediaId) {
      record("mediaStoreRemove", groupId, mediaType, mediaId);
      const ids = Array.isArray(mediaId) ? mediaId : [mediaId];
      const list = groupMediaStore.get(groupId) ?? [];
      groupMediaStore.set(
        groupId,
        list.filter((i) => !ids.includes(i.id)),
      );
      return { ok: true, removed: ids };
    },
    async oneOneMediaList(mediaType, opts = {}) {
      record("oneOneMediaList", mediaType, opts);
      return { items: oneOneMedia.filter((i) => i.mediaType === mediaType) };
    },
    async oneOneMediaPreview(limit = 50) {
      record("oneOneMediaPreview", limit);
      return { items: [...oneOneMedia] };
    },
    async oneOneMediaRemove(mediaType, mediaId) {
      record("oneOneMediaRemove", mediaType, mediaId);
      const ids = Array.isArray(mediaId) ? mediaId : [mediaId];
      for (let i = oneOneMedia.length - 1; i >= 0; i--) {
        if (ids.includes(oneOneMedia[i]!.id)) oneOneMedia.splice(i, 1);
      }
      return { ok: true, removed: ids };
    },
    async cloudViewerKey() {
      record("cloudViewerKey");
      return { key: "fake-cloud-viewer-key" };
    },
    async familyViewerKey() {
      record("familyViewerKey");
      return { key: "fake-family-viewer-key" };
    },
    async recentSearch(version = 0) {
      record("recentSearch", version);
      return recentSearchState;
    },
    async updateRecentSearch(listRecent, version, listKeyword = []) {
      record("updateRecentSearch", listRecent, version, listKeyword);
      recentSearchState = {
        items: listRecent,
        version: version + 1,
        keywords: listKeyword,
      };
      return recentSearchState;
    },
    async encryptGroupId(noiseUids) {
      record("encryptGroupId", noiseUids);
      return { map: Object.fromEntries(noiseUids.map((u) => [u, `enc-${u}`])) };
    },
    async decryptGroupId(globalUids) {
      record("decryptGroupId", globalUids);
      return {
        map: Object.fromEntries(
          globalUids.map((u) => [u, u.replace(/^enc-/, "")]),
        ),
      };
    },
    async extrasCommand(command, payload = {}) {
      record("extrasCommand", command, payload);
      return { ok: true, command, payload };
    },
    async e2eeCommand(command, payload = {}) {
      record("e2eeCommand", command, payload);
      const targetId = String(payload.threadId ?? payload.uid ?? payload.destId ?? "");
      if (command === "enableE2ee" && targetId) e2eeEnabled.add(targetId);
      if ((command === "disableE2ee" || command === "downgradeGroupE2ee") && targetId) {
        e2eeEnabled.delete(targetId);
      }
      if (command === "getE2eeUsers") {
        return { users: [...e2eeEnabled] };
      }
      if (command === "checkCompatible" || command === "checkGroupCompatible") {
        return { compatible: true, enabled: e2eeEnabled.has(targetId) };
      }
      if (command === "getKeyId") {
        return { keyId: 1 };
      }
      return { ok: true, command, enabled: e2eeEnabled.has(targetId) };
    },
  };
}
