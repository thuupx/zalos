import 'dart:typed_data';

enum ThreadType { user, group }

enum MessageKind {
  text,
  image,
  video,
  file,
  voice,
  gif,
  sticker,
  link,
  card,
  bankCard,
  location,
  poll,
  note,
  reminder,
  call,
  doodle,
  album,
  todo,
  system,
  other,
}

enum AccountStatus { starting, online, reconnecting, displaced, needsLogin, offline, error }

enum DeviceRole { admin, member }

/// personal: a Zalo user account (unofficial web protocol).
/// oa: a Zalo Official Account (official OA OpenAPI).
enum AccountKind { personal, oa }

/// What an account can do. The UI hides actions whose capability is absent.
enum AccountCapability {
  groups,
  stickers,
  reactions,
  recall,
  deleteForMe,
  forward,
  mentions,
  video,
  voice,
  typing,
  pin,
  mute,
  markUnread,
  deleteThread,
  deliveryState,
  fullAvatar,
  friends,
  presence,
  contactCard,
  report,
  deleteForAll,
  archive,
  hidden,
  labels,
  autoDelete,
  zaloDevices,
  styledText,
  gif,
  linkPreview,
  bankCard,
  bankAccounts,
  quickMessages,
  urgency,
  messageTtl,
  pinMessage,
  polls,
  notes,
  reminders,
  voiceCall,
  videoCall,
  groupManage,
  profileSettings,
  businessTools,
  mediaStore,
  e2ee,
}

enum CallMediaKind { voice, video }

enum CallDirection { incoming, outgoing }

enum CallStatus { ringing, connecting, active, ended }

class ActiveCall {
  const ActiveCall({
    required this.callId,
    required this.threadId,
    required this.threadType,
    required this.peerId,
    required this.peerName,
    this.peerAvatarUrl,
    required this.media,
    required this.direction,
    required this.status,
    required this.startedAt,
    this.answeredAt,
    this.answeredByDeviceId,
    this.isGroup = false,
    this.groupCallId,
    this.participants = const [],
    this.signalingData = const {},
  });

  final String callId;
  final String threadId;
  final ThreadType threadType;
  final String peerId;
  final String peerName;
  final String? peerAvatarUrl;
  final CallMediaKind media;
  final CallDirection direction;
  final CallStatus status;
  final int startedAt;
  final int? answeredAt;
  final String? answeredByDeviceId;
  final bool isGroup;
  final String? groupCallId;
  final List<String> participants;
  final Map<String, dynamic> signalingData;

  ActiveCall copyWith({
    CallStatus? status,
    int? answeredAt,
    String? answeredByDeviceId,
    List<String>? participants,
    Map<String, dynamic>? signalingData,
  }) =>
      ActiveCall(
        callId: callId,
        threadId: threadId,
        threadType: threadType,
        peerId: peerId,
        peerName: peerName,
        peerAvatarUrl: peerAvatarUrl,
        media: media,
        direction: direction,
        status: status ?? this.status,
        startedAt: startedAt,
        answeredAt: answeredAt ?? this.answeredAt,
        answeredByDeviceId: answeredByDeviceId ?? this.answeredByDeviceId,
        isGroup: isGroup,
        groupCallId: groupCallId,
        participants: participants ?? this.participants,
        signalingData: signalingData ?? this.signalingData,
      );
}

enum LinkState { disconnected, connecting, connected, unauthorized }

enum SendState { sending, sent, failed }

/// Why a conversation is reported to Zalo. [other] requires free text
/// content alongside the reason.
enum ReportReason { sensitive, annoy, fraud, other }

/// How far an own message got on the other side. Only meaningful when
/// [Message.isSelf] is true and [Message.sendState] is sent.
enum DeliveryState { sent, delivered, seen }

/// ready: this device holds the vault root and can open stored history.
/// needsApproval: paired without the root; waiting for another device to
/// approve after the user compares fingerprints.
enum VaultState { ready, needsApproval }

/// Progress of a server read the UI waits on (thread list, first message
/// page). [failed] is left by calling the matching reload method.
enum LoadState { loading, ready, failed }

class Attachment {
  const Attachment({
    required this.kind,
    required this.url,
    this.thumbUrl,
    this.name,
    this.size,
    this.width,
    this.height,
    this.durationMs,
  });
  final MessageKind kind;
  final String url;
  final String? thumbUrl;
  final String? name;
  final int? size;
  final int? width;
  final int? height;
  final int? durationMs;
}

class StickerRef {
  const StickerRef({
    required this.id,
    required this.cateId,
    required this.type,
    this.url,
    this.spriteUrl,
    this.frames,
    this.durationMs,
    this.animatedWebp = false,
  });
  final int id;
  final int cateId;
  final int type;
  final String? url;
  final String? spriteUrl;
  final int? frames;
  final int? durationMs;
  final bool animatedWebp;

  /// Canonical renderable image URL, falling back to Zalo's 130x130 PNG
  /// endpoint when [url] was omitted on older or echoed payloads.
  String? get resolvedUrl {
    final u = url;
    if (u != null && u.isNotEmpty) return u;
    if (id > 0) {
      return 'https://zalo-api.zadn.vn/api/emoticon/sticker/webpc?eid=$id&size=130';
    }
    return null;
  }

  bool get hasAnimation =>
      spriteUrl != null &&
      spriteUrl!.isNotEmpty &&
      (animatedWebp || (frames != null && frames! >= 2));
}

/// A contact card (danh thiếp) shared into a conversation.
class ContactCard {
  const ContactCard({required this.uid, required this.displayName, required this.avatarUrl, this.phone, this.qrCodeUrl});
  final String uid;
  final String displayName;
  final String avatarUrl;
  final String? phone;
  final String? qrCodeUrl;
}

/// A bank card (thẻ ngân hàng) shared into a conversation. Only [bin] and
/// [accountNumber] are guaranteed; the display fields are best effort and
/// the raw payload stays sealed alongside it.
class BankCard {
  const BankCard({required this.bin, required this.accountNumber, this.holderName, this.bankName, this.bankLogo});
  final int bin;
  final String accountNumber;
  final String? holderName;
  final String? bankName;
  final String? bankLogo;
}

/// A bank the composer can attach a card from.
class BankInfo {
  const BankInfo({
    required this.bin,
    required this.logo,
    required this.name,
    required this.nameEn,
    required this.shortName,
    required this.searchKeyword,
  });
  final int bin;
  final String logo;
  final String name;
  final String nameEn;
  final String shortName;
  final String searchKeyword;
}

/// One of the account's saved bank accounts.
class BankAccount {
  const BankAccount({
    required this.id,
    required this.bin,
    required this.accountNumber,
    required this.holderName,
    required this.isDefault,
    required this.accountId,
    required this.createdAt,
    required this.updatedAt,
    this.bankName,
    this.bankLogo,
  });
  final String id;
  final int bin;
  final String accountNumber;
  final String holderName;
  final bool isDefault;
  final int accountId;
  final int createdAt;
  final int updatedAt;
  final String? bankName;
  final String? bankLogo;
}

/// One page of saved bank accounts.
class BankAccounts {
  const BankAccounts({this.accounts = const [], this.total = 0, this.hasMore = false});
  final List<BankAccount> accounts;
  final int total;
  final bool hasMore;
}

/// A location shared into a conversation.
class Location {
  const Location({required this.lat, required this.lng, this.name, this.address, this.thumbUrl});
  final double lat;
  final double lng;
  final String? name;
  final String? address;
  final String? thumbUrl;
}

class PollOption {
  const PollOption({required this.id, required this.text, this.votes, this.voted});
  final int id;
  final String text;
  final int? votes;
  final bool? voted;
}

/// A poll (bình chọn) shared into a conversation.
class Poll {
  const Poll({
    required this.question,
    this.id,
    this.options = const [],
    this.multiple,
    this.closed,
    this.anonymous,
    this.totalVotes,
    this.expiredAt,
  });
  final int? id;
  final String question;
  final List<PollOption> options;
  final bool? multiple;
  final bool? closed;
  final bool? anonymous;
  final int? totalVotes;
  final int? expiredAt;
}

/// A pinned note (ghi chú) of a conversation.
class Note {
  const Note({required this.title, this.id, this.text, this.pinned});
  final String? id;
  final String title;
  final String? text;
  final bool? pinned;
}

/// A reminder (nhắc hẹn) shared into a conversation.
class Reminder {
  const Reminder({required this.title, this.id, this.startTime, this.repeat, this.emoji});
  final String? id;
  final String title;
  final int? startTime;
  final int? repeat;
  final String? emoji;
}

enum BoardItemKind { message, poll, note, reminder, link }

/// One pinned item or group board entry (message, poll, note, reminder, link).
class PinnedTopic {
  const PinnedTopic({
    required this.id,
    required this.topicType,
    required this.kind,
    required this.title,
    this.senderId,
    this.senderName,
    this.msgId,
    this.cliMsgId,
    this.pollId,
    this.thumbUrl,
    this.createdAt,
    this.pinned = true,
  });

  final String id;
  final int topicType;
  final BoardItemKind kind;
  final String title;
  final String? senderId;
  final String? senderName;
  final String? msgId;
  final String? cliMsgId;
  final int? pollId;
  final String? thumbUrl;
  final int? createdAt;
  final bool pinned;
}

class PinBoardState {
  const PinBoardState({this.items = const [], this.version = 0});
  final List<PinnedTopic> items;
  final int version;
}

class PollOptionDetail {
  const PollOptionDetail({
    required this.id,
    required this.content,
    required this.votes,
    required this.voted,
    this.voters = const [],
  });
  final int id;
  final String content;
  final int votes;
  final bool voted;
  final List<String> voters;
}

class PollDetail {
  const PollDetail({
    required this.id,
    required this.groupId,
    required this.question,
    required this.creatorId,
    required this.createdAt,
    required this.expiredAt,
    required this.closed,
    required this.multiple,
    required this.allowAdd,
    required this.hidePreview,
    required this.anonymous,
    required this.totalVotes,
    this.options = const [],
  });

  final int id;
  final String groupId;
  final String question;
  final String creatorId;
  final int createdAt;
  final int expiredAt;
  final bool closed;
  final bool multiple;
  final bool allowAdd;
  final bool hidePreview;
  final bool anonymous;
  final int totalVotes;
  final List<PollOptionDetail> options;

  bool get joined => options.any((o) => o.voted);
}

class ReminderItem {
  const ReminderItem({
    required this.id,
    required this.title,
    required this.emoji,
    required this.startTime,
    required this.repeat,
    this.creatorId,
    this.createdAt,
  });
  final String id;
  final String title;
  final String emoji;
  final int startTime;
  final int repeat;
  final String? creatorId;
  final int? createdAt;
}

class BoardUpdateEvent {
  const BoardUpdateEvent(this.threadId, this.threadType);
  final String threadId;
  final ThreadType threadType;
}

/// A voice or video call log. [callType] is `voice`, `video` or `unknown`.
class CallLog {
  const CallLog({required this.callType, this.durationMs, this.missed, this.state});
  final String callType;
  final int? durationMs;
  final bool? missed;
  final String? state;
}

/// A doodle drawing shared into a conversation.
class Doodle {
  const Doodle({required this.url, this.thumbUrl, this.width, this.height});
  final String url;
  final String? thumbUrl;
  final int? width;
  final int? height;
}

/// An album of photos sent together.
class Album {
  const Album({this.items = const [], this.caption});
  final List<Attachment> items;
  final String? caption;
}

class TodoItem {
  const TodoItem({required this.text, this.done});
  final String text;
  final bool? done;
}

/// A shared to-do list.
class Todo {
  const Todo({required this.title, this.id, this.items = const [], this.done});
  final String? id;
  final String title;
  final List<TodoItem> items;
  final bool? done;
}

/// Link preview parsed from a url for the composer and link bubbles.
class LinkPreview {
  const LinkPreview({
    required this.title,
    required this.description,
    required this.srcUrl,
    required this.href,
    this.thumbUrl,
    this.mediaType,
    this.mediaCount,
    this.mediaTitle,
    this.mediaArtist,
    this.streamUrl,
  });
  final String title;
  final String description;
  final String srcUrl;
  final String href;
  final String? thumbUrl;
  final int? mediaType;
  final int? mediaCount;
  final String? mediaTitle;
  final String? mediaArtist;
  final String? streamUrl;
}

/// A text style run of a sent message. [st] is a Zalo style code (`b`, `i`,
/// `u`, `s`, a color or font code, a list marker or the `ind_$` indent
/// marker). [indentSize] is only meaningful for `ind_$`.
class StyleRun {
  const StyleRun({required this.start, required this.len, required this.st, this.indentSize});
  final int start;
  final int len;
  final String st;
  final int? indentSize;
}

/// Delivery urgency of a sent message. [normal] is Zalo's `default`.
enum MessageUrgency { normal, important, urgent }

/// Longest per-message TTL Zalo accepts, in milliseconds.
const int maxMessageTtlMs = 7 * 86400000;

/// An image attached to a quick message.
class QuickMessageMedia {
  const QuickMessageMedia({
    required this.type,
    required this.photoId,
    required this.title,
    required this.width,
    required this.height,
    required this.previewThumb,
    required this.rawUrl,
    required this.thumbUrl,
    required this.normalUrl,
    required this.hdUrl,
  });
  final int type;
  final int photoId;
  final String title;
  final int width;
  final int height;
  final String previewThumb;
  final String rawUrl;
  final String thumbUrl;
  final String normalUrl;
  final String hdUrl;
}

/// A stored composer shortcut.
class QuickMessage {
  const QuickMessage({
    required this.id,
    required this.keyword,
    required this.title,
    required this.type,
    required this.createdTime,
    required this.lastModified,
    this.media = const [],
  });
  final int id;
  final String keyword;
  final String title;
  final int type;
  final int createdTime;
  final int lastModified;
  final List<QuickMessageMedia> media;
}

/// The quick message list with the version and cursor it was read at.
class QuickMessages {
  const QuickMessages({this.items = const [], this.version = 0, this.cursor = 0});
  final List<QuickMessage> items;
  final int version;
  final int cursor;
}

class Quote {
  const Quote({required this.msgId, required this.senderId, required this.senderName, required this.text});
  final String msgId;
  final String senderId;
  final String senderName;
  final String text;
}

class Mention {
  const Mention({required this.uid, required this.pos, required this.len});
  final String uid;
  final int pos;
  final int len;
}

class Message {
  const Message({
    required this.id,
    required this.cliId,
    required this.threadId,
    required this.threadType,
    required this.senderId,
    required this.senderName,
    required this.ts,
    required this.isSelf,
    required this.kind,
    this.text,
    this.attachments = const [],
    this.sticker,
    this.card,
    this.bankCard,
    this.location,
    this.poll,
    this.note,
    this.reminder,
    this.callLog,
    this.doodle,
    this.album,
    this.todo,
    this.linkPreview,
    this.quote,
    this.mentions = const [],
    this.styles = const [],
    this.urgency,
    this.ttl,
    this.expiresAt,
    this.reactions = const {},
    this.recalled = false,
    this.sendState = SendState.sent,
    this.deliveryState = DeliveryState.sent,
    this.sendErrorCode,
    this.raw,
  });
  final String id;
  final String? cliId;
  final String threadId;
  final ThreadType threadType;
  final String senderId;
  final String senderName;
  final int ts;
  final bool isSelf;
  final MessageKind kind;
  final String? text;
  final List<Attachment> attachments;
  final StickerRef? sticker;

  /// Set when [kind] is [MessageKind.card].
  final ContactCard? card;

  /// Structured payloads of their matching kinds. Absent when the payload
  /// did not parse; the sealed [raw] object stays available.
  final BankCard? bankCard;
  final Location? location;
  final Poll? poll;
  final Note? note;
  final Reminder? reminder;
  final CallLog? callLog;
  final Doodle? doodle;
  final Album? album;
  final Todo? todo;

  /// Preview carried by a link body, when the server includes one.
  final LinkPreview? linkPreview;
  final Quote? quote;
  final List<Mention> mentions;

  /// Styled text runs as sent. Inbound payloads rarely carry them.
  final List<StyleRun> styles;

  /// Delivery urgency as sent. Inbound payloads rarely carry it.
  final MessageUrgency? urgency;

  /// Per-message self-destruct window in ms, independent of the
  /// conversation auto-delete TTL, and its absolute expiry.
  final int? ttl;
  final int? expiresAt;
  final Map<String, List<String>> reactions;
  final bool recalled;
  final SendState sendState;
  final DeliveryState deliveryState;

  /// Server code of a rejected send (`window_expired`, `quota_exceeded`,
  /// `rate_limited`, `not_supported`, ...). Only meaningful while
  /// [sendState] is [SendState.failed]; null is a generic failure.
  final String? sendErrorCode;

  /// Opaque original payload, present once the message body is opened.
  /// Passed back to the server when quoting this message.
  final Object? raw;
}

class Thread {
  const Thread({
    required this.id,
    required this.type,
    required this.name,
    required this.avatarUrl,
    required this.lastMessage,
    required this.lastTs,
    required this.unread,
    required this.pinned,
    required this.muted,
    this.hidden = false,
    this.archived = false,
    this.autoDeleteTtl = 0,
  });
  final String id;
  final ThreadType type;
  final String name;
  final String avatarUrl;
  final Message? lastMessage;
  final int lastTs;
  final int unread;
  final bool pinned;
  final bool muted;

  /// Hidden from the main list until unlocked with the account PIN.
  final bool hidden;

  /// Archived out of the main list; still listed in the archive list.
  final bool archived;

  /// Auto-delete TTL of the conversation in milliseconds; 0 is off.
  final int autoDeleteTtl;
}

class Contact {
  const Contact({
    required this.uid,
    required this.displayName,
    required this.avatarUrl,
    this.alias,
    this.closeFriend = false,
  });
  final String uid;
  final String displayName;
  final String avatarUrl;
  final String? alias;

  /// Member of the account's close friends list.
  final bool closeFriend;
}

class GroupInfo {
  const GroupInfo({
    required this.id,
    required this.name,
    required this.avatarUrl,
    required this.memberIds,
    this.memberCount,
    this.ownerId,
    this.adminIds = const [],
    this.members = const [],
  });
  final String id;
  final String name;
  final String avatarUrl;
  final List<String> memberIds;

  /// Total members Zalo reports. [memberIds] may hold only one page, so this
  /// can be larger than its length. Null when the server did not send it.
  final int? memberCount;
  final String? ownerId;

  /// Deputies of the group. Together with [ownerId] this gates admin actions
  /// such as deleting another member's message for everyone.
  final List<String> adminIds;

  /// Member profiles embedded by the server when available.
  final List<Contact> members;
}

class ServerInfo {
  const ServerInfo({required this.name, required this.version, required this.fingerprint});
  final String name;
  final String version;
  final String fingerprint;
}

class AccountSummary {
  const AccountSummary({
    required this.slot,
    required this.uid,
    this.kind = AccountKind.personal,
    this.capabilities = const {},
    required this.displayName,
    required this.avatarUrl,
    required this.status,
    required this.unread,
  });
  final String slot;
  final AccountKind kind;
  final Set<AccountCapability> capabilities;

  /// Zalo uid of the account itself; matches ids in [Message.reactions].
  final String uid;
  final String displayName;
  final String avatarUrl;
  final AccountStatus status;
  final int unread;
}

class Manifest {
  const Manifest({required this.server, required this.deviceId, required this.deviceName, required this.role, required this.accounts});
  final ServerInfo server;
  final String deviceId;
  final String deviceName;
  final DeviceRole role;
  final List<AccountSummary> accounts;
}

class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.role,
    required this.createdAt,
    required this.lastSeenAt,
    required this.revoked,
    required this.slots,
  });
  final String id;
  final String name;
  final DeviceRole role;
  final int createdAt;
  final int? lastSeenAt;
  final bool revoked;
  final List<String> slots;
}

class PairingOffer {
  const PairingOffer({required this.uri, required this.expiresAt});
  final String uri;
  final int expiresAt;
}

class OutgoingFile {
  const OutgoingFile({required this.name, required this.bytes, required this.kind});
  final String name;
  final Uint8List bytes;
  final MessageKind kind;
}

/// The editable fields of a quick message. [media] is uploaded alongside.
class QuickMessageDraft {
  const QuickMessageDraft({required this.keyword, required this.title, this.media});
  final String keyword;
  final String title;
  final OutgoingFile? media;
}

sealed class LoginQrEvent {
  const LoginQrEvent();
}

class LoginQrImage extends LoginQrEvent {
  const LoginQrImage(this.png);
  final Uint8List png;
}

class LoginQrScanned extends LoginQrEvent {
  const LoginQrScanned(this.displayName);
  final String displayName;
}

class LoginQrDone extends LoginQrEvent {
  const LoginQrDone(this.slot);
  final String slot;
}

class LoginQrFailed extends LoginQrEvent {
  const LoginQrFailed(this.reason);
  final String reason;
}

class TypingEvent {
  const TypingEvent({required this.threadId, required this.userId});
  final String threadId;
  final String userId;
}

class VaultRequest {
  const VaultRequest({required this.deviceId, required this.name, required this.fingerprint, required this.requestedAt});
  final String deviceId;
  final String name;

  /// Fingerprint of the requesting device's box key. The user must compare it
  /// with the one shown on that device before approving.
  final String fingerprint;
  final int requestedAt;
}

/// A conversation reference, e.g. a forward destination or an entry of the
/// hidden and archived lists.
class ThreadRef {
  const ThreadRef(this.id, this.type);
  final String id;
  final ThreadType type;
}

/// Hidden conversations as Zalo holds them. The PIN hash Zalo keeps is
/// deliberately absent: the client only needs to know whether one is set.
class HiddenConversations {
  const HiddenConversations({this.pinSet = false, this.threads = const []});
  final bool pinSet;
  final List<ThreadRef> threads;
}

/// Archived conversations and the version of the archive list.
class ArchivedChatList {
  const ArchivedChatList({this.threads = const [], this.version = 0});
  final List<ThreadRef> threads;
  final int version;
}

/// A conversation label (tag). Labels are clear metadata, not sealed content.
class ConversationLabel {
  const ConversationLabel({
    required this.id,
    required this.text,
    this.textKey = '',
    this.conversations = const [],
    this.color = '',
    this.offset = 0,
    this.emoji = '',
    this.createTime = 0,
  });
  final int id;
  final String text;
  final String textKey;

  /// Ids of the conversations tagged with this label.
  final List<String> conversations;
  final String color;
  final int offset;
  final String emoji;
  final int createTime;
}

/// Whole label set of an account. A write carries the version it expects;
/// a stale version is a conflict.
class LabelsState {
  const LabelsState({this.labels = const [], this.version = 0, this.lastUpdateTime = 0});
  final List<ConversationLabel> labels;
  final int version;
  final int lastUpdateTime;
}

/// Auto-delete TTLs Zalo accepts, in milliseconds; 0 turns auto-delete off.
const List<int> autoDeleteTtls = [0, 86400000, 604800000, 1209600000];

/// Whether [ttl] is one of [autoDeleteTtls].
bool supportsAutoDeleteTtl(int ttl) => autoDeleteTtls.contains(ttl);

/// One conversation with auto-delete enabled.
class AutoDeleteConversation {
  const AutoDeleteConversation({required this.threadId, required this.threadType, this.ttl = 0, this.createdAt});
  final String threadId;
  final ThreadType threadType;
  final int ttl;
  final int? createdAt;
}

class AutoDeleteChat {
  const AutoDeleteChat({this.conversations = const []});
  final List<AutoDeleteConversation> conversations;
}

/// A companion session signed in to the same Zalo account. Only safe,
/// displayable fields are carried; Zalo's identity and signature blobs never
/// leave the server.
class LinkedDeviceCompanion {
  const LinkedDeviceCompanion({
    this.id,
    this.name,
    this.platform,
    this.lastUpdateTs,
    this.current = false,
    this.summary,
  });
  final String? id;
  final String? name;
  final String? platform;
  final int? lastUpdateTs;
  final bool current;

  /// Value-free summary of an unrecognized companion shape.
  final String? summary;
}

class LinkedDevices {
  const LinkedDevices({this.masterId = '', this.lastUpdateTs, this.companions = const []});
  final String masterId;
  final int? lastUpdateTs;
  final List<LinkedDeviceCompanion> companions;
}

/// A user found by phone number or username. [zaloName] is the name the
/// account chose on Zalo, kept apart from the display name.
class UserProfile {
  const UserProfile({
    required this.uid,
    required this.displayName,
    required this.avatarUrl,
    this.zaloName,
    this.gender,
    this.phoneNumber,
  });
  final String uid;
  final String displayName;
  final String avatarUrl;
  final String? zaloName;

  /// `male`, `female`, or absent when Zalo does not expose it.
  final String? gender;
  final String? phoneNumber;
}

/// Relationship of this account with [uid], as Zalo reports it.
class FriendRequestStatus {
  const FriendRequestStatus({
    this.isFriend = false,
    this.isRequested = false,
    this.isRequesting = false,
    this.addFriendPrivacy = 0,
    this.isSeen = false,
  });

  /// Already friends.
  final bool isFriend;

  /// The other side has a pending request to this account.
  final bool isRequested;

  /// This account has a pending request to the other side.
  final bool isRequesting;

  /// Zalo privacy level for adding this user as a friend.
  final int addFriendPrivacy;

  /// Whether a pending request has been seen.
  final bool isSeen;
}

/// A received or sent friend request. Received and sent requests share the
/// same wire shape.
class FriendRequest {
  const FriendRequest({
    required this.uid,
    required this.displayName,
    required this.avatarUrl,
    this.message,
    this.ts,
  });
  final String uid;
  final String displayName;
  final String avatarUrl;
  final String? message;
  final int? ts;
}

/// A suggested friend from Zalo's recommendation list.
class FriendRecommendation {
  const FriendRecommendation({
    required this.uid,
    required this.displayName,
    required this.avatarUrl,
    this.phoneNumber,
    this.gender,
    this.message,
  });
  final String uid;
  final String displayName;
  final String avatarUrl;
  final String? phoneNumber;
  final String? gender;
  final String? message;
}

/// The two directions of the friend request list.
class FriendRequests {
  const FriendRequests({this.received = const [], this.sent = const []});
  final List<FriendRequest> received;
  final List<FriendRequest> sent;
}

/// On-demand presence of one friend.
class FriendPresence {
  const FriendPresence({required this.uid, required this.status, required this.online});
  final String uid;

  /// Zalo's raw status label, e.g. `online` or `offline`.
  final String status;
  final bool online;
}

/// Last seen information of a friend. When [showOnlineStatus] is false Zalo
/// hides the timestamp and [lastOnline] is not meaningful.
class LastSeen {
  const LastSeen({required this.showOnlineStatus, required this.lastOnline});
  final bool showOnlineStatus;
  final int lastOnline;
}

/// Credentials of a Zalo Official Account, taken from the Zalo for Developers
/// console (app) and its API Explorer (tokens).
class OaCredentials {
  const OaCredentials({required this.appId, required this.appSecret, required this.accessToken, required this.refreshToken});
  final String appId;
  final String appSecret;
  final String accessToken;
  final String refreshToken;
}

class GroupLinkDetail {
  const GroupLinkDetail({this.link, this.expirationDate, required this.enabled});
  final String? link;
  final int? expirationDate;
  final bool enabled;
}

class GroupInviteBoxItem {
  const GroupInviteBoxItem({required this.groupId, required this.name, this.memberCount = 0});
  final String groupId;
  final String name;
  final int memberCount;
}

class ProfileInfo {
  const ProfileInfo({
    required this.uid,
    required this.displayName,
    this.avatarUrl = '',
    this.dob = '',
    this.gender = 0,
    this.bio = '',
  });
  final String uid;
  final String displayName;
  final String avatarUrl;
  final String dob;
  final int gender;
  final String bio;
}

class AutoReplyRule {
  const AutoReplyRule({
    required this.id,
    required this.enabled,
    required this.content,
    required this.startTime,
    required this.endTime,
    required this.scope,
  });
  final int id;
  final bool enabled;
  final String content;
  final int startTime;
  final int endTime;
  final int scope;
}

class CatalogItem {
  const CatalogItem({required this.catalogId, required this.catalogName, this.catalogPhoto = ''});
  final String catalogId;
  final String catalogName;
  final String catalogPhoto;
}

class CatalogProduct {
  const CatalogProduct({
    required this.productId,
    required this.catalogId,
    required this.productName,
    required this.price,
    required this.description,
    this.currencyUnit = '₫',
  });
  final String productId;
  final String catalogId;
  final String productName;
  final String price;
  final String description;
  final String currencyUnit;
}

class MediaStoreEntry {
  const MediaStoreEntry({
    required this.id,
    required this.mediaType,
    required this.url,
    this.thumbUrl = '',
    this.name = '',
    this.ts = 0,
  });
  final String id;
  final String mediaType;
  final String url;
  final String thumbUrl;
  final String name;
  final int ts;
}
