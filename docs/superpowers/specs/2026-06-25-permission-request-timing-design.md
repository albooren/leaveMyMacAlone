# Permission Request Timing — Design Spec

- **Date:** 2026-06-25
- **Status:** Approved (design); pending implementation plan
- **Topic:** Move permission requests to the moment of use, and fix the camera prompt not appearing

## Summary

Rework *when* the app asks for its two privileges:

1. **Accessibility** — requested when the user first tries to **lock** (not at app launch).
2. **Camera** — requested when the user turns the **intruder-capture toggle** on, and fixed so the system prompt actually appears for this menu-bar (accessory) app.

Launch becomes permission-clean: the app just sits in the menu bar.

## Problem being solved

- Today `AppController.start()` runs the Accessibility onboarding at launch, before the
  user has expressed any intent to lock. The user wants the prompt at the point of use.
- The camera permission prompt does **not appear** when the toggle is enabled. Root cause
  (high-confidence): the app runs as an `.accessory` (`LSUIElement`) app and the settings
  panel is a `.nonactivatingPanel`, so `AVCaptureDevice.requestAccess` is called while the
  app is not the active application and the TCC prompt never surfaces. The Accessibility
  onboarding works because it calls `NSApp.activate()` before showing its alert; the camera
  path does not activate first.

## Goal & non-goals

**Goal:** Request each privilege at its natural point of use, and make the camera prompt
reliably appear (or, if previously denied, guide the user to the right Settings pane).

**Non-goals (YAGNI):**
- No change to *what* the privileges are or how the event tap / camera capture work.
- No new permission for anything else.
- No shared "permissions framework" abstraction — mirror the existing alert/open-Settings
  pattern in place; do not over-engineer a generic requester.
- Notification permission keeps its current behavior (requested alongside camera on
  toggle-on; no special denied handling).

## Flow 1 — Accessibility at lock time

**Launch:** `AppController.start()` no longer triggers any permission onboarding. Remove the
`if !InputBlocker.hasRequiredPermissions() { startPermissionOnboarding() }` block.

**Lock entry:** split `lock()` into two:
- `lock()` (entry point, also reached by ⌃⌥⌘L via `handleHotKey`): checks
  `InputBlocker.hasAccessibilityPermission()`.
  - **Granted** → call `engageLock()` immediately.
  - **Not granted** → run the onboarding (activate app → alert → open the Accessibility
    Settings pane → poll for the grant). **On grant, automatically call `engageLock()`.** On
    cancel or timeout, do nothing (no lock, no error spam beyond the existing
    cancel/timeout messaging).
- `engageLock()` = today's locking body (the current contents of `lock()` from
  `guard machine.lock()` onward: `beginSession`, sleepGuard, shield, kiosk, inputBlocker.start,
  tap-failure rollback).

The existing helpers `startPermissionOnboarding`, `promptPermissionStep`, `waitForGrant`,
`showOnboardingTimeoutAlert` are reused; the only change is that a successful grant proceeds
to `engageLock()` instead of returning to an idle menu-bar state. `ensureAccessibilityPermission(prompt: false)`
still runs first so the app registers in the Accessibility list before the user is sent there.

**Re-entrancy:** if an onboarding task is already in flight (user pressed Lock, then pressed
again), the second press must not start a second concurrent onboarding or double-lock — guard
on the existing `onboardingTask` and on `machine.state` (only act when `.unlocked`).

The existing tap-failure alert (`showTapFailureAlert`) remains as the fallback for the case
where Accessibility IS granted but the tap still fails to install.

## Flow 2 — Camera on toggle-on (+ prompt fix)

When the intruder-capture toggle turns ON, `primeIntruderPermissions()` branches on
`AVCaptureDevice.authorizationStatus(for: .video)`:

- **`.authorized`** → nothing for camera.
- **`.notDetermined`** → `NSApp.activate()` **then** `AVCaptureDevice.requestAccess(for: .video) { _ in }`.
  The activation is the fix: it makes the app frontmost so the TCC prompt surfaces.
- **`.denied` / `.restricted`** → show an NSAlert explaining the feature needs Camera access,
  with a button that opens **System Settings → Privacy & Security → Camera**
  (`x-apple.systempreferences:com.apple.preference.security?Privacy_Camera`), plus a Cancel.

Independently (any status), request notification authorization via
`UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])` as today.

The toggle stays ON regardless of the camera outcome; capture is a silent no-op until the
grant exists (unchanged from the intruder-capture spec).

## Components & files touched

- **`AppController.swift`:**
  - `start()` — remove the launch-time onboarding block.
  - `lock()` — becomes the permission-gating entry; extract the current body into
    `engageLock()`; on missing Accessibility, run onboarding and call `engageLock()` on grant.
  - Onboarding task wiring reused; add the grant → `engageLock()` continuation and the
    re-entrancy guard.
- **`MenuBarController.swift`:**
  - `primeIntruderPermissions()` — branch on camera authorization status: activate+requestAccess
    for `.notDetermined`; alert + open Camera Settings pane for `.denied`/`.restricted`;
    nothing for `.authorized`. Keep the notification request.

No changes to `InputBlocker`, the event tap, `IntruderCapture`, or `AVFoundationPhotographer`.

## Error handling

- Onboarding cancel/timeout at lock time → no lock; reuse existing cancel/timeout messaging.
  Never strand: if the user never grants, the app simply stays unlocked.
- Camera denied → alert + Settings pane; never crash; toggle stays on.
- Re-entrant Lock presses → guarded; no double onboarding, no double lock.

## Testing

These are AppKit/TCC side-effecting flows (consistent with the existing, untested permission
onboarding). Verification is **build + manual**:
- Launch with Accessibility NOT granted → no prompt at launch; pressing Lock triggers the
  Accessibility onboarding; granting it auto-locks.
- Launch with Accessibility already granted → Lock works immediately, no onboarding.
- Toggle on with camera `.notDetermined` → the system Camera prompt appears (the bug fix);
  granting it lets the 3rd-interaction capture work.
- Toggle on with camera `.denied` → alert opens the Camera Settings pane.

If a pure decision point can be cleanly extracted without dragging in NSAlert/NSApp, add a
unit test for it; otherwise rely on the manual checklist (do not contort the code for
testability).

## Honest limitations

- The camera-prompt fix rests on the activation hypothesis (evidence: the Accessibility
  alert works because it activates first). Implementation MUST manually verify the prompt now
  appears; if activation alone is insufficient, investigate the root cause further before
  closing.
- Accessibility still cannot be granted by a system prompt — it requires the manual Settings
  toggle (unchanged); the lock-time flow guides the user there and waits.
