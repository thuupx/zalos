import 'package:flutter/widgets.dart';

import 'strings_en.dart';
import 'strings_vi.dart';

/// Hand-rolled string table: Vietnamese first, English second.
class S {
  const S(this.language);

  final String language;

  static const supported = ['vi', 'en'];
  static const Map<String, String> vi = stringsVi;
  static const Map<String, String> en = stringsEn;

  Map<String, String> get _table => language == 'en' ? en : vi;

  String t(String key, [List<Object?> args = const []]) {
    var value = _table[key] ?? vi[key];
    assert(value != null, 'missing string: $key');
    value ??= key;
    for (var i = 0; i < args.length; i++) {
      value = value!.replaceAll('{$i}', '${args[i]}');
    }
    return value!;
  }
}

class StringsScope extends InheritedWidget {
  const StringsScope({super.key, required this.strings, required super.child});

  final S strings;

  static S of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<StringsScope>()?.strings ?? const S('vi');

  @override
  bool updateShouldNotify(StringsScope oldWidget) => oldWidget.strings.language != strings.language;
}

extension StringsContext on BuildContext {
  S get s => StringsScope.of(this);
  String tr(String key, [List<Object?> args = const []]) => StringsScope.of(this).t(key, args);
}
