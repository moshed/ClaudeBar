#!/bin/bash
# Build ClaudeBar.app — a signed menu bar app (LSUIElement) and install it to
# /Applications. A real bundle is required for native UNUserNotificationCenter banners,
# and /Applications is where SMAppService expects a Login Item to live.
set -e
cd "$(dirname "$0")"

APP="ClaudeBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist  "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp claude_template.png claude_template@2x.png claude_template@3x.png "$APP/Contents/Resources/"

# -target is REQUIRED. On macOS 27 plain swiftc stamps the binary minos 28.0 and
# LaunchServices then refuses to open the app (-10825, no crash report).
# 26.0 because FoundationModels (the on-device summarizer) starts there.
xcrun swiftc -O -target arm64-apple-macos26.0 \
  Prefs.swift Icons.swift Usage.swift Settings.swift Switcher.swift main.swift -o "$APP/Contents/MacOS/ClaudeBar"

# Sign with a real identity, not ad-hoc. An ad-hoc signature changes on every build, so
# macOS forgets the "control Terminal" permission each time and asks again. No hardened
# runtime: it would need an extra Apple Events entitlement.
# Take whichever Apple Development identity is in the keychain. Hardcoding one
# breaks whenever a cert is replaced — the original left the keychain on
# 2026-10-15 — and an API-made cert carries the App Store Connect key id in its
# name, which should not sit in a public repo.
SIGN_ID=$(security find-identity -v -p codesigning | awk -F\" '/Apple Development:/ {print $2; exit}')
[ -n "$SIGN_ID" ] || { echo "no Apple Development signing identity in the keychain"; exit 1; }
codesign --force --deep --timestamp=none --sign "$SIGN_ID" "$APP"

vtool -show-build "$APP/Contents/MacOS/ClaudeBar" | grep -m1 minos

if [ "$1" != "--no-install" ]; then
  rm -rf /Applications/ClaudeBar.app
  ditto "$APP" /Applications/ClaudeBar.app
  echo "Installed: /Applications/ClaudeBar.app"
fi
echo "Built + signed: $(pwd)/$APP"
