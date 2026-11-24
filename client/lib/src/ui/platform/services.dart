
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

@immutable
class PickedFile {
  const PickedFile(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

@immutable
class PlaybackStatus {
  const PlaybackStatus({this.playing = false, this.position = Duration.zero, this.duration = Duration.zero, this.completed = false, this.ready = false});
  final bool playing;
  final Duration position;
  final Duration duration;
  final bool completed;
  final bool ready;
}

abstract class PlaybackHandle {
  ValueListenable<PlaybackStatus> get status;
  Future<void> open(String uri, {bool play = true});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// The video surface, for handles that opened a video.
  Widget video();
  void dispose();
}

abstract class VoiceRecorder {
  /// False when the microphone permission is missing.
  Future<bool> start();
  Future<PickedFile?> stop();
  Future<void> cancel();
  void dispose();
}

enum ScannerProblem { permissionDenied, unavailable }

abstract class NotificationGateway {
  Future<bool> requestPermission();
  Future<void> show({required int id, required String title, required String body, required String payload});

  /// Payloads of notifications the user activated.
  Stream<String> get activations;

  /// Dock or taskbar badge and window or tab title.
  Future<void> setUnread(int count);
}

/// Everything the UI needs from the host platform. The real implementation
/// wraps the plugins; tests replace it with a fake.
abstract class PlatformServices {
  bool get cameraScanSupported;
  bool get isDesktop;
  bool get hardwareKeyboard;
  String get defaultDeviceNameKey;

  Future<List<PickedFile>> pickImages();
  Future<List<PickedFile>> pickFiles();
  Future<PickedFile?> clipboardImage();

  /// Saves to the Downloads folder (desktop) or triggers a browser download
  /// (web). Returns a path that [openSaved] accepts, or null when the
  /// platform has no such folder and the share sheet should be used.
  Future<String?> saveToDownloads(String name, Uint8List bytes);
  Future<void> openSaved(String path);
  Future<void> share(String name, Uint8List bytes);
  Future<bool> openUrl(String url);
  Future<void> openAppSettings();

  /// A file path or blob url the player can open.
  Future<String> materialize(String name, Uint8List bytes);
  /// A player; pass [video] for one whose picture is shown, so the video
  /// surface exists before the media opens (the web player only learns the
  /// picture size from events fired while opening).
  PlaybackHandle createPlayer({bool video = false});
  VoiceRecorder createRecorder();

  Widget scanner({required ValueChanged<String> onCode, required ValueChanged<ScannerProblem> onProblem, required ValueListenable<bool> torch});
  Widget dropTarget({required Widget child, required ValueChanged<bool> onHover, required ValueChanged<List<PickedFile>> onDrop});

  /// Step-up local authentication (biometric or device passcode) before
  /// exposing or mutating high-value secrets (MASVS AUTH-3).
  Future<bool> authenticateUser(String reason);

  /// Deletes temporary decrypted media files materialized on disk.
  Future<void> clearTempMedia();

  NotificationGateway get notifications;
  void hapticTick();
  String get appVersion;
}

final platformProvider = Provider<PlatformServices>((ref) => throw UnimplementedError('platformProvider not overridden'));
