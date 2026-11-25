import { RpcError } from "../tunnel/rpc.ts";
import type { ChannelContext } from "../tunnel/server.ts";
import type { ThreadType, ZaloExtendedGateway } from "../gateway/types.ts";

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

function reqStr(v: unknown, name: string): string {
  if (typeof v !== "string" || v.trim() === "") {
    throw new RpcError("bad_request", `${name} required`);
  }
  return v.trim();
}

function optStr(v: unknown): string | undefined {
  return typeof v === "string" && v.trim() !== "" ? v.trim() : undefined;
}

function reqBool(v: unknown, name: string): boolean {
  if (typeof v !== "boolean") {
    throw new RpcError("bad_request", `${name} must be a boolean`);
  }
  return v;
}

function reqInt(v: unknown, name: string, min = 0): number {
  if (typeof v !== "number" || !Number.isInteger(v) || v < min) {
    throw new RpcError("bad_request", `${name} must be an integer >= ${min}`);
  }
  return v;
}

function reqStrList(v: unknown, name: string, max = 200): string[] {
  if (!Array.isArray(v) || v.length === 0 || v.length > max) {
    throw new RpcError(
      "bad_request",
      `${name} must be a non-empty array (max ${max})`,
    );
  }
  const out: string[] = [];
  for (let i = 0; i < v.length; i++) {
    out.push(reqStr(v[i], `${name}[${i}]`));
  }
  return out;
}

function objParam(v: unknown): Record<string, unknown> {
  return v !== null && typeof v === "object" && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : {};
}

function requireFn<K extends keyof ZaloExtendedGateway>(
  ctx: ChannelContext,
  slot: string,
  method: K,
  featureLabel: string,
): ZaloExtendedGateway[K] {
  const gw = ctx.accounts.gateway(slot);
  const fn = gw[method];
  if (typeof fn !== "function") {
    throw new RpcError("not_supported", `${featureLabel} not supported`);
  }
  return fn.bind(gw) as ZaloExtendedGateway[K];
}

function removeGroupLocal(
  ctx: ChannelContext,
  slot: string,
  groupId: string,
) {
  ctx.store.deleteThread(slot, groupId, "group");
  ctx.server.broadcastAccount(slot, "thread.deleted", {
    threadId: groupId,
    threadType: "group",
  });
}

async function withUploadedFile<T>(
  ctx: ChannelContext,
  params: Record<string, unknown>,
  defaultName: string,
  fn: (file: { name: string; path: string }) => Promise<T>,
): Promise<T> {
  const stream = reqInt(params.stream, "stream", 1);
  const upload = await ctx.channel.takeUpload(stream);
  try {
    return await fn({
      name: optStr(params.name) ?? defaultName,
      path: upload.filePath,
    });
  } finally {
    ctx.server.discardUpload(upload);
  }
}

type MethodHandler = (
  ctx: ChannelContext,
  params: Record<string, unknown>,
) => Promise<unknown>;

export function extendedAccountMethods(): Record<string, MethodHandler> {
  return {
    // ---- Extended Group Management ----
    "groups.create": async (ctx, params) => {
      const slot = slotOf(ctx);
      const createGroup = requireFn(ctx, slot, "createGroup", "groups");
      const members = reqStrList(params.members, "members");
      const name = optStr(params.name);
      return createGroup({
        ...(name !== undefined ? { name } : {}),
        members,
        ...(optStr(params.avatarPath) !== undefined
          ? { avatarPath: optStr(params.avatarPath) }
          : {}),
      });
    },

    "groups.rename": async (ctx, params) => {
      const slot = slotOf(ctx);
      const renameGroup = requireFn(ctx, slot, "renameGroup", "groups");
      const groupId = reqStr(params.groupId, "groupId");
      const name = reqStr(params.name, "name");
      await renameGroup(groupId, name);
      const existing = ctx.store.getThread(slot, groupId, "group");
      if (existing) {
        ctx.store.updateThreadProfile(
          slot,
          groupId,
          "group",
          name,
          String(existing.avatar_url ?? ""),
        );
        const thread = ctx.accounts.threadWithLast(slot, groupId, "group");
        if (thread) {
          ctx.server.broadcastAccount(slot, "thread.updated", { thread });
        }
      }
      return { ok: true };
    },

    "groups.changeAvatar": async (ctx, params) => {
      const slot = slotOf(ctx);
      const changeGroupAvatar = requireFn(
        ctx,
        slot,
        "changeGroupAvatar",
        "groups",
      );
      const groupId = reqStr(params.groupId, "groupId");
      await withUploadedFile(ctx, params, "group-avatar.jpg", (file) =>
        changeGroupAvatar(groupId, file),
      );
      return { ok: true };
    },

    "groups.addMembers": async (ctx, params) => {
      const slot = slotOf(ctx);
      const addGroupMembers = requireFn(ctx, slot, "addGroupMembers", "groups");
      return addGroupMembers(
        reqStr(params.groupId, "groupId"),
        reqStrList(params.memberIds, "memberIds"),
      );
    },

    "groups.inviteToGroups": async (ctx, params) => {
      const slot = slotOf(ctx);
      const inviteUserToGroups = requireFn(
        ctx,
        slot,
        "inviteUserToGroups",
        "groups",
      );
      return inviteUserToGroups(
        reqStr(params.userId, "userId"),
        reqStrList(params.groupIds, "groupIds"),
      );
    },

    "groups.removeMembers": async (ctx, params) => {
      const slot = slotOf(ctx);
      const removeGroupMembers = requireFn(
        ctx,
        slot,
        "removeGroupMembers",
        "groups",
      );
      return removeGroupMembers(
        reqStr(params.groupId, "groupId"),
        reqStrList(params.memberIds, "memberIds"),
      );
    },

    "groups.leave": async (ctx, params) => {
      const slot = slotOf(ctx);
      const leaveGroup = requireFn(ctx, slot, "leaveGroup", "groups");
      const groupId = reqStr(params.groupId, "groupId");
      await leaveGroup(groupId, params.silent === true);
      removeGroupLocal(ctx, slot, groupId);
      return { ok: true };
    },

    "groups.disperse": async (ctx, params) => {
      const slot = slotOf(ctx);
      const disperseGroup = requireFn(ctx, slot, "disperseGroup", "groups");
      const groupId = reqStr(params.groupId, "groupId");
      await disperseGroup(groupId);
      removeGroupLocal(ctx, slot, groupId);
      return { ok: true };
    },

    "groups.changeOwner": async (ctx, params) => {
      const slot = slotOf(ctx);
      const changeGroupOwner = requireFn(
        ctx,
        slot,
        "changeGroupOwner",
        "groups",
      );
      await changeGroupOwner(
        reqStr(params.groupId, "groupId"),
        reqStr(params.newOwnerId, "newOwnerId"),
      );
      return { ok: true };
    },

    "groups.addDeputy": async (ctx, params) => {
      const slot = slotOf(ctx);
      const addGroupDeputy = requireFn(ctx, slot, "addGroupDeputy", "groups");
      await addGroupDeputy(
        reqStr(params.groupId, "groupId"),
        reqStrList(params.memberIds, "memberIds"),
      );
      return { ok: true };
    },

    "groups.removeDeputy": async (ctx, params) => {
      const slot = slotOf(ctx);
      const removeGroupDeputy = requireFn(
        ctx,
        slot,
        "removeGroupDeputy",
        "groups",
      );
      await removeGroupDeputy(
        reqStr(params.groupId, "groupId"),
        reqStrList(params.memberIds, "memberIds"),
      );
      return { ok: true };
    },

    "groups.updateSettings": async (ctx, params) => {
      const slot = slotOf(ctx);
      const updateGroupSettings = requireFn(
        ctx,
        slot,
        "updateGroupSettings",
        "groups",
      );
      await updateGroupSettings(
        reqStr(params.groupId, "groupId"),
        objParam(params.settings),
      );
      return { ok: true };
    },

    "groups.pendingMembers": async (ctx, params) => {
      const slot = slotOf(ctx);
      const pendingGroupMembers = requireFn(
        ctx,
        slot,
        "pendingGroupMembers",
        "groups",
      );
      return pendingGroupMembers(reqStr(params.groupId, "groupId"));
    },

    "groups.reviewPending": async (ctx, params) => {
      const slot = slotOf(ctx);
      const reviewPendingGroupMembers = requireFn(
        ctx,
        slot,
        "reviewPendingGroupMembers",
        "groups",
      );
      return reviewPendingGroupMembers(
        reqStr(params.groupId, "groupId"),
        reqStrList(params.members, "members"),
        reqBool(params.isApprove, "isApprove"),
      );
    },

    "groups.blockedMembers": async (ctx, params) => {
      const slot = slotOf(ctx);
      const blockedGroupMembers = requireFn(
        ctx,
        slot,
        "blockedGroupMembers",
        "groups",
      );
      return blockedGroupMembers(
        reqStr(params.groupId, "groupId"),
        params.page === undefined ? 1 : reqInt(params.page, "page", 1),
        params.count === undefined ? 50 : reqInt(params.count, "count", 1),
      );
    },

    "groups.blockMembers": async (ctx, params) => {
      const slot = slotOf(ctx);
      const addBlockedGroupMembers = requireFn(
        ctx,
        slot,
        "addBlockedGroupMembers",
        "groups",
      );
      await addBlockedGroupMembers(
        reqStr(params.groupId, "groupId"),
        reqStrList(params.memberIds, "memberIds"),
      );
      return { ok: true };
    },

    "groups.unblockMembers": async (ctx, params) => {
      const slot = slotOf(ctx);
      const removeBlockedGroupMembers = requireFn(
        ctx,
        slot,
        "removeBlockedGroupMembers",
        "groups",
      );
      await removeBlockedGroupMembers(
        reqStr(params.groupId, "groupId"),
        reqStrList(params.memberIds, "memberIds"),
      );
      return { ok: true };
    },

    "groups.linkDetail": async (ctx, params) => {
      const slot = slotOf(ctx);
      const groupLinkDetail = requireFn(ctx, slot, "groupLinkDetail", "groups");
      return groupLinkDetail(reqStr(params.groupId, "groupId"));
    },

    "groups.enableLink": async (ctx, params) => {
      const slot = slotOf(ctx);
      const enableGroupLink = requireFn(ctx, slot, "enableGroupLink", "groups");
      return enableGroupLink(reqStr(params.groupId, "groupId"));
    },

    "groups.disableLink": async (ctx, params) => {
      const slot = slotOf(ctx);
      const disableGroupLink = requireFn(
        ctx,
        slot,
        "disableGroupLink",
        "groups",
      );
      await disableGroupLink(reqStr(params.groupId, "groupId"));
      return { ok: true };
    },

    "groups.linkInfo": async (ctx, params) => {
      const slot = slotOf(ctx);
      const groupLinkInfo = requireFn(ctx, slot, "groupLinkInfo", "groups");
      return groupLinkInfo(
        reqStr(params.link, "link"),
        params.memberPage === undefined
          ? 1
          : reqInt(params.memberPage, "memberPage", 1),
      );
    },

    "groups.joinLink": async (ctx, params) => {
      const slot = slotOf(ctx);
      const joinGroupLink = requireFn(ctx, slot, "joinGroupLink", "groups");
      return joinGroupLink(reqStr(params.link, "link"));
    },

    "groups.inviteBoxList": async (ctx, params) => {
      const slot = slotOf(ctx);
      const groupInviteBoxList = requireFn(
        ctx,
        slot,
        "groupInviteBoxList",
        "groups",
      );
      return groupInviteBoxList({
        page: typeof params.page === "number" ? params.page : undefined,
        mpage: typeof params.mpage === "number" ? params.mpage : undefined,
        invPerPage:
          typeof params.invPerPage === "number" ? params.invPerPage : undefined,
        mcount: typeof params.mcount === "number" ? params.mcount : undefined,
        lastGroupId:
          typeof params.lastGroupId === "string"
            ? params.lastGroupId
            : undefined,
      });
    },

    "groups.inviteBoxInfo": async (ctx, params) => {
      const slot = slotOf(ctx);
      const groupInviteBoxInfo = requireFn(
        ctx,
        slot,
        "groupInviteBoxInfo",
        "groups",
      );
      return groupInviteBoxInfo(
        reqStr(params.groupId, "groupId"),
        params.mcount === undefined ? 10 : reqInt(params.mcount, "mcount", 1),
        params.mpage === undefined ? 1 : reqInt(params.mpage, "mpage", 1),
      );
    },

    "groups.inviteBoxJoin": async (ctx, params) => {
      const slot = slotOf(ctx);
      const joinGroupInviteBox = requireFn(
        ctx,
        slot,
        "joinGroupInviteBox",
        "groups",
      );
      return joinGroupInviteBox(reqStr(params.groupId, "groupId"));
    },

    "groups.inviteBoxDelete": async (ctx, params) => {
      const slot = slotOf(ctx);
      const deleteGroupInviteBox = requireFn(
        ctx,
        slot,
        "deleteGroupInviteBox",
        "groups",
      );
      return deleteGroupInviteBox(reqStrList(params.groupIds, "groupIds"));
    },

    "groups.upgradeCommunity": async (ctx, params) => {
      const slot = slotOf(ctx);
      const upgradeGroupToCommunity = requireFn(
        ctx,
        slot,
        "upgradeGroupToCommunity",
        "groups",
      );
      await upgradeGroupToCommunity(reqStr(params.groupId, "groupId"));
      return { ok: true };
    },

    "groups.relatedFriendGroups": async (ctx, params) => {
      const slot = slotOf(ctx);
      const relatedFriendGroups = requireFn(
        ctx,
        slot,
        "relatedFriendGroups",
        "groups",
      );
      return relatedFriendGroups(reqStrList(params.friendIds, "friendIds"));
    },

    // ---- Profile & Settings ----
    "profile.me": async (ctx) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "fetchAccountInfo", "profile")();
    },

    "profile.update": async (ctx, params) => {
      const slot = slotOf(ctx);
      const updateProfile = requireFn(ctx, slot, "updateProfile", "profile");
      return updateProfile({
        name: reqStr(params.name, "name"),
        dob: reqStr(params.dob, "dob"),
        gender: reqInt(params.gender, "gender", 0),
        ...(optStr(params.language) !== undefined
          ? { language: optStr(params.language) }
          : {}),
      });
    },

    "profile.updateBio": async (ctx, params) => {
      const slot = slotOf(ctx);
      const updateProfileBio = requireFn(
        ctx,
        slot,
        "updateProfileBio",
        "profile",
      );
      await updateProfileBio(String(params.bio ?? ""));
      return { ok: true };
    },

    "profile.changeAvatar": async (ctx, params) => {
      const slot = slotOf(ctx);
      const changeAccountAvatar = requireFn(
        ctx,
        slot,
        "changeAccountAvatar",
        "profile",
      );
      return withUploadedFile(ctx, params, "avatar.jpg", (file) =>
        changeAccountAvatar(file),
      );
    },

    "profile.avatarList": async (ctx, params) => {
      const slot = slotOf(ctx);
      const avatarList = requireFn(ctx, slot, "avatarList", "profile");
      return avatarList(optStr(params.albumId) ?? "0");
    },

    "profile.reuseAvatar": async (ctx, params) => {
      const slot = slotOf(ctx);
      const reuseAvatar = requireFn(ctx, slot, "reuseAvatar", "profile");
      return reuseAvatar(
        reqStr(params.photoId, "photoId"),
        params.isPostSocial === true,
      );
    },

    "profile.deleteAvatar": async (ctx, params) => {
      const slot = slotOf(ctx);
      const deleteAvatar = requireFn(ctx, slot, "deleteAvatar", "profile");
      return deleteAvatar(reqStrList(params.photoIds, "photoIds"));
    },

    "profile.settings": async (ctx) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "zaloSettings", "profile settings")();
    },

    "profile.updateSettings": async (ctx, params) => {
      const slot = slotOf(ctx);
      const updateZaloSetting = requireFn(
        ctx,
        slot,
        "updateZaloSetting",
        "profile settings",
      );
      return updateZaloSetting(
        reqStr(params.type, "type"),
        reqInt(params.value, "value", 0),
      );
    },

    "profile.updateActiveStatus": async (ctx, params) => {
      const slot = slotOf(ctx);
      const updateActiveStatus = requireFn(
        ctx,
        slot,
        "updateActiveStatus",
        "profile settings",
      );
      await updateActiveStatus(reqBool(params.active, "active"));
      return { ok: true };
    },

    "profile.updateLang": async (ctx, params) => {
      const slot = slotOf(ctx);
      const updateLang = requireFn(ctx, slot, "updateLang", "profile settings");
      await updateLang(reqStr(params.language, "language"));
      return { ok: true };
    },

    "profile.lostFocus": async (ctx) => {
      const slot = slotOf(ctx);
      await requireFn(ctx, slot, "lostFocus", "profile")();
      return { ok: true };
    },

    // ---- Friends Extras ----
    "contacts.setCloseFriend": async (ctx, params) => {
      const slot = slotOf(ctx);
      const setCloseFriend = requireFn(
        ctx,
        slot,
        "setCloseFriend",
        "close friends",
      );
      await setCloseFriend(
        reqStrList(params.uids, "uids"),
        reqBool(params.add, "add"),
      );
      return { ok: true };
    },

    "contacts.findPhones": async (ctx, params) => {
      const slot = slotOf(ctx);
      const findUsersByPhones = requireFn(
        ctx,
        slot,
        "findUsersByPhones",
        "contacts lookup",
      );
      return findUsersByPhones(reqStrList(params.phones, "phones"));
    },

    "contacts.blockList": async (ctx, params) => {
      const slot = slotOf(ctx);
      const blockList = requireFn(ctx, slot, "blockList", "block list");
      return blockList(
        params.page === undefined ? 1 : reqInt(params.page, "page", 1),
        params.count === undefined ? 50 : reqInt(params.count, "count", 1),
      );
    },

    "contacts.blockFeed": async (ctx, params) => {
      const slot = slotOf(ctx);
      const blockViewFeed = requireFn(ctx, slot, "blockViewFeed", "block feed");
      await blockViewFeed(
        reqStr(params.uid, "uid"),
        reqBool(params.blocked, "blocked"),
      );
      return { ok: true };
    },

    "contacts.qr": async (ctx, params) => {
      const slot = slotOf(ctx);
      const userQr = requireFn(ctx, slot, "userQr", "user QR");
      return { qr: await userQr(reqStrList(params.uids, "uids")) };
    },

    // ---- Board Extras ----
    "notes.remove": async (ctx, params) => {
      const slot = slotOf(ctx);
      const removeNote = requireFn(ctx, slot, "removeNote", "notes");
      const groupId = reqStr(params.groupId, "groupId");
      await removeNote(groupId, reqStr(params.topicId, "topicId"));
      ctx.server.broadcastAccount(slot, "board.updated", {
        threadId: groupId,
        threadType: "group",
      });
      return { ok: true };
    },

    "reminders.detail": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "reminderDetail", "reminders")(
        reqStr(params.reminderId, "reminderId"),
      );
    },

    "reminders.responses": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "reminderResponses", "reminders")(
        reqStr(params.reminderId, "reminderId"),
      );
    },

    "pins.reorder": async (ctx, params) => {
      const slot = slotOf(ctx);
      const reorderPins = requireFn(ctx, slot, "reorderPins", "pins");
      const threadId = reqStr(params.threadId, "threadId");
      const threadType = tt(params.threadType);
      const topics = Array.isArray(params.topics) ? params.topics : [];
      const res = await reorderPins(
        threadId,
        threadType,
        topics,
        typeof params.version === "number" ? params.version : 0,
      );
      ctx.server.broadcastAccount(slot, "board.updated", {
        threadId,
        threadType,
      });
      return res;
    },

    "pins.multiUnpin": async (ctx, params) => {
      const slot = slotOf(ctx);
      const multiUnpinGroup = requireFn(ctx, slot, "multiUnpinGroup", "pins");
      const groupId = reqStr(params.groupId, "groupId");
      const topics = Array.isArray(params.topics)
        ? (params.topics as Record<string, unknown>[])
        : [];
      const res = await multiUnpinGroup(
        groupId,
        topics,
        typeof params.version === "number" ? params.version : 0,
      );
      ctx.server.broadcastAccount(slot, "board.updated", {
        threadId: groupId,
        threadType: "group",
      });
      return res;
    },

    // ---- Business Tools ----
    "business.info": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "bizAccount", "business tools")(
        optStr(params.uid),
      );
    },

    "catalogs.list": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "catalogList", "catalogs")({
        versionListCatalog:
          typeof params.versionListCatalog === "number"
            ? params.versionListCatalog
            : undefined,
        limit: typeof params.limit === "number" ? params.limit : undefined,
        lastProductId:
          typeof params.lastProductId === "number"
            ? params.lastProductId
            : undefined,
        page: typeof params.page === "number" ? params.page : undefined,
      });
    },

    "catalogs.create": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "createCatalog", "catalogs")(
        reqStr(params.catalogName, "catalogName"),
        optStr(params.catalogPhoto) ?? "",
      );
    },

    "catalogs.update": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "updateCatalog", "catalogs")({
        catalogId: reqStr(params.catalogId, "catalogId"),
        catalogName: reqStr(params.catalogName, "catalogName"),
        ...(optStr(params.catalogPhoto) !== undefined
          ? { catalogPhoto: optStr(params.catalogPhoto) }
          : {}),
      });
    },

    "catalogs.delete": async (ctx, params) => {
      const slot = slotOf(ctx);
      await requireFn(ctx, slot, "deleteCatalog", "catalogs")(
        reqStr(params.catalogId, "catalogId"),
      );
      return { ok: true };
    },

    "catalogs.register": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "registerCatalog", "catalogs")(
        params.enable !== false,
      );
    },

    "catalogs.products.list": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "productCatalogList", "catalogs")({
        catalogId: reqStr(params.catalogId, "catalogId"),
        limit: typeof params.limit === "number" ? params.limit : undefined,
        versionCatalog:
          typeof params.versionCatalog === "number"
            ? params.versionCatalog
            : undefined,
        lastProductId:
          typeof params.lastProductId === "number"
            ? params.lastProductId
            : undefined,
        page: typeof params.page === "number" ? params.page : undefined,
      });
    },

    "catalogs.products.create": async (ctx, params) => {
      const slot = slotOf(ctx);
      const price =
        typeof params.price === "number" || typeof params.price === "string"
          ? params.price
          : reqStr(params.price, "price");
      return requireFn(ctx, slot, "createProductCatalog", "catalogs")({
        catalogId: reqStr(params.catalogId, "catalogId"),
        productName: reqStr(params.productName, "productName"),
        price,
        description: String(params.description ?? ""),
        ...(Array.isArray(params.productPhotos)
          ? { productPhotos: params.productPhotos.map(String) }
          : {}),
        ...(optStr(params.currencyUnit) !== undefined
          ? { currencyUnit: optStr(params.currencyUnit) }
          : {}),
      });
    },

    "catalogs.products.update": async (ctx, params) => {
      const slot = slotOf(ctx);
      const price =
        typeof params.price === "number" || typeof params.price === "string"
          ? params.price
          : reqStr(params.price, "price");
      return requireFn(ctx, slot, "updateProductCatalog", "catalogs")({
        catalogId: reqStr(params.catalogId, "catalogId"),
        productId: reqStr(params.productId, "productId"),
        productName: reqStr(params.productName, "productName"),
        price,
        description: String(params.description ?? ""),
        ...(Array.isArray(params.productPhotos)
          ? { productPhotos: params.productPhotos.map(String) }
          : {}),
        ...(optStr(params.currencyUnit) !== undefined
          ? { currencyUnit: optStr(params.currencyUnit) }
          : {}),
      });
    },

    "catalogs.products.delete": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "deleteProductCatalog", "catalogs")(
        reqStr(params.catalogId, "catalogId"),
        reqStrList(params.productIds, "productIds"),
      );
    },

    "catalogs.products.uploadPhoto": async (ctx, params) => {
      const slot = slotOf(ctx);
      const uploadProductPhoto = requireFn(
        ctx,
        slot,
        "uploadProductPhoto",
        "catalogs",
      );
      return withUploadedFile(ctx, params, "product.jpg", (file) =>
        uploadProductPhoto(file),
      );
    },

    "autoReply.list": async (ctx) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "autoReplyList", "auto reply")();
    },

    "autoReply.create": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "createAutoReply", "auto reply")({
        isEnable: reqBool(params.isEnable, "isEnable"),
        content: reqStr(params.content, "content"),
        startTime: Number(params.startTime ?? 0),
        endTime: Number(params.endTime ?? 86_400_000),
        scope: Number(params.scope ?? 0),
        ...(Array.isArray(params.uids)
          ? { uids: params.uids.map(String) }
          : {}),
      });
    },

    "autoReply.update": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "updateAutoReply", "auto reply")({
        id: reqInt(params.id, "id", 1),
        isEnable: reqBool(params.isEnable, "isEnable"),
        content: reqStr(params.content, "content"),
        startTime: Number(params.startTime ?? 0),
        endTime: Number(params.endTime ?? 86_400_000),
        scope: Number(params.scope ?? 0),
        ...(Array.isArray(params.uids)
          ? { uids: params.uids.map(String) }
          : {}),
      });
    },

    "autoReply.delete": async (ctx, params) => {
      const slot = slotOf(ctx);
      await requireFn(ctx, slot, "deleteAutoReply", "auto reply")(
        reqInt(params.id, "id", 1),
      );
      return { ok: true };
    },

    "banks.createAccount": async (ctx, params) => {
      const slot = slotOf(ctx);
      const binBank =
        typeof params.binBank === "number" || typeof params.binBank === "string"
          ? params.binBank
          : reqInt(params.binBank, "binBank", 1);
      return requireFn(ctx, slot, "createBankAccount", "bank accounts")({
        binBank,
        numAccBank: reqStr(params.numAccBank, "numAccBank"),
        nameAccBank: reqStr(params.nameAccBank, "nameAccBank"),
      });
    },

    "banks.updateAccount": async (ctx, params) => {
      const slot = slotOf(ctx);
      const binBank =
        typeof params.binBank === "number" || typeof params.binBank === "string"
          ? params.binBank
          : reqInt(params.binBank, "binBank", 1);
      return requireFn(ctx, slot, "updateBankAccount", "bank accounts")({
        accountId: reqStr(params.accountId, "accountId"),
        binBank,
        numAccBank: reqStr(params.numAccBank, "numAccBank"),
        nameAccBank: reqStr(params.nameAccBank, "nameAccBank"),
      });
    },

    "banks.deleteAccount": async (ctx, params) => {
      const slot = slotOf(ctx);
      await requireFn(ctx, slot, "deleteBankAccount", "bank accounts")(
        reqStr(params.accountId, "accountId"),
        params.isDefault === true,
      );
      return { ok: true };
    },

    // ---- Messaging / Conversations / Stickers / Media Store / Search / Sync / Backup / E2EE ----
    "threads.unreadMarks": async (ctx) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "unreadMarks", "unread marks")();
    },

    "messages.scanUrl": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "scanUrl", "scan url")(
        reqStr(params.url, "url"),
      );
    },

    "messages.cloudHistory": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "cloudMessages", "cloud messages")({
        groupId: reqStr(params.groupId, "groupId"),
        ...(optStr(params.globalMsgId) !== undefined
          ? { globalMsgId: optStr(params.globalMsgId) }
          : {}),
        ...(typeof params.count === "number" ? { count: params.count } : {}),
        ...(Array.isArray(params.msgIds)
          ? { msgIds: params.msgIds.map(String) }
          : {}),
        ...(typeof params.isOA === "boolean" ? { isOA: params.isOA } : {}),
        ...(typeof params.src === "number" ? { src: params.src } : {}),
      });
    },

    "messages.preloadLast": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "preloadLastMessages", "preload messages")(
        objParam(params.threadIdLocalMsgId),
      );
    },

    "messages.preloadLastSeen": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "preloadLastSeen", "preload seen")(
        Array.isArray(params.group) ? params.group : [],
        Array.isArray(params.oneone) ? params.oneone : [],
      );
    },

    "messages.lastDeliverSeen": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "lastDeliverSeen", "deliver seen")(
        Array.isArray(params.oneone) ? params.oneone : [],
        Array.isArray(params.group) ? params.group : [],
      );
    },

    "stickers.emojiStatusFriends": async (ctx) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "emojiStatusFriends", "emoji status")();
    },

    "stickers.emojiStatusConfig": async (ctx) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "emojiStatusConfig", "emoji status")();
    },

    "mediaStore.list": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "mediaStoreList", "media store")(
        reqStr(params.groupId, "groupId"),
        reqStr(params.mediaType, "mediaType"),
        {
          ...(typeof params.limit === "number" ? { limit: params.limit } : {}),
          ...(params.lastId !== undefined
            ? { lastId: params.lastId as string | number }
            : {}),
          ...(typeof params.lastFetchId === "number"
            ? { lastFetchId: params.lastFetchId }
            : {}),
        },
      );
    },

    "mediaStore.preview": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "mediaStorePreview", "media store")(
        reqStr(params.groupId, "groupId"),
        typeof params.limit === "number" ? params.limit : 50,
      );
    },

    "mediaStore.remove": async (ctx, params) => {
      const slot = slotOf(ctx);
      const mediaId = Array.isArray(params.mediaId)
        ? reqStrList(params.mediaId, "mediaId")
        : reqStr(params.mediaId, "mediaId");
      return requireFn(ctx, slot, "mediaStoreRemove", "media store")(
        reqStr(params.groupId, "groupId"),
        reqStr(params.mediaType, "mediaType"),
        mediaId,
      );
    },

    "mediaStore.oneOneList": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "oneOneMediaList", "media store")(
        reqStr(params.mediaType, "mediaType"),
        {
          ...(typeof params.limit === "number" ? { limit: params.limit } : {}),
          ...(params.lastId !== undefined
            ? { lastId: params.lastId as string | number }
            : {}),
          ...(typeof params.lastFetchId === "number"
            ? { lastFetchId: params.lastFetchId }
            : {}),
        },
      );
    },

    "mediaStore.oneOnePreview": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "oneOneMediaPreview", "media store")(
        typeof params.limit === "number" ? params.limit : 50,
      );
    },

    "mediaStore.oneOneRemove": async (ctx, params) => {
      const slot = slotOf(ctx);
      const mediaId = Array.isArray(params.mediaId)
        ? reqStrList(params.mediaId, "mediaId")
        : reqStr(params.mediaId, "mediaId");
      return requireFn(ctx, slot, "oneOneMediaRemove", "media store")(
        reqStr(params.mediaType, "mediaType"),
        mediaId,
      );
    },

    "cloud.viewerKey": async (ctx) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "cloudViewerKey", "cloud")();
    },

    "cloud.familyViewerKey": async (ctx) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "familyViewerKey", "cloud")();
    },

    "search.recent": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "recentSearch", "recent search")(
        typeof params.version === "number" ? params.version : 0,
      );
    },

    "search.updateRecent": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "updateRecentSearch", "recent search")(
        Array.isArray(params.listRecent) ? params.listRecent : [],
        reqInt(params.version ?? 0, "version", 0),
        Array.isArray(params.listKeyword)
          ? params.listKeyword.map(String)
          : [],
      );
    },

    "groups.encryptId": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "encryptGroupId", "groups")(
        reqStrList(params.noiseUids, "noiseUids"),
      );
    },

    "groups.decryptId": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "decryptGroupId", "groups")(
        reqStrList(params.globalUids, "globalUids"),
      );
    },

    // ---- Sync, Backup, Interactive Files, Payment, Media Upload URL ----
    "sync.mobileRequest": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "extrasCommand", "sync")(
        "requestMobileSync",
        params,
      );
    },

    "sync.ackDelete": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "extrasCommand", "sync")(
        "ackDeleteSyncSession",
        params,
      );
    },

    "sync.wakeMobile": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "extrasCommand", "sync")(
        "wakeMobileForSync",
        params,
      );
    },

    "backup.init": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "extrasCommand", "backup")(
        "backupInit",
        params,
      );
    },

    "backup.createSession": async (ctx) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "extrasCommand", "backup")(
        "backupCreateSession",
      );
    },

    "backup.metadata": async (ctx) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "extrasCommand", "backup")(
        "backupGetMetadata",
      );
    },

    "backup.signalRestore": async (ctx) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "extrasCommand", "backup")(
        "backupSignalRestore",
      );
    },

    "backup.configs": async (ctx) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "extrasCommand", "backup")(
        "backupGetConfigs",
      );
    },

    "interactiveFiles.submit": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "extrasCommand", "interactive files")(
        "submitInteractiveFile",
        objParam(params.payload ?? params),
      );
    },

    "interactiveFiles.pull": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "extrasCommand", "interactive files")(
        "pullInteractiveFiles",
        params,
      );
    },

    "payment.inAppLink": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "extrasCommand", "payment")(
        "getInAppPaymentLink",
        { domain: reqStr(params.domain, "domain") },
      );
    },

    "media.uploadUrl": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "extrasCommand", "media")(
        "getMediaUploadUrl",
        params,
      );
    },

    // ---- E2EE ----
    "e2ee.users": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "e2eeCommand", "e2ee")("getE2eeUsers", params);
    },

    "e2ee.keyId": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "e2eeCommand", "e2ee")("getKeyId", params);
    },

    "e2ee.checkCompatible": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "e2eeCommand", "e2ee")("checkCompatible", {
        uids: reqStrList(params.uids, "uids"),
      });
    },

    "e2ee.checkGroupCompatible": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "e2eeCommand", "e2ee")(
        "checkGroupCompatible",
        {
          uids: reqStrList(params.uids, "uids"),
          groupId: reqStr(params.groupId, "groupId"),
          enableEE: params.enableEE ?? 1,
        },
      );
    },

    "e2ee.enable": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "e2eeCommand", "e2ee")("enableE2ee", params);
    },

    "e2ee.disable": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "e2eeCommand", "e2ee")(
        "disableE2ee",
        params,
      );
    },

    "e2ee.downgradeGroup": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "e2eeCommand", "e2ee")(
        "downgradeGroupE2ee",
        params,
      );
    },

    "e2ee.command": async (ctx, params) => {
      const slot = slotOf(ctx);
      return requireFn(ctx, slot, "e2eeCommand", "e2ee")(
        reqStr(params.command, "command"),
        objParam(params.payload),
      );
    },

    // ---- Extended Call Actions ----
    "calls.hold": async (ctx, params) => {
      const slot = slotOf(ctx);
      const action = params.hold === false ? "unholdRequest" : "holdRequest";
      return ctx.accounts.calls.zaloSignal(
        slot,
        reqStr(params.callId, "callId"),
        action,
        { toId: reqStr(params.peerId, "peerId") },
      );
    },

    "calls.switchMedia": async (ctx, params) => {
      const slot = slotOf(ctx);
      return ctx.accounts.calls.zaloSignal(
        slot,
        reqStr(params.callId, "callId"),
        "requestAudioToVideo",
        { calleeId: reqStr(params.peerId, "peerId"), ...objParam(params.data) },
      );
    },

    "calls.shareScreen": async (ctx, params) => {
      const slot = slotOf(ctx);
      const isGroup = Boolean(optStr(params.groupId));
      return ctx.accounts.calls.zaloSignal(
        slot,
        reqStr(params.callId, "callId"),
        isGroup ? "groupShareScreen" : "requestShareScreen",
        params,
      );
    },

    "calls.groupAddUser": async (ctx, params) => {
      const slot = slotOf(ctx);
      return ctx.accounts.calls.zaloSignal(
        slot,
        reqStr(params.callId, "callId"),
        "groupAddUser",
        params,
      );
    },

    "calls.groupJoin": async (ctx, params) => {
      const slot = slotOf(ctx);
      return ctx.accounts.calls.zaloSignal(
        slot,
        reqStr(params.callId, "callId"),
        "groupJoin",
        params,
      );
    },

    "calls.resolveZNoise": async (ctx, params) => {
      const slot = slotOf(ctx);
      return ctx.accounts.calls.zaloSignal(slot, "znoise", "resolveZNoise", {
        fids: Array.isArray(params.fids) ? params.fids.map(String) : [],
        gids: Array.isArray(params.gids) ? params.gids.map(String) : [],
      });
    },
  };
}
