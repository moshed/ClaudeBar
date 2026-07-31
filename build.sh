#!/bin/bash
# Build ClaudeBar.app — a signed menu bar agent (LSUIElement). A real bundle is
# required for native UNUserNotificationCenter banners (own icon, own click handler).
set -e
cd "$(dirname "$0")"

APP="ClaudeBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist  "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

xcrun swiftc -O Prefs.swift Settings.swift main.swift -o "$APP/Contents/MacOS/ClaudeBar"

# Ad-hoc sign so macOS will deliver notifications to it.
codesign --force --deep --sign - "$APP"

echo "Built + signed: $(pwd)/$APP"
