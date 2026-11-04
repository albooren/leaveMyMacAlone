#!/usr/bin/env bash
# Assembles a throwaway .app outside the repo (a .app inside it gets picked up by
# Spotlight and LaunchServices). run.sh executes Contents/MacOS directly, so the copy
# inherits the terminal's Accessibility grant and leaves the installed app's TCC entry
# alone. Auto-update stays off. Always builds first, so it can't hold a stale binary.
#
# LMMA_E2E_RELEASE=1 builds like bundle.sh does (release config, hardened runtime) and
# fails if the debug test hook reached the binary.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$1"
cd "$ROOT"

if [ "${LMMA_E2E_RELEASE:-0}" = "1" ]; then
    swift build -c release 2>&1 | tail -1 >&2
    BIN_DIR="$(swift build -c release --show-bin-path)"
else
    swift build 2>&1 | tail -1 >&2
    BIN_DIR="$(swift build --show-bin-path)"
fi

APP="$OUT/LeaveMyMacAlone.app"
BIN="$APP/Contents/MacOS/LeaveMyMacAlone"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/LeaveMyMacAlone" "$BIN"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" \
                        -c "Set :SUAutomaticallyUpdate false" "$APP/Contents/Info.plist"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
for lproj in "$ROOT/Resources"/*.lproj; do cp -R "$lproj" "$APP/Contents/Resources/"; done

if [ "${LMMA_E2E_RELEASE:-0}" = "1" ]; then
    if grep -aq "LMMA_TEST_" "$BIN"; then
        echo "error: the debug test hook is present in the RELEASE binary" >&2
        exit 1
    fi
    echo "release binary has no debug test hook" >&2
    ENTITLEMENTS="$(mktemp -d)/dev.entitlements"
    cp "$ROOT/Resources/LeaveMyMacAlone.entitlements" "$ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS"
    SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
    sign() { codesign --force --options runtime --timestamp=none --sign - "$@" 2>/dev/null; }
    sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
    sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
    sign "$SPARKLE/Versions/B/Autoupdate"
    sign "$SPARKLE/Versions/B/Updater.app"
    sign "$SPARKLE"
    sign --entitlements "$ENTITLEMENTS" --identifier com.alperenkisi.leavemymacalone "$APP"
fi
echo "$APP"
