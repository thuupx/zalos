import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/ui/theme/tokens.dart';
import 'package:zalos/src/ui/util/format.dart';

/// Loads real fonts so golden images are deterministic and show the real
/// typography: the bundled Plus Jakarta Sans from the app assets, Roboto from
/// the Flutter SDK cache and Material Symbols Rounded from the pub cache.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
  final fonts = '$flutterRoot/bin/cache/artifacts/material_fonts';

  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    var any = false;
    for (final path in paths) {
      final file = File(path);
      if (!file.existsSync()) continue;
      any = true;
      loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    if (any) await loader.load();
  }

  const appFonts = 'assets/fonts/PlusJakartaSans';
  await load(ZType.fontFamily, [
    for (final face in ['Regular', 'Italic', 'Medium', 'SemiBold', 'Bold']) '$appFonts/PlusJakartaSans-$face.ttf',
  ]);

  final roboto = ['$fonts/Roboto-Regular.ttf', '$fonts/Roboto-Medium.ttf', '$fonts/Roboto-Bold.ttf', '$fonts/Roboto-Italic.ttf'];
  await load('Roboto', roboto);
  await load('monospace', roboto);

  final home = Platform.environment['HOME'] ?? '';
  final config = File('.dart_tool/package_config.json');
  String? symbols;
  if (config.existsSync()) {
    final match = RegExp(r'"rootUri":\s*"file://([^"]*material_symbols_icons[^"]*)"').firstMatch(config.readAsStringSync());
    if (match != null) symbols = '${Uri.decodeFull(match.group(1)!)}/lib/fonts/MaterialSymbolsRounded.ttf';
  }
  symbols ??= '$home/.pub-cache/hosted/pub.dev/material_symbols_icons-4.2960.0/lib/fonts/MaterialSymbolsRounded.ttf';
  await load('packages/material_symbols_icons/MaterialSymbolsRounded', [symbols]);

  await load('PhosphorRegular', ['assets/fonts/Phosphor/Phosphor.ttf']);
  await load('PhosphorFill', ['assets/fonts/Phosphor/Phosphor-Fill.ttf']);

  zUseEmojiGlyphs = false;
  await testMain();
}
