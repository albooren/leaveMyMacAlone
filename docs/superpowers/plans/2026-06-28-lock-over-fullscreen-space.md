# Lock Over Full-Screen Space Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When locking from inside another app's native full-screen Space, pull that app out of full-screen so the lock shield covers the screen instead of landing on a Desktop Space.

**Architecture:** A new `FullScreenExiter` AX helper takes the frontmost app out of native full-screen using the Accessibility API. `AppController.engageLock()` calls it before showing the shield; exiting full-screen drops the user onto a Desktop Space the existing shield (`.canJoinAllSpaces`) already covers.

**Tech Stack:** Swift 6, AppKit (NSWorkspace), ApplicationServices (Accessibility / AXUIElement).

## Global Constraints

- Uses **Accessibility** only (`AXIsProcessTrusted`), already granted by the time `engageLock()` runs (lock-time permission gate). Reading/setting another app's `AXFullScreen` needs Accessibility but **NOT** AppleEvents — do not add any AppleEvents/AppleScript dependency.
- `AXFullScreen` is the window's full-screen Accessibility attribute; there is **no public Swift constant** for it — use the string `"AXFullScreen"`.
- The exit runs at the **top of `engageLock()`**, after `guard machine.lock()` and **before** `shield.show()` / app activation, while the other app is still frontmost.
- **Best-effort, never blocks the lock:** if the front app is ours, has no focused window, isn't full-screen, or uses a non-native full-screen (some games) → no-op; the lock proceeds unchanged.
- **No change** to `ShieldController`, the shield collection behavior/level, `InputBlocker`, or the auth flow.
- AX/AppKit side-effecting flow → verification is `swift build` + the existing `swift test` staying green + **manual**. No unit test is added (the logic is entirely AX calls; nothing pure extracts cleanly).

---

### Task 1: FullScreenExiter (Accessibility helper)

**Files:**
- Create: `Sources/LeaveMyMacAlone/FullScreenExiter.swift`

**Interfaces:**
- Consumes: AppKit (`NSWorkspace`, `NSRunningApplication`), ApplicationServices (`AXUIElement*`).
- Produces: `enum FullScreenExiter` with `@MainActor @discardableResult static func exitFrontmostFullScreen() -> Bool`.

- [ ] **Step 1: Create the helper**

Create `Sources/LeaveMyMacAlone/FullScreenExiter.swift`:

```swift
import AppKit
import ApplicationServices

/// Pulls the frontmost application out of native (green-button) full-screen so the
/// lock shield can cover it. A third-party window cannot cover ANOTHER app's
/// exclusive full-screen Space, so locking from inside one would otherwise leave
/// the shield stranded on a Desktop Space. Exiting the front app's full-screen
/// drops the user onto a Desktop Space the shield (`.canJoinAllSpaces`) covers.
///
/// Uses the Accessibility API (already granted for the event tap); reading/setting
/// another app's `AXFullScreen` needs Accessibility but NOT AppleEvents. Best
/// effort: an app with no focused window, or a non-native full-screen (some games)
/// that doesn't expose `AXFullScreen`, is left as-is.
enum FullScreenExiter {

    /// macOS exposes a window's full-screen state under this Accessibility
    /// attribute. There is no public Swift constant for it, so use the string.
    private static let fullScreenAttribute = "AXFullScreen" as CFString

    /// If the frontmost app (not us) has a focused window in native full-screen,
    /// take it out of full-screen. Returns whether it exited one (for logging).
    @discardableResult
    @MainActor
    static func exitFrontmostFullScreen() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = front.processIdentifier
        guard pid != NSRunningApplication.current.processIdentifier else { return false }

        let app = AXUIElementCreateApplication(pid)
        guard let window = focusedWindow(of: app), isFullScreen(window) else { return false }

        return AXUIElementSetAttributeValue(window, fullScreenAttribute, kCFBooleanFalse) == .success
    }

    /// The app's focused window, falling back to its main window.
    private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        copyWindow(app, kAXFocusedWindowAttribute as CFString)
            ?? copyWindow(app, kAXMainWindowAttribute as CFString)
    }

    private static func copyWindow(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, fullScreenAttribute, &value) == .success,
              let isFull = value as? Bool else { return false }
        return isFull
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!`, no errors, no new warnings.

(No unit test: the function is entirely Accessibility side effects against the live
window server — there is no pure logic to test. It is exercised by the manual test
in Task 2.)

- [ ] **Step 3: Commit**

```bash
git add Sources/LeaveMyMacAlone/FullScreenExiter.swift
git commit -m "feat: add FullScreenExiter to exit the frontmost app's native full-screen"
```

---

### Task 2: Call it at the top of engageLock()

**Files:**
- Modify: `Sources/LeaveMyMacAlone/AppController.swift`

**Interfaces:**
- Consumes: `FullScreenExiter.exitFrontmostFullScreen()` (Task 1).
- Produces: nothing for other tasks.

- [ ] **Step 1: Insert the call**

In `Sources/LeaveMyMacAlone/AppController.swift`, in `engageLock()`, add the
`FullScreenExiter` call immediately after the opening guard. Change:

```swift
    private func engageLock() {
        guard machine.lock() else { return } // ignore if not unlocked
        intruder.beginSession(enabled: store.captureIntruderPhoto)
```

to:

```swift
    private func engageLock() {
        guard machine.lock() else { return } // ignore if not unlocked
        // If the user is inside another app's native full-screen Space, our shield
        // (a third-party window) cannot cover it — pull that app out of full-screen
        // so the lock lands on a Desktop Space the shield covers. No-op otherwise.
        FullScreenExiter.exitFrontmostFullScreen()
        intruder.beginSession(enabled: store.captureIntruderPhoto)
```

- [ ] **Step 2: Build + full test suite**

Run: `swift build && swift test`
Expected: Build succeeds (no new warnings); `swift test` stays at 33/33 passing
(this change touches no tested code).

- [ ] **Step 3: Manual verification (human — defer if running headless)**

`./bundle.sh`, launch, with Accessibility granted:
- Put **Slack** (or Safari / QuickTime) into native full-screen (green button / ⌃⌘F),
  so it occupies its own Space. Press **⌃⌥⌘L**.
  → The app leaves full-screen and the lock shield covers the screen immediately
  (no need to switch Spaces manually).
- Lock from a regular Desktop Space → unchanged, still covers.
- Lock from a regular windowed app (not full-screen) → no app is disrupted (no-op),
  shield covers.
- Known limit: a game using its own (non-native) full-screen won't be pulled out —
  acceptable per the spec.

- [ ] **Step 4: Commit**

```bash
git add Sources/LeaveMyMacAlone/AppController.swift
git commit -m "fix: exit the frontmost app's full-screen on lock so the shield covers it"
```

---

## Self-Review

**Spec coverage:**
- Root cause / behavior (exit frontmost full-screen at lock time, before shield) → Task 2 (call site) + Task 1 (helper). ✅
- `FullScreenExiter.exitFrontmostFullScreen()` via AX (frontmost app, skip self, focused/main window, `AXFullScreen` set false) → Task 1. ✅
- Accessibility only, no AppleEvents; `AXFullScreen` as a string → Task 1 (uses `AXIsProcessTrusted`-gated AX calls and the `"AXFullScreen"` string). ✅
- Best-effort no-op (not full-screen / no window / self / non-native) → Task 1 (each guard returns false). ✅
- No change to ShieldController/InputBlocker/auth → confirmed; only AppController’s `engageLock` gains one line. ✅
- Build + manual, no unit tests → both tasks' steps. ✅

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every command has an expected result. ✅

**Type consistency:** `FullScreenExiter.exitFrontmostFullScreen()` defined in Task 1 with signature `@MainActor @discardableResult static func … -> Bool`, called (result discarded) in Task 2. Private helpers `focusedWindow(of:)`, `copyWindow(_:_:)`, `isFullScreen(_:)` and the `fullScreenAttribute` constant are self-consistent within Task 1. ✅
