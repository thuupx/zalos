import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';
import '../theme/z_icons.dart';
import 'pressable.dart';

class ZTextField extends StatelessWidget {
  const ZTextField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.errorText,
    this.helperText,
    this.enabled = true,
    this.minLines = 1,
    this.maxLines = 1,
    this.suffix,
    this.prefixIcon,
    this.mono = false,
    this.autofocus = false,
    this.onSubmitted,
    this.onChanged,
    this.keyboardType,
    this.textInputAction,
    this.maxLength,
    this.focusNode,
    this.capitalization = TextCapitalization.none,
    this.autocorrect = true,
    this.obscure = false,
  });

  final TextEditingController controller;
  final String? label;
  final String? hint;
  final String? errorText;
  final String? helperText;
  final bool enabled;
  final int minLines;
  final int maxLines;
  final Widget? suffix;
  final IconData? prefixIcon;
  final bool mono;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final int? maxLength;
  final FocusNode? focusNode;
  final TextCapitalization capitalization;
  final bool autocorrect;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    final error = errorText != null;
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(borderRadius: BorderRadius.circular(ZRadius.input), borderSide: BorderSide(color: color, width: width));
    final style = mono ? z.text.mono(14, weight: FontWeight.w400) : z.text.body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.only(bottom: ZSpace.s4),
            child: ExcludeSemantics(child: Text(label!, style: z.text.caption.copyWith(color: z.textSecondary))),
          ),
        TextField(
          controller: controller,
          focusNode: focusNode,
          enabled: enabled,
          autofocus: autofocus,
          minLines: minLines,
          maxLines: maxLines,
          maxLength: maxLength,
          onSubmitted: onSubmitted,
          onChanged: onChanged,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          textCapitalization: capitalization,
          autocorrect: autocorrect,
          obscureText: obscure,
          enableSuggestions: autocorrect && !obscure,
          style: style.copyWith(color: enabled ? z.textPrimary : z.textDisabled),
          cursorColor: z.brandText,
          decoration: InputDecoration(
            isDense: true,
            counterText: '',
            hintText: hint,
            semanticCounterText: '',
            labelText: null,
            hintStyle: style.copyWith(color: z.textTertiary),
            filled: true,
            fillColor: enabled ? z.layer : z.layerSubtle,
            contentPadding: EdgeInsets.symmetric(horizontal: ZSpace.s12, vertical: wide ? 10 : 12),
            prefixIcon: prefixIcon == null ? null : Icon(prefixIcon, size: 20, color: z.textTertiary),
            prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            suffixIcon: suffix,
            suffixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            border: border(z.border),
            enabledBorder: border(error ? z.danger : z.border),
            disabledBorder: border(z.divider),
            focusedBorder: border(error ? z.danger : z.focusRing, 1.5),
          ),
        ),
        if (error || helperText != null)
          Padding(
            padding: const EdgeInsets.only(top: ZSpace.s4),
            child: Semantics(
              liveRegion: error,
              child: Text(errorText ?? helperText!, style: z.text.caption.copyWith(color: error ? z.danger : z.textTertiary)),
            ),
          ),
      ],
    );
  }
}

class ZSearchField extends StatelessWidget {
  const ZSearchField({
    super.key,
    required this.controller,
    required this.hint,
    this.onChanged,
    this.onHeader = false,
    this.focusNode,
    this.clearLabel = '',
    this.autofocus = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final bool onHeader;
  final FocusNode? focusNode;
  final String clearLabel;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final wide = LayoutScope.wideOf(context);
    final fg = onHeader ? z.textOnBrand : z.textPrimary;
    final hintColor = onHeader ? z.textOnBrand.withValues(alpha: 0.85) : z.textTertiary;
    // The header tint is translucent. Over the light garnet gradient it leaves
    // the field surface uneven, which drops the contrast of the white text and
    // keeps Flutter's text contrast guideline from separating the glyphs from
    // the background shades. Compositing the tint onto the pressed brand tone
    // keeps the translucent look on one flat surface. The dark header is flat,
    // so its tint is already even.
    final fill = onHeader ? (z.dark ? z.headerField : Color.alphaBlend(z.headerField, z.brandPressed)) : z.layerSubtle;
    final radius = wide ? ZRadius.row : ZRadius.pill;
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: color, width: width));
    return SizedBox(
      height: wide ? 32 : ZSizes.touchTarget,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (controller.text.isNotEmpty) {
              controller.clear();
              onChanged?.call('');
            } else {
              (focusNode ?? FocusScope.of(context)).unfocus();
            }
          },
        },
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          autofocus: autofocus,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          textInputAction: TextInputAction.search,
          style: z.text.labelRegular.copyWith(color: fg),
          cursorColor: fg,
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: z.text.labelRegular.copyWith(color: hintColor),
            prefixIcon: Icon(ZIcons.search, color: hintColor, size: 18),
            prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 32),
            suffixIcon: ListenableBuilder(
              listenable: controller,
              builder: (context, _) => controller.text.isEmpty
                  ? const SizedBox.shrink()
                  : ZPressable(
                      circle: true,
                      semanticLabel: clearLabel,
                      tooltip: clearLabel,
                      hoverColor: onHeader ? z.headerField : null,
                      minSize: wide ? null : ZSizes.touchTarget,
                      onTap: () {
                        controller.clear();
                        onChanged?.call('');
                      },
                      child: SizedBox(width: 32, height: 32, child: Icon(ZIcons.close, color: hintColor, size: 16)),
                    ),
            ),
            suffixIconConstraints: BoxConstraints(minWidth: wide ? 32 : ZSizes.touchTarget, minHeight: 32),
            filled: true,
            fillColor: fill,
            hoverColor: ZalosTokens.clear,
            contentPadding: const EdgeInsets.symmetric(vertical: ZSpace.s8),
            border: border(ZalosTokens.clear),
            enabledBorder: border(onHeader ? ZalosTokens.clear : z.divider),
            focusedBorder: border(onHeader ? z.textOnBrand.withValues(alpha: 0.6) : z.focusRing, 1.5),
          ),
        ),
      ),
    );
  }
}
