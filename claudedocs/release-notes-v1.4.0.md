Leave My Mac Alone v1.4.0 — a much stronger lock. Updating is recommended.

> **Updating from v1.1.0:** install this version once by hand (download below). From here on, the app keeps itself up to date.
> **Already on v1.2.0 or later:** nothing to do — the app updates itself (or use "Check now" in the menu).

## What's new since v1.3.3
- 🔒 **Closes ways around the lock** — this release fixes several ways someone at your keyboard could get past the lock without your password. Details are in [PR #11](https://github.com/albooren/leaveMyMacAlone/pull/11).
- 👆 **Unlock right on the lock screen** — Touch ID and your password now live on the lock screen itself instead of a system prompt, so the lock stays fully in place while you unlock. You type your password into the app and macOS checks it. It is never stored or sent anywhere.
- 🖥️ **Full-screen apps stay in full screen** — the lock now covers them directly, so locking no longer pulls your video or app out of full screen.
- 🖱️ **Several displays** — the password appears on the display where you clicked Unlock or, from the keyboard, the one under your cursor.

## Behaviour to know about
- **Logging out or restarting is blocked while locked.** Unlock first. Holding the power button still works, as always.
- **The password field doesn't accept paste.** Type your password, so nobody can submit what's on your clipboard.
- **After 4 wrong passwords**, each further attempt makes you wait 30 seconds, until the next successful unlock.

## Requirements
- macOS 14 (Sonoma) or later
- Accessibility permission (requested at first lock) — needed to block input while locked
- Camera + Notification permission — only if you enable intruder photos

## Install
1. Download `LeaveMyMacAlone.dmg` below, open it, and drag **Leave My Mac Alone** to Applications (replace the old version if asked).
2. Launch it → the shield icon appears in the menu bar.
3. The first time you lock, grant **Accessibility** when prompted; it locks automatically once you do.

## Privacy
The only network request is the update check: once a day the app downloads this repository's public `appcast.xml` (and the new version, when there is one). Nothing about you or your Mac is sent. Turn off "Update automatically" and the app makes no requests unless you press "Check now". Your password, intruder photos and moving-icon image stay on your Mac.

## Notes
- This version was tested on macOS 27. It has not been tested on macOS 14–26. If the new unlock misbehaves on your Mac, you can still get out with `killall LeaveMyMacAlone` over SSH, or by holding the power button, and please [open an issue](https://github.com/albooren/leaveMyMacAlone/issues).
- It's meant to stop a curious co-worker, not to replace your Mac's own lock and FileVault.
- Runs outside the Mac App Store and is non-sandboxed (it needs the Accessibility API to block input).
- Apple Silicon only (arm64).
- Full feature list and the SSH / iPhone Shortcuts recovery are in the [README](https://github.com/albooren/leaveMyMacAlone#readme).
