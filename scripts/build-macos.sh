#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
APP="$(pwd)/dist/Translator.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
go build -trimpath -ldflags='-s -w' -o "$APP/Contents/MacOS/Translator" ./cmd/translator
swiftc -O -swift-version 5 native/macos/main.swift native/macos/PetHUD.swift native/macos/DraftWriter.swift -o "$APP/Contents/MacOS/translator-bridge"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Translator</string>
<key>CFBundleDisplayName</key><string>Translator</string>
<key>CFBundleIdentifier</key><string>local.translator.codex</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleExecutable</key><string>Translator</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAccessibilityUsageDescription</key><string>读取并替换你主动开启翻译的 Codex 消息草稿。</string>
</dict></plist>
PLIST
TRANSLATOR_SIGNING_IDENTITY="${TRANSLATOR_SIGNING_IDENTITY:--}"
codesign --force --sign "$TRANSLATOR_SIGNING_IDENTITY" --identifier local.translator.codex.bridge "$APP/Contents/MacOS/translator-bridge"
codesign --force --sign "$TRANSLATOR_SIGNING_IDENTITY" "$APP"
printf 'Built: %s\n' "$APP"
