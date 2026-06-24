#!/usr/bin/env bash
set -euo pipefail

APP_NAME="LeaveMyMacAlone"
BUNDLE_ID="com.alperenkisi.leavemymacalone"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1) Build the executable in release.
swift build -c release

# 2) Locate the built binary (robust to arch/triple changes).
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="${BIN_DIR}/${APP_NAME}"
if [[ ! -x "${BIN}" ]]; then
    echo "error: built executable not found at ${BIN}" >&2
    exit 1
fi

# 3) Assemble the .app bundle layout.
APP="${ROOT}/${APP_NAME}.app"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"

cp "${BIN}" "${APP}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP}/Contents/MacOS/${APP_NAME}"
cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"

# Validate the plist before signing.
plutil -lint "${APP}/Contents/Info.plist"

# 4) Ad-hoc codesign with entitlements + hardened runtime.
codesign --force --deep \
    --sign - \
    --entitlements "${ROOT}/Resources/${APP_NAME}.entitlements" \
    --options runtime \
    --identifier "${BUNDLE_ID}" \
    "${APP}"

# 5) Verify signature and show the cdhash (changes every rebuild → TCC reset).
codesign --verify --strict --verbose=2 "${APP}"
codesign -dvvv "${APP}" 2>&1 | grep -i 'CDHash='

echo "Built: ${APP}"
