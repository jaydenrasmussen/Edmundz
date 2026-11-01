#!/bin/sh
# Developer ID signing, notarization and stapling for the DIRECT channel.
# Needs: DEVELOPER_ID  ("Developer ID Application: Name (TEAMID)")
#        NOTARY_PROFILE (a keychain profile created with: xcrun notarytool store-credentials)
set -eu
cd "$(dirname "$0")/.."
: "${DEVELOPER_ID:?set DEVELOPER_ID}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE}"
SIGN_IDENTITY="$DEVELOPER_ID" scripts/bundle.sh direct
scripts/dmg.sh
codesign --force --timestamp --sign "$DEVELOPER_ID" build/Edmundz.dmg
xcrun notarytool submit build/Edmundz.dmg --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple build/Edmundz.dmg
spctl --assess --type open --context context:primary-signature -v build/Edmundz.dmg
echo "notarized build/Edmundz.dmg"
