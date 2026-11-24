import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zalos/src/ui/theme/theme.dart';
import 'package:zalos/src/ui/theme/tokens.dart';

const _fontDirectory = 'assets/fonts/PlusJakartaSans';
const _faces = <String, int>{
  'Regular': 400,
  'Italic': 400,
  'Medium': 500,
  'SemiBold': 600,
  'Bold': 700,
};

Map<String, int> _fontTables(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final tableCount = data.getUint16(4);
  return {
    for (var i = 0; i < tableCount; i++)
      String.fromCharCodes(bytes, 12 + i * 16, 16 + i * 16):
          data.getUint32(20 + i * 16),
  };
}

void main() {
  test(
      'pubspec registers the licensed static Plus Jakarta Sans faces at their real weights',
      () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- family: Plus Jakarta Sans'));

    for (final entry in _faces.entries) {
      final face = entry.key;
      final weight = entry.value;
      final asset = '$_fontDirectory/PlusJakartaSans-$face.ttf';
      final registration = switch (face) {
        'Italic' => '- asset: $asset\n          style: italic',
        'Regular' => '- asset: $asset',
        _ => '- asset: $asset\n          weight: $weight',
      };
      expect(pubspec, contains(registration),
          reason: '$face must map to weight $weight');

      final file = File(asset);
      expect(file.existsSync(), isTrue, reason: '$asset must be bundled');
      final bytes = file.readAsBytesSync();
      final data = ByteData.sublistView(bytes);
      final tables = _fontTables(bytes);
      expect(data.getUint32(0), 0x00010000,
          reason: '$face must be a TrueType font');
      expect(tables, contains('glyf'));
      expect(tables, isNot(contains('fvar')),
          reason: '$face must be static, not variable');
      expect(data.getUint16(tables['OS/2']! + 4), weight,
          reason: '$face has a mismatched OS/2 weight');
    }

    final license = File('$_fontDirectory/OFL.txt').readAsStringSync();
    expect(license, contains('Plus Jakarta Sans'));
    expect(license, contains('SIL Open Font License, Version 1.1'));
  });

  test('old bundled font assets are gone', () {
    expect(Directory('assets/fonts/BeVietnamPro').existsSync(), isFalse);
    expect(Directory('assets/fonts/Inter').existsSync(), isFalse);
  });

  test('shared text roles use Plus Jakarta Sans with clean hierarchy', () {
    for (final z in [ZalosTokens.light, ZalosTokens.darkTokens]) {
      final t = z.text;
      final styles = [
        t.display,
        t.title,
        t.rowTitle,
        t.rowTitleUnread,
        t.body,
        t.bodyWide,
        t.rowSub,
        t.labelRegular,
        t.label,
        t.labelStrong,
        t.meta,
        t.metaStrong,
        t.caption,
        t.captionTabular,
        t.captionStrong,
        t.navLabel,
        t.navLabelSelected,
        t.overline,
        t.badge,
      ];
      for (final style in styles) {
        expect(style.fontFamily, ZType.fontFamily);
        expect(style.fontFamilyFallback, ZType.fontFallback);
      }

      expect(t.body.fontWeight, FontWeight.w400);
      expect(t.bodyWide.fontWeight, FontWeight.w400);
      expect(t.body.fontSize, 15);
      expect(t.bodyWide.fontSize, 15);
      expect(t.bodyWide.height, closeTo(22 / 15, 0.0001));
      expect(t.rowTitle.fontWeight, FontWeight.w500);
      expect(t.rowTitleUnread.fontWeight, FontWeight.w700);
      expect(t.labelRegular.fontWeight, FontWeight.w400);
      expect(t.label.fontWeight, FontWeight.w500);
      expect(t.labelStrong.fontWeight, FontWeight.w600);
      expect(t.navLabel.fontSize, 11);
      expect(t.navLabelSelected.fontWeight, FontWeight.w600);
    }
  });

  test('Material themes propagate Plus Jakarta Sans and shared role weights',
      () {
    for (final brightness in Brightness.values) {
      final theme = buildZalosTheme(brightness);
      expect(theme.textTheme.displayLarge?.fontFamily, ZType.fontFamily);
      expect(
          theme.textTheme.displayLarge?.fontFamilyFallback, ZType.fontFallback);
      expect(theme.textTheme.bodyLarge?.fontFamily, ZType.fontFamily);
      expect(theme.textTheme.bodyLarge?.fontWeight, FontWeight.w400);
      expect(theme.textTheme.bodyMedium?.fontWeight, FontWeight.w400);
      expect(theme.textTheme.labelLarge?.fontWeight, FontWeight.w500);
      expect(theme.textTheme.titleSmall?.fontWeight, FontWeight.w500);
    }
  });

  testWidgets(
      'precomposed and decomposed Vietnamese share the same bundled roles',
      (tester) async {
    const precomposed = 'Tin nhắn Việt';
    const decomposed = 'Tin nha\u0306\u0301n Vie\u0323\u0302t';
    final t = ZalosTokens.light.text;
    await tester.pumpWidget(MaterialApp(
      theme: buildZalosTheme(Brightness.light),
      home: Scaffold(
        body: Column(
          children: [
            Text(precomposed, key: const Key('precomposed'), style: t.body),
            Text(decomposed, key: const Key('decomposed'), style: t.body),
            Text('Tìm kiếm', key: const Key('label'), style: t.labelRegular),
          ],
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
    for (final key in ['precomposed', 'decomposed', 'label']) {
      final text = tester.widget<Text>(find.byKey(Key(key)));
      expect(text.style?.fontFamily, ZType.fontFamily);
      expect(tester.getSize(find.byKey(Key(key))).height, greaterThan(0));
    }
    expect(
      tester.getSize(find.byKey(const Key('precomposed'))).height,
      tester.getSize(find.byKey(const Key('decomposed'))).height,
    );
  });
}
