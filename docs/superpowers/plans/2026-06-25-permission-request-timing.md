# Permission Request Timing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Request Accessibility at lock time (not launch) with auto-lock on grant, and request Camera when the intruder toggle turns on — fixing the prompt that never appears for this accessory app.

**Architecture:** Two independent edits. `AppController` gains a permission gate in `lock()` that runs the existing Accessibility onboarding lazily and auto-locks on grant; the locking body moves to `engageLock()`. `MenuBarController.primeIntruderPermissions()` branches on the camera authorization status, activating the app before the system prompt (the fix) and guiding denied users to the Camera Settings pane.

**Tech Stack:** Swift 6, AppKit (NSApp/NSAlert/NSWorkspace), AVFoundation, UserNotifications.

## Global Constraints

- These are AppKit/TCC side-effecting flows (consistent with the existing, untested permission onboarding). Verification is **`swift build` + manual** — do NOT add contorted unit tests; only add a unit test if a pure decision extracts cleanly (none does here).
- App is `.accessory` (`LSUIElement`); the TCC camera prompt only surfaces if the app is active — `NSApp.activate(ignoringOtherApps: true)` must precede `AVCaptureDevice.requestAccess`.
- Settings pane URLs (verbatim): Accessibility `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`; Camera `x-apple.systempreferences:com.apple.preference.security?Privacy_Camera`.
- New UI strings are Turkish literals with matching English entries in `Resources/en.lproj/Localizable.strings`. **Use straight ASCII apostrophes (U+0027) only — never let an editor normalize to curly U+2019, or the key stops matching the source literal.** (The strings in this plan are deliberately apostrophe-free to avoid the hazard.)
- No changes to `InputBlocker`, the event tap, `IntruderCapture`, or `AVFoundationPhotographer`.

---

### Task 1: Accessibility requested at lock time (auto-lock on grant)

**Files:**
- Modify: `Sources/LeaveMyMacAlone/AppController.swift`

**Interfaces:**
- Consumes: existing `InputBlocker.hasAccessibilityPermission()`, `InputBlocker.ensureAccessibilityPermission(prompt:)`, `promptPermissionStep(name:paneURL:)`, `waitForGrant(_:)`, `showOnboardingTimeoutAlert(name:)`, `onboardingTask` property, `machine`.
- Produces: nothing for other tasks.

- [ ] **Step 1: Remove the launch-time onboarding from `start()`**

In `start()`, delete this block (currently the last statements of the method, lines ~75–80):

```swift
        // Launch into the menu bar; NEVER auto-lock. The user locks on demand —
        // the "Şimdi Kilitle" menu item or the ⌃⌥⌘L hot key. If permissions are
        // missing, walk the user through granting them first.
        if !InputBlocker.hasRequiredPermissions() {
            startPermissionOnboarding()
        }
```

Replace it with just the comment (no permission call):

```swift
        // Launch into the menu bar; NEVER auto-lock and NEVER prompt for
        // permissions here. Accessibility is requested lazily, the first time the
        // user actually tries to lock (see lock()).
```

- [ ] **Step 2: Replace `lock()` with the permission gate, and add `requestAccessibilityThenLock()` + `engageLock()`**

Replace the entire current `lock()` method (from `func lock() {` through its closing brace, currently lines ~83–122) with the following three methods:

```swift
    /// Entry point for locking ("Şimdi Kilitle" and ⌃⌥⌘L). The event tap needs
    /// Accessibility; if it isn't granted yet, walk the user through it and lock
    /// automatically once granted. If already granted, lock immediately.
    func lock() {
        guard machine.state == .unlocked else { return } // ignore unless idle
        if InputBlocker.hasAccessibilityPermission() {
            engageLock()
        } else {
            requestAccessibilityThenLock()
        }
    }

    /// Run the Accessibility onboarding, then lock automatically on grant. Guarded
    /// so repeated Lock presses don't start concurrent onboarding or double-lock.
    private func requestAccessibilityThenLock() {
        guard onboardingTask == nil else { return } // onboarding already in flight
        onboardingTask = Task { @MainActor in
            defer { self.onboardingTask = nil }
            _ = InputBlocker.ensureAccessibilityPermission(prompt: false) // register in the list
            guard self.promptPermissionStep(
                name: "Erişilebilirlik",
                paneURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ) else { return }
            guard await self.waitForGrant({ InputBlocker.hasAccessibilityPermission() }) else {
                self.showOnboardingTimeoutAlert(name: "Erişilebilirlik"); return
            }
            // Granted — lock now, if still idle.
            if self.machine.state == .unlocked { self.engageLock() }
        }
    }

    /// The actual locking sequence (Accessibility already granted).
    private func engageLock() {
        guard machine.lock() else { return } // ignore if not unlocked
        intruder.beginSession(enabled: store.captureIntruderPhoto)
        // Keep the Mac awake while locked only if the user wants it (default on);
        // sleepGuard.end() on teardown is a no-op if we never began.
        if store.preventSleepWhileLocked {
            sleepGuard.begin()
        }
        // onUnlock = the "Kilidi Aç" button → begin auth. onInteract = a click
        // anywhere else on the shield → flash "still locked" while locked, or
        // re-present a buried auth sheet while authenticating (tap-independent
        // recovery, so a covering window can never strand the user).
        shield.show(opacity: store.overlayOpacity, onInteract: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.handleBackgroundClick() }
        }, onUnlock: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.handleUnlockButton() }
        })
        kiosk.engage()
        // Keyboard route into unlocking (the mouse drives the shield directly):
        // Space/Return begin auth, any other key flashes "still locked".
        let live = inputBlocker.start(onUnlockKey: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.handleUnlockButton() }
        }, onLockedKey: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.handleBackgroundClick() }
        })
        if !live {
            // Input blocking could not engage — never strand the user behind a
            // visible-but-non-functional lock. Roll back to unlocked and warn.
            inputBlocker.stop()
            kiosk.disengage()
            shield.hide()
            sleepGuard.end()
            _ = machine.abortLock()
            showTapFailureAlert()
        }
    }
```

- [ ] **Step 3: Delete the now-unused `startPermissionOnboarding()`**

`start()` no longer calls it and `requestAccessibilityThenLock()` replaces it. Delete the entire method (currently lines ~387–407):

```swift
    /// Walk the user through the two required privileges ONE AT A TIME, in order:
    /// Accessibility, then Input Monitoring. Each step opens its own Settings
    /// pane and waits until that privilege is granted before moving to the next.
    private func startPermissionOnboarding() {
        onboardingTask?.cancel()
        onboardingTask = Task { @MainActor in
            // The active keyboard tap needs only Accessibility (it supersedes
            // Input Monitoring), so this is a single step.
            if !InputBlocker.hasAccessibilityPermission() {
                _ = InputBlocker.ensureAccessibilityPermission(prompt: false) // register in the list
                guard self.promptPermissionStep(
                    name: "Erişilebilirlik",
                    paneURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                ) else { return }
                guard await self.waitForGrant({ InputBlocker.hasAccessibilityPermission() }) else {
                    self.showOnboardingTimeoutAlert(name: "Erişilebilirlik"); return
                }
            }
            // Granted — sit silently in the menu bar; the user locks on demand.
        }
    }
```

Keep `promptPermissionStep`, `waitForGrant`, and `showOnboardingTimeoutAlert` — they are reused by `requestAccessibilityThenLock()`.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!`, no errors, no new warnings. (If a warning fires about `hasRequiredPermissions` becoming unused, leave it — it is still part of `InputBlocker`'s public surface and used elsewhere; do not delete it. Confirm with `grep -rn hasRequiredPermissions Sources` that no other caller broke.)

- [ ] **Step 5: Build + full test suite stays green**

Run: `swift test`
Expected: 33/33 passing (this change touches no tested code; the suite must remain green).

- [ ] **Step 6: Manual verification (human — defer if running headless)**

`./bundle.sh` then launch, with Accessibility currently REVOKED for LeaveMyMacAlone (System Settings → Privacy → Accessibility → turn it off, or test on a fresh grant):
- Launch → no permission prompt appears at launch.
- Click "Şimdi Kilitle" (or press ⌃⌥⌘L) → the Accessibility alert appears; click through to Settings, enable LeaveMyMacAlone → the screen **locks automatically** within a few seconds, no second click needed.
- With Accessibility already granted: Lock works immediately, no onboarding.
- Press Lock twice quickly while the onboarding alert is up → only one onboarding flow, no double lock.

- [ ] **Step 7: Commit**

```bash
git add Sources/LeaveMyMacAlone/AppController.swift
git commit -m "feat: request Accessibility at lock time, auto-lock on grant"
```

---

### Task 2: Camera prompt fix + denied handling

**Files:**
- Modify: `Sources/LeaveMyMacAlone/MenuBarController.swift`
- Modify: `Resources/en.lproj/Localizable.strings`

**Interfaces:**
- Consumes: existing `AVCaptureDevice`, `UNUserNotificationCenter`, `NSApp`, `NSAlert`, `NSWorkspace` (AppKit/AVFoundation/UserNotifications already imported in this file).
- Produces: nothing for other tasks.

- [ ] **Step 1: Replace `primeIntruderPermissions()` and add `showCameraDeniedAlert()`**

Replace the current method (lines ~188–194):

```swift
    /// When the user enables intruder capture, request Camera + Notification
    /// permission now (a calm moment) so the prompts never appear mid-intrusion.
    private func primeIntruderPermissions() {
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
```

with:

```swift
    /// When the user enables intruder capture, request Camera permission now (a
    /// calm moment) so the prompt never appears mid-intrusion. For an accessory
    /// (menu-bar) app the TCC prompt only surfaces if we are the active app, so
    /// activate first. If the user previously denied camera, the system won't
    /// re-prompt — guide them to the Camera Settings pane instead.
    private func primeIntruderPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .video) { _ in }
        case .denied, .restricted:
            showCameraDeniedAlert()
        @unknown default:
            break
        }
        // Notifications power the unlock summary; independent of camera state.
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Camera was previously denied; the system won't re-prompt. Offer to open the
    /// Camera privacy pane so the user can enable it manually.
    private func showCameraDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Kamera izni gerekli",
                                              comment: "Camera denied title")
        alert.informativeText = NSLocalizedString(
            "İzinsiz giriş fotoğrafı çekebilmek için Kamera izni gerekiyor. Sistem Ayarları > Gizlilik ve Güvenlik > Kamera bölümünde LeaveMyMacAlone uygulamasına izin ver.",
            comment: "Camera denied body")
        alert.addButton(withTitle: NSLocalizedString("Kamera Ayarlarını Aç",
                                                     comment: "Open camera settings button"))
        alert.addButton(withTitle: NSLocalizedString("İptal", comment: "Cancel button"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
```

(`"İptal"` already has an English entry; only three new keys are added in Step 2.)

- [ ] **Step 2: Add the English localizations**

In `Resources/en.lproj/Localizable.strings`, under the `/* --- Permission onboarding & alerts (AppKit) --- */` section, add these three lines. Use **straight ASCII apostrophes only** (these strings contain none — keep it that way; do not let the editor insert curly quotes):

```
"Kamera izni gerekli" = "Camera permission required";
"İzinsiz giriş fotoğrafı çekebilmek için Kamera izni gerekiyor. Sistem Ayarları > Gizlilik ve Güvenlik > Kamera bölümünde LeaveMyMacAlone uygulamasına izin ver." = "Capturing intruder photos needs Camera access. In System Settings > Privacy & Security > Camera, allow LeaveMyMacAlone.";
"Kamera Ayarlarını Aç" = "Open Camera Settings";
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`, no errors, no new warnings.

- [ ] **Step 4: Verify the localization keys match the source literals exactly**

Run:
```bash
grep -c "Kamera izni gerekli" Resources/en.lproj/Localizable.strings
grep -c "Kamera Ayarlarını Aç" Resources/en.lproj/Localizable.strings
grep -nP "\x{2019}" Resources/en.lproj/Localizable.strings | grep -i kamera || echo "OK: no curly apostrophe in camera keys"
```
Expected: each `grep -c` prints `1`; the last prints `OK: no curly apostrophe in camera keys`.

- [ ] **Step 5: Manual verification (human — defer if running headless)**

`./bundle.sh`, launch:
- With camera `notDetermined` (never asked): open the panel, turn the intruder toggle ON → the **system Camera prompt appears**; grant it. Then lock, do 3 interactions → a photo lands in `~/Pictures/LeaveMyMacAlone/`.
- With camera previously denied (System Settings → Privacy → Camera → off for LeaveMyMacAlone): toggle ON → the "Kamera izni gerekli" alert appears; "Kamera Ayarlarını Aç" opens the Camera privacy pane.
- With camera already authorized: toggle ON → no camera prompt; capture works.

- [ ] **Step 6: Commit**

```bash
git add Sources/LeaveMyMacAlone/MenuBarController.swift Resources/en.lproj/Localizable.strings
git commit -m "fix: surface the Camera permission prompt for the menu-bar app, guide denied users"
```

---

## Self-Review

**Spec coverage:**
- Launch is permission-clean (remove onboarding from `start()`) → Task 1 Step 1. ✅
- Accessibility requested at lock time; auto-lock on grant; `lock()`/`engageLock()` split; re-entrancy guard → Task 1 Steps 2–3. ✅
- Camera `notDetermined` → activate + requestAccess (prompt fix) → Task 2 Step 1. ✅
- Camera `denied`/`restricted` → alert + open Camera Settings pane → Task 2 Step 1 (`showCameraDeniedAlert`). ✅
- Camera `authorized` → no-op; notification request kept independent → Task 2 Step 1. ✅
- New strings localized → Task 2 Step 2. ✅
- No changes to InputBlocker/tap/IntruderCapture/AVFoundationPhotographer → confirmed; no task touches them. ✅
- Build + manual verification, no forced unit tests → both tasks' Steps. ✅

**Placeholder scan:** No TBD/TODO; every edit shows complete code; every command has an expected result. ✅

**Type consistency:** `lock()` (entry), `engageLock()` (body), `requestAccessibilityThenLock()` defined and cross-referenced consistently in Task 1. `primeIntruderPermissions()` (replaced) and new `showCameraDeniedAlert()` consistent in Task 2. Reused helpers (`promptPermissionStep`, `waitForGrant`, `showOnboardingTimeoutAlert`, `onboardingTask`) are existing and unchanged. Settings-pane URLs match the Global Constraints verbatim. ✅
