import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../../domain/models.dart';
import '../l10n/strings.dart';
import '../theme/z_icons.dart';

/// Overridable clock so time dependent text is deterministic in tests.
abstract final class ZClock {
  static DateTime Function() source = DateTime.now;
  static DateTime now() => source();
  static int nowMs() => source().millisecondsSinceEpoch;
}

const reactionIcons = <String>['/-heart', '/-strong', ':>', ':o', ':-((', ':-h'];

const _reactionGlyph = <String, IconData>{
  '/-heart': ZIcons.heartFill,
  '/-strong': ZIcons.thumbUp,
  ':>': ZIcons.reactHaha,
  ':o': ZIcons.reactWow,
  ':-((': ZIcons.reactSad,
  ':-h': ZIcons.reactAngry,
};

const _reactionKey = <String, String>{
  '/-heart': 'reactHeart',
  '/-strong': 'reactLike',
  ':>': 'reactHaha',
  ':o': 'reactWow',
  ':-((': 'reactSad',
  ':-h': 'reactAngry',
};

const _reactionEmoji = <String, String>{
  '/-heart': '\u2764\uFE0F',
  '/-strong': '\u{1F44D}',
  ':>': '\u{1F606}',
  ':o': '\u{1F62E}',
  ':-((': '\u{1F62D}',
  ':-h': '\u{1F621}',
};

/// Emoji of a reaction, or null for unknown icons.
String? reactionEmoji(String icon) => _reactionEmoji[icon];

/// Tests switch this off so golden images do not depend on an emoji font.
bool zUseEmojiGlyphs = true;

IconData reactionGlyph(String icon) => _reactionGlyph[icon] ?? ZIcons.addReaction;

String reactionLabel(String icon, S s) => s.t(_reactionKey[icon] ?? 'reactOther');

const _foldFrom = 'àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ';
const _foldTo = 'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd';

/// Lowercases and strips Vietnamese diacritics. The result has the same
/// length in code units as the lowercased input for precomposed text, so
/// match offsets can be mapped back for highlighting.
String foldVi(String input) {
  final lower = input.toLowerCase();
  final out = StringBuffer();
  for (final rune in lower.runes) {
    final ch = String.fromCharCode(rune);
    final i = _foldFrom.indexOf(ch);
    out.write(i >= 0 ? _foldTo[i] : ch);
  }
  return out.toString();
}

/// Range of the first match of [query] in [text] ignoring case and
/// diacritics, or null.
({int start, int end})? foldMatch(String text, String query) {
  final q = foldVi(query.trim());
  if (q.isEmpty) return null;
  final folded = foldVi(text);
  final i = folded.indexOf(q);
  if (i < 0 || folded.length != text.length) {
    return i < 0 ? null : (start: 0, end: 0);
  }
  return (start: i, end: i + q.length);
}

bool foldContains(String text, String query) => foldVi(text).contains(foldVi(query.trim()));

String sectionLetter(String name) {
  final folded = foldVi(name).trim();
  if (folded.isEmpty) return '#';
  final ch = folded[0].toUpperCase();
  return RegExp(r'^[A-Z]$').hasMatch(ch) ? ch : '#';
}

String initialsOf(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  String first(String s) => String.fromCharCode(s.runes.first).toUpperCase();
  if (parts.length == 1) return first(parts.first);
  return first(parts.first) + first(parts.last);
}

String shortName(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  return parts.isEmpty ? name : parts.last;
}

String formatBytes(int? bytes) {
  if (bytes == null || bytes < 0) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(bytes < 10240 ? 1 : 0)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String formatDuration(int? ms) {
  final total = ((ms ?? 0) / 1000).round();
  final m = total ~/ 60, s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

String formatClock(int ts) => DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(ts));

int _dayDiff(DateTime now, DateTime t) =>
    DateTime(now.year, now.month, now.day).difference(DateTime(t.year, t.month, t.day)).inDays;

String _weekday(DateTime t, S s) => s.t('weekday${t.weekday}');

/// Conversation list time: "vừa xong", "5 phút", "14:05", "Hôm qua",
/// weekday within the week, "12/03" older.
String formatListTime(int ts, S s) {
  if (ts <= 0) return '';
  final now = ZClock.now();
  final t = DateTime.fromMillisecondsSinceEpoch(ts);
  final diff = now.difference(t);
  if (diff.inSeconds < 60) return s.t('timeNow');
  if (diff.inMinutes < 60) return s.t('timeMinutes', [diff.inMinutes]);
  final days = _dayDiff(now, t);
  if (days <= 0) return DateFormat('HH:mm').format(t);
  if (days == 1) return s.t('yesterday');
  if (days < 7) return s.t('weekdayShort${t.weekday}');
  if (t.year == now.year) return DateFormat('dd/MM').format(t);
  return DateFormat('dd/MM/yy').format(t);
}

String formatRelative(int? ts, S s) {
  if (ts == null || ts <= 0) return s.t('never');
  final now = ZClock.now();
  final t = DateTime.fromMillisecondsSinceEpoch(ts);
  final diff = now.difference(t);
  if (diff.inSeconds < 60) return s.t('timeNow');
  if (diff.inMinutes < 60) return s.t('timeMinutesAgo', [diff.inMinutes]);
  if (diff.inHours < 24) return s.t('timeHoursAgo', [diff.inHours]);
  if (diff.inDays < 30) return s.t('timeDaysAgo', [diff.inDays]);
  return DateFormat('dd/MM/yyyy').format(t);
}

/// Day separator: "Hôm nay", "Hôm qua" or "Thứ Hai, 12/03/2026".
String formatDay(int ts, S s) {
  final now = ZClock.now();
  final t = DateTime.fromMillisecondsSinceEpoch(ts);
  final days = _dayDiff(now, t);
  if (days == 0) return s.t('today');
  if (days == 1) return s.t('yesterday');
  return '${_weekday(t, s)}, ${DateFormat('dd/MM/yyyy').format(t)}';
}

String formatDateTime(int? ts, S s) {
  if (ts == null || ts <= 0) return s.t('never');
  return DateFormat('HH:mm dd/MM/yyyy').format(DateTime.fromMillisecondsSinceEpoch(ts));
}

bool sameDay(int a, int b) {
  final x = DateTime.fromMillisecondsSinceEpoch(a), y = DateTime.fromMillisecondsSinceEpoch(b);
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

bool isUndecryptable(Message m) {
  if (m.recalled || m.kind == MessageKind.system || m.kind == MessageKind.other) return false;
  final hasContent = (m.text ?? '').isNotEmpty ||
      m.attachments.isNotEmpty ||
      m.sticker != null ||
      m.card != null ||
      m.bankCard != null ||
      m.location != null ||
      m.poll != null ||
      m.note != null ||
      m.reminder != null ||
      m.callLog != null ||
      m.doodle != null ||
      m.album != null ||
      m.todo != null ||
      m.linkPreview != null;
  return !hasContent;
}

/// Per-message TTL options offered by the composer, in ms; 0 is off.
const List<int> messageTtls = [0, 3600000, 86400000, 604800000];

String messageTtlLabel(int? ttl, S s) => switch (ttl) {
      3600000 => s.t('sendOptionsTtl1h'),
      86400000 => s.t('sendOptionsTtl1d'),
      604800000 => s.t('sendOptionsTtl7d'),
      _ => s.t('sendOptionsTtlOff'),
    };

String messageUrgencyLabel(MessageUrgency? urgency, S s) => switch (urgency) {
      MessageUrgency.important => s.t('sendOptionsUrgencyImportant'),
      MessageUrgency.urgent => s.t('sendOptionsUrgencyUrgent'),
      _ => s.t('sendOptionsUrgencyNormal'),
    };

/// One line description of a message for lists, quotes and reply bars.
String messageSummary(Message m, S s) {
  if (m.recalled) return s.t('recalled');
  if (isUndecryptable(m)) return s.t('previewEncrypted');
  final att = m.attachments.isEmpty ? null : m.attachments.first;
  final text = (m.text ?? '').trim().replaceAll('\n', ' ');
  switch (m.kind) {
    case MessageKind.text:
    case MessageKind.system:
      return text;
    case MessageKind.image:
      return text.isEmpty ? s.t('previewImage') : '${s.t('previewImage')} $text';
    case MessageKind.gif:
      return text.isEmpty ? s.t('previewGif') : '${s.t('previewGif')} $text';
    case MessageKind.video:
      return s.t('previewVideo');
    case MessageKind.file:
      return '${s.t('previewFile')} ${att?.name ?? ''}'.trim();
    case MessageKind.voice:
      return s.t('previewVoice');
    case MessageKind.sticker:
      return s.t('previewSticker');
    case MessageKind.link:
      final title = att?.name ?? m.linkPreview?.title ?? (text.isNotEmpty ? text : att?.url ?? '');
      return '${s.t('previewLink')} $title'.trim();
    case MessageKind.card:
      return s.t('previewContact', [m.card?.displayName ?? '']);
    case MessageKind.bankCard:
      final card = m.bankCard;
      if (card == null) return text.isEmpty ? s.t('unsupportedMessage') : text;
      final bank = (card.bankName ?? '').trim();
      return s.t('previewBankCard', [bank.isEmpty ? card.accountNumber : bank]);
    case MessageKind.location:
      final location = m.location;
      if (location == null) return text.isEmpty ? s.t('unsupportedMessage') : text;
      final name = (location.name ?? '').trim();
      return s.t('previewLocation', [name.isEmpty ? '${location.lat}, ${location.lng}' : name]);
    case MessageKind.poll:
      final poll = m.poll;
      if (poll == null) return text.isEmpty ? s.t('unsupportedMessage') : text;
      return s.t('previewPoll', [poll.question]);
    case MessageKind.note:
      final note = m.note;
      if (note == null) return text.isEmpty ? s.t('unsupportedMessage') : text;
      return s.t('previewNote', [note.title]);
    case MessageKind.reminder:
      final reminder = m.reminder;
      if (reminder == null) return text.isEmpty ? s.t('unsupportedMessage') : text;
      return s.t('previewReminder', [reminder.title]);
    case MessageKind.call:
      final call = m.callLog;
      if (call == null) return text.isEmpty ? s.t('unsupportedMessage') : text;
      return s.t(call.missed == true ? 'previewCallMissed' : 'previewCall');
    case MessageKind.doodle:
      if (m.doodle == null) return text.isEmpty ? s.t('unsupportedMessage') : text;
      return s.t('previewDoodle');
    case MessageKind.album:
      final album = m.album;
      if (album == null) return text.isEmpty ? s.t('unsupportedMessage') : text;
      return s.t('previewAlbum', [album.items.length]);
    case MessageKind.todo:
      final todo = m.todo;
      if (todo == null) return text.isEmpty ? s.t('unsupportedMessage') : text;
      return s.t('previewTodo', [todo.title]);
    case MessageKind.other:
      return text.isEmpty ? s.t('unsupportedMessage') : text;
  }
}

String threadPreview(Thread t, S s) {
  final m = t.lastMessage;
  if (m == null) return '';
  final body = messageSummary(m, s);
  if (m.kind == MessageKind.system ||
      m.recalled && !m.isSelf && t.type == ThreadType.user) {
    return body;
  }
  if (m.isSelf) return s.t('previewYou', [body]);
  if (t.type == ThreadType.group && m.senderName.isNotEmpty) {
    return '${shortName(m.senderName)}: $body';
  }
  return body;
}

String statusLabel(AccountStatus status, S s) => switch (status) {
      AccountStatus.starting => s.t('statusConnecting'),
      AccountStatus.online => s.t('statusOnline'),
      AccountStatus.reconnecting => s.t('statusConnecting'),
      AccountStatus.displaced => s.t('statusDisplaced'),
      AccountStatus.needsLogin => s.t('statusNeedsLogin'),
      AccountStatus.offline => s.t('statusOffline'),
      AccountStatus.error => s.t('statusError'),
    };

/// Splits a fingerprint or code into short groups that are easy to compare.
List<String> codeGroups(String value) {
  final trimmed = value.trim();
  if (trimmed.contains(RegExp(r'[\s:-]'))) {
    return trimmed.split(RegExp(r'[\s:-]+')).where((g) => g.isNotEmpty).toList();
  }
  return [for (var i = 0; i < trimmed.length; i += 4) trimmed.substring(i, i + 4 > trimmed.length ? trimmed.length : i + 4)];
}

String fileExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 && dot < name.length - 1 ? name.substring(dot + 1).toLowerCase() : '';
}

/// Middle ellipsis that keeps the extension visible.
String middleEllipsis(String name, int max) {
  if (name.length <= max) return name;
  final ext = fileExtension(name);
  final tail = ext.isEmpty ? name.substring(name.length - 4) : name.substring(name.length - ext.length - 4);
  final head = name.substring(0, (max - tail.length - 1).clamp(1, name.length));
  return '$head\u2026$tail';
}

MessageKind kindForFileName(String name) {
  final ext = fileExtension(name);
  if (ext == 'gif') return MessageKind.gif;
  if (const {'jpg', 'jpeg', 'png', 'webp', 'heic', 'bmp'}.contains(ext)) {
    return MessageKind.image;
  }
  if (const {'mp4', 'mov', 'mkv', 'webm', 'avi', '3gp'}.contains(ext)) {
    return MessageKind.video;
  }
  return MessageKind.file;
}

final _urlPattern = RegExp(r'(https?://[^\s<>]+[^\s<>.,;:!?)\]}"])', caseSensitive: false);

Iterable<RegExpMatch> urlMatches(String text) => _urlPattern.allMatches(text);

final _emojiOnly = RegExp(
  r'^(?:[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}\u{1F1E6}-\u{1F1FF}]|\s)+$',
  unicode: true,
);

/// True for a message made of one to three emoji and nothing else.
bool isEmojiOnly(String text) {
  final t = text.trim();
  if (t.isEmpty || !_emojiOnly.hasMatch(t)) return false;
  final count = t.runes.where((r) => r != 0xFE0F && r != 0x200D && r > 0x20).length;
  return count >= 1 && count <= 3;
}
