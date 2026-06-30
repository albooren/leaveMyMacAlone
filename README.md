# 🛡️ Leave My Mac Alone

> Keep your Mac working while you step away — but stop anyone from touching the keyboard or mouse.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black?logo=apple)
![License](https://img.shields.io/badge/license-MIT-blue)
[![Latest release](https://img.shields.io/github/v/release/albooren/leaveMyMacAlone?label=download&color=success)](https://github.com/albooren/leaveMyMacAlone/releases/latest)

LeaveMyMacAlone is a tiny macOS menu-bar app. When you lock, the screen stays
awake, an adjustable dim layer drops over it, and keyboard/mouse input is blocked.
Unlocking needs **Touch ID or your password** — so whatever is running in the
background (downloads, renders, builds…) keeps going uninterrupted.

## ✨ Features
- 🔒 **One-tap lock** — "Lock Now" from the menu, or the **⌃⌥⌘L** hotkey.
- 👆 **Touch ID / password** to unlock (Unlock button, or Space / Enter).
- 🌗 **Adjustable darkness** — from a light tint to fully opaque; live preview while dragging.
- ☕ **Stays awake** — keeps the display/system awake while locked (optional, can be turned off).
- 📸 **Intruder capture** *(opt-in)* — snaps a front-camera photo if someone keeps trying to get past the lock; saved to `~/Pictures/LeaveMyMacAlone/`, with a notification on unlock that opens the folder.
- 🖥️ **Covers full-screen apps** — locking from inside a full-screen app (Slack, Safari, a video) pulls it out of full-screen so the lock actually covers the screen.
- 🪶 **Lean permissions** — Accessibility for the lock (asked the first time you lock); Camera + Notifications only if you turn on intruder capture.
- 🧰 **Menu-bar app** — no Dock clutter, never auto-locks on launch.
- 🆘 **SSH kill switch** — recover remotely with `killall` if it ever hangs.
- 🌍 Turkish + English UI (follows the system language).

## 📦 Install
1. Download **`LeaveMyMacAlone.dmg`** from
   [Releases](https://github.com/albooren/leaveMyMacAlone/releases/latest), open it,
   and drag the app to **Applications**.
2. Launch it → a shield icon appears in the menu bar.
3. The **first time you lock**, it asks for **Accessibility** (needed to block input):
   click "Open Accessibility Settings" → turn on `LeaveMyMacAlone` → it locks
   automatically once granted.

## 🎛️ Usage
| Action | How |
|---|---|
| **Lock** | Menu > Lock Now · or **⌃⌥⌘L** |
| **Unlock** | Unlock button / **Space** / **Enter** → Touch ID or password |
| **Darkness** | Menu > slider (set it while unlocked; persists) |
| **Stay awake while locked** | Menu > "Prevent sleep while locked" toggle |
| **Intruder photo** | Menu > "Capture intruder photo" toggle (opt-in) |
| **Quit** | Menu > Quit |

## 🆘 Recovery if it hangs (SSH kill switch)
If the lock ever gets stuck, kill the app **from another device** — your background
work and session keep running (unlike a forced restart):
```bash
ssh <user>@<mac-ip> 'killall LeaveMyMacAlone'
```

**Prerequisite (on the Mac, once):** System Settings > General > Sharing >
**Remote Login** → ON.
(`systemsetup -setremotelogin on` from Terminal needs Full Disk Access; the GUI
toggle above is easiest.)

### 📱 One tap from iPhone (Shortcuts)
Set this up **before** you ever get stuck:
1. **Shortcuts** app → new shortcut → **"Run Script Over SSH"** action.
2. Fill in:
   - **Host:** your Mac's IP (e.g. `192.168.1.x`) or local name (`<computer-name>.local`)
   - **Port:** `22`
   - **User:** your Mac username
   - **Authentication:** Password → your Mac login password (or an SSH key)
   - **Script:** `killall LeaveMyMacAlone`
3. Name it "Unlock Mac"; add it to the Home Screen / Action Button / Siri.

When the Mac hangs, tap the shortcut (on the same Wi-Fi) → the lock dies, the Mac is back.

> **Tips:** the iPhone and Mac must be on the **same network**. The IP can change —
> use a DHCP reservation on your router or the `.local` name. To reach it away from
> home, set up a free VPN like **Tailscale**.
>
> **Last resort:** with no SSH, **holding the power button** force-restarts the Mac
> (software can't block that) — but your background work is lost too.

## 🛠️ Development
```bash
swift build && swift test     # build + tests (33 tests)
./bundle.sh                   # local .app (self-signed dev identity)
```
Create a one-time `LeaveMyMacAlone Dev` code-signing certificate (`bundle.sh` finds
it automatically) and the Accessibility grant survives rebuilds.

## ⚠️ Honest limitations
- On a bare laptop, **closing the lid** still sleeps it (hardware clamshell). Keep
  the lid open, or attach an external display + power.
- **Holding the power button** shuts it down at the hardware level (software can't block it).
- It's non-sandboxed, so it **can't be on the Mac App Store**; it ships as a directly
  distributed, Developer ID-signed download.
- A few **games** use their own (non-native) full-screen that macOS can't pull out of — the
  lock may land behind those. Native full-screen apps (Slack, Safari, video) are handled.
- Intruder capture's **green camera light is hardware-enforced** — it's evidence/deterrence, not covert.
- It stops a prankster co-worker; it is not a military-grade lock.

## 🔐 Privacy
No network access, no data collection. LocalAuthentication for Touch ID/password,
IOKit to keep awake, a CoreGraphics event tap to block input. Intruder photos (opt-in)
are saved only to `~/Pictures/LeaveMyMacAlone/` on your Mac — never uploaded. All local.

## 📄 License
[MIT](LICENSE) © 2026 Alperen Kişi
