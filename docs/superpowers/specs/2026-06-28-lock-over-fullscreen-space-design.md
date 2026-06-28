# Lock Over Full-Screen Space — Design Spec

- **Date:** 2026-06-28
- **Status:** Approved (design); pending implementation plan
- **Topic:** The lock shield does not cover another app's full-screen Space

## Summary

When the user is in another app's **native full-screen Space** (e.g. Slack, Safari,
QuickTime in full-screen) and locks, the shield does not appear over that Space —
it lands on a regular Desktop Space, so the screen looks unlocked until the user
manually switches Spaces. Fix: at lock time, exit the frontmost app's native
full-screen via the Accessibility API (already granted), which drops the user onto
a Desktop Space where the existing shield (with `.canJoinAllSpaces`) covers
everything.

## Problem & root cause

The shield windows are created with `collectionBehavior = [.canJoinAllSpaces,
.stationary, .fullScreenAuxiliary]` at `CGShieldingWindowLevel()`. `.canJoinAllSpaces`
reliably covers regular **Desktop** Spaces, but a third-party app's window **cannot
cover ANOTHER app's exclusive full-screen Space**, regardless of collection behavior
or window level — macOS treats a full-screen app's Space as exclusive. So locking
from inside another app's full-screen Space leaves the shield on a Desktop Space.

Confirmed empirically: the bug occurs **only** when the front app is in full-screen;
a regular second Desktop Space (Desktop 2) locks correctly.

## Chosen approach (of three considered)

**Exit the frontmost app's native full-screen on lock**, via the Accessibility API.
- Considered and rejected: **`CGDisplayCapture`** (covers everything but the
  LocalAuthentication system unlock UI renders in a separate process and may not
  appear on a captured display → unlock/strand risk; would require a fragile
  capture-release dance around auth). And **do nothing / document only** (not a fix).
- Chosen because it uses the Accessibility grant we already hold, targets only the
  problematic case, and leaves the existing safe unlock flow untouched.

## Behavior

At lock time, **before** the shield is shown and before our app is activated:
1. Find the frontmost application. If it is our own app, do nothing.
2. If its focused window is in native full-screen, set that window out of
   full-screen via the Accessibility API.
3. Proceed with the normal lock. Exiting full-screen transitions the user to a
   Desktop Space; the shield (`.canJoinAllSpaces`) is already there and covers it.

If the front app is not in full-screen, nothing happens (no disruption when not
needed).

## Components & files

- **`FullScreenExiter` (new, `Sources/LeaveMyMacAlone/FullScreenExiter.swift`)** —
  a small AX helper. Static `exitFrontmostFullScreen()`:
  - `NSWorkspace.shared.frontmostApplication` → `processIdentifier`; skip if it is
    our own pid.
  - `AXUIElementCreateApplication(pid)` → `kAXFocusedWindowAttribute` (fall back to
    `kAXMainWindowAttribute`).
  - Read `kAXFullScreenAttribute` ("AXFullScreen"); if it is `true`, set it to
    `false` via `AXUIElementSetAttributeValue`.
  - Best-effort and side-effect-only; returns nothing (or a `Bool` "exited" for
    logging). Never throws.
- **`AppController` (changed)** — call `FullScreenExiter.exitFrontmostFullScreen()`
  at the very top of `engageLock()`, before `shield.show()` / activation.
- **No change** to `ShieldController`, the shield collection behavior/level,
  `InputBlocker`, or the auth flow.

## Permissions

Uses **Accessibility** only (`AXIsProcessTrusted`), which is already granted by the
time `engageLock()` runs (the lock-time permission gate added earlier). Reading and
setting another app's `AXFullScreen` attribute via the AX C API requires
Accessibility but **not** AppleEvents — so no new permission and no AppleEvents
entitlement is needed.

## Error handling

- Front app not full-screen, or has no focused window, or doesn't expose
  `AXFullScreen` → no-op; proceed with the normal lock.
- AX calls that fail (returns non-success) → ignored; the lock proceeds regardless
  (worst case is the pre-existing behavior: shield on a Desktop Space).
- Never blocks or delays the lock path on failure.

## Testing

AX/AppKit side-effecting (manipulates another app's window) — consistent with the
existing untested permission/AppKit code. Verification is **`swift build` + manual**:
- Put Slack (or Safari/QuickTime) in native full-screen, lock (⌃⌥⌘L) → the app
  leaves full-screen and the shield covers the screen immediately.
- Lock from a regular Desktop Space → unchanged (still works).
- Lock from a regular windowed app → no app is disrupted (no-op), shield covers.

No unit test is added unless a pure decision extracts cleanly (it does not — the
logic is entirely AX calls).

## Honest limitations

- Apps using a **non-native full-screen** (some games render their own exclusive
  full-screen rather than the macOS green-button full-screen) do not expose
  `AXFullScreen`, so this cannot pull them out — the shield-on-wrong-Space behavior
  remains for those. This is the residual limit of the chosen approach (the only
  alternative that covers them, `CGDisplayCapture`, breaks the unlock UI).
- Multi-display / multiple simultaneous full-screen Spaces: best-effort — only the
  frontmost app's full-screen is exited.
