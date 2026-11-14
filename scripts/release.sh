#!/bin/bash
# Builds Glint, signs it with a Developer ID certificate, has Apple notarize it,
# staples the ticket and writes build/Glint.zip, ready to attach to a release.
#
# One-time setup (stores your Apple credentials in the keychain, not in this repo):
#   xcrun notarytool store-credentials glint-notary --apple-id <you> --team-id <team>
#
# Options, as environment variables:
#   DEVID    signing identity (default: the first "Developer ID Application" in the keychain)
#   PROFILE  notarytool keychain profile (default: glint-notary)
#   SKIP_NOTARIZE=1  sign only, to test the signature
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${PROFILE:-glint-notary}"
DEVID="${DEVID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
[ -n "$DEVID" ] || { echo "No Developer ID Application certificate in the keychain."; exit 1; }

DD=build/release
APP="$DD/Build/Products/Release/Glint.app"
ZIP=build/Glint.zip

command -v xcodegen >/dev/null && xcodegen >/dev/null
# Build ad hoc (ignoring any Local.xcconfig), then re-sign for distribution.
xcodebuild -project Glint.xcodeproj -scheme Glint -configuration Release -derivedDataPath "$DD" \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build | tail -1

codesign --force --options runtime --timestamp \
  --entitlements Config/Release.entitlements --sign "$DEVID" "$APP"
codesign --verify --deep --strict "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ "${SKIP_NOTARIZE:-}" = "1" ]; then
  echo "Signed, not notarized: $ZIP"
  exit 0
fi

xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl -a -vv "$APP"
echo "Notarized: $ZIP"
