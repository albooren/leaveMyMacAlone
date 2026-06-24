#!/usr/bin/env bash
set -euo pipefail

APP_NAME="LeaveMyMacAlone"
BUNDLE_ID="com.alperenkisi.leavemymacalone"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${ROOT}/${APP_NAME}.app"
DMG="${ROOT}/${APP_NAME}.dmg"

# Required credentials (set by you; see the release design spec):
#   DEVELOPER_ID   e.g. "Developer ID Application: Alperen Kişi (TEAMID)"
#   NOTARY_PROFILE the notarytool keychain profile name you created with
#                  `xcrun notarytool store-credentials`.
: "${DEVELOPER_ID:?Set DEVELOPER_ID to your 'Developer ID Application: …' identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your notarytool keychain profile name}"

# 1) Build + assemble the .app via the dev bundler, signing with the Developer ID.
echo "==> Assembling app (Developer ID)"
SIGN_IDENTITY="${DEVELOPER_ID}" "${ROOT}/bundle.sh"

# 2) Re-sign with hardened runtime + secure timestamp (required for notarization).
echo "==> Signing for notarization"
codesign --force --deep --options runtime --timestamp \
    --entitlements "${ROOT}/Resources/${APP_NAME}.entitlements" \
    --identifier "${BUNDLE_ID}" \
    --sign "${DEVELOPER_ID}" \
    "${APP}"
codesign --verify --strict --verbose=2 "${APP}"

# 3) Build a compressed DMG with an Applications drop target.
echo "==> Building DMG"
STAGE="$(mktemp -d)"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
rm -f "${DMG}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}"
rm -rf "${STAGE}"

# 4) Notarize the DMG, then staple the ticket to both the DMG and the app.
echo "==> Notarizing (this can take a few minutes)"
xcrun notarytool submit "${DMG}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${DMG}"
xcrun stapler staple "${APP}"

# 5) Verify Gatekeeper would accept it.
echo "==> Verifying"
spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG}" || true
codesign -dvv "${APP}" 2>&1 | grep -iE "Authority=|TeamIdentifier="
echo "Done: ${DMG}"
