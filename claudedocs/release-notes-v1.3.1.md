LeaveMyMacAlone v1.3.1 — the app now goes by its proper name: **Leave My Mac Alone**.

> **Updating from v1.3.0 or v1.2.0:** nothing to do — the app updates itself (or use "Check now" in the menu).

## What's new since v1.3.0
- 🏷️ **Proper name everywhere** — Finder, the Applications folder, System Settings, permission prompts and the menu now say "Leave My Mac Alone" instead of "LeaveMyMacAlone". Your settings, permissions and intruder photos folder are unchanged, and the recovery command is still `killall LeaveMyMacAlone`.

## Requirements
- macOS 14 (Sonoma) or later
- Accessibility permission (requested at first lock) — needed to block input while locked
- Camera + Notification permission — only if you enable intruder photos

## Install
1. Download `LeaveMyMacAlone.dmg` below, open it, and drag **Leave My Mac Alone** to Applications (replace the old version if asked).
2. Launch it → the shield icon appears in the menu bar.
3. The first time you lock, grant **Accessibility** when prompted; it locks automatically once you do.

## Privacy
The only network request is the update check: once a day the app downloads this repository's public `appcast.xml` (and the new version, when there is one). Nothing about you or your Mac is sent. Turn off "Update automatically" and the app makes no requests unless you press "Check now". Intruder photos and your moving-icon image stay on your Mac.

## Notes
- Runs outside the Mac App Store and is non-sandboxed (it needs the Accessibility API to block input).
- Apple Silicon only (arm64).
- Full feature list and the SSH / iPhone Shortcuts kill-switch recovery are in the [README](https://github.com/albooren/leaveMyMacAlone#readme).
