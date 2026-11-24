import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart' hide PickedFile;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'native_stub.dart' if (dart.library.io) 'native_io.dart' if (dart.library.js_interop) 'native_web.dart';
import '../util/haptics.dart';
import 'services.dart';

String mimeForName(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return const {
        'jpg': 'image/jpeg',
        'jpeg': 'image/jpeg',
        'png': 'image/png',
        'gif': 'image/gif',
        'webp': 'image/webp',
        'mp4': 'video/mp4',
        'mov': 'video/quicktime',
        'webm': 'video/webm',
        'm4a': 'audio/mp4',
        'aac': 'audio/aac',
        'mp3': 'audio/mpeg',
        'wav': 'audio/wav',
        'ogg': 'audio/ogg',
        'pdf': 'application/pdf',
        'txt': 'text/plain',
      }[ext] ??
      'application/octet-stream';
}

Future<void> initPlatform() async {
  MediaKit.ensureInitialized();
  await nativeClearTempMedia();
  await nativeInitWindow();
}

class RealPlatform implements PlatformServices {
  RealPlatform({this.appVersion = const String.fromEnvironment('ZALOS_VERSION', defaultValue: '1.0.0')});

  @override
  final String appVersion;

  @override
  Future<bool> authenticateUser(String reason) => nativeAuthenticateUser(reason);

  @override
  Future<void> clearTempMedia() => nativeClearTempMedia();

  @override
  late final NotificationGateway notifications = nativeNotifications();

  @override
  bool get cameraScanSupported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  bool get isDesktop => !kIsWeb && nativeIsDesktop;

  @override
  bool get hardwareKeyboard => kIsWeb || nativeIsDesktop;

  @override
  String get defaultDeviceNameKey {
    if (kIsWeb) return 'deviceWeb';
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'deviceIphone',
      TargetPlatform.android => 'deviceAndroid',
      TargetPlatform.macOS => 'deviceMac',
      TargetPlatform.windows => 'deviceWindows',
      _ => 'deviceLinux',
    };
  }

  @override
  Future<List<PickedFile>> pickImages() async {
    final picked = await ImagePicker().pickMultiImage();
    return [for (final x in picked) PickedFile(x.name, await x.readAsBytes())];
  }

  @override
  Future<List<PickedFile>> pickFiles() async {
    final result = await FilePicker.pickFiles(withData: true, allowMultiple: true);
    return [
      for (final f in result?.files ?? const <PlatformFile>[])
        if (f.bytes != null) PickedFile(f.name, f.bytes!),
    ];
  }

  @override
  Future<PickedFile?> clipboardImage() async {
    try {
      final bytes = await Pasteboard.image;
      return bytes == null || bytes.isEmpty ? null : PickedFile('clipboard-${DateTime.now().millisecondsSinceEpoch}.png', bytes);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> saveToDownloads(String name, Uint8List bytes) => nativeSaveDownload(name, bytes, mimeForName(name));

  @override
  Future<void> openSaved(String path) => nativeOpenSaved(path);

  @override
  Future<void> share(String name, Uint8List bytes) async {
    await SharePlus.instance.share(ShareParams(files: [XFile.fromData(bytes, name: name, mimeType: mimeForName(name))], fileNameOverrides: [name]));
  }

  @override
  Future<bool> openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> openAppSettings() async {
    try {
      await launchUrl(Uri.parse('app-settings:'));
    } catch (_) {}
  }

  @override
  Future<String> materialize(String name, Uint8List bytes) => nativeMaterialize(name, bytes, mimeForName(name));

  @override
  PlaybackHandle createPlayer({bool video = false}) => _MediaKitPlayback(video: video);

  @override
  VoiceRecorder createRecorder() => _RecordRecorder();

  @override
  Widget scanner({required ValueChanged<String> onCode, required ValueChanged<ScannerProblem> onProblem, required ValueListenable<bool> torch}) =>
      _Scanner(onCode: onCode, onProblem: onProblem, torch: torch);

  @override
  Widget dropTarget({required Widget child, required ValueChanged<bool> onHover, required ValueChanged<List<PickedFile>> onDrop}) {
    return DropTarget(
      onDragEntered: (_) => onHover(true),
      onDragExited: (_) => onHover(false),
      onDragDone: (details) async {
        onHover(false);
        final files = <PickedFile>[];
        for (final f in details.files) {
          try {
            files.add(PickedFile(f.name, await f.readAsBytes()));
          } catch (_) {}
        }
        if (files.isNotEmpty) onDrop(files);
      },
      child: child,
    );
  }

  @override
  void hapticTick() {
    ZHaptics.selection();
  }
}

class _MediaKitPlayback implements PlaybackHandle {
  _MediaKitPlayback({required bool video}) {
    if (video) _video = VideoController(_player);
    _subs = [
      _player.stream.playing.listen((v) => _set(playing: v)),
      _player.stream.position.listen((v) => _set(position: v)),
      _player.stream.duration.listen((v) => _set(duration: v)),
      _player.stream.completed.listen((v) => _set(completed: v)),
    ];
  }

  final Player _player = Player();
  VideoController? _video;
  late final List<StreamSubscription<Object?>> _subs;
  final ValueNotifier<PlaybackStatus> _status = ValueNotifier(const PlaybackStatus());
  bool _disposed = false;

  void _set({bool? playing, Duration? position, Duration? duration, bool? completed}) {
    if (_disposed) return;
    final s = _status.value;
    _status.value = PlaybackStatus(
      playing: playing ?? s.playing,
      position: position ?? s.position,
      duration: duration ?? s.duration,
      completed: completed ?? s.completed,
      ready: true,
    );
  }

  @override
  ValueListenable<PlaybackStatus> get status => _status;

  @override
  Future<void> open(String uri, {bool play = true}) => _player.open(Media(uri), play: play);

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Widget video() => Video(controller: _video ??= VideoController(_player));

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
  }
}

class _RecordRecorder implements VoiceRecorder {
  final AudioRecorder _recorder = AudioRecorder();

  @override
  Future<bool> start() async {
    if (!await _recorder.hasPermission()) return false;
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: await nativeRecordPath());
    return true;
  }

  @override
  Future<PickedFile?> stop() async {
    final uri = await _recorder.stop();
    if (uri == null || uri.isEmpty) return null;
    final bytes = await nativeReadUri(uri);
    return bytes.isEmpty ? null : PickedFile('voice-${DateTime.now().millisecondsSinceEpoch}.m4a', bytes);
  }

  @override
  Future<void> cancel() => _recorder.cancel();

  @override
  void dispose() {
    _recorder.dispose();
  }
}

class _Scanner extends StatefulWidget {
  const _Scanner({required this.onCode, required this.onProblem, required this.torch});

  final ValueChanged<String> onCode;
  final ValueChanged<ScannerProblem> onProblem;
  final ValueListenable<bool> torch;

  @override
  State<_Scanner> createState() => _ScannerState();
}

class _ScannerState extends State<_Scanner> {
  final MobileScannerController _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _torch = false;

  @override
  void initState() {
    super.initState();
    widget.torch.addListener(_syncTorch);
  }

  void _syncTorch() {
    if (widget.torch.value != _torch) {
      _torch = widget.torch.value;
      _controller.toggleTorch();
    }
  }

  @override
  void dispose() {
    widget.torch.removeListener(_syncTorch);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MobileScanner(
      controller: _controller,
      onDetect: (capture) {
        for (final code in capture.barcodes) {
          final value = code.rawValue;
          if (value != null) widget.onCode(value);
        }
      },
      errorBuilder: (context, error) {
        final problem =
            error.errorCode == MobileScannerErrorCode.permissionDenied ? ScannerProblem.permissionDenied : ScannerProblem.unavailable;
        WidgetsBinding.instance.addPostFrameCallback((_) => widget.onProblem(problem));
        return const SizedBox.expand();
      },
    );
  }
}
