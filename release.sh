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

# 1+2) Build + assemble the .app via the bundler, signing every nested Sparkle
# component and the app with the Developer ID, hardened runtime and the secure
# timestamp notarization requires (bundle.sh signs inside-out; never --deep).
echo "==> Assembling + signing app (Developer ID)"
SIGN_IDENTITY="${DEVELOPER_ID}" SIGN_TIMESTAMP=1 "${ROOT}/bundle.sh"

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

# 6) Sparkle appcast. generate_appcast signs the DMG with the EdDSA private key
# from this Mac's Keychain and writes appcast.xml pointing at this version's
# release asset. Installed copies poll
# releases/latest/download/appcast.xml, so BOTH files must be attached to the
# GitHub release, which must be the "latest" (non-prerelease) one.
echo "==> Generating Sparkle appcast"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${ROOT}/Resources/Info.plist")"
TAG="v${VERSION}"
APPCAST_DIR="$(mktemp -d)"
cp "${DMG}" "${APPCAST_DIR}/"
"${ROOT}/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" \
    --download-url-prefix "https://github.com/albooren/leaveMyMacAlone/releases/download/${TAG}/" \
    --link "https://github.com/albooren/leaveMyMacAlone/releases/tag/${TAG}" \
    "${APPCAST_DIR}"
cp "${APPCAST_DIR}/appcast.xml" "${ROOT}/appcast.xml"
rm -rf "${APPCAST_DIR}"

echo "Done: ${DMG} + ${ROOT}/appcast.xml"
echo "Publish both (installed apps update from the latest release):"
echo "  gh release create ${TAG} \"${DMG}\" \"${ROOT}/appcast.xml\" --title \"${TAG}\" --notes-file <notes.md>"
echo "  (or, for an existing release: gh release upload ${TAG} \"${DMG}\" \"${ROOT}/appcast.xml\" --clobber)"
