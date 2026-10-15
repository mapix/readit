#!/bin/bash
# Build Readlet.app.
#
# Direct-download edition (default): Developer ID / ad-hoc signed, installed into /Applications, zipped into dist/.
#   ./build_app.sh                      universal (Apple Silicon + Intel) when the toolchain allows, else native
#   UNIVERSAL=0 ./build_app.sh          native architecture only (faster)
#   INSTALL=0 ./build_app.sh            don't copy into /Applications
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=readlet-notary ./build_app.sh
#                                       sign with hardened runtime and notarize (Apple Developer account)
#
# Mac App Store edition: see build_mas.sh (sets MAS=1): sandboxed, no self-update, signed .pkg for upload.
set -e
cd "$(dirname "$0")"
VERSION=$(cat VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
MAS=${MAS:-0}
NAME=Readlet
BUNDLE_ID=io.novarock.readlet

SWIFT_FLAGS=()
[ "$MAS" = "1" ] && SWIFT_FLAGS=(-Xswiftc -DMAS)

BIN=""
if [ "${UNIVERSAL:-1}" = "1" ]; then
  if swift build -c release --arch arm64 --arch x86_64 "${SWIFT_FLAGS[@]}" 2>/tmp/readlet-universal.log; then
    BIN=.build/apple/Products/Release/$NAME
    echo "built universal binary (arm64 + x86_64)"
  else
    [ "$MAS" = "1" ] && { echo "!! the App Store build must be universal — install Xcode (see /tmp/readlet-universal.log)"; exit 1; }
    echo "universal build unavailable (needs full Xcode) — building for this Mac only; see /tmp/readlet-universal.log"
  fi
fi
if [ -z "$BIN" ]; then
  swift build -c release "${SWIFT_FLAGS[@]}"
  BIN=.build/release/$NAME
fi

OUT=build; [ "$MAS" = "1" ] && OUT=build/mas
APP=$OUT/$NAME.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
cp Resources/Acknowledgements.md "$APP/Contents/Resources/"
# web import / document conversion: Mozilla Readability, marked, Readlet's article extractor
mkdir -p "$APP/Contents/Resources/web"
cp Resources/web/*.js "$APP/Contents/Resources/web/"
# localized bundle names so Finder / the App Store list the languages
for l in en zh-Hans ja; do mkdir -p "$APP/Contents/Resources/$l.lproj"; printf '"CFBundleDisplayName" = "%s";\n' "$NAME" > "$APP/Contents/Resources/$l.lproj/InfoPlist.strings"; done

# build-environment keys App Store validation expects (normally added by Xcode)
SDK_VER=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo 14.0)
SDK_BUILD=$(xcrun --sdk macosx --show-sdk-build-version 2>/dev/null || echo "")
XC=$(xcodebuild -version 2>/dev/null | awk '/^Xcode/{print $2}' | tr -d . ; true)
XCB=$(xcodebuild -version 2>/dev/null | awk '/Build version/{print $3}'; true)
OSB=$(sw_vers -buildVersion 2>/dev/null || echo "")
[ ${#XC} -eq 2 ] && XC="${XC}00"; [ ${#XC} -eq 3 ] && XC="0${XC}"

cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundleDisplayName</key><string>$NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleVersion</key><string>${BUILD}</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleExecutable</key><string>$NAME</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>ja</string></array>
<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.education</string>
<key>NSHumanReadableCopyright</key><string>© 2026 Novarock. All rights reserved.</string>
<key>ITSAppUsesNonExemptEncryption</key><false/>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Hold the mic during AI narration to ask a question by voice. / AI 解读时按住麦克风语音提问。</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Turns your spoken question into text. / 把你的语音提问转成文字。</string>
<key>NSAppTransportSecurity</key><dict>
  <!-- model gateways and speech servers are configured by the user; local ones (Ollama, LM Studio) use http:// -->
  <key>NSAllowsArbitraryLoads</key><true/>
  <key>NSAllowsLocalNetworking</key><true/>
</dict>
<key>DTPlatformName</key><string>macosx</string>
<key>DTPlatformVersion</key><string>$SDK_VER</string>
<key>DTSDKName</key><string>macosx$SDK_VER</string>
<key>DTSDKBuild</key><string>$SDK_BUILD</string>
<key>DTXcode</key><string>$XC</string>
<key>DTXcodeBuild</key><string>$XCB</string>
<key>DTCompiler</key><string>com.apple.compilers.llvm.clang.1_0</string>
<key>BuildMachineOSBuild</key><string>$OSB</string>
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
printf 'APPL????' > "$APP/Contents/PkgInfo"

mkdir -p dist
if [ "$MAS" = "1" ]; then
  # ---------------------------------------------------------------- Mac App Store
  : "${MAS_APP_IDENTITY:?set MAS_APP_IDENTITY, e.g. \"Apple Distribution: Your Name (TEAMID)\"}"
  : "${MAS_INSTALLER_IDENTITY:?set MAS_INSTALLER_IDENTITY, e.g. \"3rd Party Mac Developer Installer: Your Name (TEAMID)\"}"
  : "${MAS_PROFILE:?set MAS_PROFILE to the Mac App Store provisioning profile (.provisionprofile) for $BUNDLE_ID}"
  : "${TEAM_ID:?set TEAM_ID (10 characters)}"
  cp "$MAS_PROFILE" "$APP/Contents/embedded.provisionprofile"
  sed -e "s/__TEAM_ID__/$TEAM_ID/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" Resources/Readlet-MAS.entitlements > build/mas/readlet.entitlements
  codesign --force --options runtime --timestamp --entitlements build/mas/readlet.entitlements -s "$MAS_APP_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  PKG="dist/$NAME-$VERSION-AppStore.pkg"
  rm -f "$PKG"
  productbuild --component "$APP" /Applications --sign "$MAS_INSTALLER_IDENTITY" "$PKG"
  echo "packaged $PKG"
  echo "next: ./upload_mas.sh $PKG    (or drag it into Transporter)"
  exit 0
fi

# -------------------------------------------------------------------- direct download
cat > build/readlet.entitlements <<E
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
E
if [ -n "${DEVELOPER_ID:-}" ]; then
  echo "signing with: $DEVELOPER_ID (hardened runtime)"
  codesign --force --deep --options runtime --timestamp --entitlements build/readlet.entitlements -s "$DEVELOPER_ID" "$APP"
else
  codesign --force --deep -s - "$APP"     # ad-hoc: fine locally, Gatekeeper asks on other Macs
fi

rm -f "dist/$NAME-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$NAME-$VERSION.zip"
if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "notarizing (this takes a few minutes)…"
  xcrun notarytool submit "dist/$NAME-$VERSION.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "dist/$NAME-$VERSION.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$NAME-$VERSION.zip"
  spctl --assess --type execute -v "$APP" || true
fi
echo "packaged dist/$NAME-$VERSION.zip"

if [ "${INSTALL:-1}" = "1" ]; then
  rm -rf /Applications/BiReader.app /Applications/Readit.app "/Applications/$NAME.app"
  cp -R "$APP" /Applications/
  # register with LaunchServices so Finder offers Readlet in "Open With"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$NAME.app" >/dev/null 2>&1 || true
  echo "installed /Applications/$NAME.app"
fi
