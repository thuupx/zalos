// Phase D: inline text styles of the composer and of incoming messages.
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../domain/models.dart';
import '../theme/tokens.dart';

/// Style codes the composer offers as toggles.
const List<String> composerStyleCodes = ['b', 'i', 'u', 's'];

/// [base] with the inline contributions of [codes] applied. List markers
/// (`lst_*`) and the indent marker (`ind_$`) are block layout hints and are
/// ignored here, so a newer server cannot break a bubble.
TextStyle applyStyleRuns(TextStyle base, Iterable<String> codes, ZalosTokens z) {
  var bold = false;
  var italic = false;
  var underline = false;
  var strike = false;
  Color? color;
  double? size;
  for (final code in codes) {
    switch (code) {
      case 'b':
        bold = true;
      case 'i':
        italic = true;
      case 'u':
        underline = true;
      case 's':
        strike = true;
      case 'c_db342e':
        color = z.danger;
      case 'c_f27806':
        color = z.warning;
      case 'c_f7b503':
        color = z.accentText;
      case 'c_15a85f':
        color = z.success;
      case 'f_13':
        size = z.text.meta.fontSize;
      case 'f_18':
        size = z.text.title.fontSize;
    }
  }
  final decorations = <TextDecoration>[];
  void add(TextDecoration decoration) {
    if (!decorations.contains(decoration)) decorations.add(decoration);
  }

  final existing = base.decoration;
  if (existing != null) {
    for (final decoration in const [TextDecoration.underline, TextDecoration.lineThrough, TextDecoration.overline]) {
      if (existing.contains(decoration)) add(decoration);
    }
  }
  if (underline) add(TextDecoration.underline);
  if (strike) add(TextDecoration.lineThrough);
  return base
      .copyWith(
        fontWeight: bold ? FontWeight.w700 : null,
        fontStyle: italic ? FontStyle.italic : null,
        decoration: decorations.isEmpty ? null : TextDecoration.combine(decorations),
        decorationColor: color,
        color: color,
      )
      .apply(fontSizeFactor: size == null ? 1.0 : size / base.fontSize!);
}

/// True when [start]..[end] is fully covered by runs of [st].
bool styleRunsCover(List<StyleRun> runs, String st, int start, int end) {
  if (end <= start) return false;
  final intervals = <(int, int)>[
    for (final run in runs)
      if (run.st == st && run.len > 0) (run.start, run.start + run.len),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  var cursor = start;
  for (final (from, to) in intervals) {
    if (to <= cursor) continue;
    if (from > cursor) break;
    cursor = math.max(cursor, to);
    if (cursor >= end) return true;
  }
  return false;
}

/// Adds [st] over [start]..[end], or removes it when the range is already
/// covered.
List<StyleRun> toggleStyleRun(List<StyleRun> runs, String st, int start, int end, {int? textLength}) {
  var from = math.min(start, end);
  var to = math.max(start, end);
  if (textLength != null) {
    from = from.clamp(0, textLength);
    to = to.clamp(0, textLength);
  }
  if (to <= from) return runs;
  final covered = styleRunsCover(runs, st, from, to);
  final next = <StyleRun>[];
  for (final run in runs) {
    final runEnd = run.start + run.len;
    if (run.st != st || runEnd <= from || run.start >= to) {
      next.add(run);
      continue;
    }
    if (run.start < from) next.add(StyleRun(start: run.start, len: from - run.start, st: run.st, indentSize: run.indentSize));
    if (runEnd > to) next.add(StyleRun(start: to, len: runEnd - to, st: run.st, indentSize: run.indentSize));
  }
  if (!covered) next.add(StyleRun(start: from, len: to - from, st: st));
  next.sort((a, b) => a.start.compareTo(b.start));
  return _mergeRuns(next);
}

class _TextChange {
  const _TextChange(this.prefix, this.removed, this.inserted);
  final int prefix;
  final int removed;
  final int inserted;
  int get delta => inserted - removed;
}

_TextChange _textChange(String oldText, String newText) {
  final oldLength = oldText.length;
  final newLength = newText.length;
  var prefix = 0;
  final maxPrefix = math.min(oldLength, newLength);
  while (prefix < maxPrefix && oldText.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
    prefix++;
  }
  var suffix = 0;
  final maxSuffix = math.min(oldLength - prefix, newLength - prefix);
  while (suffix < maxSuffix && oldText.codeUnitAt(oldLength - 1 - suffix) == newText.codeUnitAt(newLength - 1 - suffix)) {
    suffix++;
  }
  return _TextChange(prefix, oldLength - prefix - suffix, newLength - prefix - suffix);
}

/// Moves the ranges of [runs] from [oldText] to [newText] using the changed
/// region between the common prefix and suffix.
List<StyleRun> shiftStyleRuns(List<StyleRun> runs, String oldText, String newText) {
  if (runs.isEmpty || oldText == newText) return runs;
  final change = _textChange(oldText, newText);
  int map(int position) {
    if (position <= change.prefix) return position;
    if (position >= change.prefix + change.removed) return position + change.delta;
    return change.prefix + change.inserted;
  }

  final out = <StyleRun>[];
  for (final run in runs) {
    final start = map(run.start);
    final end = map(run.start + run.len);
    if (end <= start) continue;
    out.add(StyleRun(start: start, len: end - start, st: run.st, indentSize: run.indentSize));
  }
  return out;
}

/// New offset of [offset] after [oldText] became [newText]. Unlike a style
/// run, a token that starts exactly at an insertion point moves right, so a
/// mention keeps its `@` when text is typed before it.
int shiftTextOffset(int offset, String oldText, String newText) {
  if (oldText == newText) return offset;
  final change = _textChange(oldText, newText);
  if (offset < change.prefix) return offset;
  if (offset >= change.prefix + change.removed) return offset + change.delta;
  return change.prefix + change.inserted;
}

List<StyleRun> _mergeRuns(List<StyleRun> runs) {
  final out = <StyleRun>[];
  for (final run in runs) {
    if (run.len <= 0) continue;
    if (out.isNotEmpty) {
      final last = out.last;
      final lastEnd = last.start + last.len;
      if (last.st == run.st && last.indentSize == run.indentSize && run.start <= lastEnd) {
        out[out.length - 1] = StyleRun(
          start: last.start,
          len: math.max(lastEnd, run.start + run.len) - last.start,
          st: last.st,
          indentSize: last.indentSize,
        );
        continue;
      }
    }
    out.add(run);
  }
  return out;
}
