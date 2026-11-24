import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'services.dart';

bool get nativeIsDesktop => false;

Future<void> nativeInitWindow() async {}

String _blobUrl(Uint8List bytes, String mime) {
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mime));
  return web.URL.createObjectURL(blob);
}

Future<String> nativeMaterialize(String name, Uint8List bytes, String mime) async => _blobUrl(bytes, mime);

Future<String?> nativeSaveDownload(String name, Uint8List bytes, String mime) async {
  final url = _blobUrl(bytes, mime);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = name
    ..style.display = 'none';
  web.document.body?.appendChild(anchor);
  anchor.click();
  anchor.remove();
  return url;
}

Future<void> nativeOpenSaved(String path) async {
  web.window.open(path, '_blank');
}

Future<Uint8List> nativeReadUri(String uri) async {
  final response = await web.window.fetch(uri.toJS).toDart;
  final buffer = await response.arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}

Future<String> nativeRecordPath() async => '';

Future<bool> nativeAuthenticateUser(String reason) async => true;

Future<void> nativeClearTempMedia() async {}

NotificationGateway nativeNotifications() => _WebNotifications();

class _WebNotifications implements NotificationGateway {
  final StreamController<String> _activations = StreamController.broadcast();

  @override
  Stream<String> get activations => _activations.stream;

  @override
  Future<bool> requestPermission() async {
    try {
      if (web.Notification.permission == 'granted') return true;
      final result = await web.Notification.requestPermission().toDart;
      return result.toDart == 'granted';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> show({required int id, required String title, required String body, required String payload}) async {
    try {
      if (web.Notification.permission != 'granted') return;
      final n = web.Notification(title, web.NotificationOptions(body: body, tag: payload));
      n.onclick = ((web.Event _) {
        web.window.focus();
        _activations.add(payload);
        n.close();
      }).toJS;
    } catch (_) {}
  }

  @override
  Future<void> setUnread(int count) async {
    web.document.title = count > 0 ? '($count) zalos' : 'zalos';
  }
}
