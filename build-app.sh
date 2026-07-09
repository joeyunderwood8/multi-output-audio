#!/bin/sh
# Build "Multi-Output Audio.app" — a menu-bar GUI for playing Mac audio to
# several output devices at once.
set -e
cd "$(dirname "$0")"

APP="Multi-Output Audio.app"
BIN="$APP/Contents/MacOS/Multi-Output Audio"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "Compiling…"
swiftc -O -parse-as-library MultiOutputAudioApp.swift -o "$BIN" \
    -framework SwiftUI -framework AppKit -framework CoreAudio

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Multi-Output Audio</string>
    <key>CFBundleDisplayName</key><string>Multi-Output Audio</string>
    <key>CFBundleIdentifier</key><string>com.multioutputaudio.app</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Multi-Output Audio</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS runs the locally-built app without fuss.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built \"$APP\""
echo "Launch it with:  open \"./$APP\""
