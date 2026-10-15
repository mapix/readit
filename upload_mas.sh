#!/bin/bash
# Validate and upload the App Store package to App Store Connect.
# Uses an App Store Connect API key (Users and Access → Integrations → App Store Connect API):
#   ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=xxxxxxxx-xxxx-… ./upload_mas.sh dist/Readlet-1.0.0-AppStore.pkg
# The .p8 key file must be at ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
# (Alternative: open the .pkg with Apple's Transporter app.)
set -e
PKG=${1:?usage: ./upload_mas.sh dist/Readlet-<version>-AppStore.pkg}
: "${ASC_KEY_ID:?set ASC_KEY_ID}"; : "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
xcrun altool --validate-app -f "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
xcrun altool --upload-app   -f "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
echo "uploaded — the build appears in App Store Connect → TestFlight after processing (10–30 min)"
