import type {
  API,
  BinBankCard,
  Gender,
  PreKeyUpload,
  UpdateGroupSettingsOptions,
} from "@zalos/zalo-sdk";
import { RpcError } from "../tunnel/rpc.ts";
import type { ZaloExtendedGateway } from "./types.ts";

export function dispatchExtendedCallSignal(
  api: API,
  action: string,
  payload: Record<string, unknown>,
): Promise<unknown> | null {
  switch (action) {
    case "sendCallInvite":
      return api.call.sendCallInvite({
        calleeId: String(payload.calleeId ?? ""),
        rtcpAddress: String(payload.rtcpAddress ?? ""),
        rtpAddress: String(payload.rtpAddress ?? ""),
        codec: String(payload.codec ?? "[]"),
        session: payload.session ?? "",
        callId: String(payload.callId ?? ""),
        ...(payload.extendData !== undefined
          ? { extendData: payload.extendData }
          : {}),
      });
    case "answerAck":
      return api.call.answerAck(
        String(payload.calleeId ?? ""),
        String(payload.callId ?? ""),
        Number(payload.status ?? 0),
      );
    case "cancelCall":
      return api.call.cancelCall(
        String(payload.toId ?? payload.peerId ?? ""),
        String(payload.callId ?? ""),
        Number(payload.callType ?? 1),
        Number(payload.status ?? 0),
      );
    case "logEndCall":
      return api.call.logEndCall({
        call_id: String(payload.call_id ?? payload.callId ?? ""),
        partner_id: String(payload.partner_id ?? payload.peerId ?? ""),
        status: Number(payload.status ?? 3),
        logdata: payload.logdata ?? {},
        duration: Number(payload.duration ?? 0),
        role: Number(payload.role ?? 1),
      });
    case "holdRequest":
    case "hold":
      return api.call.holdRequest(String(payload.toId ?? payload.peerId ?? ""));
    case "holdResponse":
      return api.call.holdResponse(String(payload.toId ?? payload.peerId ?? ""));
    case "unholdRequest":
    case "unhold":
      return api.call.unholdRequest(String(payload.toId ?? payload.peerId ?? ""));
    case "unholdResponse":
      return api.call.unholdResponse(String(payload.toId ?? payload.peerId ?? ""));
    case "requestShareScreen":
      return api.call.requestShareScreen(
        String(payload.uidTo ?? payload.peerId ?? ""),
        String(payload.callId ?? ""),
        Number(payload.status ?? 1),
      );
    case "requestAudioToVideo":
    case "switchMedia":
      return api.call.requestAudioToVideo(payload);
    case "groupSendInvite":
      return api.call.groupSendInvite(
        payload as unknown as Parameters<API["call"]["groupSendInvite"]>[0],
      );
    case "groupAddUser":
      return api.call.groupAddUser(
        payload as unknown as Parameters<API["call"]["groupAddUser"]>[0],
      );
    case "groupRingRing":
      return api.call.groupRingRing(
        payload as unknown as Parameters<API["call"]["groupRingRing"]>[0],
      );
    case "groupFinish":
      return api.call.groupFinish(
        payload as unknown as Parameters<API["call"]["groupFinish"]>[0],
      );
    case "groupNotify":
      return api.call.groupNotify(
        payload as unknown as Parameters<API["call"]["groupNotify"]>[0],
      );
    case "groupPing":
      return api.call.groupPing(
        payload as unknown as Parameters<API["call"]["groupPing"]>[0],
      );
    case "groupBroadcast":
      return api.call.groupBroadcast(
        payload as unknown as Parameters<API["call"]["groupBroadcast"]>[0],
      );
    case "groupJoin":
      return api.call.groupJoin(
        payload as unknown as Parameters<API["call"]["groupJoin"]>[0],
      );
    case "groupShareScreen":
      return api.call.groupShareScreen(
        payload as unknown as Parameters<API["call"]["groupShareScreen"]>[0],
      );
    case "resolveZNoise":
      return api.call.resolveZNoise(
        Array.isArray(payload.fids) ? payload.fids.map(String) : [],
        Array.isArray(payload.gids) ? payload.gids.map(String) : [],
      );
    case "uploadCallLog": {
      const logBytes =
        typeof payload.logBase64 === "string"
          ? Buffer.from(payload.logBase64, "base64")
          : Buffer.from(String(payload.logText ?? ""), "utf8");
      return api.call.uploadCallLog({
        callId: String(payload.callId ?? ""),
        ownerId: String(payload.ownerId ?? ""),
        partnerId:
          typeof payload.partnerId === "string" ? payload.partnerId : undefined,
        hostCall:
          typeof payload.hostCall === "string" ? payload.hostCall : undefined,
        joinTime:
          typeof payload.joinTime === "number" ? payload.joinTime : undefined,
        timestamp: Number(payload.timestamp ?? Date.now()),
        duration: Number(payload.duration ?? 0),
        logType:
          typeof payload.logType === "number" ? payload.logType : undefined,
        logBytes,
        alreadyGzipped: payload.alreadyGzipped === true,
      });
    }
    default:
      return null;
  }
}

export function createZcaExtendedMethods(
  withApi: <T>(fn: (api: API) => Promise<T>) => Promise<T>,
  onSelfUpdated?: (patch: { displayName?: string; avatarUrl?: string }) => void,
): ZaloExtendedGateway {
  return {
    // ---- Groups ----
    async createGroup(opts) {
      const res = await withApi((api) =>
        api.groups.createGroup({
          name: opts.name,
          members: opts.members,
          avatarSource: opts.avatarPath,
        }),
      );
      return {
        groupId: String(res?.groupId ?? ""),
        raw: res,
      };
    },
    async renameGroup(groupId, name) {
      await withApi((api) => api.groups.changeGroupName(name, groupId));
    },
    async changeGroupAvatar(groupId, file) {
      await withApi((api) => api.groups.changeGroupAvatar(file.path, groupId));
    },
    addGroupMembers(groupId, memberIds) {
      return withApi((api) => api.groups.addUserToGroup(memberIds, groupId));
    },
    inviteUserToGroups(userId, groupIds) {
      return withApi((api) => api.groups.inviteUserToGroups(userId, groupIds));
    },
    removeGroupMembers(groupId, memberIds) {
      return withApi((api) => api.groups.removeUserFromGroup(memberIds, groupId));
    },
    async leaveGroup(groupId, silent = false) {
      await withApi((api) => api.groups.leaveGroup(groupId, silent));
    },
    async disperseGroup(groupId) {
      await withApi((api) => api.groups.disperseGroup(groupId));
    },
    async changeGroupOwner(groupId, newOwnerId) {
      await withApi((api) => api.groups.changeGroupOwner(newOwnerId, groupId));
    },
    async addGroupDeputy(groupId, memberIds) {
      await withApi((api) => api.groups.addGroupDeputy(memberIds, groupId));
    },
    async removeGroupDeputy(groupId, memberIds) {
      await withApi((api) => api.groups.removeGroupDeputy(memberIds, groupId));
    },
    async updateGroupSettings(groupId, settings) {
      await withApi((api) =>
        api.groups.updateGroupSettings(
          settings as UpdateGroupSettingsOptions,
          groupId,
        ),
      );
    },
    pendingGroupMembers(groupId) {
      return withApi((api) => api.groups.getPendingGroupMembers(groupId));
    },
    reviewPendingGroupMembers(groupId, members, isApprove) {
      return withApi((api) =>
        api.groups.reviewPendingMemberRequest({ members, isApprove }, groupId),
      );
    },
    blockedGroupMembers(groupId, page = 1, count = 50) {
      return withApi((api) =>
        api.groups.getGroupBlockedMember({ page, count }, groupId),
      );
    },
    async addBlockedGroupMembers(groupId, memberIds) {
      await withApi((api) =>
        api.groups.addGroupBlockedMember(memberIds, groupId),
      );
    },
    async removeBlockedGroupMembers(groupId, memberIds) {
      await withApi((api) =>
        api.groups.removeGroupBlockedMember(memberIds, groupId),
      );
    },
    async groupLinkDetail(groupId) {
      const res = await withApi((api) => api.groups.getGroupLinkDetail(groupId));
      return {
        link: res?.link,
        expirationDate: res?.expiration_date,
        enabled: res?.enabled === 1,
      };
    },
    enableGroupLink(groupId) {
      return withApi((api) => api.groups.enableGroupLink(groupId));
    },
    async disableGroupLink(groupId) {
      await withApi((api) => api.groups.disableGroupLink(groupId));
    },
    groupLinkInfo(link, memberPage = 1) {
      return withApi((api) =>
        api.groups.getGroupLinkInfo({ link, memberPage }),
      );
    },
    joinGroupLink(link) {
      return withApi((api) => api.groups.joinGroupLink(link));
    },
    groupInviteBoxList(opts = {}) {
      return withApi((api) => api.groups.getGroupInviteBoxList(opts));
    },
    groupInviteBoxInfo(groupId, mcount = 10, mpage = 1) {
      return withApi((api) =>
        api.groups.getGroupInviteBoxInfo({ groupId, mcount, mpage }),
      );
    },
    joinGroupInviteBox(groupId) {
      return withApi((api) => api.groups.joinGroupInviteBox(groupId));
    },
    deleteGroupInviteBox(groupIds) {
      return withApi((api) => api.groups.deleteGroupInviteBox(groupIds));
    },
    async upgradeGroupToCommunity(groupId) {
      await withApi((api) => api.groups.upgradeGroupToCommunity(groupId));
    },
    relatedFriendGroups(friendIds) {
      return withApi((api) => api.groups.getRelatedFriendGroup(friendIds));
    },

    // ---- Profile & Settings ----
    async fetchAccountInfo() {
      const res = await withApi((api) => api.profile.fetchAccountInfo());
      return (res ?? {}) as unknown as Record<string, unknown>;
    },
    async updateProfile(opts) {
      const res = await withApi((api) =>
        api.profile.updateProfile({
          name: opts.name,
          dob: opts.dob as `${number}-${number}-${number}`,
          gender: opts.gender as Gender,
          language: opts.language,
        }),
      );
      onSelfUpdated?.({ displayName: opts.name });
      return res;
    },
    async updateProfileBio(bio) {
      await withApi((api) => api.profile.updateProfileBio(bio));
    },
    changeAccountAvatar(file) {
      return withApi((api) => api.profile.changeAccountAvatar(file.path));
    },
    avatarList(albumId = "0") {
      return withApi((api) => api.profile.getAvatarList(albumId));
    },
    reuseAvatar(photoId, isPostSocial = false) {
      return withApi((api) => api.profile.reuseAvatar(photoId, isPostSocial));
    },
    deleteAvatar(photoIds) {
      return withApi((api) => api.profile.deleteAvatar(photoIds));
    },
    zaloSettings() {
      return withApi((api) => api.profile.getSettings());
    },
    updateZaloSetting(type, value) {
      return withApi((api) => api.profile.updateSettings(type, value));
    },
    async updateActiveStatus(active) {
      await withApi((api) => api.profile.updateActiveStatus(active));
    },
    async updateLang(language) {
      await withApi((api) => api.profile.updateLang(language));
    },
    async lostFocus() {
      await withApi((api) => api.profile.lostFocus());
    },

    // ---- Friends Extras ----
    async setCloseFriend(uids, add) {
      await withApi((api) => api.friends.updateCloseFriend(uids, add));
    },
    findUsersByPhones(phones) {
      return withApi((api) => api.friends.getMultiUsersByPhones(phones));
    },
    blockList(page = 1, count = 50) {
      return withApi((api) => api.friends.getBlockList(page, count));
    },
    async blockViewFeed(uid, blocked) {
      await withApi((api) => api.friends.blockViewFeed(blocked, uid));
    },
    userQr(uids) {
      return withApi((api) => api.friends.getQR(uids));
    },

    // ---- Board Extras ----
    async removeNote(groupId, topicId) {
      await withApi((api) => api.board.removeGroupNote(topicId, groupId));
    },
    reminderDetail(reminderId) {
      return withApi((api) => api.board.getReminder(reminderId));
    },
    reminderResponses(reminderId) {
      return withApi((api) => api.board.getReminderResponses(reminderId));
    },
    reorderPins(threadId, threadType, topics, version = 0) {
      return withApi((api) =>
        threadType === "group"
          ? api.board.reorderGroupPins(
              threadId,
              topics as Record<string, unknown>[],
              version,
            )
          : api.board.reorderFriendPins(
              threadId,
              topics as Array<string | number | Record<string, unknown>>,
              version,
            ),
      );
    },
    multiUnpinGroup(groupId, topics, version = 0) {
      return withApi((api) =>
        api.board.multiUnpinGroupTopics(groupId, topics, version),
      );
    },

    // ---- Business ----
    bizAccount(uid) {
      return withApi((api) => api.business.getBizAccount(uid));
    },
    catalogList(opts = {}) {
      return withApi((api) => api.business.getCatalogList(opts));
    },
    createCatalog(catalogName, catalogPhoto = "") {
      return withApi((api) =>
        api.business.createCatalog(catalogName, catalogPhoto),
      );
    },
    updateCatalog(opts) {
      return withApi((api) => api.business.updateCatalog(opts));
    },
    async deleteCatalog(catalogId) {
      await withApi((api) => api.business.deleteCatalog(catalogId));
    },
    registerCatalog(enable = true) {
      return withApi((api) => api.business.registerCatalog(enable));
    },
    productCatalogList(opts) {
      return withApi((api) => api.business.getProductCatalogList(opts));
    },
    createProductCatalog(opts) {
      return withApi((api) => api.business.createProductCatalog(opts));
    },
    updateProductCatalog(opts) {
      return withApi((api) => api.business.updateProductCatalog(opts));
    },
    deleteProductCatalog(catalogId, productIds) {
      return withApi((api) =>
        api.business.deleteProductCatalog({ catalogId, productIds }),
      );
    },
    uploadProductPhoto(file) {
      return withApi((api) => api.business.uploadProductPhoto(file.path));
    },
    autoReplyList() {
      return withApi((api) => api.business.getAutoReplyList());
    },
    createAutoReply(opts) {
      return withApi((api) => api.business.createAutoReply(opts));
    },
    updateAutoReply(opts) {
      return withApi((api) => api.business.updateAutoReply(opts));
    },
    async deleteAutoReply(id) {
      await withApi((api) => api.business.deleteAutoReply(id));
    },
    createBankAccount(opts) {
      return withApi((api) =>
        api.business.createBankAccount({
          binBank: opts.binBank as BinBankCard | string,
          numAccBank: opts.numAccBank,
          nameAccBank: opts.nameAccBank,
        }),
      );
    },
    updateBankAccount(opts) {
      return withApi((api) =>
        api.business.updateBankAccount({
          accountId: opts.accountId,
          binBank: opts.binBank as BinBankCard | string,
          numAccBank: opts.numAccBank,
          nameAccBank: opts.nameAccBank,
        }),
      );
    },
    async deleteBankAccount(accountId, isDefault) {
      await withApi((api) =>
        api.business.deleteBankAccount({ accountId, isDefault }),
      );
    },

    // ---- Messaging / Conversations / Stickers Extras ----
    unreadMarks() {
      return withApi((api) => api.conversations.getUnreadMark());
    },
    scanUrl(url) {
      return withApi((api) => api.messaging.scanURL(url));
    },
    cloudMessages(opts) {
      return withApi((api) =>
        api.messaging.getCloudMessage(
          opts as Parameters<API["messaging"]["getCloudMessage"]>[0],
        ),
      );
    },
    preloadLastMessages(threadIdLocalMsgId) {
      return withApi((api) =>
        api.messaging.preloadLastMessages(threadIdLocalMsgId),
      );
    },
    preloadLastSeen(group = [], oneone = []) {
      return withApi((api) => api.messaging.preloadLastSeen(group, oneone));
    },
    lastDeliverSeen(oneone = [], group = []) {
      return withApi((api) => api.messaging.getLastDeliverSeen(oneone, group));
    },
    emojiStatusFriends() {
      return withApi((api) => api.stickers.getEmojiStatusFriends());
    },
    emojiStatusConfig() {
      return withApi((api) => api.stickers.getEmojiStatusConfig());
    },

    // ---- Extras ----
    mediaStoreList(groupId, mediaType, opts = {}) {
      return withApi((api) =>
        api.extras.listMediaStore(groupId, mediaType, opts),
      );
    },
    mediaStorePreview(groupId, limit = 50) {
      return withApi((api) => api.extras.previewMediaStore(groupId, limit));
    },
    mediaStoreRemove(groupId, mediaType, mediaId) {
      return withApi((api) =>
        api.extras.removeMediaStore(groupId, mediaType, mediaId),
      );
    },
    oneOneMediaList(mediaType, opts = {}) {
      return withApi((api) => api.extras.listOneOneMedia(mediaType, opts));
    },
    oneOneMediaPreview(limit = 50) {
      return withApi((api) => api.extras.previewOneOneMedia(limit));
    },
    oneOneMediaRemove(mediaType, mediaId) {
      return withApi((api) =>
        api.extras.removeOneOneMedia(mediaType, mediaId),
      );
    },
    cloudViewerKey() {
      return withApi((api) => api.extras.getCloudViewerKey());
    },
    familyViewerKey() {
      return withApi((api) => api.extras.getFamilyViewerKey());
    },
    recentSearch(version = 0) {
      return withApi((api) => api.extras.getRecentSearch(version));
    },
    updateRecentSearch(listRecent, version, listKeyword = []) {
      return withApi((api) =>
        api.extras.updateRecentSearch(listRecent, version, listKeyword),
      );
    },
    encryptGroupId(noiseUids) {
      return withApi((api) => api.extras.encryptGroupId(noiseUids));
    },
    decryptGroupId(globalUids) {
      return withApi((api) => api.extras.decryptGroupId(globalUids));
    },
    extrasCommand(command, payload = {}) {
      return withApi((api) => {
        switch (command) {
          case "requestMobileSync":
            return api.extras.requestMobileSync(
              (payload.data as Record<string, unknown> | undefined) ?? payload,
            );
          case "ackDeleteSyncSession":
            return api.extras.ackDeleteSyncSession(
              (payload.data as Record<string, unknown> | undefined) ?? payload,
            );
          case "wakeMobileForSync":
            return api.extras.wakeMobileForSync(
              (payload.data as Record<string, unknown> | undefined) ?? payload,
            );
          case "backupInit":
            return api.extras.backupInit(
              (payload.data as Record<string, unknown> | undefined) ?? payload,
            );
          case "backupCreateSession":
            return api.extras.backupCreateSession();
          case "backupGetMetadata":
            return api.extras.backupGetMetadata();
          case "backupSignalRestore":
            return api.extras.backupSignalRestore();
          case "backupGetConfigs":
            return api.extras.backupGetConfigs();
          case "submitInteractiveFile":
            return api.extras.submitInteractiveFile(payload);
          case "pullInteractiveFiles":
            return api.extras.pullInteractiveFiles(
              Number(payload.lastId ?? 0),
              Number(payload.maxItem ?? 50),
            );
          case "getInAppPaymentLink":
            return api.extras.getInAppPaymentLink(String(payload.domain ?? ""));
          case "getMediaUploadUrl":
            return api.extras.getMediaUploadUrl(payload);
          default:
            throw new RpcError(
              "bad_request",
              `unknown extras command: ${command}`,
            );
        }
      });
    },

    // ---- E2EE ----
    e2eeCommand(command, payload = {}) {
      return withApi((api) => {
        switch (command) {
          case "submitBundle":
            return api.e2ee.submitBundle(
              payload as unknown as Parameters<API["e2ee"]["submitBundle"]>[0],
            );
          case "getBundle":
            return api.e2ee.getBundle(
              (payload.uids as Array<{ uid: string; deviceId?: number }>) ?? [],
              Number(payload.isReInit ?? 0),
              Number(payload.isAutoUpgrade ?? 0),
            );
          case "submitPreKeys":
            return api.e2ee.submitPreKeys(
              Number(payload.deviceId ?? 0),
              Number(payload.id ?? 0),
              (payload.opKeys as PreKeyUpload[]) ?? [],
            );
          case "initSession":
            return api.e2ee.initSession(
              Number(payload.type ?? 0),
              String(payload.uidTo ?? ""),
              payload.data,
            );
          case "ackInitSession":
            return api.e2ee.ackInitSession(
              Number(payload.type ?? 0),
              String(payload.uidTo ?? ""),
              (payload.data as Array<Record<string, unknown>>) ?? [],
            );
          case "markSessionProcessed":
            return api.e2ee.markSessionProcessed(
              String(payload.queueName ?? ""),
              payload.info,
            );
          case "ackGroupSessionsStale":
            return api.e2ee.ackGroupSessionsStale(
              Array.isArray(payload.groupIds)
                ? payload.groupIds.map(String)
                : [],
              typeof payload.ts === "number" ? payload.ts : undefined,
            );
          case "deleteKey":
            return api.e2ee.deleteKey(
              payload as unknown as Parameters<API["e2ee"]["deleteKey"]>[0],
            );
          case "deleteOfflineAck":
            return api.e2ee.deleteOfflineAck(
              Boolean(payload.isGroup),
              Array.isArray(payload.delivereds) ? payload.delivereds : [],
            );
          case "checkCompatible":
            return api.e2ee.checkCompatible(
              Array.isArray(payload.uids) ? payload.uids.map(String) : [],
            );
          case "initGroupSession":
            return api.e2ee.initGroupSession(
              Number(payload.type ?? 0),
              String(payload.uidTo ?? ""),
              String(payload.tId ?? ""),
              (payload.data as Array<Record<string, unknown>>) ?? [],
            );
          case "checkGroupCompatible":
            return api.e2ee.checkGroupCompatible(
              Array.isArray(payload.uids) ? payload.uids.map(String) : [],
              String(payload.groupId ?? ""),
              Number(payload.enableEE ?? 1),
            );
          case "getE2eeUsers":
            return api.e2ee.getE2eeUsers(
              payload.first !== false,
              typeof payload.lastId === "string" ? payload.lastId : null,
            );
          case "getKeyId":
            return api.e2ee.getKeyId(Number(payload.platformType ?? 2));
          case "enableE2ee":
            return api.e2ee.enableE2ee(payload);
          case "disableE2ee":
            return api.e2ee.disableE2ee(payload);
          case "downgradeGroupE2ee":
            return api.e2ee.downgradeGroupE2ee(
              String(payload.destId ?? ""),
              (payload.id as string | number) ?? "",
              Number(payload.reason ?? 0),
            );
          case "sendE2eeMessage":
            return api.e2ee.sendE2eeMessage(
              (payload.kind as Parameters<API["e2ee"]["sendE2eeMessage"]>[0]) ??
                "sms",
              (payload.body as Record<string, unknown>) ?? payload,
              Boolean(payload.isGroup),
            );
          case "undoE2eeMessage":
            return api.e2ee.undoE2eeMessage(
              payload as unknown as Parameters<
                API["e2ee"]["undoE2eeMessage"]
              >[0],
              Boolean(payload.isGroup),
            );
          case "multiUndoE2eeMessage":
            return api.e2ee.multiUndoE2eeMessage(
              String(payload.threadId ?? ""),
              Array.isArray(payload.msgs) ? payload.msgs : [],
              Boolean(payload.isGroup),
            );
          case "deleteE2eeMessage":
            return api.e2ee.deleteE2eeMessage(
              (payload.body as Record<string, unknown>) ?? payload,
              Boolean(payload.isGroup),
            );
          case "deleteE2eeConversation":
            return api.e2ee.deleteE2eeConversation(
              (payload.body as Record<string, unknown>) ?? payload,
              Boolean(payload.isGroup),
            );
          case "sendE2eeDelivered":
            return api.e2ee.sendE2eeDelivered(
              (payload.body as Record<string, unknown>) ?? payload,
              Boolean(payload.isGroup),
            );
          case "sendE2eeSeen":
            return api.e2ee.sendE2eeSeen(
              (payload.body as Record<string, unknown>) ?? payload,
              Boolean(payload.isGroup),
            );
          default:
            throw new RpcError("bad_request", `unknown e2ee command: ${command}`);
        }
      });
    },
  };
}
