{{flutter_js}}
{{flutter_build_config}}

// Color emoji instead of the default monochrome Noto Emoji fallback, so
// emoji and reactions look the same as on the native platforms.
_flutter.loader.load({
  config: {
    useColorEmoji: true,
  },
});
