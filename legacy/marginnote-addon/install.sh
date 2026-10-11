#!/bin/bash
# Install the add-on into MarginNote 3 and (re)start the app.
set -e
EXT=~/Library/Containers/QReader.MarginStudyMac/Data/Library/"MarginNote Extensions"
DST="$EXT/marginnote.extension.immersivetranslate"
osascript -e 'quit app "MarginNote 3"' >/dev/null 2>&1 || true; sleep 2
mkdir -p "$DST/cache"
cp -R src/main.js src/panel.html src/logo.png src/mnaddon.json src/vendor src/bilingual.js "$DST/"
defaults write QReader.MarginStudyMac mindbooks_allowuncertifiedext -bool true
[ -n "$ANTHROPIC_AUTH_TOKEN" ] && defaults write QReader.MarginStudyMac imt_apiKey "$ANTHROPIC_AUTH_TOKEN"
[ -n "$ANTHROPIC_BASE_URL" ] && defaults write QReader.MarginStudyMac imt_baseURL "$ANTHROPIC_BASE_URL"
(cd src && rm -f ../ImmersiveTranslate.mnaddon && zip -qr ../ImmersiveTranslate.mnaddon main.js panel.html logo.png mnaddon.json vendor bilingual.js)
echo installed to "$DST"
