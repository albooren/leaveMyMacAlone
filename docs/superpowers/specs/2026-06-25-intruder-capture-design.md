# Intruder Capture — Design Spec

- **Date:** 2026-06-25
- **Status:** Approved (design); pending implementation plan
- **Topic:** Capture a front-camera photo when someone tries to force the lock open

## Summary

When the Mac is locked by LeaveMyMacAlone and an unauthorized person interacts
with the locked screen, the app captures a still photo from the built-in front
camera and saves it locally. The feature is **opt-in**, toggled from Settings
directly under the existing "Prevent sleep while locked" toggle. On unlock, the
owner is notified if any photos were captured and can open the folder from the menu.

## Goal & non-goals

**Goal:** Give the owner photographic evidence / deterrence when a passer-by tries
to get past the lock, without burdening the normal owner unlock flow.

**Non-goals (YAGNI — explicitly out of scope):**
- No upload, email, cloud sync, or network transmission of photos (the app is
  network-free; this stays local).
- No video/audio recording — single still frames only.
- No facial recognition / identification.
- No remote alerting to a phone (the SSH/Shortcuts kill-switch already exists for
  remote control; intruder photos are reviewed locally).
- No configurable grace count / cooldown / storage path in v1 — values are fixed
  constants (can be revisited later).

## User-facing behavior

1. Settings gains a toggle **"Capture intruder photo"** (TR: *"İzinsiz girişte
   fotoğraf çek"*) immediately below the sleep toggle. **Default: OFF.**
2. When the user turns it ON, the app proactively requests **Camera** permission
   (and Notification permission) at that calm moment — not during an intrusion.
3. While locked, interactions are counted (see Trigger & policy). The 3rd
   interaction in a lock session triggers the first photo; further interactions
   trigger more photos, throttled to one per 5 seconds.
4. Each photo is written to `~/Pictures/LeaveMyMacAlone/`.
5. On successful unlock, if ≥1 photo was captured this lock session, a macOS
   notification reports the count. A menu item **"Open intruder photos"**
   (TR: *"İzinsiz giriş fotoğraflarını aç"*) opens the folder in Finder.

## Trigger & policy (pure, testable logic)

State held per lock session in `IntruderCapture`:

- **Interaction** = a key-down OR a mouse-down (left/right) intercepted while in
  the **full-locked** state, plus a press of the **"Kilidi Aç" (Unlock) button**
  (counted once, at the moment it is pressed, before auth mode begins). Mouse
  movement does NOT count.
- **Auth mode pauses counting** — while the password/Touch ID sheet is up, the
  owner's keystrokes are NOT interactions. Counting resumes if auth fails back to
  locked.
- **Grace = 2.** Interactions 1 and 2 are free. The **3rd** interaction fires the
  first capture.
- **Cooldown = 5 s.** After a capture, subsequent interactions fire a new capture
  only if ≥5 s have elapsed since the last capture.
- **Reset** of the counter and cooldown clock happens on **lock** (fresh session)
  and on **successful unlock**. A **failed** auth does NOT reset (the attacker is
  still the attacker).

Constants (fixed in v1): `graceInteractions = 2`, `captureCooldown = 5 s`.

### Decision function

`noteInteraction(now:)` returns whether to capture:

```
if !enabled { return false }                     // disabled → don't even count
count += 1
if count <= graceInteractions { return false }   // 1st, 2nd → free
if let last = lastCaptureAt, now - last < cooldown { return false }
lastCaptureAt = now
return true
```

`reset()` clears `count` and `lastCaptureAt`. The "enabled" read comes from
`AppSettingsStore.captureIntruderPhoto`.

## Capture mechanics

- Built-in front camera via **AVFoundation** (`AVCaptureSession` +
  `AVCapturePhotoOutput`, or a single-frame `AVCaptureVideoDataOutput`).
- **Lazy session:** the capture session is started on demand when a capture is
  needed, allowed a brief exposure warm-up (~0.5–1 s), one frame grabbed, then the
  session is torn down. Rationale: the green camera LED only lights during an
  actual capture (~1 s), never for the whole lock duration.
- Capture is asynchronous and must never block the unlock path or the event tap.
- Output encoded as JPEG.

## Storage

- Directory: `~/Pictures/LeaveMyMacAlone/` (created if absent).
- Filename: `intruder-YYYY-MM-DD_HH-mm-ss.jpg` (local time, zero-padded).
  Collisions within the same second get a `-2`, `-3`, … suffix.

## Settings & permissions

- New persisted setting `captureIntruderPhoto: Bool` in `AppSettingsStore`
  (UserDefaults key `captureIntruderPhoto`, default `false`), following the exact
  pattern of `preventSleepWhileLocked`.
- `Info.plist` gains `NSCameraUsageDescription` (e.g., *"Photographs whoever tries
  to unlock your Mac while it is locked."*).
- Permission priming on toggle-ON: request `AVCaptureDevice` authorization and
  `UNUserNotificationCenter` authorization. If the user denies camera, the toggle
  stays on but capture is a no-op and the menu surfaces the denied state.

## Notification & menu

- On unlock with captures > 0: post a local notification via
  `UNUserNotificationCenter` ("N intruder photos captured"). If notification
  permission is unavailable, degrade silently to the menu surface only.
- Menu (shown only while the feature is enabled): **"Open intruder photos"** opens
  `~/Pictures/LeaveMyMacAlone/` in Finder (`NSWorkspace.open`).

## Architecture & components

Follows the existing pattern: `AppController` coordinates subsystems; each unit is
single-purpose and lives in its own file.

- **`IntruderCapturePolicy` (new, in `LeaveMyMacAloneCore`)** — the pure,
  unit-tested counting/cooldown logic (no Foundation, no AppKit). Surface:
  - `init(enabled: Bool)` / `mutating func setEnabled(_:)`
  - `mutating func noteInteraction(now: Double) -> Bool` — `now` is monotonic
    seconds; returns whether a capture should be taken (decision function above).
  - `mutating func reset()`
- **`IntruderPhotographer` (new protocol, in app target)** — the hardware
  boundary: `func capture() async -> Data?` returns JPEG bytes or nil (lid closed /
  no camera / denied). Behind a protocol so the coordinator is testable with a fake.
- **`IntruderCapture` (new coordinator, app target, `@MainActor`)** — owns an
  `IntruderCapturePolicy` + an `IntruderPhotographer` + the output directory.
  Surface:
  - `beginSession(enabled: Bool)` — set policy enabled + reset + zero the count
    (called from `lock()`).
  - `endSession()` — reset (called on successful unlock).
  - `registerInteraction() -> Bool` — feeds `policy.noteInteraction(now:)` with
    `ProcessInfo.processInfo.systemUptime`; returns whether to capture.
  - `performCapture() async` — await the photographer; on non-nil data, write the
    JPEG and increment `capturedThisSession`.
  - `capturedThisSession: Int` and `postUnlockNotification()` for the unlock nudge.
  - static `defaultDirectory` + `openPhotosFolder()` (used by the menu item).
- **`AppSettingsStore` (changed)** — `+captureIntruderPhoto`.
- **`MenuBarController` (changed)** — `+toggle` under the sleep toggle;
  `+"Open intruder photos"` menu item; triggers permission priming on enable.
- **`AppController` (changed)** — owns the `IntruderCapture` instance and wires
  interaction/lock/unlock signals into it. Every locked-state interaction already
  funnels through exactly two handlers: `handleUnlockButton()` (Space/Return via
  `onUnlockKey`, plus the Unlock-button click via `onUnlock`) and
  `handleBackgroundClick()` (any other key via `onLockedKey`, plus background
  clicks via `onInteract`). It registers an interaction in the `.locked` branch of
  each (so auth-mode keystrokes are never counted); calls `beginSession()` in
  `lock()`, and `postUnlockNotification()` + `endSession()` in
  `finishAuth(success: true)`.
- **`InputBlocker` — NO change.** Arbitrary keys already call back via
  `onLockedKey` (non-autorepeat keyDown) and Space/Return via `onUnlockKey`; auth
  mode fires neither. The existing callbacks fully supply the interaction signal,
  so no new hook is needed.
- **`Info.plist` (changed)** — `+NSCameraUsageDescription`.
- **`Package.swift` (changed)** — link `AVFoundation` and `UserNotifications` on
  the executable target.

## Data flow

```
locked ─other key─▶ InputBlocker.onLockedKey ─▶ AppController.handleBackgroundClick(.locked) ─▶ registerInteraction()
locked ─Space/Ret─▶ InputBlocker.onUnlockKey ─▶ AppController.handleUnlockButton(.locked) ───▶ registerInteraction()
locked ─bg click──▶ shield.onInteract ───────▶ AppController.handleBackgroundClick(.locked) ─▶ registerInteraction()
locked ─Unlock btn▶ shield.onUnlock ──────────▶ AppController.handleUnlockButton(.locked) ───▶ registerInteraction()
                                            (count>2 && cooldown ok) ─▶ Task { performCapture() }  (LED ~1s)
                                                                              ─▶ write ~/Pictures/LeaveMyMacAlone/intruder-*.jpg
                                                            │ (count>2 && cooldown ok)
                                                            ▼
                                                   IntruderPhotographer.capture()  (LED ~1s)
                                                            ▼
                                              write ~/Pictures/LeaveMyMacAlone/intruder-*.jpg
lock        ─▶ IntruderCapture.reset()
unlock(ok)  ─▶ notification(capturedThisSession) ─▶ IntruderCapture.reset()
auth sheet  ─▶ counting paused (no noteInteraction while in auth mode)
```

## Error handling

- Capture failure (lid closed, no camera, permission denied, timeout) → return nil,
  log, no file written, no crash; the lock flow is unaffected.
- Directory creation failure → log, skip the write for that capture.
- Capture is fully detached from the unlock/event-tap path; a slow or hung camera
  must never delay unlock or strand the lock.
- All capture work is throttled by the 5 s cooldown, bounding file/CPU churn under
  sustained mashing.

## Testing

- Unit-test `IntruderCapture` policy with an injected clock and a fake
  `IntruderPhotographer` in `Tests/LeaveMyMacAloneTests`:
  - 1st & 2nd interaction → no capture; 3rd → capture.
  - 4th immediately after → no capture (cooldown); after 5 s → capture.
  - `reset()` returns to the grace state.
  - disabled setting → never captures regardless of interaction count.
  - failed auth (no reset) keeps the count; lock/unlock resets it.
- The AVFoundation `IntruderPhotographer` impl is the untestable hardware boundary
  and is exercised manually.

## Honest limitations (carry into README/release notes)

- The **green camera LED is hardware-enforced** and lights during capture — the
  intruder can see the camera is active; this is deterrence/evidence, not covert
  surveillance.
- A **closed lid** or absent camera yields no frame; captures are silently skipped.
- If camera permission is **denied**, the feature is a no-op (toggle stays on, menu
  shows the denied state).
- Photos are stored **unencrypted** in `~/Pictures/LeaveMyMacAlone/`; anyone with
  access to the unlocked account can view/delete them.
