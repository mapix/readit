#!/bin/bash
# Build Readit.app and install it into /Applications.
#
#   ./build_app.sh                      universal (Apple Silicon + Intel) when the toolchain allows, else native
#   UNIVERSAL=0 ./build_app.sh          native architecture only (faster)
#   INSTALL=0 ./build_app.sh            don't copy into /Applications
#
# Optional distribution signing + notarization (needs an Apple Developer account):
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=readit-notary \      # created once with: xcrun notarytool store-credentials readit-notary …
#   ./build_app.sh
set -e
cd "$(dirname "$0")"
VERSION=$(cat VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

BIN=""
if [ "${UNIVERSAL:-1}" = "1" ]; then
  if swift build -c release --arch arm64 --arch x86_64 2>/tmp/readit-universal.log; then
    BIN=.build/apple/Products/Release/Readit
    echo "built universal binary (arm64 + x86_64)"
  else
    echo "universal build unavailable (needs full Xcode) — building for this Mac only; see /tmp/readit-universal.log"
  fi
fi
if [ -z "$BIN" ]; then
  swift build -c release
  BIN=.build/release/Readit
fi

APP=build/Readit.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Readit"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# web import: Mozilla Readability + Readit's article extractor (loaded by WebImporter)
mkdir -p "$APP/Contents/Resources/web"
cp Resources/web/*.js "$APP/Contents/Resources/web/"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Readit</string>
<key>CFBundleDisplayName</key><string>Readit</string>
<key>CFBundleIdentifier</key><string>local.bireader.app</string>
<key>CFBundleVersion</key><string>${BUILD}</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleExecutable</key><string>Readit</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>AI 解读时按住麦克风语音提问 / Hold the mic to ask questions during AI narration</string>
<key>NSSpeechRecognitionUsageDescription</key><string>把你的语音提问转成文字 / Turns your spoken question into text</string>
<key>NSAppTransportSecurity</key><dict>
  <!-- model gateways and TTS servers are user-configured: allow http:// (Ollama, LM Studio, LAN servers) -->
  <key>NSAllowsArbitraryLoads</key><true/>
  <key>NSAllowsLocalNetworking</key><true/>
</dict>
<key>CFBundleDocumentTypes</key><array>
<dict>
  <key>CFBundleTypeName</key><string>PDF</string>
  <key>CFBundleTypeRole</key><string>Editor</string>
  <key>LSHandlerRank</key><string>Default</string>
  <key>CFBundleTypeExtensions</key><array><string>pdf</string></array>
  <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
</dict>
<dict>
  <key>CFBundleTypeName</key><string>Document</string>
  <key>CFBundleTypeRole</key><string>Viewer</string>
  <key>LSHandlerRank</key><string>Alternate</string>
  <key>CFBundleTypeExtensions</key><array><string>epub</string><string>md</string><string>markdown</string><string>docx</string><string>doc</string><string>rtf</string><string>html</string><string>htm</string><string>txt</string></array>
  <key>LSItemContentTypes</key><array><string>org.idpf.epub-container</string><string>net.daringfireball.markdown</string><string>org.openxmlformats.wordprocessingml.document</string><string>com.microsoft.word.doc</string><string>public.rtf</string><string>public.html</string><string>public.plain-text</string></array>
</dict>
</array>
</dict></plist>
P

cat > build/readit.entitlements <<E
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
E

if [ -n "${DEVELOPER_ID:-}" ]; then
  echo "signing with: $DEVELOPER_ID (hardened runtime)"
  codesign --force --deep --options runtime --timestamp --entitlements build/readit.entitlements -s "$DEVELOPER_ID" "$APP"
else
  codesign --force --deep -s - "$APP"     # ad-hoc: fine locally, Gatekeeper asks on other Macs
fi

# distributable zip (used by the landing page download)
mkdir -p dist
rm -f "dist/Readit-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/Readit-$VERSION.zip"

if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "notarizing (this takes a few minutes)…"
  xcrun notarytool submit "dist/Readit-$VERSION.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "dist/Readit-$VERSION.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/Readit-$VERSION.zip"
  spctl --assess --type execute -v "$APP" || true
fi
echo "packaged dist/Readit-$VERSION.zip"

if [ "${INSTALL:-1}" = "1" ]; then
  # register with LaunchServices so Finder offers Readit in "Open With"
  rm -rf /Applications/BiReader.app /Applications/Readit.app
  cp -R "$APP" /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Readit.app >/dev/null 2>&1 || true
  echo "installed /Applications/Readit.app"
fi
