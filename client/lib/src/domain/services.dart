
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';

/// Contract between the UI layer and the data layer. The UI only talks to
/// these interfaces. Two implementations exist: the real one (tunnel to a
/// zalos server) and a demo one with in-memory sample data.
///
/// All `ValueListenable`s are safe to read synchronously and notify on change.
/// Every timestamp is epoch milliseconds.

abstract class ZalosApp {
  /// Null until a server is paired.
  ValueListenable<ServerLink?> get link;

  /// Pair with a server from a `zalos://pair?...` uri. Throws [PairingException].
  Future<void> pair(String uri, {required String deviceName});

  /// Forget the paired server and wipe local keys.
  Future<void> unpair();

  /// Whether this device can open stored history.
  ValueListenable<VaultState> get vault;

  /// Fingerprint of this device's box key, shown while waiting for approval.
  String get boxFingerprint;

  /// The vault root as a recovery code. Throws when the vault is not ready.
  Future<String> exportRecoveryCode();

  /// Makes the vault ready from a recovery code. Throws [FormatException] on
  /// a malformed code.
  Future<void> importRecoveryCode(String code);

  /// Sends a fresh vault request to the server, e.g. after a rejection.
  Future<void> requestVaultApproval();
}

/// Why pairing failed. The UI maps the code to localized text and only uses
/// [PairingException.message] for logs and as a detail (e.g. the host).
enum PairingErrorCode {
  /// The text is not a zalos pairing uri.
  invalid,
  /// The one-time code expired or was already used.
  expired,
  /// The server could not be reached; message carries `host:port`.
  unreachable,
  /// The Noise handshake failed (wrong server key or tampering).
  handshake,
  /// The server answered but refused to pair.
  refused,
  /// The server sent a reply this client does not understand.
  protocol,
  /// The device keys could not be stored locally.
  storage,
  unknown,
}

class PairingException implements Exception {
  const PairingException(this.message, {this.code = PairingErrorCode.unknown, this.detail});
  final String message;
  final PairingErrorCode code;
  /// Code specific detail for the UI, e.g. `host:port` for [PairingErrorCode.unreachable].
  final String? detail;
  @override
  String toString() => message;
}

/// Optional lifecycle hook for server links that maintain live sockets and
/// should wake immediately on foreground resume or background refresh.
abstract interface class WakeableLink {
  void wake();
}

/// The control channel of one paired server.
abstract class ServerLink {
  ValueListenable<LinkState> get state;
  ValueListenable<Manifest?> get manifest;

  /// Session for an account slot listed in the manifest. Sessions are created
  /// lazily, kept connected, and cached per slot.
  AccountSession account(String slot);

  Future<List<DeviceInfo>> listDevices();
  Future<void> revokeDevice(String deviceId);
  Future<void> setDeviceAcl(String deviceId, List<String> slots);

  /// The returned uri carries the vault root, so it must only be shown as a
  /// QR on this device and never sent through the server.
  Future<PairingOffer> createPairing({required DeviceRole role});

  /// Devices waiting for the vault root. Empty for non-admin devices.
  ValueListenable<List<VaultRequest>> get vaultRequests;

  /// Wraps the vault root for the requesting device. Call only after the user
  /// confirmed the fingerprint.
  Future<void> approveVaultRequest(VaultRequest request);

  /// Clears a pending vault request; the requesting device is notified.
  Future<void> rejectVaultRequest(VaultRequest request);

  /// True after this device's vault request was rejected; cleared when a new
  /// request is sent or the root arrives.
  ValueListenable<bool> get vaultRejected;
  Stream<LoginQrEvent> startLoginQr();
  /// Adds a Zalo Official Account. Returns its slot. Throws with a readable
  /// message when the credentials are rejected by Zalo. Admin only.
  Future<String> addOaAccount(OaCredentials credentials);

  /// Replaces the tokens of an Official Account that needs login again.
  Future<void> updateOaTokens(String slot, {required String accessToken, required String refreshToken});
  Future<void> removeAccount(String slot);
}

/// The private tunnel of one Zalo account.
abstract class AccountSession {
  String get slot;
  ValueListenable<LinkState> get state;

  /// Sorted: pinned first, then by lastTs descending.
  ValueListenable<List<Thread>> get threads;

  /// Load progress of [threads]: [LoadState.loading] until the first server
  /// answer (cached threads may already be listed), [LoadState.failed] when
  /// it could not be fetched.
  ValueListenable<LoadState> get threadsLoad;

  /// Retries the thread list fetch after [LoadState.failed].
  Future<void> reloadThreads();

  /// Messages of a thread, oldest first, including optimistic local sends.
  /// The first call for a thread loads the latest page.
  ValueListenable<List<Message>> messages(String threadId, ThreadType type);

  /// Load progress of the latest page of [messages] for the same thread.
  ValueListenable<LoadState> messagesLoad(String threadId, ThreadType type);

  /// Retries the latest page fetch after [LoadState.failed].
  Future<void> reloadMessages(String threadId, ThreadType type);

  /// Loads one older page. Returns false when there is nothing older.
  Future<bool> loadOlder(String threadId, ThreadType type);

  Stream<TypingEvent> get typing;

  Future<void> sendText(
    String threadId,
    ThreadType type,
    String text, {
    Message? quote,
    List<Mention> mentions = const [],
    List<StyleRun> styles = const [],
    MessageUrgency? urgency,
    int? ttl,
  });
  /// Uploads [file] with an optional [caption], delivery [urgency] and
  /// per-message [ttl] in ms. The server refuses urgency for voice and video
  /// attachments with `not_supported`.
  Future<void> sendFile(
    String threadId,
    ThreadType type,
    OutgoingFile file, {
    String? caption,
    MessageUrgency? urgency,
    int? ttl,
  });
  Future<void> sendSticker(String threadId, ThreadType type, StickerRef sticker);

  /// Shares [card] into a conversation. Optimistic like [sendSticker]: the
  /// card is listed at once and the server dedupes the cliId on retry.
  /// Requires [AccountCapability.contactCard].
  Future<void> sendCard(String threadId, ThreadType type, ContactCard card);

  /// Parses [link] into the composer preview. Requires
  /// [AccountCapability.linkPreview].
  Future<LinkPreview> parseLink(String link);

  /// Shares [link] with an optional [msg] note and per-message [ttl] in ms.
  /// Optimistic like [sendText]; the server dedupes the cliId on retry.
  Future<void> sendLink(String threadId, ThreadType type, String link, {String? msg, int? ttl});

  /// Shares [card]. The real API answers without a msgId, so no optimistic
  /// record is listed: the bubble arrives from the server echo. The cliId
  /// still guards retries against a double send. Requires
  /// [AccountCapability.bankCard].
  Future<void> sendBankCard(String threadId, ThreadType type, BankCard card);

  /// Banks the composer can attach a card from. Requires
  /// [AccountCapability.bankAccounts].
  Future<List<BankInfo>> banks();

  /// One page of the account's saved bank accounts. [page] starts at 0 and
  /// [limit] is 1..50.
  Future<BankAccounts> bankAccounts({int page = 0, int limit = 20});

  /// Stored composer shortcuts with the version and cursor they were read
  /// at. Requires [AccountCapability.quickMessages].
  Future<QuickMessages> quickMessages();

  /// Adds [draft]. Returns the stored item and the new list version.
  Future<({QuickMessage item, int version})> addQuickMessage(QuickMessageDraft draft);

  /// Replaces the fields of quick message [id].
  Future<({QuickMessage item, int version})> updateQuickMessage(int id, QuickMessageDraft draft);

  /// Removes [ids]. Returns the removed ids and the new list version.
  Future<({List<int> itemIds, int version})> removeQuickMessages(List<int> ids);

  /// Retries a message whose [Message.sendState] is failed, in place.
  Future<void> resend(Message message);
  Future<List<StickerRef>> searchStickers(String query);

  /// Loads all stickers belonging to one Zalo sticker pack ([cateId]).
  Future<List<StickerRef>> stickerCategory(int cateId) async => const [];

  /// Empty [icon] removes the reaction.
  Future<void> react(Message message, String icon);
  Future<void> recall(Message message);
  Future<void> deleteForMe(Message message);

  /// Deletes [message] for everyone in a group. The server enforces that the
  /// account is the group owner or a deputy; local state follows the
  /// sequenced deletion event. Requires [AccountCapability.deleteForAll].
  Future<void> deleteForAll(Message message);

  /// Reports the conversation to Zalo. [content] is required when [reason]
  /// is [ReportReason.other]. Returns the server report id.
  /// Requires [AccountCapability.report].
  Future<String> report(String threadId, ThreadType type, ReportReason reason, {String? content});
  Future<void> markSeen(String threadId, ThreadType type);

  /// Thread level actions. Each one is applied on Zalo and reflected to every
  /// device through [threads].
  Future<void> setPinned(String threadId, ThreadType type, bool pinned);
  Future<void> setMuted(String threadId, ThreadType type, bool muted);
  Future<void> markUnread(String threadId, ThreadType type);

  /// Removes the conversation and its stored history for this account.
  Future<void> deleteThread(String threadId, ThreadType type);

  /// Hidden conversations and whether the account PIN is set. The PIN itself
  /// is write-only and never returned. Requires [AccountCapability.hidden].
  Future<HiddenConversations> hiddenConversations();
  Future<void> setHidden(String threadId, ThreadType type, bool hidden);

  /// Sets the hidden conversations PIN. The value is forwarded to Zalo and
  /// never stored or logged. Requires [AccountCapability.hidden].
  Future<void> setHiddenPin(String pin);
  Future<void> resetHiddenPin();

  /// Archived conversations and the archive list version. Requires
  /// [AccountCapability.archive].
  Future<ArchivedChatList> archivedChats();
  Future<void> setArchived(String threadId, ThreadType type, bool archived);

  /// Whole label set with its version. Requires [AccountCapability.labels].
  Future<LabelsState> labels();

  /// Replaces the whole label set at [version]. A stale version fails with
  /// the server `conflict` code; reload with [labels] and retry.
  Future<LabelsState> updateLabels(List<ConversationLabel> labels, int version);

  /// Conversations with auto-delete enabled. Requires
  /// [AccountCapability.autoDelete].
  Future<AutoDeleteChat> autoDeleteChats();

  /// Sets the auto-delete TTL of a conversation. [ttl] must be one of
  /// [autoDeleteTtls]; 0 turns it off.
  Future<void> setAutoDelete(String threadId, ThreadType type, int ttl);

  /// Companion sessions signed in to this Zalo account. Read only, and free
  /// of identity and signature blobs. Requires [AccountCapability.zaloDevices].
  Future<LinkedDevices> linkedDevices();

  /// Forwards [message] to each destination. Requires [Message.raw].
  Future<void> forward(Message message, List<ThreadRef> to);

  /// Profiles for arbitrary user ids (group members, senders who are not
  /// friends). Cached; unknown ids come back with an empty display name.
  Future<List<Contact>> users(List<String> uids);

  /// Url of the full size avatar of [uid] for the profile sheet, empty when
  /// Zalo has none. Pass it to [media]. Requires
  /// [AccountCapability.fullAvatar].
  Future<String> fullAvatar(String uid);
  void sendTyping(String threadId, ThreadType type);

  Future<List<Contact>> contacts();
  Future<List<GroupInfo>> groups();
  Future<GroupInfo> groupInfo(String groupId);

  /// Finds a user by phone number. Null when Zalo has no match. The account
  /// may still need a friend request before messaging them.
  Future<UserProfile?> findUserByPhone(String phone);

  /// Finds a user by Zalo username. Null when Zalo has no match.
  Future<UserProfile?> findUserByUsername(String username);

  /// Sends a friend request. [message] is the greeting shown to [uid].
  Future<void> sendFriendRequest(String uid, {String message = ''});

  /// Relationship with [uid], including pending requests in both directions.
  Future<FriendRequestStatus> friendRequestStatus(String uid);

  Future<void> acceptFriendRequest(String uid);
  Future<void> rejectFriendRequest(String uid);

  /// Withdraws a request this account sent to [uid].
  Future<void> cancelFriendRequest(String uid);

  /// Received and sent requests, newest first per Zalo's own order.
  Future<FriendRequests> friendRequests();

  /// Suggested friends from Zalo.
  Future<List<FriendRecommendation>> friendRecommendations();

  /// Sets the local alias shown instead of the friend's Zalo name.
  Future<void> setAlias(String uid, String alias);
  Future<void> removeAlias(String uid);

  /// Unfriends [uid]. The contact list refreshes on the next [contacts].
  Future<void> removeFriend(String uid);
  Future<void> blockUser(String uid);
  Future<void> unblockUser(String uid);

  /// On-demand presence of friends. No polling; call again when the UI needs
  /// a fresh value. Requires [AccountCapability.presence].
  Future<List<FriendPresence>> presence();

  /// Last seen information of [uid]. Requires [AccountCapability.presence].
  Future<LastSeen> lastSeen(String uid);

  /// Bytes of a Zalo media url, fetched through the tunnel and cached in
  /// memory. The UI never loads Zalo urls directly.
  Future<Uint8List> media(String url);

  // ---- Pins, Group Board, Polls, Notes & Reminders ----

  Stream<BoardUpdateEvent> get boardUpdates;

  Future<PinBoardState> listPins(String threadId, ThreadType type);
  Future<List<PinnedTopic>> listBoard(String groupId, {int page = 1, int count = 20});
  Future<PinBoardState> pinMessage(Message message, {required String title});
  Future<void> pinBoardItem(String groupId, String topicId, int topicType);
  Future<PinBoardState> unpinTopic(String threadId, ThreadType type, String topicId, int topicType);

  Future<PollDetail> createPoll(
    String groupId, {
    required String question,
    required List<String> options,
    int expiredTime = 0,
    bool allowMultiChoices = true,
    bool allowAddNewOption = true,
    bool hideVotePreview = false,
    bool isAnonymous = false,
    bool pin = false,
  });
  Future<PollDetail> pollDetail(int pollId, {String? groupId});
  Future<PollDetail> votePoll(int pollId, List<int> optionIds, {String? groupId});
  Future<PollDetail> addPollOption(
    int pollId,
    String content, {
    List<int> votedOptionIds = const [],
    bool voteNew = true,
    String? groupId,
  });
  Future<PollDetail> lockPoll(int pollId, {String? groupId});
  Future<void> sharePoll(int pollId);

  Future<PinnedTopic> createNote(String groupId, String title, {bool pin = false});
  Future<PinnedTopic> editNote(String groupId, String topicId, String title, {bool pin = false});

  Future<List<ReminderItem>> listReminders(String threadId, ThreadType type, {int page = 1, int count = 20});
  Future<ReminderItem> createReminder(
    String threadId,
    ThreadType type, {
    required String title,
    String emoji = '⏰',
    required int startTime,
    int repeat = 0,
  });
  Future<ReminderItem> editReminder(
    String threadId,
    ThreadType type, {
    required String id,
    required String title,
    String emoji = '⏰',
    required int startTime,
    int repeat = 0,
  });
  Future<void> removeReminder(String threadId, ThreadType type, String id);

  // ---- Voice & Video Calls ----

  ValueListenable<ActiveCall?> get activeCall;
  Stream<Map<String, dynamic>> get callMediaIceEvents;
  Future<ActiveCall> startCall(String threadId, ThreadType type, CallMediaKind media);
  Future<void> acceptCall(String callId);
  Future<void> rejectCall(String callId, {bool localOnly = false});
  Future<void> hangupCall(String callId);
  Future<Map<String, dynamic>> callMediaOffer(String callId, String sdp);
  Future<List<Map<String, dynamic>>> callMediaIceServers() async => const [];
  Future<void> callMediaIce(String callId, Map<String, dynamic> candidate);
  Future<Map<String, dynamic>> groupCallState(String groupId);
  Future<void> callHold(String callId, {required String peerId, required bool hold});
  Future<void> callSwitchMedia(String callId, {required String peerId});

  // ---- Extended SDK APIs ----
  Future<String> createGroup({String? name, required List<String> members});
  Future<void> renameGroup(String groupId, String name);
  Future<void> changeGroupAvatar(String groupId, OutgoingFile file);
  Future<void> addGroupMembers(String groupId, List<String> memberIds);
  Future<void> inviteUserToGroups(String userId, List<String> groupIds);
  Future<void> removeGroupMembers(String groupId, List<String> memberIds);
  Future<void> leaveGroup(String groupId, {bool silent = false});
  Future<void> disperseGroup(String groupId);
  Future<void> changeGroupOwner(String groupId, String newOwnerId);
  Future<void> addGroupDeputy(String groupId, List<String> memberIds);
  Future<void> removeGroupDeputy(String groupId, List<String> memberIds);
  Future<void> updateGroupSettings(String groupId, Map<String, dynamic> settings);
  Future<List<Contact>> pendingGroupMembers(String groupId);
  Future<void> reviewPendingGroupMembers(String groupId, List<String> members, bool approve);
  Future<List<Contact>> blockedGroupMembers(String groupId);
  Future<void> addBlockedGroupMembers(String groupId, List<String> memberIds);
  Future<void> removeBlockedGroupMembers(String groupId, List<String> memberIds);
  Future<GroupLinkDetail> groupLinkDetail(String groupId);
  Future<GroupLinkDetail> enableGroupLink(String groupId);
  Future<void> disableGroupLink(String groupId);
  Future<Map<String, dynamic>> groupLinkInfo(String link);
  Future<void> joinGroupLink(String link);
  Future<List<GroupInviteBoxItem>> groupInviteBoxList();
  Future<void> joinGroupInviteBox(String groupId);
  Future<void> deleteGroupInviteBox(List<String> groupIds);
  Future<void> upgradeGroupToCommunity(String groupId);

  Future<ProfileInfo> fetchProfile();
  Future<void> updateProfile({required String name, required String dob, required int gender});
  Future<void> updateProfileBio(String bio);
  Future<void> changeAccountAvatar(OutgoingFile file);
  Future<List<({String photoId, String url})>> avatarList();
  Future<void> reuseAvatar(String photoId);
  Future<void> deleteAvatars(List<String> photoIds);
  Future<Map<String, dynamic>> zaloSettings();
  Future<void> updateZaloSetting(String type, int value);
  Future<void> updateActiveStatus(bool active);
  Future<void> updateZaloLang(String language);

  Future<void> setCloseFriend(List<String> uids, bool add);
  Future<List<Contact>> blockList();
  Future<void> blockViewFeed(String uid, bool blocked);
  Future<Map<String, String>> userQr(List<String> uids);
  Future<void> removeNote(String groupId, String topicId);

  Future<List<CatalogItem>> catalogs();
  Future<CatalogItem> createCatalog(String name);
  Future<void> deleteCatalog(String catalogId);
  Future<List<CatalogProduct>> catalogProducts(String catalogId);
  Future<CatalogProduct> createCatalogProduct(
    String catalogId, {
    required String name,
    required String price,
    required String description,
  });
  Future<void> deleteCatalogProduct(String catalogId, List<String> productIds);
  Future<List<AutoReplyRule>> autoReplies();
  Future<AutoReplyRule> createAutoReply({
    required bool enabled,
    required String content,
    int startTime = 0,
    int endTime = 86400000,
    int scope = 0,
  });
  Future<AutoReplyRule> updateAutoReply(AutoReplyRule rule);
  Future<void> deleteAutoReply(int id);
  Future<void> createBankAccount({required int bin, required String accountNumber, required String holderName});
  Future<void> deleteBankAccount(String accountId, {bool isDefault = false});

  Future<List<MediaStoreEntry>> mediaStoreList(String threadId, ThreadType type, String mediaType);
  Future<void> mediaStoreRemove(String threadId, ThreadType type, String mediaType, String mediaId);
  Future<bool> e2eeCheckCompatible(String threadId, ThreadType type);
  Future<void> e2eeEnable(String threadId, ThreadType type, bool enable);
  Future<Map<String, dynamic>> rawRpc(String method, [Map<String, dynamic> params = const {}]);
}

/// Overridden in main() with the real or demo implementation.
final zalosAppProvider = Provider<ZalosApp>((ref) => throw UnimplementedError('zalosAppProvider not overridden'));
