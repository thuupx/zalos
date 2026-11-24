import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/domain/models.dart';
import 'package:zalos/src/domain/services.dart';
import 'package:zalos/src/ui/chat/message_row.dart';
import 'package:zalos/src/ui/l10n/strings.dart';
import 'package:zalos/src/ui/pairing/pairing_screen.dart';
import 'package:zalos/src/ui/theme/tokens.dart';
import 'package:zalos/src/ui/threads/thread_tile.dart';
import 'package:zalos/src/ui/util/format.dart';

import '../support/fake_zalos.dart';
import '../support/harness.dart';

Iterable<File> _uiFiles() => Directory('lib/src/ui').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));

void main() {
  test('no literal colors or font sizes outside the theme', () {
    final offenders = <String>[];
    final pattern = RegExp(r'Color\(0x|Colors\.|fontSize:');
    for (final f in _uiFiles()) {
      if (f.path.contains('/theme/')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (pattern.hasMatch(lines[i])) offenders.add('${f.path}:${i + 1}');
      }
    }
    expect(offenders, isEmpty);
  });

  test('string tables match and every used key exists', () {
    expect(S.en.keys.toSet(), S.vi.keys.toSet());
    final missing = <String>{};
    final call = RegExp(r"\b(?:tr|t)\(\s*((?:[^()]|\([^()]*\))*?)(?:,\s*\[|\))");
    final key = RegExp(r"'([a-zA-Z][A-Za-z0-9]*)'");
    for (final f in _uiFiles()) {
      if (f.path.contains('/l10n/')) continue;
      for (final m in call.allMatches(f.readAsStringSync())) {
        for (final k in key.allMatches(m.group(1)!)) {
          if (!S.vi.containsKey(k.group(1))) missing.add('${k.group(1)} (${f.path})');
        }
      }
    }
    expect(missing, isEmpty);
  });

  test('nothing in lib imports test code and no dash characters', () {
    for (final f in [..._uiFiles(), File('lib/main.dart')]) {
      final text = f.readAsStringSync();
      expect(text.contains('test/support') || text.contains('package:flutter_test'), isFalse, reason: f.path);
      expect(text.contains('\u2013') || text.contains('\u2014'), isFalse, reason: f.path);
    }
  });

  test('token text pairs meet WCAG AA', () {
    double lum(Color c) {
      double ch(int v) {
        final s = v / 255;
        return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055).clamp(0, 1).toDouble().pow(2.4);
      }

      return 0.2126 * ch((c.r * 255.0).round()) + 0.7152 * ch((c.g * 255.0).round()) + 0.0722 * ch((c.b * 255.0).round());
    }

    double ratio(Color a, Color b) {
      final x = lum(a), y = lum(b);
      return (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
    }

    for (final z in [ZalosTokens.light, ZalosTokens.darkTokens]) {
      final pairs = <(Color, Color)>[
        (z.textPrimary, z.layer),
        (z.textSecondary, z.layer),
        (z.textTertiary, z.layer),
        (z.textTertiary, z.layerSubtle),
        (z.brandText, z.layer),
        (z.brandText, z.brandSubtle),
        (z.textOnBrand, z.brand),
        (z.onAccent, z.badge),
        (z.onBadgeMention, z.badgeMention),
        (z.textPrimary, z.bubbleOut),
        (z.bubbleMetaOut, z.bubbleOut),
        (z.bubbleMetaIn, z.bubbleIn),
        (z.danger, z.layer),
        (z.success, z.layer),
        (z.accentText, z.layer),
      ];
      for (final (fg, bg) in pairs) {
        expect(ratio(fg, bg), greaterThanOrEqualTo(4.5), reason: '$fg on $bg (dark: ${z.dark})');
      }
    }
  });

  test('formatting helpers', () {
    ZClock.source = () => fakeNow;
    addTearDown(() => ZClock.source = DateTime.now);
    const s = S('vi');
    expect(foldVi('Nguyễn Đỗ'), 'nguyen do');
    expect(foldMatch('Nguyễn Thị Lan', 'nguyen'), (start: 0, end: 6));
    expect(initialsOf('Nguyễn Thị Lan'), 'NL');
    expect(formatListTime(minutesAgo(0), s), 'vừa xong');
    expect(formatListTime(minutesAgo(5), s), '5 phút');
    expect(formatListTime(minutesAgo(125), s), '12:00');
    expect(formatListTime(minutesAgo(60 * 24), s), 'Hôm qua');
    expect(formatListTime(minutesAgo(60 * 24 * 3), s), 'Th 2');
    expect(formatListTime(minutesAgo(60 * 24 * 30), s), '10/02');
    expect(formatDay(minutesAgo(60 * 24 * 3), s), 'Thứ Hai, 09/03/2026');
    expect(middleEllipsis('Bao_cao_doanh_thu_quy_3_ban_cuoi_cung_da_duyet.pdf', 24).endsWith('yet.pdf'), isTrue);
    expect(isEmojiOnly('😀😀'), isTrue);
    expect(isEmojiOnly('ok 😀'), isFalse);
    expect(codeGroups('4F2A91C7'), ['4F2A', '91C7']);
    expect(isPairingUri(FakeZalosApp.samplePairingUri), isTrue);
    expect(isPairingUri('https://example.com'), isFalse);
    expect(pairingErrorText(s, const PairingException('Could not reach the server at host:1.', code: PairingErrorCode.unreachable, detail: 'host:1')), contains('host:1'));
    expect(pairingErrorText(s, const PairingException('This pairing code has expired or was already used.', code: PairingErrorCode.expired)), contains('hết hạn'));
    expect(pairingErrorText(s, const PairingException('Secure handshake with the server failed.', code: PairingErrorCode.handshake)), contains('Khóa'));
    expect(pairingErrorText(s, const PairingException('Unexpected reply.', code: PairingErrorCode.protocol)), contains('định dạng'));
    expect(pairingErrorText(s, StateError('x')), isNot(contains('Bad state')));
    expect(layoutClassFor(719), LayoutClass.compact);
    expect(layoutClassFor(720), LayoutClass.medium);
    expect(layoutClassFor(1100), LayoutClass.expanded);
  });

  testWidgets('5,000 messages and 2,000 threads: one update rebuilds a bounded number of rows', (tester) async {
    final h = await pumpZalos(tester, app: FakeZalosApp(large: true), size: expanded);
    expect(h.main.threads.value.length, 2000);
    await openThreadByKey(tester, 'u01');
    expect(h.main.messages('u01', ThreadType.user).value.length, 5000);
    await settle(tester);

    final rowsBefore = MessageRow.debugBuilds;
    final tilesBefore = ThreadTile.debugBuilds;
    h.main.receive('u01', 'Tin mới duy nhất');
    await settle(tester);
    expect(find.text('Tin mới duy nhất'), findsWidgets);
    expect(MessageRow.debugBuilds - rowsBefore, lessThanOrEqualTo(6));
    expect(ThreadTile.debugBuilds - tilesBefore, lessThanOrEqualTo(6));

    final target = h.main.messages('u01', ThreadType.user).value[4990];
    final rows2 = MessageRow.debugBuilds;
    await h.main.react(target, '/-heart');
    await settle(tester);
    expect(MessageRow.debugBuilds - rows2, lessThanOrEqualTo(4));
    expect(tester.widgetList(find.byType(MessageRow)).length, lessThan(60));
    expect(tester.widgetList(find.byType(ThreadTile)).length, lessThan(40));
    await drain(tester);
  });
}

extension on double {
  double pow(double e) => _pow(this, e);
}

double _pow(double b, double e) {
  var result = 1.0;
  // Exponent 2.4 as b^2 * b^(2/5), with the fifth root by Newton iteration.
  var root = b <= 0 ? 0.0 : 1.0;
  for (var i = 0; i < 40 && b > 0; i++) {
    root = root - (root * root * root * root * root - b) / (5 * root * root * root * root);
  }
  result = b * b * root * root;
  assert(e == 2.4);
  return result;
}
