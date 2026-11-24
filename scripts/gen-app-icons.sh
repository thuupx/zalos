#!/usr/bin/env bash
# Generate every platform app icon and the in-app logo assets from
# assets/logo/zalos-icon.svg. Uses only tools that ship with macOS plus
# Google Chrome (headless) for SVG rendering with transparency; falls back to
# qlmanage (opaque) when Chrome is missing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/assets/logo/zalos-icon.svg"
MARK="$ROOT/assets/logo/zalos-mark.svg"
CLIENT="$ROOT/client"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

render() { # render <svg> <png> <size>
  local svg="$1" png="$2" size="$3"
  if [ -x "$CHROME" ]; then
    cat > "$TMP/page.html" <<HTML
<!doctype html><html><body style="margin:0;background:transparent"><img src="file://$svg" width="$size" height="$size" style="display:block"></body></html>
HTML
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
      --default-background-color=00000000 --window-size="$size,$size" \
      --screenshot="$png" "file://$TMP/page.html" >/dev/null 2>&1
  else
    qlmanage -t -s "$size" -o "$TMP" "$svg" >/dev/null 2>&1
    mv "$TMP/$(basename "$svg").png" "$png"
  fi
}

resize() { sips -z "$3" "$3" "$1" --out "$2" >/dev/null; }

GLYPHS="$(grep '<path' "$SRC")"
DEFS='<defs><linearGradient id="g" x1="0" y1="1" x2="1" y2="0"><stop offset="0" stop-color="#7A2A1B"/><stop offset="1" stop-color="#B4533A"/></linearGradient></defs>'

# Full bleed square (iOS, maskable web icons): no rounded corners, no alpha.
cat > "$TMP/square.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">$DEFS<rect width="1024" height="1024" fill="url(#g)"/>$GLYPHS</svg>
SVG
# macOS: the rounded square sits inside the 1024 canvas with the system margin.
cat > "$TMP/macos.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="-100 -100 1224 1224">$DEFS<rect width="1024" height="1024" rx="228" fill="url(#g)"/>$GLYPHS</svg>
SVG
# Android adaptive foreground: glyphs only, inside the 66 percent safe zone.
cat > "$TMP/foreground.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="-300 -300 1624 1624">$GLYPHS</svg>
SVG
# Maskable web icon: glyphs inside the 80 percent safe zone on the gradient.
cat > "$TMP/maskable.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">$DEFS<rect width="1024" height="1024" fill="url(#g)"/><g transform="translate(128 128) scale(0.75)">$GLYPHS</g></svg>
SVG

render "$SRC" "$TMP/icon.png" 1024
render "$TMP/square.svg" "$TMP/square.png" 1024
render "$TMP/macos.svg" "$TMP/macos.png" 1024
render "$TMP/foreground.svg" "$TMP/foreground.png" 432
render "$TMP/maskable.svg" "$TMP/maskable.png" 512
render "$MARK" "$TMP/mark.png" 512

# In-app assets.
mkdir -p "$CLIENT/assets/logo"
resize "$TMP/icon.png" "$CLIENT/assets/logo/zalos-icon.png" 288
resize "$TMP/mark.png" "$CLIENT/assets/logo/zalos-mark.png" 288

# macOS.
MAC="$CLIENT/macos/Runner/Assets.xcassets/AppIcon.appiconset"
for s in 16 32 64 128 256 512 1024; do resize "$TMP/macos.png" "$MAC/app_icon_$s.png" "$s"; done

# iOS (opaque).
IOS="$CLIENT/ios/Runner/Assets.xcassets/AppIcon.appiconset"
ios() { resize "$TMP/square.png" "$IOS/$1" "$2"; }
ios Icon-App-1024x1024@1x.png 1024
ios Icon-App-20x20@1x.png 20;  ios Icon-App-20x20@2x.png 40;  ios Icon-App-20x20@3x.png 60
ios Icon-App-29x29@1x.png 29;  ios Icon-App-29x29@2x.png 58;  ios Icon-App-29x29@3x.png 87
ios Icon-App-40x40@1x.png 40;  ios Icon-App-40x40@2x.png 80;  ios Icon-App-40x40@3x.png 120
ios Icon-App-60x60@2x.png 120; ios Icon-App-60x60@3x.png 180
ios Icon-App-76x76@1x.png 76;  ios Icon-App-76x76@2x.png 152
ios Icon-App-83.5x83.5@2x.png 167

# Android: legacy launcher icons plus the adaptive icon.
RES="$CLIENT/android/app/src/main/res"
for pair in mdpi:48:108 hdpi:72:162 xhdpi:96:216 xxhdpi:144:324 xxxhdpi:192:432; do
  IFS=: read -r density legacy fg <<<"$pair"
  mkdir -p "$RES/mipmap-$density"
  resize "$TMP/icon.png" "$RES/mipmap-$density/ic_launcher.png" "$legacy"
  resize "$TMP/foreground.png" "$RES/mipmap-$density/ic_launcher_foreground.png" "$fg"
done
mkdir -p "$RES/mipmap-anydpi-v26" "$RES/values"
cat > "$RES/mipmap-anydpi-v26/ic_launcher.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
XML
cat > "$RES/values/ic_launcher_background.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#8E3524</color>
</resources>
XML

# Web: favicon and manifest icons.
WEB="$CLIENT/web"
resize "$TMP/icon.png" "$WEB/favicon.png" 48
resize "$TMP/icon.png" "$WEB/icons/Icon-192.png" 192
resize "$TMP/icon.png" "$WEB/icons/Icon-512.png" 512
resize "$TMP/maskable.png" "$WEB/icons/Icon-maskable-192.png" 192
resize "$TMP/maskable.png" "$WEB/icons/Icon-maskable-512.png" 512

# Linux: icon installed next to the bundle data.
mkdir -p "$CLIENT/linux/assets"
resize "$TMP/icon.png" "$CLIENT/linux/assets/zalos.png" 256

# Windows: multi-size ico with embedded PNG entries.
for s in 16 24 32 48 64 128 256; do resize "$TMP/icon.png" "$TMP/ico-$s.png" "$s"; done
python3 - "$TMP" "$CLIENT/windows/runner/resources/app_icon.ico" <<'PY'
import struct, sys
tmp, out = sys.argv[1], sys.argv[2]
sizes = [16, 24, 32, 48, 64, 128, 256]
blobs = [open(f"{tmp}/ico-{s}.png", "rb").read() for s in sizes]
header = struct.pack("<HHH", 0, 1, len(sizes))
offset = 6 + 16 * len(sizes)
entries = b""
for s, b in zip(sizes, blobs):
    entries += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(b), offset)
    offset += len(b)
open(out, "wb").write(header + entries + b"".join(blobs))
PY

echo "icons generated from $SRC"
