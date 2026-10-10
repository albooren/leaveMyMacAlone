Leave My Mac Alone v1.3.2 — automatic updates, a lock screen that tells people where you are, a redesigned menu, and a new look.

> **Updating from v1.1.0:** install this version once by hand (download below). From here on, the app keeps itself up to date.
> **Already on v1.2.0 or later:** nothing to do — the app updates itself (or use "Check now" in the menu).

## What's new since v1.1.0
- 🔄 **Automatic updates** — new versions download in the background, are verified (EdDSA signature + Developer ID), and install with a quick relaunch. Never while the Mac is locked: an update that arrives while you're away waits until you unlock. Can be turned off in the menu; "Check now" is right next to it.
- 💬 **Lock-screen message** — tell passers-by where you are: "In a meeting", "At lunch", "Back soon", or your own text — plus an optional return time ("Back at 14:30"). Step it with − / +, or click the time and type any duration ("50", "1:30").
- 📀 **Moving icon** — pick an emoji (search the full set right in the menu) or your own image, and it drifts across the lock screen like the old DVD screensaver. Small / Medium / Large.
- ⏸️ **Pauses music and video** — whatever is playing pauses the moment you lock, so nothing keeps playing at an empty desk. Want it to keep going? Turn the switch off.
- 👀 **Redesigned menu with a live preview** — a mini lock screen shows your darkness, message, return time and icon as you change them. Lock Now sits at the top; every setting is a plain sentence with a standard switch.
- 🪟 **Liquid Glass** — the menu and the lock screen's unlock button use Liquid Glass on macOS 26 and later (frosted materials on macOS 14–15).
- 🛡️ **New app icon and menu bar icon** — the shield is now the body of a lock whose green shackle is a progress bar: locked, but your work keeps going. The menu bar icon is the same shape in one color.
- 🏷️ **Proper name everywhere** — Finder, System Settings, permission prompts and the menu say "Leave My Mac Alone". Your settings, permissions and intruder photos folder are unchanged, and the recovery command is still `killall LeaveMyMacAlone`.
- 🌍 **Unlock prompt in your language** — the Touch ID / password prompt is now English on English systems ("Verify your identity to unlock your Mac.").

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
