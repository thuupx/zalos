import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:zalos/src/ui/platform/services.dart';

class FakeNotifications implements NotificationGateway {
  final List<({int id, String title, String body, String payload})> shown = [];
  final StreamController<String> activate = StreamController.broadcast();
  int unread = -1;
  int permissionRequests = 0;

  @override
  Stream<String> get activations => activate.stream;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return true;
  }

  @override
  Future<void> setUnread(int count) async => unread = count;

  @override
  Future<void> show({required int id, required String title, required String body, required String payload}) async {
    shown.add((id: id, title: title, body: body, payload: payload));
  }
}

class FakePlayback implements PlaybackHandle {
  final ValueNotifier<PlaybackStatus> _status = ValueNotifier(const PlaybackStatus());
  String? uri;
  bool disposed = false;

  /// Created with a video surface (see [PlatformServices.createPlayer]).
  bool withVideo = false;

  @override
  ValueListenable<PlaybackStatus> get status => _status;

  void set(PlaybackStatus s) => _status.value = s;

  @override
  Future<void> open(String uri, {bool play = true}) async {
    this.uri = uri;
    _status.value = PlaybackStatus(playing: play, duration: const Duration(seconds: 12), ready: true);
  }

  @override
  Future<void> pause() async => _status.value = PlaybackStatus(playing: false, position: _status.value.position, duration: _status.value.duration, ready: true);

  @override
  Future<void> play() async => _status.value = PlaybackStatus(playing: true, position: _status.value.position, duration: _status.value.duration, ready: true);

  @override
  Future<void> seek(Duration position) async => _status.value = PlaybackStatus(playing: _status.value.playing, position: position, duration: _status.value.duration, ready: true);

  @override
  Widget video() => const SizedBox(key: Key('fakeVideoSurface'), width: 320, height: 240);

  @override
  void dispose() => disposed = true;
}

class FakeRecorder implements VoiceRecorder {
  FakeRecorder(this.platform);
  final FakePlatform platform;
  bool cancelled = false;
  bool stopped = false;

  @override
  Future<bool> start() async => platform.micAllowed;

  @override
  Future<PickedFile?> stop() async {
    stopped = true;
    return PickedFile('voice-test.m4a', Uint8List.fromList(List.filled(64, 7)));
  }

  @override
  Future<void> cancel() async => cancelled = true;

  @override
  void dispose() {}
}

class FakePlatform implements PlatformServices {
  FakePlatform({this.cameraScanSupported = true, this.isDesktop = true, this.hardwareKeyboard = true});

  @override
  final bool cameraScanSupported;
  @override
  final bool isDesktop;
  @override
  final bool hardwareKeyboard;
  @override
  String get defaultDeviceNameKey => 'deviceMac';
  @override
  String get appVersion => '1.0.0';
  @override
  final FakeNotifications notifications = FakeNotifications();

  List<PickedFile> nextImages = const [];
  List<PickedFile> nextFiles = const [];
  PickedFile? clipboard;
  bool micAllowed = true;
  bool urlOpens = true;
  bool hasDownloads = true;
  final List<String> openedUrls = [];
  final List<String> saved = [];
  final List<String> openedSaved = [];
  final List<String> shared = [];
  final List<FakePlayback> players = [];
  final List<FakeRecorder> recorders = [];
  int settingsOpened = 0;
  int haptics = 0;
  bool stepUpAllowed = true;
  int stepUpCalls = 0;
  int tempMediaClears = 0;

  @override
  Future<bool> authenticateUser(String reason) async {
    stepUpCalls++;
    return stepUpAllowed;
  }

  @override
  Future<void> clearTempMedia() async {
    tempMediaClears++;
  }

  ValueChanged<String>? scannerOnCode;
  ValueChanged<ScannerProblem>? scannerOnProblem;
  ValueListenable<bool>? scannerTorch;
  ValueChanged<bool>? dropOnHover;
  ValueChanged<List<PickedFile>>? dropOnDrop;

  @override
  Future<List<PickedFile>> pickImages() async => nextImages;

  @override
  Future<List<PickedFile>> pickFiles() async => nextFiles;

  @override
  Future<PickedFile?> clipboardImage() async => clipboard;

  @override
  Future<String?> saveToDownloads(String name, Uint8List bytes) async {
    if (!hasDownloads) return null;
    saved.add(name);
    return '/downloads/$name';
  }

  @override
  Future<void> openSaved(String path) async => openedSaved.add(path);

  @override
  Future<void> share(String name, Uint8List bytes) async => shared.add(name);

  @override
  Future<bool> openUrl(String url) async {
    openedUrls.add(url);
    return urlOpens;
  }

  @override
  Future<void> openAppSettings() async => settingsOpened++;

  @override
  Future<String> materialize(String name, Uint8List bytes) async => 'memory://$name';

  @override
  PlaybackHandle createPlayer({bool video = false}) {
    final p = FakePlayback()..withVideo = video;
    players.add(p);
    return p;
  }

  @override
  VoiceRecorder createRecorder() {
    final r = FakeRecorder(this);
    recorders.add(r);
    return r;
  }

  @override
  Widget scanner({required ValueChanged<String> onCode, required ValueChanged<ScannerProblem> onProblem, required ValueListenable<bool> torch}) {
    scannerOnCode = onCode;
    scannerOnProblem = onProblem;
    scannerTorch = torch;
    return const SizedBox.expand(key: Key('fakeScanner'));
  }

  @override
  Widget dropTarget({required Widget child, required ValueChanged<bool> onHover, required ValueChanged<List<PickedFile>> onDrop}) {
    dropOnHover = onHover;
    dropOnDrop = onDrop;
    return child;
  }

  @override
  void hapticTick() => haptics++;
}
