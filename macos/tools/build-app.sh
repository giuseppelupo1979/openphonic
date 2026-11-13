#!/bin/bash
# Builds dist/OpenPhonic.app: release binary + DeepFilterNet + RNNoise model + icon, signed.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
WEB="$ROOT/../web"
APP="$ROOT/dist/OpenPhonic.app"
VERSION="$(head -1 "$ROOT/../VERSION" 2>/dev/null || echo 1.0.0)"

# build outside the project folder (avoids SwiftPM build-database locking issues on synced folders)
SCRATCH="${BUILD_DIR:-${TMPDIR:-/tmp}/openphonic-build}"
swift build -c release --scratch-path "$SCRATCH"
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/OpenPhonic"

# DeepFilterNet + RNNoise model: reuse the web version's downloads, fetch them if missing
if ! ls "$WEB"/bin/deep-filter-* >/dev/null 2>&1; then
  mkdir -p "$WEB/bin"
  curl -fL -o "$WEB/bin/deep-filter-0.5.6-aarch64-apple-darwin" \
    https://github.com/Rikorose/DeepFilterNet/releases/download/v0.5.6/deep-filter-0.5.6-aarch64-apple-darwin
  chmod +x "$WEB"/bin/deep-filter-*
fi
if [ ! -f "$WEB/models/std.rnnn" ]; then
  mkdir -p "$WEB/models"
  curl -fL -o "$WEB/models/std.rnnn" \
    https://raw.githubusercontent.com/GregorR/rnnoise-models/master/somnolent-hogwash-2018-09-01/sh.rnnn
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OpenPhonic"
cp "$(ls "$WEB"/bin/deep-filter-*aarch64-apple-darwin | head -1)" "$APP/Contents/Resources/deep-filter"
cp "$WEB/models/std.rnnn" "$APP/Contents/Resources/std.rnnn"

# icon
swift tools/make-icon.swift dist/icon-1024.png
ICONSET="$ROOT/dist/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s dist/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) dist/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OpenPhonic</string>
  <key>CFBundleDisplayName</key><string>OpenPhonic</string>
  <key>CFBundleIdentifier</key><string>net.giuseppelupo.openphonic</string>
  <key>CFBundleExecutable</key><string>OpenPhonic</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSpeechRecognitionUsageDescription</key><string>OpenPhonic trascrive il parlato sul tuo Mac per creare testo e sottotitoli.</string>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSItemContentTypes</key><array><string>public.audio</string><string>public.movie</string></array>
  </dict></array>
</dict>
</plist>
PLIST

# sign: Apple Development identity if present, otherwise ad-hoc
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
SIGN="${IDENTITY:--}"
codesign --force --options runtime --timestamp=none -s "$SIGN" "$APP/Contents/Resources/deep-filter"
codesign --force --options runtime --timestamp=none -s "$SIGN" "$APP"
codesign --verify --deep --strict "$APP"
# release package for the self-updater
rm -f dist/OpenPhonic-macos.zip
ditto -c -k --keepParent "$APP" dist/OpenPhonic-macos.zip
echo "OK: $APP $VERSION (firma: ${IDENTITY:-ad-hoc})"
