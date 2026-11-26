import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zalos/src/ui/theme/theme.dart';
import 'package:zalos/src/ui/theme/tokens.dart';

const _fontDirectory = 'assets/fonts/GoogleSansFlex';
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
  test('pubspec registers the licensed Google Sans Flex variable font', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- family: GoogleSansFlex'));
    expect(pubspec, isNot(contains('- family: Plus Jakarta Sans')));

    const asset = '$_fontDirectory/GoogleSansFlex.ttf';
    expect(pubspec, contains('- asset: $asset'));
    final file = File(asset);
    expect(file.existsSync(), isTrue, reason: '$asset must be bundled');
    final bytes = file.readAsBytesSync();
    final data = ByteData.sublistView(bytes);
    final tables = _fontTables(bytes);
    expect(data.getUint32(0), 0x00010000,
        reason: 'Google Sans Flex must be a TrueType font');
    expect(tables, contains('glyf'));
    expect(tables, contains('fvar'),
        reason: 'Google Sans Flex must remain a variable font');

    final license = File('$_fontDirectory/OFL.txt').readAsStringSync();
    expect(license, contains('Google Sans Flex'));
    expect(license, contains('SIL OPEN FONT LICENSE'));
  });

  test('retired bundled font assets are gone', () {
    expect(Directory('assets/fonts/BeVietnamPro').existsSync(), isFalse);
    expect(Directory('assets/fonts/Inter').existsSync(), isFalse);
    expect(Directory('assets/fonts/PlusJakartaSans').existsSync(), isFalse);
  });

  test('shared text roles use Google Sans Flex with Zalo chat hierarchy', () {
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
        t.rowSubUnread,
        t.labelRegular,
        t.label,
        t.labelStrong,
        t.meta,
        t.metaStrong,
        t.senderName,
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
        final variations = style.fontVariations;
        expect(variations, isNotNull);
        final wght = variations!.singleWhere((v) => v.axis == 'wght');
        expect(wght.value, style.fontWeight!.value);
        final opsz = variations.singleWhere((v) => v.axis == 'opsz');
        expect(opsz.value, style.fontSize!.clamp(8.0, 144.0));
      }

      expect(t.body.fontWeight!.value, 400);
      expect(t.bodyWide.fontWeight!.value, 400);
      expect(t.body.fontSize, 15);
      expect(t.bodyWide.fontSize, 15);
      expect(t.body.height, 1.45);
      expect(t.body.letterSpacing, 0);
      expect(t.bodyWide.height, 1.45);
      expect(t.bodyWide.letterSpacing, 0);
      expect(t.rowTitle.fontWeight!.value, 550);
      expect(t.rowTitleUnread.fontWeight!.value, 650);
      expect(t.rowSub.fontWeight!.value, 400);
      expect(t.rowSubUnread.fontWeight!.value, 520);
      expect(t.senderName.fontSize, 13);
      expect(t.senderName.fontWeight!.value, 580);
      expect(t.senderName.height, 1.3);
      expect(t.senderName.letterSpacing, 0.1);
      expect(t.captionTabular.fontSize, 11.5);
      expect(t.captionTabular.fontWeight!.value, 420);
      expect(t.captionTabular.height, 1.2);
      expect(t.captionTabular.letterSpacing, 0.2);
      expect(t.captionTabular.fontFeatures,
          contains(isA<FontFeature>().having((f) => f.feature, 'feature', 'tnum')));
      expect(t.labelRegular.fontWeight, FontWeight.w400);
      expect(t.label.fontWeight, FontWeight.w500);
      expect(t.labelStrong.fontWeight, FontWeight.w600);
      expect(t.navLabel.fontSize, 11);
      expect(t.navLabelSelected.fontWeight, FontWeight.w600);
    }
  });

  test('Material themes propagate Google Sans Flex and shared role weights',
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
