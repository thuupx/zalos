import 'dart:typed_data';

import 'services.dart';

bool get nativeIsDesktop => false;
Future<void> nativeInitWindow() async {}
Future<String> nativeMaterialize(String name, Uint8List bytes, String mime) => throw UnsupportedError('materialize');
Future<String?> nativeSaveDownload(String name, Uint8List bytes, String mime) async => null;
Future<void> nativeOpenSaved(String path) async {}
Future<Uint8List> nativeReadUri(String uri) => throw UnsupportedError('readUri');
Future<String> nativeRecordPath() async => '';
Future<bool> nativeAuthenticateUser(String reason) async => true;
Future<void> nativeClearTempMedia() async {}
NotificationGateway nativeNotifications() => throw UnsupportedError('notifications');
