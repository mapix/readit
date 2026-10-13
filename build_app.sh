#!/bin/bash
# Build Readit.app and install it into /Applications.
set -e
cd "$(dirname "$0")"
VERSION=$(cat VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
swift build -c release
APP=build/Readit.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Readit "$APP/Contents/MacOS/Readit"
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
<key>NSMicrophoneUsageDescription</key><string>AI 解读时按住麦克风语音提问</string>
<key>NSSpeechRecognitionUsageDescription</key><string>把你的语音提问转成文字</string>
<key>CFBundleDocumentTypes</key><array><dict>
  <key>CFBundleTypeName</key><string>PDF</string>
  <key>CFBundleTypeRole</key><string>Editor</string>
  <key>LSHandlerRank</key><string>Default</string>
  <key>CFBundleTypeExtensions</key><array><string>pdf</string></array>
  <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
</dict></array>
</dict></plist>
P
codesign --force --deep -s - "$APP"
# register with LaunchServices so Finder offers Readit in "Open With"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
rm -rf /Applications/BiReader.app /Applications/Readit.app
cp -R "$APP" /Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Readit.app >/dev/null 2>&1 || true
echo "installed /Applications/Readit.app"

# distributable zip (used by the landing page download)
mkdir -p dist
rm -f "dist/Readit-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/Readit-$VERSION.zip"
echo "packaged dist/Readit-$VERSION.zip"
