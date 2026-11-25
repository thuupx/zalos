import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:zalos/src/data/protocol/noise_channel.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/domain/services.dart';

import 'fake_png.dart';

/// Fixed "now" of every UI test: Thursday 12/03/2026 14:05.
final DateTime fakeNow = DateTime(2026, 3, 12, 14, 5);
int get _nowMs => fakeNow.millisecondsSinceEpoch;
int minutesAgo(int m) => _nowMs - m * 60000;

/// Sentinel for [FakeSession.copy]: keep the current send error code.
const Object _keepSendError = Object();

class FakePerson {
  const FakePerson(this.uid, this.name, {this.alias});
  final String uid;
  final String name;
  final String? alias;
}

const fakePeople = <FakePerson>[
  FakePerson('u01', 'Nguyễn Thị Lan'),
  FakePerson('u02', 'Trần Quốc Bảo'),
  FakePerson('u03', 'Lê Hoàng Anh'),
  FakePerson('u04', 'Phạm Gia Huy'),
  FakePerson('u05', 'Phạm Thị Mai', alias: 'Mẹ'),
  FakePerson('u06', 'Đỗ Thùy Linh'),
  FakePerson('u07', 'Vũ Đức Minh'),
  FakePerson('u08', 'Bùi Khánh Vy'),
  FakePerson('u09', 'Hoàng Văn Nam'),
  FakePerson('u10', 'Ngô Thanh Tâm'),
  FakePerson('u11', 'Đặng Ngọc Ánh'),
  FakePerson('u12', 'Chu Văn Sáu'),
  FakePerson('u13', 'Âu Dương Tuấn'),
  FakePerson('u14', 'Ông Hạnh chủ nhà'),
];

FakePerson? fakePerson(String uid) {
  for (final p in fakePeople) {
    if (p.uid == uid) return p;
  }
  return null;
}

/// Members of the close friends list in the default fake contact list.
const fakeCloseFriends = {'u04', 'u05'};

class FakeGroup {
  const FakeGroup(this.id, this.name, this.members, {this.avatar = false});
  final String id;
  final String name;
  final List<String> members;
  final bool avatar;
}

const fakeGroups = <FakeGroup>[
  FakeGroup('g01', 'Gia đình mình', ['u05', 'u04', 'u03']),
  FakeGroup('g02', 'Lớp 12A1 - THPT Lê Quý Đôn', ['u01', 'u03', 'u09', 'u10', 'u11']),
  FakeGroup('g03', 'Team Marketing Q3', ['u02', 'u06', 'u07', 'u08']),
  FakeGroup('g04', 'Hội cư dân chung cư Sunrise City - Block B từ tầng 12 đến tầng 20', ['u14', 'u09', 'u12']),
];

class FakeFlags {
  bool failSends = false;
  bool failContacts = false;
  bool failGroups = false;
  bool failStickers = false;
  bool failThreadActions = false;
  bool failForward = false;
  bool failDevices = false;
  bool failPairingOffer = false;
  bool failRecoveryExport = false;
  bool failVaultApprove = false;
  final Set<String> failMedia = {};
}

class FakeZalosApp implements ZalosApp {
  FakeZalosApp({bool paired = true, bool vaultPending = false, this.latency = Duration.zero, this.large = false, this.empty = false, this.withOa = false, DeviceRole role = DeviceRole.admin, bool noAccounts = false})
      : _vault = ValueNotifier(vaultPending ? VaultState.needsApproval : VaultState.ready),
        _role = role,
        _noAccounts = noAccounts {
    if (paired) _link.value = FakeServerLink(this, deviceName: 'MacBook của Thư', role: role, noAccounts: noAccounts);
  }

  static const samplePairingUri = 'zalos://pair?h=zalos.tailnet.ts.net:8443&k=3f9ac1d27b5e&t=test-token';
  static const sampleRecoveryCode = 'ZLS1-7K2M-Q9XD-4TTP-HW3C-8NVA-R6JE-B5YU';

  final Duration latency;
  final bool large;
  final bool empty;
  final bool withOa;
  final DeviceRole _role;
  final bool _noAccounts;
  final FakeFlags flags = FakeFlags();
  final ValueNotifier<ServerLink?> _link = ValueNotifier(null);
  final ValueNotifier<VaultState> _vault;
  int vaultRequestsSent = 0;
  PairingException? pairError;

  FakeServerLink get fakeLink => _link.value! as FakeServerLink;

  Future<void> wait() => latency == Duration.zero ? Future<void>.value() : Future<void>.delayed(latency);

  @override
  ValueListenable<ServerLink?> get link => _link;

  @override
  ValueListenable<VaultState> get vault => _vault;

  void setVault(VaultState state) => _vault.value = state;

  @override
  String get boxFingerprint => '4F2A91C7D03BE65A18FC';

  @override
  Future<void> pair(String uri, {required String deviceName}) async {
    await wait();
    final error = pairError;
    if (error != null) throw error;
    if (!uri.trim().startsWith('zalos://pair?')) throw const PairingException('This is not a valid zalos pairing code.', code: PairingErrorCode.invalid);
    _link.value = FakeServerLink(this, deviceName: deviceName, role: _role, noAccounts: _noAccounts);
  }

  @override
  Future<void> unpair() async {
    final old = _link.value;
    _link.value = null;
    if (old is FakeServerLink) old.dispose();
  }

  @override
  Future<String> exportRecoveryCode() async {
    await wait();
    if (flags.failRecoveryExport || _vault.value != VaultState.ready) throw StateError('vault is not ready');
    return sampleRecoveryCode;
  }

  @override
  Future<void> importRecoveryCode(String code) async {
    await wait();
    if (!RegExp(r'^[A-Za-z0-9]{16,}$').hasMatch(code.replaceAll(RegExp(r'[\s-]'), ''))) throw const FormatException('bad code');
    _vault.value = VaultState.ready;
  }

  @override
  Future<void> requestVaultApproval() async {
    await wait();
    vaultRequestsSent++;
    if (_link.value != null) fakeLink.setVaultRejected(false);
  }

  void dispose() {
    final old = _link.value;
    if (old is FakeServerLink) old.dispose();
  }
}

class _Account {
  _Account(this.slot, this.name, this.status, {this.kind = AccountKind.personal});
  final String slot;
  String name;
  AccountStatus status;
  final AccountKind kind;
  Set<AccountCapability>? customCapabilities;
  Set<AccountCapability> get capabilities => customCapabilities ?? (kind == AccountKind.oa ? const {} : AccountCapability.values.toSet());
  String get uid => 'self-$slot';
}

class FakeServerLink implements ServerLink {
  FakeServerLink(this.app, {required this.deviceName, required this.role, bool noAccounts = false}) {
    if (!noAccounts) {
      _accounts.addAll([
        _Account('main', 'Phạm Minh Thư', AccountStatus.online),
        _Account('shop', 'Tiệm Hoa Nhà Thư', AccountStatus.needsLogin),
        if (app.withOa) _Account('oa', 'Hoa Nhà Thư OA', AccountStatus.online, kind: AccountKind.oa),
      ]);
    }
    const day = 86400000;
    devices.addAll([
      DeviceInfo(id: 'dev-self', name: deviceName, role: role, createdAt: _nowMs - 40 * day, lastSeenAt: _nowMs, revoked: false, slots: const ['main', 'shop']),
      DeviceInfo(id: 'dev-iphone', name: 'iPhone của Thư', role: DeviceRole.member, createdAt: _nowMs - 31 * day, lastSeenAt: _nowMs - 15 * 60000, revoked: false, slots: const ['main']),
      DeviceInfo(id: 'dev-office', name: 'Windows văn phòng', role: DeviceRole.member, createdAt: _nowMs - 12 * day, lastSeenAt: _nowMs - 2 * day, revoked: false, slots: const ['main', 'shop']),
      DeviceInfo(id: 'dev-ipad', name: 'iPad cũ', role: DeviceRole.member, createdAt: _nowMs - 200 * day, lastSeenAt: _nowMs - 90 * day, revoked: true, slots: const []),
    ]);
    if (role == DeviceRole.admin) {
      _vaultRequests.value = [VaultRequest(deviceId: 'dev-tablet', name: 'Galaxy Tab của Thư', fingerprint: '9C41E7A05B2D83F6017A', requestedAt: _nowMs - 4 * 60000)];
    }
    for (final a in _accounts) {
      _session(a);
    }
    publish();
  }

  final FakeZalosApp app;
  final String deviceName;
  final DeviceRole role;
  final List<_Account> _accounts = [];
  final Map<String, FakeSession> _sessions = {};
  final List<DeviceInfo> devices = [];
  final ValueNotifier<LinkState> _state = ValueNotifier(LinkState.connected);
  final ValueNotifier<Manifest?> _manifest = ValueNotifier(null);
  final ValueNotifier<List<VaultRequest>> _vaultRequests = ValueNotifier(const []);
  final ValueNotifier<bool> _vaultRejected = ValueNotifier(false);
  StreamController<LoginQrEvent>? loginQr;
  int loginQrStarts = 0;
  bool loginQrCancelled = false;
  int pairingSeq = 0;
  Duration pairingTtl = const Duration(minutes: 5);
  bool manifestHidden = false;
  bool _disposed = false;

  @override
  ValueListenable<LinkState> get state => _state;
  void setState(LinkState s) => _state.value = s;

  @override
  ValueListenable<Manifest?> get manifest => _manifest;

  @override
  ValueListenable<List<VaultRequest>> get vaultRequests => _vaultRequests;

  @override
  ValueListenable<bool> get vaultRejected => _vaultRejected;
  void setVaultRejected(bool v) => _vaultRejected.value = v;

  void setStatus(String slot, AccountStatus status) {
    _accounts.firstWhere((a) => a.slot == slot).status = status;
    publish();
  }

  void setCapabilities(String slot, Set<AccountCapability> capabilities) {
    _accounts.firstWhere((a) => a.slot == slot).customCapabilities = Set.of(capabilities);
    publish();
  }

  FakeSession _session(_Account a) => _sessions.putIfAbsent(a.slot, () {
        final s = FakeSession(this, a.slot, a.uid, a.name);
        s.threads.addListener(publish);
        return s;
      });

  FakeSession session(String slot) => _sessions[slot]!;

  void publish() {
    if (_disposed) return;
    _manifest.value = manifestHidden
        ? null
        : Manifest(
            server: const ServerInfo(name: 'zalos-home', version: '0.4.0', fingerprint: '9F2C41AB7D03E6B815FA2C9D88E14B70'),
            deviceId: 'dev-self',
            deviceName: deviceName,
            role: role,
            accounts: [
              for (final a in _accounts)
                AccountSummary(
                  slot: a.slot,
                  uid: a.uid,
                  displayName: a.name,
                  avatarUrl: '',
                  status: a.status,
                  kind: a.kind,
                  capabilities: a.capabilities,
                  unread: _sessions[a.slot]?.threads.value.fold<int>(0, (n, t) => n + (t.muted ? 0 : t.unread)) ?? 0,
                ),
            ],
          );
  }

  @override
  AccountSession account(String slot) => _session(_accounts.firstWhere((a) => a.slot == slot));

  @override
  Future<List<DeviceInfo>> listDevices() async {
    await app.wait();
    if (app.flags.failDevices) throw StateError('devices unavailable');
    return List.of(devices);
  }

  void _replace(String id, DeviceInfo Function(DeviceInfo d) f) {
    final i = devices.indexWhere((d) => d.id == id);
    if (i >= 0) devices[i] = f(devices[i]);
  }

  @override
  Future<void> revokeDevice(String deviceId) async {
    await app.wait();
    _replace(deviceId, (d) => DeviceInfo(id: d.id, name: d.name, role: d.role, createdAt: d.createdAt, lastSeenAt: d.lastSeenAt, revoked: true, slots: const []));
  }

  @override
  Future<void> setDeviceAcl(String deviceId, List<String> slots) async {
    await app.wait();
    _replace(deviceId, (d) => DeviceInfo(id: d.id, name: d.name, role: d.role, createdAt: d.createdAt, lastSeenAt: d.lastSeenAt, revoked: d.revoked, slots: List.of(slots)));
  }

  @override
  Future<PairingOffer> createPairing({required DeviceRole role}) async {
    await app.wait();
    if (app.flags.failPairingOffer) throw StateError('offer failed');
    pairingSeq++;
    return PairingOffer(uri: 'zalos://pair?h=zalos.tailnet.ts.net:8443&k=3f9ac1d27b5e&t=test-$pairingSeq&r=${role.name}', expiresAt: _nowMs + pairingTtl.inMilliseconds);
  }

  @override
  Future<void> approveVaultRequest(VaultRequest request) async {
    await app.wait();
    if (app.flags.failVaultApprove) throw StateError('approve failed');
    _vaultRequests.value = [for (final r in _vaultRequests.value) if (r.deviceId != request.deviceId) r];
  }

  @override
  Future<void> rejectVaultRequest(VaultRequest request) async {
    await app.wait();
    _vaultRequests.value = [for (final r in _vaultRequests.value) if (r.deviceId != request.deviceId) r];
  }

  /// The test drives the login by adding events to [loginQr].
  @override
  Stream<LoginQrEvent> startLoginQr() {
    loginQrStarts++;
    loginQrCancelled = false;
    final c = StreamController<LoginQrEvent>(onCancel: () => loginQrCancelled = true);
    loginQr = c;
    return c.stream;
  }

  void finishLogin(String slot) {
    setStatus(slot, AccountStatus.online);
    loginQr?.add(LoginQrDone(slot));
  }

  final List<OaCredentials> oaAdded = [];
  final List<({String slot, String accessToken, String refreshToken})> oaTokenUpdates = [];
  String? oaError;

  @override
  Future<String> addOaAccount(OaCredentials credentials) async {
    await app.wait();
    final error = oaError;
    if (error != null) throw StateError(error);
    oaAdded.add(credentials);
    final slot = 'oa${_accounts.length}';
    final account = _Account(slot, 'OA ${credentials.appId}', AccountStatus.online, kind: AccountKind.oa);
    _accounts.add(account);
    _session(account);
    publish();
    return slot;
  }

  @override
  Future<void> updateOaTokens(String slot, {required String accessToken, required String refreshToken}) async {
    await app.wait();
    final error = oaError;
    if (error != null) throw StateError(error);
    oaTokenUpdates.add((slot: slot, accessToken: accessToken, refreshToken: refreshToken));
    setStatus(slot, AccountStatus.online);
  }

  @override
  Future<void> removeAccount(String slot) async {
    await app.wait();
    _accounts.removeWhere((a) => a.slot == slot);
    _sessions.remove(slot)?.dispose();
    publish();
  }

  void dispose() {
    _disposed = true;
    for (final s in _sessions.values) {
      s.dispose();
    }
  }
}

const _peerLines = [
  'Chiều nay bạn rảnh không?',
  'Ok nha, để mình xem lại rồi báo.',
  'Mình vừa gửi mail rồi đó, bạn kiểm tra giúp nhé.',
  'Tối nay đi ăn bún chả không?',
  'Cảm ơn bạn nhiều nha!',
  'Để mai mình gọi lại, giờ đang họp.',
  'Trời mưa to quá, bạn về tới nhà chưa?',
  'Mình chuyển khoản rồi nhé, bạn kiểm tra giúp.',
];

const _selfLines = [
  'Ok bạn ơi.',
  'Để mình coi lịch rồi nhắn lại nha.',
  'Mình nhận được rồi, cảm ơn nhé.',
  'Khoảng 6 giờ mình tới.',
  'Mình đang trên đường, 10 phút nữa tới.',
];

class FakeSession implements AccountSession {
  FakeSession(this.fakeLink, this.slot, this.selfUid, this.selfName) {
    linkedDeviceList = LinkedDevices(
      masterId: selfUid,
      lastUpdateTs: minutesAgo(3),
      companions: [
        LinkedDeviceCompanion(id: 'zd-1', name: 'iPhone của Thư', platform: 'ios', lastUpdateTs: minutesAgo(3), current: true),
        LinkedDeviceCompanion(id: 'zd-2', name: 'Windows văn phòng', platform: 'windows', lastUpdateTs: minutesAgo(120)),
        const LinkedDeviceCompanion(summary: 'object(3)'),
      ],
    );
    _build();
    _fetchThreads();
  }

  static const pageSize = 30;

  final FakeServerLink fakeLink;
  @override
  final String slot;
  final String selfUid;
  final String selfName;
  final ValueNotifier<LinkState> _state = ValueNotifier(LinkState.connected);
  final ValueNotifier<List<Thread>> _threads = ValueNotifier(const []);
  final ValueNotifier<LoadState> _threadsLoad = ValueNotifier(LoadState.loading);
  final Map<String, ValueNotifier<LoadState>> _messagesLoad = {};

  /// Makes the next thread list fetch fail; cleared once used.
  bool failNextThreadsLoad = false;

  /// Makes the next latest page fetch of any thread fail; cleared once used.
  bool failNextMessagesLoad = false;
  int reloadThreadsCalls = 0;
  int reloadMessagesCalls = 0;
  final Map<String, Thread> _threadMap = {};
  final Map<String, List<Message>> _all = {};

  /// Whole history of a thread, including pages not loaded yet.
  List<Message> history(String id) => List.unmodifiable(_all[id] ?? const []);
  final Map<String, int> _shown = {};
  final Map<String, ValueNotifier<List<Message>>> _notifiers = {};
  final StreamController<TypingEvent> _typing = StreamController.broadcast();
  int _seq = 0;
  bool _disposed = false;

  int typingSent = 0;
  int markSeenCalls = 0;
  int mediaCalls = 0;
  int usersCalls = 0;
  final List<String> resent = [];
  final List<(Message, List<ThreadRef>)> forwarded = [];
  final List<OutgoingFile> sentFiles = [];
  final List<({OutgoingFile file, String? caption, MessageUrgency? urgency, int? ttl})> sentFileOptions = [];
  final List<StickerRef> sentStickers = [];
  final List<({String text, Message? quote, List<Mention> mentions, List<StyleRun> styles, MessageUrgency? urgency, int? ttl})>
      sentTexts = [];
  final List<({String threadId, ThreadType type, String link, String? msg, int? ttl})> sentLinks = [];
  final List<({String threadId, ThreadType type, BankCard card})> sentBankCards = [];

  // ---- Phase C seeds and recordings ----

  /// Friends served by [contacts]; tests may edit the list, and friend
  /// mutations below keep it up to date.
  final List<Contact> contactList = [
    for (final p in fakePeople)
      Contact(uid: p.uid, displayName: p.name, avatarUrl: '', alias: p.alias, closeFriend: fakeCloseFriends.contains(p.uid)),
  ];

  final List<FriendRequest> receivedRequests = [
    FriendRequest(uid: 'u15', displayName: 'Lý Minh Châu', avatarUrl: 'fake://avatar/u15', message: 'Chào Thư, mình là đồng nghiệp cũ của Bảo.', ts: minutesAgo(120)),
    FriendRequest(uid: 'u16', displayName: 'Trịnh Văn Khoa', avatarUrl: '', ts: minutesAgo(60 * 20)),
  ];

  final List<FriendRequest> sentRequests = [
    FriendRequest(uid: 'u17', displayName: 'Mai Phương Thảo', avatarUrl: '', ts: minutesAgo(60 * 5)),
  ];

  final List<FriendRecommendation> recommendations = [
    const FriendRecommendation(uid: 'u18', displayName: 'Nguyễn Bảo Ngọc', avatarUrl: 'fake://avatar/u18', gender: 'female', message: 'Cùng nhóm học tiếng Anh'),
    const FriendRecommendation(uid: 'u19', displayName: 'Trần Hữu Phước', avatarUrl: '', phoneNumber: '0900000019'),
  ];

  /// Relationship overrides served by [friendRequestStatus]; unlisted uids
  /// fall back to their membership in [contactList].
  final Map<String, FriendRequestStatus> requestStatuses = {
    'u15': const FriendRequestStatus(isRequested: true, addFriendPrivacy: 1),
    'u17': const FriendRequestStatus(isRequesting: true),
  };

  final Map<String, UserProfile> profilesByPhone = {
    '0900000015': const UserProfile(uid: 'u15', displayName: 'Lý Minh Châu', avatarUrl: 'fake://avatar/u15', gender: 'female', phoneNumber: '0900000015'),
    '0900000019': const UserProfile(uid: 'u19', displayName: 'Trần Hữu Phước', avatarUrl: '', phoneNumber: '0900000019'),
  };

  final Map<String, UserProfile> profilesByUsername = {
    'minhchau': const UserProfile(uid: 'u15', displayName: 'Lý Minh Châu', avatarUrl: 'fake://avatar/u15', zaloName: 'minhchau', gender: 'female'),
  };

  final List<FriendPresence> presenceList = [
    const FriendPresence(uid: 'u01', status: 'online', online: true),
    const FriendPresence(uid: 'u02', status: 'offline', online: false),
  ];

  final Map<String, LastSeen> lastSeenMap = {
    'u02': LastSeen(showOnlineStatus: true, lastOnline: minutesAgo(30)),
  };

  final List<({String threadId, ThreadType type, ContactCard card})> sentCards = [];
  final List<String> deletedForAll = [];
  final List<({String threadId, ThreadType type, ReportReason reason, String? content})> reports = [];
  final List<({String uid, String message})> friendRequestsSent = [];
  final List<String> friendRequestsAccepted = [];
  final List<String> friendRequestsRejected = [];
  final List<String> friendRequestsCancelled = [];
  final List<String> removedFriends = [];
  final List<String> blockedUsers = [];
  final List<String> unblockedUsers = [];
  final List<({String uid, String alias})> aliasesSet = [];
  final List<String> aliasesRemoved = [];
  final Set<String> blocked = {};
  int phoneLookups = 0;
  int usernameLookups = 0;
  int presenceCalls = 0;
  int lastSeenCalls = 0;
  int friendRequestsCalls = 0;
  int recommendationCalls = 0;
  int _reportSeq = 0;

  // ---- Phase D seeds and recordings ----

  /// Hidden conversations. The PIN itself is never kept: [hiddenPinSets] only
  /// counts the writes so a test can prove one was forwarded.
  final List<ThreadRef> hiddenThreads = [];
  bool hiddenPinSet = false;
  int hiddenPinSets = 0;

  final List<ThreadRef> archivedThreads = [];
  int archiveVersion = 0;

  final List<ConversationLabel> labelList = [
    ConversationLabel(id: 1, text: 'Gia đình', conversations: const ['g01', 'u05'], color: '#E86A5B', createTime: minutesAgo(60 * 24 * 90)),
    ConversationLabel(id: 2, text: 'Công việc', conversations: const ['g03', 'u02'], color: '#4A7DFF', createTime: minutesAgo(60 * 24 * 60)),
    ConversationLabel(id: 3, text: 'Khách hàng', conversations: const ['u01', 'u06'], color: '#2FA36B', createTime: minutesAgo(60 * 24 * 30)),
  ];
  int labelsVersion = 4;
  int labelsLastUpdateTime = minutesAgo(60 * 24 * 2);

  final List<AutoDeleteConversation> autoDeleteList = [];

  late LinkedDevices linkedDeviceList;

  /// Banks served by [banks] for the composer.
  final List<BankInfo> bankList = const [
    BankInfo(bin: 970436, logo: 'fake://bank/vcb', name: 'Ngân hàng TMCP Ngoại thương Việt Nam', nameEn: 'Vietcombank', shortName: 'VCB', searchKeyword: 'vietcombank vcb'),
    BankInfo(bin: 970422, logo: 'fake://bank/mb', name: 'Ngân hàng TMCP Quân đội', nameEn: 'MB Bank', shortName: 'MB', searchKeyword: 'mb bank quan doi'),
    BankInfo(bin: 970407, logo: 'fake://bank/tcb', name: 'Ngân hàng TMCP Kỹ thương Việt Nam', nameEn: 'Techcombank', shortName: 'TCB', searchKeyword: 'techcombank tcb'),
  ];

  /// Saved bank accounts served by [bankAccounts], in Zalo's order.
  final List<BankAccount> bankAccountList = [
    BankAccount(id: 'ba1', bin: 970436, accountNumber: '0071000123456', holderName: 'PHAM MINH THU', isDefault: true, accountId: 11, bankName: 'Vietcombank', bankLogo: 'fake://bank/vcb', createdAt: minutesAgo(60 * 24 * 200), updatedAt: minutesAgo(60 * 24 * 20)),
    BankAccount(id: 'ba2', bin: 970422, accountNumber: '0900123456789', holderName: 'PHAM MINH THU', isDefault: false, accountId: 12, bankName: 'MB Bank', bankLogo: 'fake://bank/mb', createdAt: minutesAgo(60 * 24 * 120), updatedAt: minutesAgo(60 * 24 * 12)),
    BankAccount(id: 'ba3', bin: 970407, accountNumber: '19036789012345', holderName: 'TIEM HOA NHA THU', isDefault: false, accountId: 13, createdAt: minutesAgo(60 * 24 * 60), updatedAt: minutesAgo(60 * 24 * 6)),
  ];

  int bankListCalls = 0;
  int bankAccountsCalls = 0;
  int parseLinkCalls = 0;

  /// Previews served by [parseLink]; an unknown link gets a host based one.
  final Map<String, LinkPreview> linkPreviews = {
    'https://thoitiet.example.vn/du-bao-cuoi-tuan': const LinkPreview(
      title: 'Dự báo thời tiết cuối tuần',
      description: 'Miền Trung nắng đẹp, ít mưa.',
      srcUrl: 'https://thoitiet.example.vn/du-bao-cuoi-tuan',
      href: 'https://thoitiet.example.vn/du-bao-cuoi-tuan',
      thumbUrl: 'fake://photo/weather',
      mediaType: 0,
    ),
  };

  final List<QuickMessage> quickMessageList = [
    QuickMessage(
      id: 1,
      keyword: '/diachi',
      title: 'Địa chỉ shop: 12 Nguyễn Huệ, Quận 1, TP.HCM',
      type: 0,
      createdTime: minutesAgo(60 * 24 * 30),
      lastModified: minutesAgo(60 * 24 * 30),
    ),
    QuickMessage(
      id: 2,
      keyword: '/banggia',
      title: 'Bảng giá hoa hồng Đà Lạt',
      type: 1,
      createdTime: minutesAgo(60 * 24 * 20),
      lastModified: minutesAgo(60 * 24 * 20),
      media: const [
        QuickMessageMedia(
          type: 1,
          photoId: 9001,
          title: 'Bảng giá hoa hồng Đà Lạt',
          width: 320,
          height: 240,
          previewThumb: 'fake://quick/9001-preview',
          rawUrl: 'fake://quick/9001-raw',
          thumbUrl: 'fake://quick/9001-thumb',
          normalUrl: 'fake://quick/9001',
          hdUrl: 'fake://quick/9001-hd',
        ),
      ],
    ),
  ];
  int quickMessagesVersion = 3;
  int quickMessagesCursor = 17;
  int _quickMessageSeq = 2;
  final List<QuickMessageDraft> quickMessagesAdded = [];
  final List<({int id, QuickMessageDraft draft})> quickMessagesUpdated = [];
  final List<List<int>> quickMessagesRemoved = [];

  FakeFlags get _flags => fakeLink.app.flags;
  Future<void> _wait() => fakeLink.app.wait();

  @override
  ValueListenable<LinkState> get state => _state;
  void setState(LinkState s) => _state.value = s;

  @override
  ValueListenable<List<Thread>> get threads => _threads;

  @override
  ValueListenable<LoadState> get threadsLoad => _threadsLoad;

  /// Simulates the thread list fetch: the listed threads stand for the cache,
  /// the state settles after the app latency.
  Future<void> _fetchThreads() async {
    _threadsLoad.value = LoadState.loading;
    await _wait();
    if (_disposed) return;
    final fail = failNextThreadsLoad;
    failNextThreadsLoad = false;
    _threadsLoad.value = fail ? LoadState.failed : LoadState.ready;
  }

  @override
  Future<void> reloadThreads() {
    reloadThreadsCalls++;
    return _fetchThreads();
  }

  @override
  ValueListenable<LoadState> messagesLoad(String threadId, ThreadType type) {
    messages(threadId, type);
    return _messagesLoad[threadId]!;
  }

  Future<void> _fetchMessages(String threadId) async {
    final load = _messagesLoad.putIfAbsent(threadId, () => ValueNotifier(LoadState.loading));
    load.value = LoadState.loading;
    await _wait();
    if (_disposed) return;
    final fail = failNextMessagesLoad;
    failNextMessagesLoad = false;
    load.value = fail ? LoadState.failed : LoadState.ready;
  }

  @override
  Future<void> reloadMessages(String threadId, ThreadType type) {
    reloadMessagesCalls++;
    return _fetchMessages(threadId);
  }

  @override
  Stream<TypingEvent> get typing => _typing.stream;

  void emitTyping(String threadId, String userId) => _typing.add(TypingEvent(threadId: threadId, userId: userId));

  Message msg(
    String threadId,
    ThreadType type,
    String senderId,
    int ts, {
    MessageKind kind = MessageKind.text,
    String? text,
    List<Attachment> attachments = const [],
    StickerRef? sticker,
    ContactCard? card,
    BankCard? bankCard,
    Location? location,
    Poll? poll,
    Note? note,
    Reminder? reminder,
    CallLog? callLog,
    Doodle? doodle,
    Album? album,
    Todo? todo,
    LinkPreview? linkPreview,
    Quote? quote,
    List<Mention> mentions = const [],
    List<StyleRun> styles = const [],
    MessageUrgency? urgency,
    int? ttl,
    int? expiresAt,
    Map<String, List<String>> reactions = const {},
    bool recalled = false,
    SendState sendState = SendState.sent,
    DeliveryState deliveryState = DeliveryState.sent,
    String? sendErrorCode,
    String? cliId,
    bool sealed = false,
  }) {
    final self = senderId == selfUid;
    return Message(
      id: '$slot-m${++_seq}',
      cliId: cliId,
      threadId: threadId,
      threadType: type,
      senderId: senderId,
      senderName: self ? selfName : (fakePerson(senderId)?.name ?? ''),
      ts: ts,
      isSelf: self,
      kind: kind,
      text: text,
      attachments: attachments,
      sticker: sticker,
      card: card,
      bankCard: bankCard,
      location: location,
      poll: poll,
      note: note,
      reminder: reminder,
      callLog: callLog,
      doodle: doodle,
      album: album,
      todo: todo,
      linkPreview: linkPreview,
      quote: quote,
      mentions: mentions,
      styles: styles,
      urgency: urgency,
      ttl: ttl,
      expiresAt: expiresAt,
      reactions: reactions,
      recalled: recalled,
      sendState: sendState,
      deliveryState: deliveryState,
      sendErrorCode: sendErrorCode,
      raw: sealed ? null : const <String, Object?>{'fake': true},
    );
  }

  Attachment image(String seed) => Attachment(kind: MessageKind.image, url: 'fake://photo/$seed', thumbUrl: 'fake://photo/$seed', width: 320, height: 240);

  List<Message> _family() {
    const id = 'g01';
    const t = ThreadType.group;
    final me = selfUid;
    final first = msg(id, t, 'u05', minutesAgo(60 * 50), text: 'Cuối tuần này cả nhà về ăn cơm nhé, mẹ đi chợ mua đồ ngon.');
    return [
      msg(id, t, 'u05', minutesAgo(60 * 73), kind: MessageKind.system, text: 'Mẹ đã thêm Phạm Gia Huy vào nhóm'),
      first,
      msg(id, t, me, minutesAgo(60 * 50 - 2), text: 'Dạ, con về tối thứ 6 ạ', reactions: const {'/-heart': ['u05', 'u04'], '/-strong': ['u03']}),
      msg(id, t, 'u04', minutesAgo(60 * 49), kind: MessageKind.image, attachments: [image('garden')]),
      msg(id, t, 'u04', minutesAgo(60 * 49 - 1), kind: MessageKind.image, text: 'Vườn nhà mình hôm nay nè', attachments: [image('g1'), image('g2'), image('g3')]),
      msg(id, t, 'u05', minutesAgo(60 * 48), kind: MessageKind.sticker, sticker: const StickerRef(id: 1, cateId: 1, type: 1, url: 'fake://sticker/1')),
      msg(id, t, 'u03', minutesAgo(60 * 28), kind: MessageKind.file, attachments: const [Attachment(kind: MessageKind.file, url: 'fake://file/lich', name: 'Lich_ve_que_thang_8.xlsx', size: 48211)]),
      msg(id, t, me, minutesAgo(60 * 27), kind: MessageKind.voice, attachments: const [Attachment(kind: MessageKind.voice, url: 'fake://voice/2', durationMs: 12000)]),
      msg(id, t, 'u04', minutesAgo(60 * 26), kind: MessageKind.video, attachments: const [Attachment(kind: MessageKind.video, url: 'fake://video/cat', thumbUrl: 'fake://photo/cat', width: 320, height: 240, durationMs: 34000)]),
      msg(id, t, 'u05', minutesAgo(60 * 25), kind: MessageKind.link, text: 'Cuối tuần trời đẹp nè các con', attachments: const [
        Attachment(kind: MessageKind.link, url: 'https://thoitiet.example.vn/du-bao-cuoi-tuan', name: 'Dự báo thời tiết cuối tuần: miền Trung nắng đẹp, ít mưa', thumbUrl: 'fake://photo/weather'),
      ]),
      msg(id, t, me, minutesAgo(60 * 24), text: 'Con mua thêm trái cây nha mẹ', quote: Quote(msgId: first.id, senderId: 'u05', senderName: 'Phạm Thị Mai', text: first.text!)),
      msg(id, t, 'u04', minutesAgo(60 * 24 - 3), text: '', recalled: true),
      msg(id, t, 'u03', minutesAgo(60 * 23), text: '@Phạm Minh Thư nhớ mang sạc dự phòng giùm anh nha, xem https://example.vn/sac', mentions: [Mention(uid: me, pos: 0, len: 14)]),
      msg(id, t, 'u03', minutesAgo(60 * 23 - 1), sealed: true),
      msg(id, t, 'u05', minutesAgo(60 * 22), kind: MessageKind.other),
      msg(id, t, me, minutesAgo(40), text: 'Con sắp xếp đồ xong rồi, mai con đi chuyến xe sáng.', deliveryState: DeliveryState.seen),
      msg(id, t, 'u04', minutesAgo(4), text: 'Chị Thư ơi mấy giờ chị tới?'),
      msg(id, t, 'u05', minutesAgo(3), text: 'Mẹ nấu canh chua rồi đó'),
    ];
  }

  List<Message> _generated(String id, ThreadType type, List<String> members, int count, int ago) {
    final r = math.Random(id.codeUnits.fold<int>(count, (a, b) => a * 31 + b) & 0xffff);
    final list = <Message>[];
    var minutes = ago + count * 7;
    for (var i = 0; i < count; i++) {
      final self = r.nextInt(5) < 2;
      final sender = self ? selfUid : (type == ThreadType.group ? members[r.nextInt(members.length)] : id);
      final lines = self ? _selfLines : _peerLines;
      list.add(msg(id, type, sender, minutesAgo(minutes), text: '${lines[r.nextInt(lines.length)]}${count > 100 ? ' #$i' : ''}'));
      minutes -= r.nextInt(3) == 0 ? 1 : 3 + r.nextInt(9);
      if (minutes < ago) minutes = ago;
    }
    return list;
  }

  void _add(String id, ThreadType type, String name, List<Message> list, {bool pinned = false, bool muted = false, int unread = 0, bool avatar = false}) {
    _all[id] = list;
    _threadMap[id] = Thread(
      id: id,
      type: type,
      name: name,
      avatarUrl: avatar ? 'fake://avatar/$id' : '',
      lastMessage: list.isEmpty ? null : list.last,
      lastTs: list.isEmpty ? 0 : list.last.ts,
      unread: unread,
      pinned: pinned,
      muted: muted,
    );
  }

  void _build() {
    final app = fakeLink.app;
    if (app.empty) {
      _publish();
      return;
    }
    if (slot.startsWith('oa')) {
      if (slot != 'oa') {
        _publish();
        return;
      }
      _add('u06', ThreadType.user, 'Đỗ Thùy Linh', [
        msg('u06', ThreadType.user, 'u06', minutesAgo(50), text: 'Shop ơi còn hoa hồng Đà Lạt không ạ?'),
        msg('u06', ThreadType.user, selfUid, minutesAgo(48), text: 'Dạ còn ạ, bên em giao trong ngày.', deliveryState: DeliveryState.seen),
        msg('u06', ThreadType.user, 'u06', minutesAgo(45), kind: MessageKind.image, attachments: [image('oa1')]),
      ]);
      _add('u09', ThreadType.user, 'Hoàng Văn Nam', [msg('u09', ThreadType.user, 'u09', minutesAgo(60 * 30), text: 'Cho mình hỏi giá bó hoa cưới.')]);
      _publish();
      return;
    }
    if (slot != 'main') {
      _add('u13', ThreadType.user, 'Âu Dương Tuấn', _generated('u13', ThreadType.user, const [], 12, 18), pinned: true, unread: 2);
      _add('u11', ThreadType.user, 'Đặng Ngọc Ánh', _generated('u11', ThreadType.user, const [], 8, 300));
      _publish();
      return;
    }
    const g = ThreadType.group, u = ThreadType.user;
    _add('g01', g, 'Gia đình mình', _family(), pinned: true, unread: 2);
    _add('u01', u, 'Nguyễn Thị Lan', _generated('u01', u, const [], app.large ? 5000 : 80, 12), pinned: true, avatar: true);
    _add('u02', u, 'Trần Quốc Bảo', [..._generated('u02', u, const [], 10, 40), msg('u02', u, 'u02', minutesAgo(26), kind: MessageKind.image, attachments: [image('bao')])], unread: 3);
    _add('g03', g, 'Team Marketing Q3', [
      ..._generated('g03', g, fakeGroups[2].members, 14, 60),
      msg('g03', g, 'u02', minutesAgo(41), kind: MessageKind.file, attachments: const [Attachment(kind: MessageKind.file, url: 'fake://file/bao-cao', name: 'Bao_cao_doanh_thu_quy_3_ban_cuoi_cung_da_duyet.pdf', size: 2411724)]),
    ], unread: 12);
    _add('u05', u, 'Mẹ', [..._generated('u05', u, const [], 6, 90), msg('u05', u, 'u05', minutesAgo(75), kind: MessageKind.voice, attachments: const [Attachment(kind: MessageKind.voice, url: 'fake://voice/1', durationMs: 23000)])]);
    _add('u06', u, 'Đỗ Thùy Linh', [..._generated('u06', u, const [], 6, 140), msg('u06', u, 'u06', minutesAgo(130), kind: MessageKind.sticker, sticker: const StickerRef(id: 3, cateId: 1, type: 1, url: 'fake://sticker/3'))], unread: 1);
    _add('g02', g, 'Lớp 12A1 - THPT Lê Quý Đôn', _generated('g02', g, fakeGroups[1].members, 30, 190), muted: true, unread: 128);
    _add('u07', u, 'Vũ Đức Minh', [..._generated('u07', u, const [], 6, 60 * 8), msg('u07', u, selfUid, minutesAgo(60 * 7), text: 'Ok, vậy hẹn gặp mọi người lúc 7 giờ tối nha.')]);
    _add('g04', g, fakeGroups[3].name, [
      ..._generated('g04', g, fakeGroups[3].members, 6, 60 * 24),
      msg('g04', g, 'u14', minutesAgo(60 * 22), kind: MessageKind.link, text: 'Mọi người xem thông báo bảo trì thang máy nhé', attachments: const [
        Attachment(kind: MessageKind.link, url: 'https://sunrisecity.example.vn/thong-bao/bao-tri-thang-may', name: 'Thông báo bảo trì thang máy Block B tháng 8'),
      ]),
    ], muted: true);
    _add('u08', u, 'Bùi Khánh Vy', [..._generated('u08', u, const [], 5, 60 * 30), msg('u08', u, 'u08', minutesAgo(60 * 26), kind: MessageKind.video, attachments: const [Attachment(kind: MessageKind.video, url: 'fake://video/vy', thumbUrl: 'fake://photo/vy', width: 320, height: 240, durationMs: 47000)])]);
    _add('u03', u, 'Lê Hoàng Anh', [..._generated('u03', u, const [], 5, 60 * 32), msg('u03', u, 'u03', minutesAgo(60 * 30), sealed: true)]);
    _add('u09', u, 'Hoàng Văn Nam', [..._generated('u09', u, const [], 4, 60 * 24 * 4 + 10), msg('u09', u, 'u09', minutesAgo(60 * 24 * 4), text: '', recalled: true)]);
    _add('u10', u, 'Ngô Thanh Tâm', _generated('u10', u, const [], 5, 60 * 24 * 9));
    _add('u04', u, 'Phạm Gia Huy', _generated('u04', u, const [], 4, 60 * 24 * 40));
    if (app.large) {
      for (var i = 0; i < 1986; i++) {
        final id = 'x${i.toString().padLeft(4, '0')}';
        final m = msg(id, u, id, minutesAgo(60 * 24 * 50 + i), text: 'Tin nhắn số $i');
        _all[id] = [m];
        _threadMap[id] = Thread(id: id, type: u, name: 'Khách hàng $i', avatarUrl: '', lastMessage: m, lastTs: m.ts, unread: 0, pinned: false, muted: false);
      }
    }
    _publish();
  }

  void _publish() {
    if (_disposed) return;
    final list = _threadMap.values.toList()
      ..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return b.lastTs.compareTo(a.lastTs);
      });
    _threads.value = list;
  }

  void _touch(String id, ThreadType type, {int? unread, bool? pinned, bool? muted, bool? hidden, bool? archived, int? autoDeleteTtl}) {
    final list = _all[id] ?? const <Message>[];
    final old = _threadMap[id];
    final name = old?.name ?? (type == ThreadType.user ? (fakePerson(id)?.name ?? id) : fakeGroups.firstWhere((g) => g.id == id).name);
    _threadMap[id] = Thread(
      id: id,
      type: type,
      name: name,
      avatarUrl: old?.avatarUrl ?? '',
      lastMessage: list.isEmpty ? null : list.last,
      lastTs: list.isEmpty ? (old?.lastTs ?? 0) : list.last.ts,
      unread: unread ?? old?.unread ?? 0,
      pinned: pinned ?? old?.pinned ?? false,
      muted: muted ?? old?.muted ?? false,
      hidden: hidden ?? old?.hidden ?? false,
      archived: archived ?? old?.archived ?? false,
      autoDeleteTtl: autoDeleteTtl ?? old?.autoDeleteTtl ?? 0,
    );
    _publish();
  }

  void _refresh(String id) {
    if (_disposed) return;
    final all = _all[id] ?? const <Message>[];
    final shown = math.min(_shown[id] ?? pageSize, all.length);
    _notifiers[id]?.value = all.sublist(all.length - shown);
  }

  @override
  ValueListenable<List<Message>> messages(String threadId, ThreadType type) {
    return _notifiers.putIfAbsent(threadId, () {
      final all = _all.putIfAbsent(threadId, () => []);
      final shown = math.min(fakeLink.app.large ? all.length : pageSize, all.length);
      _shown[threadId] = shown;
      _fetchMessages(threadId);
      return ValueNotifier(all.sublist(all.length - shown));
    });
  }

  List<Message> allOf(String threadId) => _all[threadId] ?? const [];

  @override
  Future<bool> loadOlder(String threadId, ThreadType type) async {
    final all = _all[threadId] ?? const <Message>[];
    final shown = _shown[threadId] ?? 0;
    if (shown >= all.length) return false;
    await _wait();
    _shown[threadId] = math.min(all.length, shown + pageSize);
    _refresh(threadId);
    return true;
  }

  void _append(Message m, {bool countUnread = false}) {
    _all.putIfAbsent(m.threadId, () => []).add(m);
    _shown[m.threadId] = (_shown[m.threadId] ?? 0) + 1;
    _refresh(m.threadId);
    _touch(m.threadId, m.threadType, unread: countUnread ? (_threadMap[m.threadId]?.unread ?? 0) + 1 : null);
  }

  /// Code returned by the next failed send, as the data layer reports it.
  String? sendErrorCode;

  /// Injects an incoming message as if it arrived from the server.
  Message receive(String threadId, String text, {String? from, MessageKind kind = MessageKind.text, List<Attachment> attachments = const [], int? ts}) {
    final type = _threadMap[threadId]?.type ?? (threadId.startsWith('g') ? ThreadType.group : ThreadType.user);
    final sender = from ?? (type == ThreadType.group ? fakeGroups.firstWhere((g) => g.id == threadId).members.first : threadId);
    final m = msg(threadId, type, sender, ts ?? _nowMs + _seq, text: text, kind: kind, attachments: attachments);
    _append(m, countUnread: true);
    return m;
  }

  void replace(Message old, Message? Function(Message m) f) {
    final list = _all[old.threadId];
    if (list == null) return;
    final i = list.indexWhere((m) => m.id == old.id);
    if (i < 0) return;
    final next = f(list[i]);
    if (next == null) {
      list.removeAt(i);
      _shown[old.threadId] = math.max(0, (_shown[old.threadId] ?? 1) - 1);
    } else {
      list[i] = next;
    }
    _refresh(old.threadId);
    _touch(old.threadId, old.threadType);
  }

  Message copy(
    Message m, {
    Map<String, List<String>>? reactions,
    bool recalled = false,
    SendState? sendState,
    DeliveryState? deliveryState,
    Object? sendErrorCode = _keepSendError,
  }) =>
      Message(
        id: m.id,
        cliId: m.cliId,
        threadId: m.threadId,
        threadType: m.threadType,
        senderId: m.senderId,
        senderName: m.senderName,
        ts: m.ts,
        isSelf: m.isSelf,
        kind: recalled ? MessageKind.text : m.kind,
        text: recalled ? '' : m.text,
        attachments: recalled ? const [] : m.attachments,
        sticker: recalled ? null : m.sticker,
        card: recalled ? null : m.card,
        bankCard: recalled ? null : m.bankCard,
        location: recalled ? null : m.location,
        poll: recalled ? null : m.poll,
        note: recalled ? null : m.note,
        reminder: recalled ? null : m.reminder,
        callLog: recalled ? null : m.callLog,
        doodle: recalled ? null : m.doodle,
        album: recalled ? null : m.album,
        todo: recalled ? null : m.todo,
        linkPreview: recalled ? null : m.linkPreview,
        quote: recalled ? null : m.quote,
        mentions: recalled ? const [] : m.mentions,
        styles: recalled ? const [] : m.styles,
        urgency: recalled ? null : m.urgency,
        ttl: recalled ? null : m.ttl,
        expiresAt: recalled ? null : m.expiresAt,
        reactions: reactions ?? m.reactions,
        recalled: recalled || m.recalled,
        sendState: sendState ?? m.sendState,
        deliveryState: deliveryState ?? m.deliveryState,
        sendErrorCode: identical(sendErrorCode, _keepSendError) ? m.sendErrorCode : sendErrorCode as String?,
        raw: m.raw,
      );

  /// Appends a pre-built message as if the server delivered it, for seeds
  /// that need a structured payload.
  void deliver(Message m, {bool countUnread = false}) => _append(m, countUnread: countUnread);

  bool get _online => fakeLink.manifest.value?.accounts.any((a) => a.slot == slot && a.status == AccountStatus.online) ?? false;

  Future<void> _send(Message m) async {
    _append(m);
    await _wait();
    final ok = _online && !_flags.failSends && fakeLink.state.value == LinkState.connected;
    if (fakeLink.state.value != LinkState.connected && !_flags.failSends) return;
    final code = sendErrorCode;
    final failed = !ok || code != null;
    replace(m, (cur) => copy(cur, sendState: failed ? SendState.failed : SendState.sent, sendErrorCode: failed ? code : null));
    if (code != null) throw StateError('$code: rejected by Zalo');
  }

  @override
  Future<void> sendText(
    String threadId,
    ThreadType type,
    String text, {
    Message? quote,
    List<Mention> mentions = const [],
    List<StyleRun> styles = const [],
    MessageUrgency? urgency,
    int? ttl,
  }) async {
    sentTexts.add((text: text, quote: quote, mentions: mentions, styles: styles, urgency: urgency, ttl: ttl));
    await _send(msg(
      threadId,
      type,
      selfUid,
      _nowMs + _seq,
      text: text,
      mentions: mentions,
      styles: styles,
      urgency: urgency,
      ttl: ttl != null && ttl > 0 ? ttl : null,
      expiresAt: ttl != null && ttl > 0 ? _nowMs + ttl : null,
      sendState: SendState.sending,
      cliId: 'cli-$_seq',
      quote: quote == null ? null : Quote(msgId: quote.id, senderId: quote.senderId, senderName: quote.senderName, text: quote.text ?? ''),
    ));
  }

  @override
  Future<void> sendFile(
    String threadId,
    ThreadType type,
    OutgoingFile file, {
    String? caption,
    MessageUrgency? urgency,
    int? ttl,
  }) async {
    sentFiles.add(file);
    sentFileOptions.add((file: file, caption: caption, urgency: urgency, ttl: ttl));
    // The UI classifies a gif by file name; the session agrees so a gif
    // sent as a plain file still renders inline.
    final kind = file.kind == MessageKind.gif || file.name.toLowerCase().endsWith('.gif')
        ? MessageKind.gif
        : file.kind;
    final url = 'fake://upload/${++_seq}';
    final expires = ttl != null && ttl > 0 ? ttl : null;
    await _send(msg(threadId, type, selfUid, _nowMs + _seq, kind: kind, text: caption, urgency: urgency, ttl: expires, expiresAt: expires == null ? null : _nowMs + expires, sendState: SendState.sending, cliId: 'cli-$_seq', attachments: [
      Attachment(kind: kind, url: url, thumbUrl: kind == MessageKind.image ? 'fake://photo/upload$_seq' : null, name: file.name, size: file.bytes.length, width: 320, height: 240, durationMs: kind == MessageKind.voice ? 5000 : null),
    ]));
  }

  @override
  Future<void> sendSticker(String threadId, ThreadType type, StickerRef sticker) async {
    sentStickers.add(sticker);
    await _send(msg(threadId, type, selfUid, _nowMs + _seq, kind: MessageKind.sticker, sticker: sticker, sendState: SendState.sending, cliId: 'cli-$_seq'));
  }

  @override
  Future<void> sendCard(String threadId, ThreadType type, ContactCard card) async {
    sentCards.add((threadId: threadId, type: type, card: card));
    await _send(msg(
      threadId,
      type,
      selfUid,
      _nowMs + _seq,
      kind: MessageKind.card,
      text: card.displayName,
      card: card,
      sendState: SendState.sending,
      cliId: 'cli-$_seq',
    ));
  }

  @override
  Future<LinkPreview> parseLink(String link) async {
    parseLinkCalls++;
    await _wait();
    final seeded = linkPreviews[link];
    if (seeded != null) return seeded;
    final host = Uri.tryParse(link)?.host ?? '';
    return LinkPreview(
      title: host.isEmpty ? link : host,
      description: '',
      srcUrl: link,
      href: link,
    );
  }

  @override
  Future<void> sendLink(String threadId, ThreadType type, String link, {String? msg, int? ttl}) async {
    sentLinks.add((threadId: threadId, type: type, link: link, msg: msg, ttl: ttl));
    final note = msg != null && msg.isNotEmpty ? msg : null;
    final expires = ttl != null && ttl > 0 ? ttl : null;
    await _send(this.msg(
      threadId,
      type,
      selfUid,
      _nowMs + _seq,
      kind: MessageKind.link,
      text: note ?? link,
      attachments: [Attachment(kind: MessageKind.link, url: link)],
      ttl: expires,
      expiresAt: expires == null ? null : _nowMs + expires,
      sendState: SendState.sending,
      cliId: 'cli-$_seq',
    ));
  }

  @override
  Future<void> sendBankCard(String threadId, ThreadType type, BankCard card) async {
    sentBankCards.add((threadId: threadId, type: type, card: card));
    await _wait();
    if (_flags.failSends || !_online) throw StateError('bank card not sent');
    // The real API answers without a msgId; the bubble arrives from the
    // server echo, which the fake replays at once.
    deliver(msg(
      threadId,
      type,
      selfUid,
      _nowMs + _seq,
      kind: MessageKind.bankCard,
      text: card.bankName ?? 'Bank card',
      bankCard: card,
    ));
  }

  @override
  Future<List<BankInfo>> banks() async {
    bankListCalls++;
    await _wait();
    return List.of(bankList);
  }

  @override
  Future<BankAccounts> bankAccounts({int page = 0, int limit = 20}) async {
    bankAccountsCalls++;
    await _wait();
    if (page < 0) throw const RpcException('bad_request', 'page must be an integer >= 0');
    if (limit < 1 || limit > 50) throw const RpcException('bad_request', 'limit must be an integer 1..50');
    final start = page * limit;
    final end = math.min(start + limit, bankAccountList.length);
    return BankAccounts(
      accounts: start >= bankAccountList.length ? const [] : bankAccountList.sublist(start, end),
      total: bankAccountList.length,
      hasMore: end < bankAccountList.length,
    );
  }

  @override
  Future<QuickMessages> quickMessages() async {
    await _wait();
    return QuickMessages(items: List.of(quickMessageList), version: quickMessagesVersion, cursor: quickMessagesCursor);
  }

  void _validateDraft(QuickMessageDraft draft) {
    if (draft.keyword.trim().isEmpty) throw const RpcException('bad_request', 'keyword required');
    if (draft.title.trim().isEmpty) throw const RpcException('bad_request', 'title required');
    if (draft.keyword.trim().length > 50) throw const RpcException('bad_request', 'keyword must be at most 50 characters');
    if (draft.title.trim().length > 2000) throw const RpcException('bad_request', 'title must be at most 2000 characters');
  }

  List<QuickMessageMedia> _draftMedia(QuickMessageDraft draft, int id) {
    final media = draft.media;
    if (media == null) return const [];
    return [
      QuickMessageMedia(
        type: 1,
        photoId: 9000 + id,
        title: draft.title.trim(),
        width: 320,
        height: 240,
        previewThumb: 'fake://quick/$id-preview',
        rawUrl: 'fake://quick/$id-raw',
        thumbUrl: 'fake://quick/$id-thumb',
        normalUrl: 'fake://quick/$id',
        hdUrl: 'fake://quick/$id-hd',
      ),
    ];
  }

  @override
  Future<({QuickMessage item, int version})> addQuickMessage(QuickMessageDraft draft) async {
    quickMessagesAdded.add(draft);
    await _wait();
    _validateDraft(draft);
    final id = ++_quickMessageSeq;
    final item = QuickMessage(
      id: id,
      keyword: draft.keyword.trim(),
      title: draft.title.trim(),
      type: draft.media == null ? 0 : 1,
      createdTime: _nowMs,
      lastModified: _nowMs,
      media: _draftMedia(draft, id),
    );
    quickMessageList.add(item);
    quickMessagesVersion++;
    return (item: item, version: quickMessagesVersion);
  }

  @override
  Future<({QuickMessage item, int version})> updateQuickMessage(int id, QuickMessageDraft draft) async {
    quickMessagesUpdated.add((id: id, draft: draft));
    await _wait();
    _validateDraft(draft);
    final index = quickMessageList.indexWhere((q) => q.id == id);
    if (index < 0) throw RpcException('not_found', 'quick message $id not found');
    final old = quickMessageList[index];
    final item = QuickMessage(
      id: id,
      keyword: draft.keyword.trim(),
      title: draft.title.trim(),
      type: draft.media == null ? old.type : 1,
      createdTime: old.createdTime,
      lastModified: _nowMs,
      media: draft.media == null ? old.media : _draftMedia(draft, id),
    );
    quickMessageList[index] = item;
    quickMessagesVersion++;
    return (item: item, version: quickMessagesVersion);
  }

  @override
  Future<({List<int> itemIds, int version})> removeQuickMessages(List<int> ids) async {
    final unique = ids.toSet().toList();
    quickMessagesRemoved.add(unique);
    await _wait();
    if (unique.isEmpty) throw const RpcException('bad_request', 'ids must be a non-empty array');
    if (unique.length > 100) throw const RpcException('bad_request', 'at most 100 ids');
    final removed = [
      for (final id in unique)
        if (quickMessageList.any((q) => q.id == id)) id,
    ];
    quickMessageList.removeWhere((q) => removed.contains(q.id));
    if (removed.isNotEmpty) quickMessagesVersion++;
    return (itemIds: removed, version: quickMessagesVersion);
  }

  @override
  Future<void> resend(Message message) async {
    resent.add(message.id);
    replace(message, (m) => copy(m, sendState: SendState.sending, sendErrorCode: null));
    await _wait();
    final code = _flags.failSends ? null : sendErrorCode;
    final failed = _flags.failSends || code != null;
    replace(message, (m) => copy(m, sendState: failed ? SendState.failed : SendState.sent, sendErrorCode: failed ? code : null));
  }

  @override
  Future<List<StickerRef>> searchStickers(String query) async {
    await _wait();
    if (_flags.failStickers) throw StateError('stickers unavailable');
    if (query.trim() == 'zzz') return const [];
    final offset = query.trim().isEmpty ? 0 : 20;
    return [for (var i = 0; i < 12; i++) StickerRef(id: offset + i, cateId: 1, type: 1, url: 'fake://sticker/${offset + i}')];
  }

  @override
  Future<List<StickerRef>> stickerCategory(int cateId) async {
    await _wait();
    if (_flags.failStickers) throw StateError('stickers unavailable');
    return [for (var i = 0; i < 12; i++) StickerRef(id: cateId * 100 + i, cateId: cateId, type: 1, url: 'fake://sticker/$cateId-$i')];
  }

  final StreamController<BoardUpdateEvent> _boardUpdates = StreamController<BoardUpdateEvent>.broadcast();
  final Map<String, List<PinnedTopic>> _pins = {};
  final Map<int, PollDetail> _polls = {};
  final Map<String, List<ReminderItem>> _reminders = {};
  int _pollSeq = 200;
  int _boardSeq = 1;

  @override
  Stream<BoardUpdateEvent> get boardUpdates => _boardUpdates.stream;

  @override
  Future<PinBoardState> listPins(String threadId, ThreadType type) async {
    await _wait();
    return PinBoardState(items: List.unmodifiable(_pins['${type.name}:$threadId'] ?? const []), version: _boardSeq);
  }

  @override
  Future<List<PinnedTopic>> listBoard(String groupId, {int page = 1, int count = 20}) async {
    await _wait();
    final pinned = _pins['group:$groupId'] ?? const <PinnedTopic>[];
    final seen = {for (final p in pinned) p.id};
    final out = <PinnedTopic>[...pinned];
    for (final poll in _polls.values) {
      if (poll.groupId == groupId && seen.add('${poll.id}')) {
        out.add(PinnedTopic(
          id: '${poll.id}',
          topicType: 3,
          kind: BoardItemKind.poll,
          title: poll.question,
          senderId: poll.creatorId,
          pollId: poll.id,
          createdAt: poll.createdAt,
          pinned: false,
        ));
      }
    }
    return List.unmodifiable(out);
  }

  @override
  Future<PinBoardState> pinMessage(Message message, {required String title}) async {
    await _wait();
    final key = '${message.threadType.name}:${message.threadId}';
    final list = _pins.putIfAbsent(key, () => []);
    list.removeWhere((t) => t.msgId == message.id);
    list.insert(
      0,
      PinnedTopic(
        id: 'pin-${message.id}',
        topicType: 2,
        kind: BoardItemKind.message,
        title: title,
        senderId: message.senderId,
        senderName: message.senderName,
        msgId: message.id,
        cliMsgId: message.cliId,
        createdAt: _nowMs,
        pinned: true,
      ),
    );
    _boardSeq++;
    if (!_boardUpdates.isClosed) _boardUpdates.add(BoardUpdateEvent(message.threadId, message.threadType));
    return PinBoardState(items: List.unmodifiable(list), version: _boardSeq);
  }

  @override
  Future<void> pinBoardItem(String groupId, String topicId, int topicType) async {
    await _wait();
    final list = _pins.putIfAbsent('group:$groupId', () => []);
    if (!list.any((t) => t.id == topicId)) {
      final pollId = topicType == 3 ? int.tryParse(topicId) : null;
      final title = pollId != null && _polls[pollId] != null ? _polls[pollId]!.question : 'Topic $topicId';
      list.insert(
        0,
        PinnedTopic(
          id: topicId,
          topicType: topicType,
          kind: topicType == 3 ? BoardItemKind.poll : BoardItemKind.note,
          title: title,
          pollId: pollId,
          createdAt: _nowMs,
          pinned: true,
        ),
      );
      _boardSeq++;
      if (!_boardUpdates.isClosed) _boardUpdates.add(BoardUpdateEvent(groupId, ThreadType.group));
    }
  }

  @override
  Future<PinBoardState> unpinTopic(String threadId, ThreadType type, String topicId, int topicType) async {
    await _wait();
    final key = '${type.name}:$threadId';
    final list = _pins.putIfAbsent(key, () => []);
    list.removeWhere((t) => t.id == topicId);
    _boardSeq++;
    if (!_boardUpdates.isClosed) _boardUpdates.add(BoardUpdateEvent(threadId, type));
    return PinBoardState(items: List.unmodifiable(list), version: _boardSeq);
  }

  @override
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
  }) async {
    await _wait();
    final id = _pollSeq++;
    final poll = PollDetail(
      id: id,
      groupId: groupId,
      question: question,
      creatorId: selfUid,
      createdAt: _nowMs,
      expiredAt: expiredTime,
      closed: false,
      multiple: allowMultiChoices,
      allowAdd: allowAddNewOption,
      hidePreview: hideVotePreview,
      anonymous: isAnonymous,
      totalVotes: 0,
      options: [
        for (var i = 0; i < options.length; i++)
          PollOptionDetail(id: i + 1, content: options[i], votes: 0, voted: false),
      ],
    );
    _polls[id] = poll;
    if (pin) await pinBoardItem(groupId, '$id', 3);
    return poll;
  }

  @override
  Future<PollDetail> pollDetail(int pollId, {String? groupId}) async {
    await _wait();
    return _polls[pollId] ??
        PollDetail(
          id: pollId,
          groupId: groupId ?? '',
          question: 'Poll #$pollId',
          creatorId: selfUid,
          createdAt: _nowMs,
          expiredAt: 0,
          closed: false,
          multiple: true,
          allowAdd: true,
          hidePreview: false,
          anonymous: false,
          totalVotes: 0,
        );
  }

  @override
  Future<PollDetail> votePoll(int pollId, List<int> optionIds, {String? groupId}) async {
    await _wait();
    final cur = await pollDetail(pollId, groupId: groupId);
    final chosen = optionIds.toSet();
    final next = PollDetail(
      id: cur.id,
      groupId: cur.groupId,
      question: cur.question,
      creatorId: cur.creatorId,
      createdAt: cur.createdAt,
      expiredAt: cur.expiredAt,
      closed: cur.closed,
      multiple: cur.multiple,
      allowAdd: cur.allowAdd,
      hidePreview: cur.hidePreview,
      anonymous: cur.anonymous,
      totalVotes: chosen.isEmpty ? 0 : 1,
      options: [
        for (final o in cur.options)
          PollOptionDetail(
            id: o.id,
            content: o.content,
            votes: chosen.contains(o.id) ? 1 : 0,
            voted: chosen.contains(o.id),
            voters: chosen.contains(o.id) ? [selfUid] : const [],
          ),
      ],
    );
    _polls[pollId] = next;
    return next;
  }

  @override
  Future<PollDetail> addPollOption(
    int pollId,
    String content, {
    List<int> votedOptionIds = const [],
    bool voteNew = true,
    String? groupId,
  }) async {
    await _wait();
    final cur = await pollDetail(pollId, groupId: groupId);
    final nextId = cur.options.fold<int>(0, (m, o) => o.id > m ? o.id : m) + 1;
    final withOpt = PollDetail(
      id: cur.id,
      groupId: cur.groupId,
      question: cur.question,
      creatorId: cur.creatorId,
      createdAt: cur.createdAt,
      expiredAt: cur.expiredAt,
      closed: cur.closed,
      multiple: cur.multiple,
      allowAdd: cur.allowAdd,
      hidePreview: cur.hidePreview,
      anonymous: cur.anonymous,
      totalVotes: cur.totalVotes,
      options: [...cur.options, PollOptionDetail(id: nextId, content: content, votes: 0, voted: false)],
    );
    _polls[pollId] = withOpt;
    return votePoll(pollId, voteNew ? [...votedOptionIds, nextId] : votedOptionIds, groupId: groupId);
  }

  @override
  Future<PollDetail> lockPoll(int pollId, {String? groupId}) async {
    await _wait();
    final cur = await pollDetail(pollId, groupId: groupId);
    final locked = PollDetail(
      id: cur.id,
      groupId: cur.groupId,
      question: cur.question,
      creatorId: cur.creatorId,
      createdAt: cur.createdAt,
      expiredAt: cur.expiredAt,
      closed: true,
      multiple: cur.multiple,
      allowAdd: cur.allowAdd,
      hidePreview: cur.hidePreview,
      anonymous: cur.anonymous,
      totalVotes: cur.totalVotes,
      options: cur.options,
    );
    _polls[pollId] = locked;
    return locked;
  }

  @override
  Future<void> sharePoll(int pollId) async {
    await _wait();
  }

  @override
  Future<PinnedTopic> createNote(String groupId, String title, {bool pin = false}) async {
    await _wait();
    final note = PinnedTopic(
      id: 'note-${_boardSeq++}',
      topicType: 0,
      kind: BoardItemKind.note,
      title: title,
      senderId: selfUid,
      senderName: 'Bạn',
      createdAt: _nowMs,
      pinned: pin,
    );
    if (pin) {
      _pins.putIfAbsent('group:$groupId', () => []).insert(0, note);
      if (!_boardUpdates.isClosed) _boardUpdates.add(BoardUpdateEvent(groupId, ThreadType.group));
    }
    return note;
  }

  @override
  Future<PinnedTopic> editNote(String groupId, String topicId, String title, {bool pin = false}) async {
    await _wait();
    final note = PinnedTopic(
      id: topicId,
      topicType: 0,
      kind: BoardItemKind.note,
      title: title,
      senderId: selfUid,
      senderName: 'Bạn',
      createdAt: _nowMs,
      pinned: pin,
    );
    final list = _pins.putIfAbsent('group:$groupId', () => []);
    list.removeWhere((t) => t.id == topicId);
    if (pin) list.insert(0, note);
    if (!_boardUpdates.isClosed) _boardUpdates.add(BoardUpdateEvent(groupId, ThreadType.group));
    return note;
  }

  @override
  Future<List<ReminderItem>> listReminders(String threadId, ThreadType type, {int page = 1, int count = 20}) async {
    await _wait();
    return List.unmodifiable(_reminders['${type.name}:$threadId'] ?? const []);
  }

  @override
  Future<ReminderItem> createReminder(
    String threadId,
    ThreadType type, {
    required String title,
    String emoji = '⏰',
    required int startTime,
    int repeat = 0,
  }) async {
    await _wait();
    final item = ReminderItem(
      id: 'rem-${_boardSeq++}',
      title: title,
      emoji: emoji,
      startTime: startTime,
      repeat: repeat,
      creatorId: selfUid,
      createdAt: _nowMs,
    );
    _reminders.putIfAbsent('${type.name}:$threadId', () => []).insert(0, item);
    if (!_boardUpdates.isClosed) _boardUpdates.add(BoardUpdateEvent(threadId, type));
    return item;
  }

  @override
  Future<ReminderItem> editReminder(
    String threadId,
    ThreadType type, {
    required String id,
    required String title,
    String emoji = '⏰',
    required int startTime,
    int repeat = 0,
  }) async {
    await _wait();
    final item = ReminderItem(
      id: id,
      title: title,
      emoji: emoji,
      startTime: startTime,
      repeat: repeat,
      creatorId: selfUid,
      createdAt: _nowMs,
    );
    final list = _reminders.putIfAbsent('${type.name}:$threadId', () => []);
    list.removeWhere((r) => r.id == id);
    list.insert(0, item);
    if (!_boardUpdates.isClosed) _boardUpdates.add(BoardUpdateEvent(threadId, type));
    return item;
  }

  @override
  Future<void> removeReminder(String threadId, ThreadType type, String id) async {
    await _wait();
    _reminders['${type.name}:$threadId']?.removeWhere((r) => r.id == id);
    if (!_boardUpdates.isClosed) _boardUpdates.add(BoardUpdateEvent(threadId, type));
  }

  @override
  Future<void> react(Message message, String icon) async {
    await _wait();
    replace(message, (m) {
      final next = <String, List<String>>{};
      m.reactions.forEach((k, v) {
        final users = v.where((x) => x != selfUid).toList();
        if (users.isNotEmpty) next[k] = users;
      });
      if (icon.isNotEmpty) next[icon] = [...?next[icon], selfUid];
      return copy(m, reactions: next);
    });
  }

  @override
  Future<void> recall(Message message) async {
    await _wait();
    replace(message, (m) => copy(m, recalled: true, reactions: const {}));
  }

  @override
  Future<void> deleteForMe(Message message) async {
    await _wait();
    replace(message, (m) => null);
  }

  @override
  Future<void> deleteForAll(Message message) async {
    deletedForAll.add(message.id);
    await _wait();
    _guardThread();
    replace(message, (m) => null);
  }

  @override
  Future<String> report(String threadId, ThreadType type, ReportReason reason, {String? content}) async {
    reports.add((threadId: threadId, type: type, reason: reason, content: content));
    await _wait();
    _guardThread();
    return 'report-${++_reportSeq}';
  }

  @override
  Future<void> markSeen(String threadId, ThreadType type) async {
    markSeenCalls++;
    final t = _threadMap[threadId];
    if (t == null || t.unread == 0) return;
    _touch(threadId, type, unread: 0);
  }

  void _guardThread() {
    if (_flags.failThreadActions) throw UnimplementedError('not implemented yet');
  }

  @override
  Future<void> setPinned(String threadId, ThreadType type, bool pinned) async {
    await _wait();
    _guardThread();
    _touch(threadId, type, pinned: pinned);
  }

  @override
  Future<void> setMuted(String threadId, ThreadType type, bool muted) async {
    await _wait();
    _guardThread();
    _touch(threadId, type, muted: muted);
  }

  @override
  Future<void> markUnread(String threadId, ThreadType type) async {
    await _wait();
    _guardThread();
    _touch(threadId, type, unread: 1);
  }

  @override
  Future<void> deleteThread(String threadId, ThreadType type) async {
    await _wait();
    _guardThread();
    _threadMap.remove(threadId);
    _all.remove(threadId);
    _publish();
  }

  void _putRef(List<ThreadRef> refs, String threadId, ThreadType type, bool present) {
    refs.removeWhere((t) => t.id == threadId && t.type == type);
    if (present) refs.add(ThreadRef(threadId, type));
  }

  @override
  Future<HiddenConversations> hiddenConversations() async {
    await _wait();
    return HiddenConversations(pinSet: hiddenPinSet, threads: List.of(hiddenThreads));
  }

  @override
  Future<void> setHidden(String threadId, ThreadType type, bool hidden) async {
    await _wait();
    _guardThread();
    _putRef(hiddenThreads, threadId, type, hidden);
    _touch(threadId, type, hidden: hidden);
  }

  @override
  Future<void> setHiddenPin(String pin) async {
    await _wait();
    _guardThread();
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) throw const RpcException('bad_request', 'pin must be 4 digits');
    // Write-only: only the fact that a PIN was set is kept.
    hiddenPinSet = true;
    hiddenPinSets++;
  }

  @override
  Future<void> resetHiddenPin() async {
    await _wait();
    _guardThread();
    hiddenPinSet = false;
  }

  @override
  Future<ArchivedChatList> archivedChats() async {
    await _wait();
    return ArchivedChatList(threads: List.of(archivedThreads), version: archiveVersion);
  }

  @override
  Future<void> setArchived(String threadId, ThreadType type, bool archived) async {
    await _wait();
    _guardThread();
    _putRef(archivedThreads, threadId, type, archived);
    archiveVersion++;
    _touch(threadId, type, archived: archived);
  }

  @override
  Future<LabelsState> labels() async {
    await _wait();
    return LabelsState(labels: List.of(labelList), version: labelsVersion, lastUpdateTime: labelsLastUpdateTime);
  }

  @override
  Future<LabelsState> updateLabels(List<ConversationLabel> labels, int version) async {
    await _wait();
    _guardThread();
    if (version != labelsVersion) throw RpcException('conflict', 'labels version $labelsVersion != $version');
    labelList
      ..clear()
      ..addAll(labels);
    labelsVersion = version + 1;
    labelsLastUpdateTime = _nowMs;
    return LabelsState(labels: List.of(labelList), version: labelsVersion, lastUpdateTime: labelsLastUpdateTime);
  }

  @override
  Future<AutoDeleteChat> autoDeleteChats() async {
    await _wait();
    return AutoDeleteChat(conversations: List.of(autoDeleteList));
  }

  @override
  Future<void> setAutoDelete(String threadId, ThreadType type, int ttl) async {
    await _wait();
    _guardThread();
    if (!supportsAutoDeleteTtl(ttl)) throw ArgumentError.value(ttl, 'ttl', 'unsupported auto-delete ttl');
    autoDeleteList.removeWhere((c) => c.threadId == threadId && c.threadType == type);
    if (ttl > 0) {
      autoDeleteList.add(AutoDeleteConversation(threadId: threadId, threadType: type, ttl: ttl, createdAt: _nowMs));
    }
    _touch(threadId, type, autoDeleteTtl: ttl);
  }

  @override
  Future<LinkedDevices> linkedDevices() async {
    await _wait();
    return linkedDeviceList;
  }

  @override
  Future<void> forward(Message message, List<ThreadRef> to) async {
    await _wait();
    if (_flags.failForward) throw StateError('forward failed');
    forwarded.add((message, to));
  }

  @override
  Future<List<Contact>> users(List<String> uids) async {
    usersCalls++;
    await _wait();
    return [
      for (final uid in uids)
        uid == selfUid
            ? Contact(uid: uid, displayName: selfName, avatarUrl: '')
            : Contact(uid: uid, displayName: fakePerson(uid)?.name ?? '', avatarUrl: '', alias: fakePerson(uid)?.alias),
    ];
  }

  int fullAvatarCalls = 0;

  /// Full size avatar url: known people have one, unknown uids none.
  @override
  Future<String> fullAvatar(String uid) async {
    fullAvatarCalls++;
    await _wait();
    return fakePerson(uid) == null ? '' : 'fake://photo/avatar-$uid-full';
  }

  @override
  void sendTyping(String threadId, ThreadType type) => typingSent++;

  @override
  Future<List<Contact>> contacts() async {
    await _wait();
    if (_flags.failContacts) throw StateError('contacts unavailable');
    if (fakeLink.app.empty) return const [];
    return List.of(contactList);
  }

  void _guardContacts() {
    if (_flags.failContacts) throw StateError('contacts unavailable');
  }

  @override
  Future<UserProfile?> findUserByPhone(String phone) async {
    phoneLookups++;
    await _wait();
    _guardContacts();
    return profilesByPhone[phone.replaceAll(RegExp(r'[^0-9]'), '')];
  }

  @override
  Future<UserProfile?> findUserByUsername(String username) async {
    usernameLookups++;
    await _wait();
    _guardContacts();
    return profilesByUsername[username.trim()];
  }

  @override
  Future<void> sendFriendRequest(String uid, {String message = ''}) async {
    friendRequestsSent.add((uid: uid, message: message));
    await _wait();
    _guardContacts();
    sentRequests.removeWhere((r) => r.uid == uid);
    sentRequests.add(FriendRequest(
      uid: uid,
      displayName: fakePerson(uid)?.name ?? '',
      avatarUrl: '',
      message: message,
      ts: _nowMs,
    ));
    requestStatuses[uid] = const FriendRequestStatus(isRequesting: true);
  }

  @override
  Future<FriendRequestStatus> friendRequestStatus(String uid) async {
    await _wait();
    _guardContacts();
    final seeded = requestStatuses[uid];
    if (seeded != null) return seeded;
    return FriendRequestStatus(isFriend: contactList.any((c) => c.uid == uid), addFriendPrivacy: 1);
  }

  @override
  Future<void> acceptFriendRequest(String uid) async {
    friendRequestsAccepted.add(uid);
    await _wait();
    _guardContacts();
    final index = receivedRequests.indexWhere((r) => r.uid == uid);
    if (index >= 0) {
      final request = receivedRequests.removeAt(index);
      if (!contactList.any((c) => c.uid == uid)) {
        contactList.add(Contact(uid: uid, displayName: request.displayName, avatarUrl: request.avatarUrl));
      }
    }
    requestStatuses[uid] = const FriendRequestStatus(isFriend: true);
  }

  @override
  Future<void> rejectFriendRequest(String uid) async {
    friendRequestsRejected.add(uid);
    await _wait();
    _guardContacts();
    receivedRequests.removeWhere((r) => r.uid == uid);
    requestStatuses[uid] = const FriendRequestStatus();
  }

  @override
  Future<void> cancelFriendRequest(String uid) async {
    friendRequestsCancelled.add(uid);
    await _wait();
    _guardContacts();
    sentRequests.removeWhere((r) => r.uid == uid);
    requestStatuses[uid] = const FriendRequestStatus();
  }

  @override
  Future<FriendRequests> friendRequests() async {
    friendRequestsCalls++;
    await _wait();
    _guardContacts();
    return FriendRequests(received: List.of(receivedRequests), sent: List.of(sentRequests));
  }

  @override
  Future<List<FriendRecommendation>> friendRecommendations() async {
    recommendationCalls++;
    await _wait();
    _guardContacts();
    return List.of(recommendations);
  }

  @override
  Future<void> setAlias(String uid, String alias) async {
    aliasesSet.add((uid: uid, alias: alias));
    await _wait();
    _guardContacts();
    _patchContact(uid, (c) => Contact(uid: c.uid, displayName: c.displayName, avatarUrl: c.avatarUrl, alias: alias, closeFriend: c.closeFriend));
  }

  @override
  Future<void> removeAlias(String uid) async {
    aliasesRemoved.add(uid);
    await _wait();
    _guardContacts();
    _patchContact(uid, (c) => Contact(uid: c.uid, displayName: c.displayName, avatarUrl: c.avatarUrl, closeFriend: c.closeFriend));
  }

  @override
  Future<void> removeFriend(String uid) async {
    removedFriends.add(uid);
    await _wait();
    _guardContacts();
    contactList.removeWhere((c) => c.uid == uid);
    requestStatuses[uid] = const FriendRequestStatus();
  }

  @override
  Future<void> blockUser(String uid) async {
    blockedUsers.add(uid);
    await _wait();
    _guardContacts();
    blocked.add(uid);
  }

  @override
  Future<void> unblockUser(String uid) async {
    unblockedUsers.add(uid);
    await _wait();
    _guardContacts();
    blocked.remove(uid);
  }

  void _patchContact(String uid, Contact Function(Contact contact) f) {
    final index = contactList.indexWhere((c) => c.uid == uid);
    if (index >= 0) contactList[index] = f(contactList[index]);
  }

  @override
  Future<List<FriendPresence>> presence() async {
    presenceCalls++;
    await _wait();
    _guardContacts();
    return List.of(presenceList);
  }

  @override
  Future<LastSeen> lastSeen(String uid) async {
    lastSeenCalls++;
    await _wait();
    _guardContacts();
    return lastSeenMap[uid] ?? const LastSeen(showOnlineStatus: false, lastOnline: 0);
  }

  /// Group deputies by group id, served by [groupInfo] and [groups]. A test
  /// seeds an entry with [selfUid] to exercise admin-only actions.
  final Map<String, List<String>> groupAdminIds = {};

  /// Total member count by group id, for groups whose member list is only a
  /// page. Absent means the list length is the total.
  final Map<String, int> groupMemberCounts = {};
  late final List<({String id, String name, List<String> members})> _mutableGroups = [
    for (final g in fakeGroups) (id: g.id, name: g.name, members: List.of(g.members)),
  ];

  GroupInfo _info(({String id, String name, List<String> members}) g) => GroupInfo(
        id: g.id,
        name: g.name,
        avatarUrl: '',
        memberIds: [selfUid, ...g.members],
        memberCount: groupMemberCounts[g.id],
        ownerId: g.members.isNotEmpty ? g.members.first : selfUid,
        adminIds: groupAdminIds[g.id] ?? const [],
      );

  @override
  Future<List<GroupInfo>> groups() async {
    await _wait();
    if (_flags.failGroups) throw StateError('groups unavailable');
    if (fakeLink.app.empty) return const [];
    return [for (final g in _mutableGroups) _info(g)];
  }

  @override
  Future<GroupInfo> groupInfo(String groupId) async {
    await _wait();
    if (_flags.failGroups) throw StateError('group unavailable');
    return _info(_mutableGroups.firstWhere((g) => g.id == groupId));
  }

  final Map<String, Uint8List> _media = {};

  @override
  Future<Uint8List> media(String url) async {
    mediaCalls++;
    await _wait();
    if (_flags.failMedia.contains(url) || _flags.failMedia.contains('*')) throw StateError('media unavailable');
    final uri = Uri.parse(url);
    final photo = uri.host == 'photo';
    return _media.putIfAbsent(url, () => fakePng(url, width: photo ? 160 : 48, height: photo ? 120 : 48));
  }

  // ---- Voice & Video Calls ----

  final ValueNotifier<ActiveCall?> _activeCall = ValueNotifier<ActiveCall?>(null);
  int _callSeq = 1;
  final List<({String threadId, ThreadType type, CallMediaKind media})> callsStarted = [];
  final List<String> callsAccepted = [];
  final List<({String callId, bool localOnly})> callsRejected = [];
  final List<String> callsHungUp = [];

  @override
  ValueListenable<ActiveCall?> get activeCall => _activeCall;

  void simulateIncomingCall(ActiveCall call) {
    if (_disposed) return;
    _activeCall.value = call;
  }

  @override
  Future<ActiveCall> startCall(String threadId, ThreadType type, CallMediaKind media) async {
    await _wait();
    callsStarted.add((threadId: threadId, type: type, media: media));
    final match = threads.value.where((t) => t.id == threadId && t.type == type).firstOrNull;
    final call = ActiveCall(
      callId: 'fake-call-${_callSeq++}',
      threadId: threadId,
      threadType: type,
      peerId: threadId,
      peerName: match?.name ?? threadId,
      peerAvatarUrl: match?.avatarUrl,
      media: media,
      direction: CallDirection.outgoing,
      status: CallStatus.ringing,
      startedAt: DateTime.now().millisecondsSinceEpoch,
      answeredByDeviceId: 'fake-device',
      isGroup: type == ThreadType.group,
    );
    _activeCall.value = call;
    return call;
  }

  @override
  Future<void> acceptCall(String callId) async {
    await _wait();
    callsAccepted.add(callId);
    final cur = _activeCall.value;
    if (cur != null && cur.callId == callId) {
      _activeCall.value = cur.copyWith(
        status: CallStatus.active,
        answeredAt: DateTime.now().millisecondsSinceEpoch,
        answeredByDeviceId: 'fake-device',
      );
    }
  }

  @override
  Future<void> rejectCall(String callId, {bool localOnly = false}) async {
    await _wait();
    callsRejected.add((callId: callId, localOnly: localOnly));
    if (_activeCall.value?.callId == callId) {
      _activeCall.value = null;
    }
  }

  @override
  Future<void> hangupCall(String callId) async {
    await _wait();
    callsHungUp.add(callId);
    if (_activeCall.value?.callId == callId) {
      _activeCall.value = null;
    }
  }

  @override
  Future<Map<String, dynamic>> groupCallState(String groupId) async {
    await _wait();
    return {'groupId': groupId, 'active': false, 'members': const <String>[]};
  }

  @override
  Future<void> callHold(String callId, {required String peerId, required bool hold}) async {
    await _wait();
    rawRpcCalls.add(('calls.hold', {'callId': callId, 'peerId': peerId, 'hold': hold}));
  }

  @override
  Future<void> callSwitchMedia(String callId, {required String peerId}) async {
    await _wait();
    rawRpcCalls.add(('calls.switchMedia', {'callId': callId, 'peerId': peerId}));
  }

  // ---- Extended SDK state for tests & demo ----
  final List<(String, Map<String, dynamic>)> rawRpcCalls = [];
  int _extSeq = 1;
  final Map<String, bool> _groupLinks = {};
  final Map<String, Map<String, dynamic>> _groupSettings = {};
  final List<GroupInviteBoxItem> _inviteBox = [const GroupInviteBoxItem(groupId: 'inv-g01', name: 'Nhóm Cộng đồng Zalos', memberCount: 28)];
  ProfileInfo _profile = const ProfileInfo(uid: 'self-main', displayName: 'Phạm Minh Thư', avatarUrl: '', dob: '1997-04-12', gender: 1, bio: 'Xin chào!');
  final List<({String photoId, String url})> _avatars = [(photoId: 'av-1', url: 'https://example.com/av1.jpg')];
  final Map<String, dynamic> _zaloSettings = {'show_online_status': 1, 'allow_find_phone': 1, 'display_seen_status': 1};
  bool _activeStatus = true;
  String _zaloLang = 'vi';
  final Set<String> _feedBlocked = {};
  final List<CatalogItem> _catalogs = [const CatalogItem(catalogId: 'cat-1', catalogName: 'Sản phẩm nổi bật')];
  final Map<String, List<CatalogProduct>> _products = {
    'cat-1': [const CatalogProduct(productId: 'prod-1', catalogId: 'cat-1', productName: 'Bó hoa hướng dương', price: '350000', description: 'Tặng kèm thiệp')],
  };
  final List<AutoReplyRule> _autoReplies = [
    const AutoReplyRule(id: 1, enabled: true, content: 'Mình sẽ phản hồi bạn sớm nhất!', startTime: 0, endTime: 86400000, scope: 0),
  ];
  final List<MediaStoreEntry> _mediaStore = [
    const MediaStoreEntry(id: 'ms-1', mediaType: 'image', url: 'https://photo/1.jpg', thumbUrl: 'https://photo/1-t.jpg', name: 'hoa.jpg', ts: 1700000000000),
  ];
  final Set<String> _e2eeThreads = {};

  @override
  Future<Map<String, dynamic>> rawRpc(String method, [Map<String, dynamic> params = const {}]) async {
    await _wait();
    rawRpcCalls.add((method, params));
    return {'ok': true, 'method': method};
  }

  @override
  Future<String> createGroup({String? name, required List<String> members}) async {
    await _wait();
    final id = 'g-new-${_extSeq++}';
    final gName = name != null && name.trim().isNotEmpty ? name.trim() : 'Nhóm mới $_extSeq';
    _mutableGroups.add((id: id, name: gName, members: List.of(members)));
    _threadMap[id] = Thread(
      id: id,
      type: ThreadType.group,
      name: gName,
      avatarUrl: '',
      lastMessage: null,
      lastTs: DateTime.now().millisecondsSinceEpoch,
      unread: 0,
      pinned: false,
      muted: false,
    );
    _publish();
    return id;
  }

  @override
  Future<void> renameGroup(String groupId, String name) async {
    await _wait();
    final idx = _mutableGroups.indexWhere((g) => g.id == groupId);
    if (idx >= 0) {
      final old = _mutableGroups[idx];
      _mutableGroups[idx] = (id: old.id, name: name, members: old.members);
    }
    final oldT = _threadMap[groupId];
    if (oldT != null) {
      _threadMap[groupId] = Thread(
        id: oldT.id,
        type: oldT.type,
        name: name,
        avatarUrl: oldT.avatarUrl,
        lastMessage: oldT.lastMessage,
        lastTs: oldT.lastTs,
        unread: oldT.unread,
        pinned: oldT.pinned,
        muted: oldT.muted,
        hidden: oldT.hidden,
        archived: oldT.archived,
        autoDeleteTtl: oldT.autoDeleteTtl,
      );
      _publish();
    }
  }

  @override
  Future<void> changeGroupAvatar(String groupId, OutgoingFile file) async {
    await _wait();
  }

  @override
  Future<void> addGroupMembers(String groupId, List<String> memberIds) async {
    await _wait();
    final idx = _mutableGroups.indexWhere((g) => g.id == groupId);
    if (idx >= 0) {
      for (final m in memberIds) {
        if (!_mutableGroups[idx].members.contains(m)) _mutableGroups[idx].members.add(m);
      }
    }
  }

  @override
  Future<void> inviteUserToGroups(String userId, List<String> groupIds) async {
    await _wait();
    for (final gid in groupIds) {
      await addGroupMembers(gid, [userId]);
    }
  }

  @override
  Future<void> removeGroupMembers(String groupId, List<String> memberIds) async {
    await _wait();
    final idx = _mutableGroups.indexWhere((g) => g.id == groupId);
    if (idx >= 0) _mutableGroups[idx].members.removeWhere(memberIds.contains);
  }

  @override
  Future<void> leaveGroup(String groupId, {bool silent = false}) async {
    await _wait();
    _mutableGroups.removeWhere((g) => g.id == groupId);
    _threadMap.remove(groupId);
    _publish();
  }

  @override
  Future<void> disperseGroup(String groupId) => leaveGroup(groupId);

  @override
  Future<void> changeGroupOwner(String groupId, String newOwnerId) async {
    await _wait();
    final idx = _mutableGroups.indexWhere((g) => g.id == groupId);
    if (idx >= 0 && _mutableGroups[idx].members.remove(newOwnerId)) {
      _mutableGroups[idx].members.insert(0, newOwnerId);
    }
  }

  @override
  Future<void> addGroupDeputy(String groupId, List<String> memberIds) async {
    await _wait();
    final cur = List<String>.of(groupAdminIds[groupId] ?? const []);
    for (final m in memberIds) {
      if (!cur.contains(m)) cur.add(m);
    }
    groupAdminIds[groupId] = cur;
  }

  @override
  Future<void> removeGroupDeputy(String groupId, List<String> memberIds) async {
    await _wait();
    final cur = List<String>.of(groupAdminIds[groupId] ?? const []);
    cur.removeWhere(memberIds.contains);
    groupAdminIds[groupId] = cur;
  }

  @override
  Future<void> updateGroupSettings(String groupId, Map<String, dynamic> settings) async {
    await _wait();
    _groupSettings[groupId] = {...?_groupSettings[groupId], ...settings};
  }

  @override
  Future<List<Contact>> pendingGroupMembers(String groupId) async {
    await _wait();
    return const [Contact(uid: 'u-pending-1', displayName: 'Trần Minh Khôi', avatarUrl: '')];
  }

  @override
  Future<void> reviewPendingGroupMembers(String groupId, List<String> members, bool approve) async {
    await _wait();
  }

  @override
  Future<List<Contact>> blockedGroupMembers(String groupId) async {
    await _wait();
    return const [];
  }

  @override
  Future<void> addBlockedGroupMembers(String groupId, List<String> memberIds) async {
    await _wait();
  }

  @override
  Future<void> removeBlockedGroupMembers(String groupId, List<String> memberIds) async {
    await _wait();
  }

  @override
  Future<GroupLinkDetail> groupLinkDetail(String groupId) async {
    await _wait();
    final en = _groupLinks[groupId] ?? true;
    return GroupLinkDetail(enabled: en, link: en ? 'https://zalo.me/g/$groupId' : null);
  }

  @override
  Future<GroupLinkDetail> enableGroupLink(String groupId) async {
    await _wait();
    _groupLinks[groupId] = true;
    return GroupLinkDetail(enabled: true, link: 'https://zalo.me/g/$groupId');
  }

  @override
  Future<void> disableGroupLink(String groupId) async {
    await _wait();
    _groupLinks[groupId] = false;
  }

  @override
  Future<Map<String, dynamic>> groupLinkInfo(String link) async {
    await _wait();
    return {'name': 'Nhóm từ liên kết', 'link': link, 'totalMember': 12};
  }

  @override
  Future<void> joinGroupLink(String link) async {
    await _wait();
  }

  @override
  Future<List<GroupInviteBoxItem>> groupInviteBoxList() async {
    await _wait();
    return List.of(_inviteBox);
  }

  @override
  Future<void> joinGroupInviteBox(String groupId) async {
    await _wait();
    _inviteBox.removeWhere((i) => i.groupId == groupId);
  }

  @override
  Future<void> deleteGroupInviteBox(List<String> groupIds) async {
    await _wait();
    _inviteBox.removeWhere((i) => groupIds.contains(i.groupId));
  }

  @override
  Future<void> upgradeGroupToCommunity(String groupId) async {
    await _wait();
  }

  @override
  Future<ProfileInfo> fetchProfile() async {
    await _wait();
    return _profile;
  }

  @override
  Future<void> updateProfile({required String name, required String dob, required int gender}) async {
    await _wait();
    _profile = ProfileInfo(uid: _profile.uid, displayName: name, avatarUrl: _profile.avatarUrl, dob: dob, gender: gender, bio: _profile.bio);
  }

  @override
  Future<void> updateProfileBio(String bio) async {
    await _wait();
    _profile = ProfileInfo(uid: _profile.uid, displayName: _profile.displayName, avatarUrl: _profile.avatarUrl, dob: _profile.dob, gender: _profile.gender, bio: bio);
  }

  @override
  Future<void> changeAccountAvatar(OutgoingFile file) async {
    await _wait();
  }

  @override
  Future<List<({String photoId, String url})>> avatarList() async {
    await _wait();
    return List.of(_avatars);
  }

  @override
  Future<void> reuseAvatar(String photoId) async {
    await _wait();
  }

  @override
  Future<void> deleteAvatars(List<String> photoIds) async {
    await _wait();
    _avatars.removeWhere((a) => photoIds.contains(a.photoId));
  }

  @override
  Future<Map<String, dynamic>> zaloSettings() async {
    await _wait();
    return {..._zaloSettings, 'activeStatus': _activeStatus, 'language': _zaloLang};
  }

  @override
  Future<void> updateZaloSetting(String type, int value) async {
    await _wait();
    _zaloSettings[type] = value;
  }

  @override
  Future<void> updateActiveStatus(bool active) async {
    await _wait();
    _activeStatus = active;
  }

  @override
  Future<void> updateZaloLang(String language) async {
    await _wait();
    _zaloLang = language;
  }

  @override
  Future<void> setCloseFriend(List<String> uids, bool add) async {
    await _wait();
    for (final u in uids) {
      _patchContact(u, (c) => Contact(uid: c.uid, displayName: c.displayName, avatarUrl: c.avatarUrl, alias: c.alias, closeFriend: add));
    }
  }

  @override
  Future<List<Contact>> blockList() async {
    await _wait();
    return [for (final u in blocked) Contact(uid: u, displayName: u, avatarUrl: '')];
  }

  @override
  Future<void> blockViewFeed(String uid, bool blocked) async {
    await _wait();
    if (blocked) {
      _feedBlocked.add(uid);
    } else {
      _feedBlocked.remove(uid);
    }
  }

  @override
  Future<Map<String, String>> userQr(List<String> uids) async {
    await _wait();
    return {for (final u in uids) u: 'https://zalo.me/qr/$u'};
  }

  @override
  Future<void> removeNote(String groupId, String topicId) async {
    await _wait();
    _pins['group:$groupId']?.removeWhere((p) => p.id == topicId);
    if (!_boardUpdates.isClosed) _boardUpdates.add(BoardUpdateEvent(groupId, ThreadType.group));
  }

  @override
  Future<List<CatalogItem>> catalogs() async {
    await _wait();
    return List.of(_catalogs);
  }

  @override
  Future<CatalogItem> createCatalog(String name) async {
    await _wait();
    final item = CatalogItem(catalogId: 'cat-${++_extSeq}', catalogName: name);
    _catalogs.add(item);
    _products[item.catalogId] = [];
    return item;
  }

  @override
  Future<void> deleteCatalog(String catalogId) async {
    await _wait();
    _catalogs.removeWhere((c) => c.catalogId == catalogId);
    _products.remove(catalogId);
  }

  @override
  Future<List<CatalogProduct>> catalogProducts(String catalogId) async {
    await _wait();
    return List.of(_products[catalogId] ?? const []);
  }

  @override
  Future<CatalogProduct> createCatalogProduct(String catalogId, {required String name, required String price, required String description}) async {
    await _wait();
    final item = CatalogProduct(productId: 'prod-${++_extSeq}', catalogId: catalogId, productName: name, price: price, description: description);
    _products.putIfAbsent(catalogId, () => []).add(item);
    return item;
  }

  @override
  Future<void> deleteCatalogProduct(String catalogId, List<String> productIds) async {
    await _wait();
    _products[catalogId]?.removeWhere((p) => productIds.contains(p.productId));
  }

  @override
  Future<List<AutoReplyRule>> autoReplies() async {
    await _wait();
    return List.of(_autoReplies);
  }

  @override
  Future<AutoReplyRule> createAutoReply({required bool enabled, required String content, int startTime = 0, int endTime = 86400000, int scope = 0}) async {
    await _wait();
    final rule = AutoReplyRule(id: ++_extSeq, enabled: enabled, content: content, startTime: startTime, endTime: endTime, scope: scope);
    _autoReplies.add(rule);
    return rule;
  }

  @override
  Future<AutoReplyRule> updateAutoReply(AutoReplyRule rule) async {
    await _wait();
    final idx = _autoReplies.indexWhere((r) => r.id == rule.id);
    if (idx >= 0) _autoReplies[idx] = rule;
    return rule;
  }

  @override
  Future<void> deleteAutoReply(int id) async {
    await _wait();
    _autoReplies.removeWhere((r) => r.id == id);
  }

  @override
  Future<void> createBankAccount({required int bin, required String accountNumber, required String holderName}) async {
    await _wait();
    final id = 'ba-${++_extSeq}';
    bankAccountList.add(BankAccount(id: id, bin: bin, accountNumber: accountNumber, holderName: holderName.toUpperCase(), isDefault: false, accountId: _extSeq, createdAt: 1700000000000, updatedAt: 1700000000000));
  }

  @override
  Future<void> deleteBankAccount(String accountId, {bool isDefault = false}) async {
    await _wait();
    bankAccountList.removeWhere((b) => b.id == accountId);
  }

  @override
  Future<List<MediaStoreEntry>> mediaStoreList(String threadId, ThreadType type, String mediaType) async {
    await _wait();
    return _mediaStore.where((m) => m.mediaType == mediaType).toList();
  }

  @override
  Future<void> mediaStoreRemove(String threadId, ThreadType type, String mediaType, String mediaId) async {
    await _wait();
    _mediaStore.removeWhere((m) => m.id == mediaId);
  }

  @override
  Future<bool> e2eeCheckCompatible(String threadId, ThreadType type) async {
    await _wait();
    return _e2eeThreads.contains(threadId);
  }

  @override
  Future<void> e2eeEnable(String threadId, ThreadType type, bool enable) async {
    await _wait();
    if (enable) {
      _e2eeThreads.add(threadId);
    } else {
      _e2eeThreads.remove(threadId);
    }
  }

  void dispose() {
    _disposed = true;
    _activeCall.dispose();
    _typing.close();
  }
}
