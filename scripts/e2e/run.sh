#!/usr/bin/env bash
# End-to-end lock tests on the real screen. See CONTRIBUTING.md.
# usage: run.sh [scenario ...]     (no arguments = every scenario)
#
# Stops the installed copy for the duration (its hot key would collide with the test
# copy) and always restores it, and the frontmost app, afterwards. Uses signals and
# `open` rather than AppleScript so no Automation consent dialog can appear.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${TMPDIR:-/tmp}/lmma-e2e"
INSTALLED="/Applications/LeaveMyMacAlone.app"
INSTALLED_BIN="$INSTALLED/Contents/MacOS/LeaveMyMacAlone"
RELEASE="${LMMA_E2E_RELEASE:-0}"
mkdir -p "$WORK/build"

FRONT_BUNDLE="$(lsappinfo info -only bundleid "$(lsappinfo front)" | grep -o 'bundleID="[^"]*"' | head -1 | cut -d'"' -f2)"
INSTALLED_PID="$(pgrep -f "^$INSTALLED_BIN" | head -1)"

restore() {
    pkill -9 -f "$WORK/build/LeaveMyMacAlone.app/Contents/MacOS/LeaveMyMacAlone" 2>/dev/null
    if [ -n "$INSTALLED_PID" ] && ! pgrep -f "^$INSTALLED_BIN" >/dev/null; then
        open -g "$INSTALLED"
    fi
    [ -n "$FRONT_BUNDLE" ] && open -b "$FRONT_BUNDLE"
    rm -rf "$WORK"
}
trap restore EXIT

APP="$("$HERE/make-dev-bundle.sh" "$WORK/build")" || { echo "bundle failed"; exit 1; }
swiftc -swift-version 5 -O -o "$WORK/drive" "$HERE/drive.swift" 2>&1 | grep "error:"
swiftc -swift-version 5 -O -o "$WORK/fsapp" "$HERE/fsapp.swift" 2>&1 | grep "error:"
swiftc -swift-version 5 -O -o "$WORK/launcher" "$HERE/launcher.swift" 2>&1 | grep "error:"
[ -x "$WORK/drive" ] && [ -x "$WORK/fsapp" ] && [ -x "$WORK/launcher" ] || { echo "test tools failed to compile"; exit 1; }

[ -n "$INSTALLED_PID" ] && kill "$INSTALLED_PID"
sleep 1

SCENARIOS=("$@")
if [ ${#SCENARIOS[@]} -eq 0 ]; then
    SCENARIOS=(quit-while-locked lock-with-other-app-in-front fullscreen-space password-stage
               launcher-during-auth reclaim-foreground wrong-password cancel-and-keyboard-route
               every-display-covered sigterm-rescue)
    # The fixed test password only exists in debug builds.
    [ "$RELEASE" = "1" ] || SCENARIOS+=(unlock-and-quit)
fi

LOG="$WORK/results.log"
: > "$LOG"
for s in "${SCENARIOS[@]}"; do
    echo "===================== $s ====================="
    TEST_PASSWORD=""
    [ "$s" = "unlock-and-quit" ] && TEST_PASSWORD="abc"
    "$WORK/drive" "$APP" "$s" $TEST_PASSWORD 2>&1 | grep -v sandbox_extension | tee -a "$LOG"
    sleep 1
done

echo
PASSED="$(grep -c '^PASS' "$LOG")"
FAILED="$(grep -c '^FAIL' "$LOG")"
echo "passed: $PASSED  failed: $FAILED"
grep '^FAIL' "$LOG"
[ "$FAILED" -eq 0 ] && [ "$PASSED" -gt 0 ]
