#!/usr/bin/env bash
# Build release and wrap it into build/Dictate.app.
# Signing: ad-hoc by default. Ad-hoc builds get a new identity on every rebuild,
# so macOS asks for Microphone/Accessibility again. Sign with a stable identity
# to keep the grants, e.g.
#   SIGN_ID="Apple Development: <Name> (<TEAMID>)" scripts/bundle.sh
# Heavy: run via `slot run gh-dictate-orch "bundle" -- scripts/bundle.sh`.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v disk-guard >/dev/null && { disk-guard 5 || { echo "low disk"; exit 1; }; }
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

swift build -c release --product Dictate
BIN="$(swift build -c release --show-bin-path)"

APP="build/Dictate.app"
mkdir -p build
# Replace the previous bundle in place (build output only).
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Dictate" "$APP/Contents/MacOS/Dictate"

# App icon from the committed master (regenerate with: swift scripts/make-icon.swift).
ICON_SRC="Resources/AppIcon-1024.png"
ICON_KEY=""
if [ -f "$ICON_SRC" ]; then
  SET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$SET"
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz "$ICON_SRC" --out "$SET/icon_${sz}x${sz}.png" >/dev/null
    sips -z $((sz*2)) $((sz*2)) "$ICON_SRC" --out "$SET/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY="  <key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.mclee.dictate</string>
  <key>CFBundleName</key><string>Dictate</string>
  <key>CFBundleDisplayName</key><string>Dictate</string>
  <key>CFBundleExecutable</key><string>Dictate</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
$ICON_KEY
  <key>NSMicrophoneUsageDescription</key><string>Dictate 需要麥克風來錄下你的語音並轉成文字。</string>
</dict>
</plist>
PLIST

if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --options runtime --entitlements scripts/Dictate.entitlements -s "$SIGN_ID" "$APP"
  echo "signed: $SIGN_ID"
else
  codesign --force --options runtime --entitlements scripts/Dictate.entitlements -s - "$APP"
  echo "signed: ad-hoc"
fi
codesign --verify --strict "$APP"
echo "built: $APP"
