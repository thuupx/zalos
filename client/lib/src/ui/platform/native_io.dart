import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'services.dart';

bool get nativeIsDesktop => Platform.isMacOS || Platform.isWindows || Platform.isLinux;

// window_manager 0.5.2 does not compile against Flutter 3.24 (it reads
// Color.r/g/b), so its registered native plugin is driven over its method
// channel instead of through its Dart library.
const MethodChannel _window = MethodChannel('window_manager');

Future<void> _windowCall(String method, [Map<String, Object?>? arguments]) async {
  try {
    await _window.invokeMethod<void>(method, arguments);
  } catch (_) {}
}

Future<void> nativeInitWindow() async {
  if (!nativeIsDesktop) return;
  await _windowCall('ensureInitialized');
  await _windowCall('setMinimumSize', {'devicePixelRatio': PlatformDispatcher.instance.views.first.devicePixelRatio, 'width': 400.0, 'height': 560.0});
  await _windowCall('setTitle', {'title': 'zalos'});
}

String _safeName(String name) => name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');

final Set<String> _materializedFiles = {};

String _randomHex128() {
  final rng = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buf.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}

Future<void> _chmodRestrictive(String path, String mode) async {
  if (Platform.isWindows) return;
  try {
    await Process.run('chmod', [mode, path]);
  } catch (_) {}
}

Future<String> nativeMaterialize(String name, Uint8List bytes, String mime) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/zalos-media');
  if (!await dir.exists()) {
    await dir.create(recursive: true);
    await _chmodRestrictive(dir.path, '700');
  }
  final safe = _safeName(name);
  final dot = safe.lastIndexOf('.');
  final ext = dot > 0 && dot >= safe.length - 10 ? safe.substring(dot) : '';
  final file = File('${dir.path}/${_randomHex128()}$ext');
  final raf = await file.open(mode: FileMode.writeOnly);
  try {
    await raf.writeFrom(bytes);
    await raf.flush();
  } finally {
    await raf.close();
  }
  await _chmodRestrictive(file.path, '600');
  _materializedFiles.add(file.path);
  return file.path;
}

Future<void> nativeClearTempMedia() async {
  for (final path in List.of(_materializedFiles)) {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
  _materializedFiles.clear();
  try {
    final dir = Directory('${(await getTemporaryDirectory()).path}/zalos-media');
    if (await dir.exists()) await dir.delete(recursive: true);
  } catch (_) {}
}

Future<bool> nativeAuthenticateUser(String reason) async {
  try {
    final auth = LocalAuthentication();
    final supported = await auth.isDeviceSupported();
    if (!supported) return true;
    return await auth.authenticate(
      localizedReason: reason,
      options: const AuthenticationOptions(
        biometricOnly: false,
        stickyAuth: true,
      ),
    );
  } on PlatformException {
    return false;
  } catch (_) {
    return false;
  }
}

Future<String?> nativeSaveDownload(String name, Uint8List bytes, String mime) async {
  if (!nativeIsDesktop) return null;
  final dir = await getDownloadsDirectory();
  if (dir == null) return null;
  final safe = _safeName(name);
  final dot = safe.lastIndexOf('.');
  final stem = dot > 0 ? safe.substring(0, dot) : safe;
  final ext = dot > 0 ? safe.substring(dot) : '';
  var file = File('${dir.path}/$safe');
  for (var i = 1; await file.exists(); i++) {
    file = File('${dir.path}/$stem ($i)$ext');
  }
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

Future<void> nativeOpenSaved(String path) async {
  await launchUrl(Uri.file(path));
}

Future<Uint8List> nativeReadUri(String uri) => File(uri).readAsBytes();

Future<String> nativeRecordPath() async {
  final dir = await getTemporaryDirectory();
  return '${dir.path}/zalos-voice-${DateTime.now().microsecondsSinceEpoch}.m4a';
}

NotificationGateway nativeNotifications() => _IoNotifications();

class _IoNotifications implements NotificationGateway {
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  final StreamController<String> _activations = StreamController.broadcast();
  Future<void>? _ready;

  Future<void> _init() async {
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
        macOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
        windows: WindowsInitializationSettings(appName: 'zalos', appUserModelId: 'dev.zalos.client', guid: '6f0d2a5e-7c1b-4e0e-9a54-2f3b7c9d1e60'),
      ),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload != null && payload.isNotEmpty) _activations.add(payload);
      },
    );
  }

  @override
  Stream<String> get activations => _activations.stream;

  @override
  Future<bool> requestPermission() async {
    try {
      await (_ready ??= _init());
      if (Platform.isMacOS) {
        return await _plugin
                .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()
                ?.requestPermissions(alert: true, badge: true, sound: true) ??
            false;
      }
      if (Platform.isIOS) {
        return await _plugin
                .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
                ?.requestPermissions(alert: true, badge: true, sound: true) ??
            false;
      }
      if (Platform.isAndroid) {
        return await _plugin
                .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
                ?.requestNotificationsPermission() ??
            true;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> show({required int id, required String title, required String body, required String payload}) async {
    try {
      await (_ready ??= _init());
      await _plugin.show(
        id,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails('messages', 'Messages', groupKey: payload, importance: Importance.high, priority: Priority.high),
          iOS: DarwinNotificationDetails(threadIdentifier: payload),
          macOS: DarwinNotificationDetails(threadIdentifier: payload),
          linux: const LinuxNotificationDetails(),
          windows: const WindowsNotificationDetails(),
        ),
        payload: payload,
      );
      if (kDebugMode && (Platform.isMacOS || Platform.isIOS || Platform.isAndroid)) {
        final active = await _plugin.getActiveNotifications();
        debugPrint('zalos notifications active: ${active.length} (${active.map((n) => n.title).join(', ')})');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('zalos notification failed: $e');
    }
  }

  @override
  Future<void> setUnread(int count) async {
    if (!nativeIsDesktop) return;
    try {
      await _windowCall('setTitle', {'title': count > 0 ? '($count) zalos' : 'zalos'});
      if (Platform.isMacOS) await _windowCall('setBadgeLabel', {'label': count > 0 ? (count > 99 ? '99+' : '$count') : ''});
    } catch (_) {}
  }
}
