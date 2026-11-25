import '../domain/models.dart';

typedef Json = Map<String, dynamic>;

Json asJson(Object? value) {
  if (value is Json) return value;
  if (value is Map) return value.map((key, v) => MapEntry('$key', v));
  return const {};
}

List<Json> asJsonList(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is Map) asJson(item),
  ];
}

int _int(Object? value, [int fallback = 0]) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

int? _intOrNull(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String _string(Object? value, [String fallback = '']) {
  if (value == null) return fallback;
  return value is String ? value : '$value';
}

String? _stringOrNull(Object? value) {
  if (value == null) return null;
  return value is String ? value : '$value';
}

bool _bool(Object? value) => value == true || value == 1;

bool? _boolOrNull(Object? value) => value == null ? null : _bool(value);

double _double(Object? value, [double fallback = 0]) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item != null) '$item',
  ];
}

ThreadType threadTypeFromWire(Object? value) => value == 'group' ? ThreadType.group : ThreadType.user;

String threadTypeToWire(ThreadType type) => type == ThreadType.group ? 'group' : 'user';

MessageKind messageKindFromWire(Object? value) {
  // The server calls a bank card `bank`; the client names the kind after
  // the payload it carries.
  if (value == 'bank') return MessageKind.bankCard;
  for (final kind in MessageKind.values) {
    if (kind.name == value) return kind;
  }
  return MessageKind.other;
}

String messageKindToWire(MessageKind kind) => kind == MessageKind.bankCard ? 'bank' : kind.name;

ReportReason reportReasonFromWire(Object? value) {
  for (final reason in ReportReason.values) {
    if (reason.name == value) return reason;
  }
  return ReportReason.other;
}

String reportReasonToWire(ReportReason reason) => reason.name;

AccountStatus accountStatusFromWire(Object? value) {
  switch (value) {
    case 'starting':
      return AccountStatus.starting;
    case 'online':
      return AccountStatus.online;
    case 'reconnecting':
      return AccountStatus.reconnecting;
    case 'displaced':
      return AccountStatus.displaced;
    case 'needs_login':
    case 'needsLogin':
      return AccountStatus.needsLogin;
    case 'offline':
      return AccountStatus.offline;
    default:
      return AccountStatus.error;
  }
}

DeviceRole deviceRoleFromWire(Object? value) => value == 'admin' ? DeviceRole.admin : DeviceRole.member;

String deviceRoleToWire(DeviceRole role) => role == DeviceRole.admin ? 'admin' : 'member';

Attachment attachmentFromJson(Json json) => Attachment(
      kind: messageKindFromWire(json['kind']),
      url: _string(json['url']),
      thumbUrl: _stringOrNull(json['thumbUrl']),
      name: _stringOrNull(json['name']),
      size: _intOrNull(json['size']),
      width: _intOrNull(json['width']),
      height: _intOrNull(json['height']),
      durationMs: _intOrNull(json['durationMs']),
    );

StickerRef stickerFromJson(Json json) => StickerRef(
      id: _int(json['id']),
      cateId: _int(json['cateId']),
      type: _int(json['type']),
      url: _stringOrNull(json['url']),
      spriteUrl: _stringOrNull(json['spriteUrl']),
      frames: _intOrNull(json['frames']),
      durationMs: _intOrNull(json['durationMs']),
      animatedWebp: _bool(json['animatedWebp']),
    );

Json stickerToJson(StickerRef sticker) => {
      'id': sticker.id,
      'cateId': sticker.cateId,
      'type': sticker.type,
      if (sticker.url != null) 'url': sticker.url,
      if (sticker.spriteUrl != null) 'spriteUrl': sticker.spriteUrl,
      if (sticker.frames != null) 'frames': sticker.frames,
      if (sticker.durationMs != null) 'durationMs': sticker.durationMs,
      if (sticker.animatedWebp) 'animatedWebp': true,
    };

ContactCard contactCardFromJson(Json json) => ContactCard(
      uid: _string(json['uid']),
      displayName: _string(json['displayName']),
      avatarUrl: _string(json['avatarUrl']),
      phone: _stringOrNull(json['phone']),
      qrCodeUrl: _stringOrNull(json['qrCodeUrl']),
    );

BankCard bankCardFromJson(Json json) => BankCard(
      bin: _int(json['bin']),
      accountNumber: _string(json['accountNumber']),
      holderName: _stringOrNull(json['holderName']),
      bankName: _stringOrNull(json['bankName']),
      bankLogo: _stringOrNull(json['bankLogo']),
    );

BankInfo bankInfoFromJson(Json json) => BankInfo(
      bin: _int(json['bin']),
      logo: _string(json['logo']),
      name: _string(json['name']),
      nameEn: _string(json['nameEn']),
      shortName: _string(json['shortName']),
      searchKeyword: _string(json['searchKeyword']),
    );

BankAccount bankAccountFromJson(Json json) => BankAccount(
      id: _string(json['id']),
      bin: _int(json['bin']),
      accountNumber: _string(json['accountNumber']),
      holderName: _string(json['holderName']),
      isDefault: _bool(json['isDefault']),
      accountId: _int(json['accountId']),
      createdAt: _int(json['createdAt']),
      updatedAt: _int(json['updatedAt']),
      bankName: _stringOrNull(json['bankName']),
      bankLogo: _stringOrNull(json['bankLogo']),
    );

BankAccounts bankAccountsFromJson(Json json) => BankAccounts(
      accounts: [for (final item in asJsonList(json['accounts'])) bankAccountFromJson(item)],
      total: _int(json['total']),
      hasMore: _bool(json['hasMore']),
    );

Location locationFromJson(Json json) => Location(
      lat: _double(json['lat']),
      lng: _double(json['lng']),
      name: _stringOrNull(json['name']),
      address: _stringOrNull(json['address']),
      thumbUrl: _stringOrNull(json['thumbUrl']),
    );

PollOption pollOptionFromJson(Json json) => PollOption(
      id: _int(json['id']),
      text: _string(json['text']),
      votes: _intOrNull(json['votes']),
      voted: _boolOrNull(json['voted']),
    );

Poll pollFromJson(Json json) => Poll(
      id: _intOrNull(json['id']),
      question: _string(json['question']),
      options: [for (final item in asJsonList(json['options'])) pollOptionFromJson(item)],
      multiple: _boolOrNull(json['multiple']),
      closed: _boolOrNull(json['closed']),
      anonymous: _boolOrNull(json['anonymous']),
      totalVotes: _intOrNull(json['totalVotes']),
      expiredAt: _intOrNull(json['expiredAt']),
    );

Note noteFromJson(Json json) => Note(
      id: _stringOrNull(json['id']),
      title: _string(json['title']),
      text: _stringOrNull(json['text']),
      pinned: _boolOrNull(json['pinned']),
    );

Reminder reminderFromJson(Json json) => Reminder(
      id: _stringOrNull(json['id']),
      title: _string(json['title']),
      startTime: _intOrNull(json['startTime']),
      repeat: _intOrNull(json['repeat']),
      emoji: _stringOrNull(json['emoji']),
    );

BoardItemKind boardItemKindFromWire(Object? value) {
  for (final k in BoardItemKind.values) {
    if (k.name == value) return k;
  }
  return BoardItemKind.message;
}

PinnedTopic pinnedTopicFromJson(Json json) => PinnedTopic(
      id: _string(json['id']),
      topicType: _int(json['topicType'], 2),
      kind: boardItemKindFromWire(json['kind']),
      title: _string(json['title']),
      senderId: _stringOrNull(json['senderId']),
      senderName: _stringOrNull(json['senderName']),
      msgId: _stringOrNull(json['msgId']),
      cliMsgId: _stringOrNull(json['cliMsgId']),
      pollId: _intOrNull(json['pollId']),
      thumbUrl: _stringOrNull(json['thumbUrl']),
      createdAt: _intOrNull(json['createdAt']),
      pinned: json['pinned'] == null ? true : _bool(json['pinned']),
    );

PinBoardState pinBoardStateFromJson(Json json) => PinBoardState(
      items: [for (final item in asJsonList(json['items'])) pinnedTopicFromJson(item)],
      version: _int(json['version']),
    );

PollOptionDetail pollOptionDetailFromJson(Json json) => PollOptionDetail(
      id: _int(json['id']),
      content: _string(json['content']),
      votes: _int(json['votes']),
      voted: _bool(json['voted']),
      voters: _stringList(json['voters']),
    );

PollDetail pollDetailFromJson(Json json) => PollDetail(
      id: _int(json['id']),
      groupId: _string(json['groupId']),
      question: _string(json['question']),
      creatorId: _string(json['creatorId']),
      createdAt: _int(json['createdAt']),
      expiredAt: _int(json['expiredAt']),
      closed: _bool(json['closed']),
      multiple: _bool(json['multiple']),
      allowAdd: _bool(json['allowAdd']),
      hidePreview: _bool(json['hidePreview']),
      anonymous: _bool(json['anonymous']),
      totalVotes: _int(json['totalVotes']),
      options: [for (final item in asJsonList(json['options'])) pollOptionDetailFromJson(item)],
    );

ReminderItem reminderItemFromJson(Json json) => ReminderItem(
      id: _string(json['id']),
      title: _string(json['title']),
      emoji: _string(json['emoji'], '⏰'),
      startTime: _int(json['startTime']),
      repeat: _int(json['repeat']),
      creatorId: _stringOrNull(json['creatorId']),
      createdAt: _intOrNull(json['createdAt']),
    );

BoardUpdateEvent boardUpdateEventFromJson(Json json) => BoardUpdateEvent(
      _string(json['threadId']),
      threadTypeFromWire(json['threadType']),
    );

CallLog callLogFromJson(Json json) => CallLog(
      callType: _string(json['callType'], 'unknown'),
      durationMs: _intOrNull(json['durationMs']),
      missed: _boolOrNull(json['missed']),
      state: _stringOrNull(json['state']),
    );

Doodle doodleFromJson(Json json) => Doodle(
      url: _string(json['url']),
      thumbUrl: _stringOrNull(json['thumbUrl']),
      width: _intOrNull(json['width']),
      height: _intOrNull(json['height']),
    );

Album albumFromJson(Json json) => Album(
      items: [for (final item in asJsonList(json['items'])) attachmentFromJson(item)],
      caption: _stringOrNull(json['caption']),
    );

TodoItem todoItemFromJson(Json json) => TodoItem(
      text: _string(json['text']),
      done: _boolOrNull(json['done']),
    );

Todo todoFromJson(Json json) => Todo(
      id: _stringOrNull(json['id']),
      title: _string(json['title']),
      items: [for (final item in asJsonList(json['items'])) todoItemFromJson(item)],
      done: _boolOrNull(json['done']),
    );

LinkPreview linkPreviewFromJson(Json json) => LinkPreview(
      title: _string(json['title']),
      description: _string(json['description']),
      srcUrl: _string(json['srcUrl']),
      href: _string(json['href']),
      thumbUrl: _stringOrNull(json['thumbUrl']),
      mediaType: _intOrNull(json['mediaType']),
      mediaCount: _intOrNull(json['mediaCount']),
      mediaTitle: _stringOrNull(json['mediaTitle']),
      mediaArtist: _stringOrNull(json['mediaArtist']),
      streamUrl: _stringOrNull(json['streamUrl']),
    );

StyleRun styleRunFromJson(Json json) => StyleRun(
      start: _int(json['start']),
      len: _int(json['len']),
      st: _string(json['st']),
      indentSize: _intOrNull(json['indentSize']),
    );

Json styleRunToJson(StyleRun run) => {
      'start': run.start,
      'len': run.len,
      'st': run.st,
      if (run.indentSize != null) 'indentSize': run.indentSize,
    };

/// Zalo's wire urgency is `default|important|urgent`; unknown values are
/// dropped so an old or new server cannot break the message.
MessageUrgency? messageUrgencyFromWire(Object? value) {
  switch (value) {
    case 'default':
    case 'normal':
      return MessageUrgency.normal;
    case 'important':
      return MessageUrgency.important;
    case 'urgent':
      return MessageUrgency.urgent;
    default:
      return null;
  }
}

String messageUrgencyToWire(MessageUrgency urgency) =>
    urgency == MessageUrgency.normal ? 'default' : urgency.name;

QuickMessageMedia quickMessageMediaFromJson(Json json) => QuickMessageMedia(
      type: _int(json['type']),
      photoId: _int(json['photoId']),
      title: _string(json['title']),
      width: _int(json['width']),
      height: _int(json['height']),
      previewThumb: _string(json['previewThumb']),
      rawUrl: _string(json['rawUrl']),
      thumbUrl: _string(json['thumbUrl']),
      normalUrl: _string(json['normalUrl']),
      hdUrl: _string(json['hdUrl']),
    );

QuickMessage quickMessageFromJson(Json json) => QuickMessage(
      id: _int(json['id']),
      keyword: _string(json['keyword']),
      title: _string(json['title']),
      type: _int(json['type']),
      createdTime: _int(json['createdTime']),
      lastModified: _int(json['lastModified']),
      media: [for (final item in asJsonList(json['media'])) quickMessageMediaFromJson(item)],
    );

QuickMessages quickMessagesFromJson(Json json) => QuickMessages(
      items: [for (final item in asJsonList(json['items'])) quickMessageFromJson(item)],
      version: _int(json['version']),
      cursor: _int(json['cursor']),
    );

/// A message body carries the normalized quote the server built at send
/// time: `{msgId, senderId, senderName, text}`.
Quote? quoteFromJson(Json json) {
  if (json['msgId'] == null) return null;
  return Quote(
    msgId: _string(json['msgId']),
    senderId: _string(json['senderId']),
    senderName: _string(json['senderName']),
    text: _string(json['text']),
  );
}

Mention mentionFromJson(Json json) => Mention(
      uid: _string(json['uid']),
      pos: _int(json['pos']),
      len: _int(json['len']),
    );

Json mentionToJson(Mention mention) => {'uid': mention.uid, 'pos': mention.pos, 'len': mention.len};

Map<String, List<String>> _reactions(Object? value) {
  if (value is! Map) return const {};
  return {
    for (final entry in value.entries) '${entry.key}': _stringList(entry.value),
  };
}

/// Opens the `sealed` field of a record. Returns null when the vault is not
/// ready or the record does not open.
typedef BodyOpener = Json? Function(String msgId, String sealed);

/// Maps a message record. Content lives in `body` (plaintext), in `sealed`
/// (opened through [open]) or is absent (recalled). A record that cannot be
/// opened keeps its clear fields with empty content and is reported through
/// [onLocked] so it can be mapped again once the vault is ready.
Message messageFromJson(Json json, {BodyOpener? open, void Function(Json record)? onLocked}) {
  final id = _string(json['id']);
  Json content = json;
  final body = json['body'];
  final sealed = json['sealed'];
  if (body is Map) {
    content = asJson(body);
  } else if (sealed is String) {
    final opened = open?.call(id, sealed);
    if (opened == null) {
      onLocked?.call(json);
      content = const {};
    } else {
      content = opened;
    }
  }
  final sticker = content['sticker'];
  final card = content['card'];
  final bankCard = content['bankCard'];
  final location = content['location'];
  final poll = content['poll'];
  final note = content['note'];
  final reminder = content['reminder'];
  final callLog = content['callLog'];
  final doodle = content['doodle'];
  final album = content['album'];
  final todo = content['todo'];
  final linkPreview = content['linkPreview'];
  final quote = content['quote'];
  return Message(
    id: id,
    cliId: _stringOrNull(json['cliId']),
    threadId: _string(json['threadId']),
    threadType: threadTypeFromWire(json['threadType']),
    senderId: _string(json['senderId']),
    senderName: _string(content['senderName']),
    ts: _int(json['ts']),
    isSelf: _bool(json['isSelf']),
    kind: messageKindFromWire(json['kind']),
    text: _stringOrNull(content['text']),
    attachments: [for (final item in asJsonList(content['attachments'])) attachmentFromJson(item)],
    sticker: sticker is Map ? stickerFromJson(asJson(sticker)) : null,
    card: card is Map ? contactCardFromJson(asJson(card)) : null,
    bankCard: bankCard is Map ? bankCardFromJson(asJson(bankCard)) : null,
    location: location is Map ? locationFromJson(asJson(location)) : null,
    poll: poll is Map ? pollFromJson(asJson(poll)) : null,
    note: note is Map ? noteFromJson(asJson(note)) : null,
    reminder: reminder is Map ? reminderFromJson(asJson(reminder)) : null,
    callLog: callLog is Map ? callLogFromJson(asJson(callLog)) : null,
    doodle: doodle is Map ? doodleFromJson(asJson(doodle)) : null,
    album: album is Map ? albumFromJson(asJson(album)) : null,
    todo: todo is Map ? todoFromJson(asJson(todo)) : null,
    linkPreview: linkPreview is Map ? linkPreviewFromJson(asJson(linkPreview)) : null,
    quote: quote is Map ? quoteFromJson(asJson(quote)) : null,
    mentions: [for (final item in asJsonList(content['mentions'])) mentionFromJson(item)],
    styles: [for (final item in asJsonList(content['styles'])) styleRunFromJson(item)],
    urgency: messageUrgencyFromWire(content['urgency']),
    ttl: _intOrNull(content['ttl']),
    expiresAt: _intOrNull(content['expiresAt']),
    reactions: _reactions(json['reactions']),
    recalled: _bool(json['recalled']),
    sendState: SendState.sent,
    deliveryState: deliveryStateFromWire(json['delivery']),
    raw: content['raw'],
  );
}

DeliveryState deliveryStateFromWire(Object? value) {
  final state = value is Map ? _string(value['state']) : _stringOrNull(value) ?? '';
  switch (state) {
    case 'seen':
      return DeliveryState.seen;
    case 'delivered':
      return DeliveryState.delivered;
    default:
      return DeliveryState.sent;
  }
}

Thread threadFromJson(Json json, {BodyOpener? open, void Function(Json record)? onLocked}) {
  final last = json['lastMessage'];
  return Thread(
    id: _string(json['id']),
    type: threadTypeFromWire(json['type']),
    name: _string(json['name']),
    avatarUrl: _string(json['avatarUrl']),
    lastMessage: last is Map ? messageFromJson(asJson(last), open: open, onLocked: onLocked) : null,
    lastTs: _int(json['lastTs']),
    unread: _int(json['unread']),
    pinned: _bool(json['pinned']),
    muted: _bool(json['muted']),
    hidden: _bool(json['hidden']),
    archived: _bool(json['archived']),
    autoDeleteTtl: _int(json['autoDeleteTtl']),
  );
}

ThreadRef threadRefFromJson(Json json) => ThreadRef(_string(json['threadId']), threadTypeFromWire(json['threadType']));

List<ThreadRef> _threadRefs(Object? value) => [for (final item in asJsonList(value)) threadRefFromJson(item)];

HiddenConversations hiddenConversationsFromJson(Json json) => HiddenConversations(
      pinSet: _bool(json['pinSet']),
      threads: _threadRefs(json['threads']),
    );

ArchivedChatList archivedChatListFromJson(Json json) => ArchivedChatList(
      threads: _threadRefs(json['threads']),
      version: _int(json['version']),
    );

ConversationLabel conversationLabelFromJson(Json json) => ConversationLabel(
      id: _int(json['id']),
      text: _string(json['text']),
      textKey: _string(json['textKey']),
      conversations: _stringList(json['conversations']),
      color: _string(json['color']),
      offset: _int(json['offset']),
      emoji: _string(json['emoji']),
      createTime: _int(json['createTime']),
    );

Json conversationLabelToJson(ConversationLabel label) => {
      'id': label.id,
      'text': label.text,
      'textKey': label.textKey,
      'conversations': label.conversations,
      'color': label.color,
      'offset': label.offset,
      'emoji': label.emoji,
      'createTime': label.createTime,
    };

LabelsState labelsStateFromJson(Json json) => LabelsState(
      labels: [for (final item in asJsonList(json['labels'])) conversationLabelFromJson(item)],
      version: _int(json['version']),
      lastUpdateTime: _int(json['lastUpdateTime']),
    );

AutoDeleteChat autoDeleteChatFromJson(Json json) => AutoDeleteChat(
      conversations: [
        for (final item in asJsonList(json['conversations']))
          AutoDeleteConversation(
            threadId: _string(item['threadId']),
            threadType: threadTypeFromWire(item['threadType']),
            ttl: _int(item['ttl']),
            createdAt: _intOrNull(item['createdAt']),
          ),
      ],
    );

/// Maps the `devices` field of `account.linkedDevices`. Only the displayable
/// fields are read, so identity and signature blobs cannot reach the app.
LinkedDevices? linkedDevicesFromJson(Object? value) {
  if (value is! Map) return null;
  final json = asJson(value);
  return LinkedDevices(
    masterId: _string(json['masterId']),
    lastUpdateTs: _intOrNull(json['lastUpdateTs']),
    companions: [
      for (final item in asJsonList(json['companions']))
        LinkedDeviceCompanion(
          id: _stringOrNull(item['id']),
          name: _stringOrNull(item['name']),
          platform: _stringOrNull(item['platform']),
          lastUpdateTs: _intOrNull(item['lastUpdateTs']),
          current: _bool(item['current']),
          summary: _stringOrNull(item['summary']),
        ),
    ],
  );
}

Contact contactFromJson(Json json) => Contact(
      uid: _string(json['uid']),
      displayName: _string(json['displayName']),
      avatarUrl: _string(json['avatarUrl']),
      alias: _stringOrNull(json['alias']),
      closeFriend: _bool(json['closeFriend']),
    );

GroupInfo groupInfoFromJson(Json json) {
  final members = [
    for (final item in asJsonList(json['members']))
      if (_string(item['uid']).isNotEmpty) contactFromJson(item),
  ];
  final explicitIds = _stringList(json['memberIds']);
  final memberIds = explicitIds.isNotEmpty
      ? explicitIds
      : [for (final m in members) m.uid];
  return GroupInfo(
    id: _string(json['id']),
    name: _string(json['name']),
    avatarUrl: _string(json['avatarUrl']),
    memberIds: memberIds,
    memberCount: _intOrNull(json['memberCount']),
    ownerId: _stringOrNull(json['ownerId']),
    adminIds: _stringList(json['adminIds']),
    members: members,
  );
}

/// A user found by phone or username. Null when Zalo has no match, which the
/// server reports as a null `user`.
UserProfile? userProfileFromJson(Object? value) {
  if (value is! Map) return null;
  final json = asJson(value);
  final uid = _string(json['uid']);
  if (uid.isEmpty) return null;
  return UserProfile(
    uid: uid,
    displayName: _string(json['displayName']),
    avatarUrl: _string(json['avatarUrl']),
    zaloName: _stringOrNull(json['zaloName']),
    gender: _stringOrNull(json['gender']),
    phoneNumber: _stringOrNull(json['phoneNumber']),
  );
}

FriendRequestStatus friendRequestStatusFromJson(Json json) => FriendRequestStatus(
      isFriend: _bool(json['isFriend']),
      isRequested: _bool(json['isRequested']),
      isRequesting: _bool(json['isRequesting']),
      addFriendPrivacy: _int(json['addFriendPrivacy']),
      isSeen: _bool(json['isSeen']),
    );

FriendRequest friendRequestFromJson(Json json) => FriendRequest(
      uid: _string(json['uid']),
      displayName: _string(json['displayName']),
      avatarUrl: _string(json['avatarUrl']),
      message: _stringOrNull(json['message']),
      ts: _intOrNull(json['ts']),
    );

FriendRequests friendRequestsFromJson(Json json) => FriendRequests(
      received: [for (final item in asJsonList(json['received'])) friendRequestFromJson(item)],
      sent: [for (final item in asJsonList(json['sent'])) friendRequestFromJson(item)],
    );

FriendRecommendation friendRecommendationFromJson(Json json) => FriendRecommendation(
      uid: _string(json['uid']),
      displayName: _string(json['displayName']),
      avatarUrl: _string(json['avatarUrl']),
      phoneNumber: _stringOrNull(json['phoneNumber']),
      gender: _stringOrNull(json['gender']),
      message: _stringOrNull(json['message']),
    );

FriendPresence friendPresenceFromJson(Json json) => FriendPresence(
      uid: _string(json['uid']),
      status: _string(json['status']),
      online: _bool(json['online']),
    );

LastSeen lastSeenFromJson(Json json) => LastSeen(
      showOnlineStatus: _bool(json['showOnlineStatus']),
      lastOnline: _int(json['lastOnline']),
    );

ServerInfo serverInfoFromJson(Json json) => ServerInfo(
      name: _string(json['name']),
      version: _string(json['version']),
      fingerprint: _string(json['fingerprint']),
    );

AccountKind _accountKind(String? wire) => wire == 'oa' ? AccountKind.oa : AccountKind.personal;

AccountCapability? _capability(String wire) {
  for (final c in AccountCapability.values) {
    if (c.name == wire) return c;
  }
  return null;
}

AccountSummary accountSummaryFromJson(Json json) => AccountSummary(
      slot: _string(json['slot']),
      kind: _accountKind(json['kind'] as String?),
      capabilities: {
        for (final item in _stringList(json['capabilities']))
          if (_capability(item) case final c?) c,
      },
      uid: _string(json['uid']),
      displayName: _string(json['displayName']),
      avatarUrl: _string(json['avatarUrl']),
      status: accountStatusFromWire(json['status']),
      unread: _int(json['unread']),
    );

Manifest manifestFromJson(Json json) {
  final device = asJson(json['device']);
  return Manifest(
    server: serverInfoFromJson(asJson(json['server'])),
    deviceId: _string(device['id']),
    deviceName: _string(device['name']),
    role: deviceRoleFromWire(device['role']),
    accounts: [for (final item in asJsonList(json['accounts'])) accountSummaryFromJson(item)],
  );
}

DeviceInfo deviceInfoFromJson(Json json) => DeviceInfo(
      id: _string(json['id']),
      name: _string(json['name']),
      role: deviceRoleFromWire(json['role']),
      createdAt: _int(json['createdAt']),
      lastSeenAt: _intOrNull(json['lastSeenAt']),
      revoked: _bool(json['revoked']) || json['revokedAt'] != null,
      slots: _stringList(json['slots']),
    );

PairingOffer pairingOfferFromJson(Json json) => PairingOffer(
      uri: _string(json['uri']),
      expiresAt: _int(json['expiresAt']),
    );

String? vaultKeyFromJson(Json account) => _stringOrNull(account['vaultKey']);

TypingEvent typingEventFromJson(Json json) => TypingEvent(
      threadId: _string(json['threadId']),
      userId: _string(json['userId']),
    );

CallMediaKind callMediaKindFromWire(Object? value) => value == 'video' ? CallMediaKind.video : CallMediaKind.voice;

String callMediaKindToWire(CallMediaKind media) => media == CallMediaKind.video ? 'video' : 'voice';

CallDirection callDirectionFromWire(Object? value) =>
    value == 'outgoing' ? CallDirection.outgoing : CallDirection.incoming;

CallStatus callStatusFromWire(Object? value) {
  switch (value) {
    case 'connecting':
      return CallStatus.connecting;
    case 'active':
      return CallStatus.active;
    case 'ended':
      return CallStatus.ended;
    default:
      return CallStatus.ringing;
  }
}

ActiveCall activeCallFromJson(Json json) => ActiveCall(
      callId: _string(json['callId']),
      threadId: _string(json['threadId']),
      threadType: threadTypeFromWire(json['threadType']),
      peerId: _string(json['peerId']),
      peerName: _string(json['peerName']),
      peerAvatarUrl: _stringOrNull(json['peerAvatarUrl']),
      media: callMediaKindFromWire(json['media']),
      direction: callDirectionFromWire(json['direction']),
      status: callStatusFromWire(json['status']),
      startedAt: _int(json['startedAt']),
      answeredAt: _intOrNull(json['answeredAt']),
      answeredByDeviceId: _stringOrNull(json['answeredByDeviceId']),
      isGroup: _bool(json['isGroup']),
      groupCallId: _stringOrNull(json['groupCallId']),
      participants: _stringList(json['participants']),
      signalingData: asJson(json['signalingData']),
    );

/// Sentinel for [copyMessage]'s [sendErrorCode]: keep the current code.
const Object _keepSendError = Object();

Message copyMessage(
  Message m, {
  String? id,
  SendState? sendState,
  List<Attachment>? attachments,
  StickerRef? sticker,
  Quote? quote,
  Object? sendErrorCode = _keepSendError,
}) =>
    Message(
      id: id ?? m.id,
      cliId: m.cliId,
      threadId: m.threadId,
      threadType: m.threadType,
      senderId: m.senderId,
      senderName: m.senderName,
      ts: m.ts,
      isSelf: m.isSelf,
      kind: m.kind,
      text: m.text,
      attachments: attachments ?? m.attachments,
      sticker: sticker ?? m.sticker,
      card: m.card,
      bankCard: m.bankCard,
      location: m.location,
      poll: m.poll,
      note: m.note,
      reminder: m.reminder,
      callLog: m.callLog,
      doodle: m.doodle,
      album: m.album,
      todo: m.todo,
      linkPreview: m.linkPreview,
      quote: quote ?? m.quote,
      mentions: m.mentions,
      styles: m.styles,
      urgency: m.urgency,
      ttl: m.ttl,
      expiresAt: m.expiresAt,
      reactions: m.reactions,
      recalled: m.recalled,
      sendState: sendState ?? m.sendState,
      sendErrorCode: identical(sendErrorCode, _keepSendError) ? m.sendErrorCode : sendErrorCode as String?,
      raw: m.raw,
    );

Thread copyThread(
  Thread t, {
  Message? lastMessage,
  int? unread,
  bool? pinned,
  bool? muted,
  bool? hidden,
  bool? archived,
  int? autoDeleteTtl,
}) =>
    Thread(
      id: t.id,
      type: t.type,
      name: t.name,
      avatarUrl: t.avatarUrl,
      lastMessage: lastMessage ?? t.lastMessage,
      lastTs: t.lastTs,
      unread: unread ?? t.unread,
      pinned: pinned ?? t.pinned,
      muted: muted ?? t.muted,
      hidden: hidden ?? t.hidden,
      archived: archived ?? t.archived,
      autoDeleteTtl: autoDeleteTtl ?? t.autoDeleteTtl,
    );
