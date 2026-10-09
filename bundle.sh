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

# Sparkle (auto-update). ditto keeps the framework's Versions/ symlinks intact;
# the executable finds it via the @executable_path/../Frameworks rpath.
mkdir -p "${APP}/Contents/Frameworks"
ditto "${BIN_DIR}/Sparkle.framework" "${APP}/Contents/Frameworks/Sparkle.framework"

# App icon.
cp "${ROOT}/Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"

# Localizations: copy every .lproj (e.g. en.lproj) into the bundle so the .app's
# main bundle resolves them. The Turkish development-language strings are the
# keys, so Turkish needs no .lproj.
for lproj in "${ROOT}/Resources"/*.lproj; do
    [ -d "${lproj}" ] && cp -R "${lproj}" "${APP}/Contents/Resources/"
done

# Validate the plist before signing.
plutil -lint "${APP}/Contents/Info.plist"
# Validate every localization table.
for strings in "${APP}/Contents/Resources"/*.lproj/Localizable.strings; do
    [ -f "${strings}" ] && plutil -lint "${strings}"
done

# 4) Codesign with entitlements + hardened runtime.
#
# Signing identity: prefer a STABLE self-signed code-signing certificate so that
# Accessibility / Input Monitoring (TCC) grants SURVIVE rebuilds — TCC keys the
# grant on (bundle id + signing identity), and a stable cert keeps that constant.
# Ad-hoc ("-") is re-keyed from the binary content on every build, so it resets
# those grants each time. Create the cert once via Keychain Access > Certificate
# Assistant (Code Signing, self-signed) named exactly "LeaveMyMacAlone Dev", or
# override with SIGN_IDENTITY="My Cert Name" ./bundle.sh
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "${SIGN_IDENTITY}" ]]; then
    # Match WITHOUT -v: a self-signed dev cert is untrusted (CSSMERR_TP_NOT_TRUSTED)
    # so it never appears in the "valid only" (-v) list, yet codesign signs with
    # it fine and TCC keys on it (stable identity → grants survive rebuilds).
    if security find-identity -p codesigning 2>/dev/null | grep -q "LeaveMyMacAlone Dev"; then
        SIGN_IDENTITY="LeaveMyMacAlone Dev"
    else
        SIGN_IDENTITY="-"
    fi
fi
echo "Signing with identity: ${SIGN_IDENTITY} ($([[ "${SIGN_IDENTITY}" == "-" ]] && echo 'ad-hoc — TCC resets each build' || echo 'stable — TCC persists'))"

# Sign inside-out (NOT --deep: it would strip the entitlements Sparkle's helpers
# ship with). Nested Sparkle code first, then the app itself. SIGN_TIMESTAMP=1
# (set by release.sh) adds the secure timestamp notarization requires.
if [[ "${SIGN_TIMESTAMP:-0}" == "1" ]]; then TIMESTAMP="--timestamp"; else TIMESTAMP="--timestamp=none"; fi
sign() { codesign --force --options runtime ${TIMESTAMP} --sign "${SIGN_IDENTITY}" "$@"; }

SPARKLE="${APP}/Contents/Frameworks/Sparkle.framework"
sign "${SPARKLE}/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "${SPARKLE}/Versions/B/XPCServices/Downloader.xpc"
sign "${SPARKLE}/Versions/B/Autoupdate"
sign "${SPARKLE}/Versions/B/Updater.app"
sign "${SPARKLE}"

# Library validation only lets the app load Sparkle.framework when both carry
# the same Team ID. A Developer ID build has one; the self-signed dev cert (and
# ad-hoc) has none, so dyld would refuse Sparkle and the app dies at launch.
# Dev builds therefore get disable-library-validation; release builds never do.
ENTITLEMENTS="${ROOT}/Resources/${APP_NAME}.entitlements"
if [[ "${SIGN_IDENTITY}" != "Developer ID Application:"* ]]; then
    DEV_ENTITLEMENTS="$(mktemp -d)/dev.entitlements"
    cp "${ENTITLEMENTS}" "${DEV_ENTITLEMENTS}"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "${DEV_ENTITLEMENTS}"
    ENTITLEMENTS="${DEV_ENTITLEMENTS}"
    echo "Dev signing: library validation disabled (not used for Developer ID builds)"
fi

sign --entitlements "${ENTITLEMENTS}" \
    --identifier "${BUNDLE_ID}" \
    "${APP}"

# 5) Verify signature and show the cdhash (changes every rebuild; with a stable
# identity the TCC Designated Requirement still matches, so grants persist).
codesign --verify --deep --strict --verbose=2 "${APP}"
codesign -dvvv "${APP}" 2>&1 | grep -i 'CDHash='

echo "Built: ${APP}"
