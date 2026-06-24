# Transparency Live-Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a full-screen, live, non-locking preview of the lock-screen dim while the menu bar panel is open, so the user can judge the opacity against their real screen without locking.

**Architecture:** A new, self-contained `PreviewOverlayController` opens one borderless, click-through (`ignoresMouseEvents`) window per screen, just below the menu bar panel's level. Its SwiftUI content (`PreviewDimView`) observes `AppSettingsStore.overlayOpacity`, so it dims live as the slider moves. `MenuBarController` starts the preview when the panel opens and stops it when the panel closes. The preview never touches the event tap, kiosk, sleep guard, or lock state machine.

**Tech Stack:** Swift 6, AppKit (`NSWindow`, `NSScreen`, `NSHostingView`), SwiftUI, XCTest.

## Global Constraints

- Platform: macOS 14+ (`Package.swift` declares `.macOS(.v14)`).
- No new third-party dependencies.
- The preview is PURELY VISUAL: it must NOT engage `InputBlocker`, `KioskMode`, `SleepGuard`, or `LockStateMachine`.
- The preview must NEVER block input: every preview window has `ignoresMouseEvents = true`.
- UI copy is Turkish: the preview label reads exactly `Önizleme`.
- The test target already links the executable target `LeaveMyMacAlone` and uses `@testable import LeaveMyMacAlone` (see `Package.swift` and `Tests/LeaveMyMacAloneTests/InputBlockerTests.swift`).
- Build with `swift build`; test with `swift test`; package with `./bundle.sh`.

---

### Task 1: PreviewOverlayController + PreviewDimView

**Files:**
- Create: `Sources/LeaveMyMacAlone/PreviewOverlayController.swift`
- Test: `Tests/LeaveMyMacAloneTests/PreviewOverlayControllerTests.swift`

**Interfaces:**
- Consumes: `AppSettingsStore` (existing, `@MainActor`, `@Published var overlayOpacity: Double`).
- Produces:
  - `@MainActor final class PreviewOverlayController` with `init(store: AppSettingsStore)`, `func start()`, `func stop()`, and `var windowCountForTesting: Int { get }`.
  - `struct PreviewDimView: View` with `init(store: AppSettingsStore)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/LeaveMyMacAloneTests/PreviewOverlayControllerTests.swift`:

```swift
import XCTest
import AppKit
@testable import LeaveMyMacAlone

@MainActor
final class PreviewOverlayControllerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared   // ensure AppKit is initialised for window creation
    }

    func testFreshControllerHasNoWindows() {
        let controller = PreviewOverlayController(store: AppSettingsStore())
        XCTAssertEqual(controller.windowCountForTesting, 0)
    }

    func testStartCreatesOneWindowPerScreen() {
        let controller = PreviewOverlayController(store: AppSettingsStore())
        controller.start()
        XCTAssertEqual(controller.windowCountForTesting, NSScreen.screens.count)
        controller.stop()
    }

    func testStopRemovesAllWindows() {
        let controller = PreviewOverlayController(store: AppSettingsStore())
        controller.start()
        controller.stop()
        XCTAssertEqual(controller.windowCountForTesting, 0)
    }

    func testStartIsIdempotent() {
        let controller = PreviewOverlayController(store: AppSettingsStore())
        controller.start()
        let first = controller.windowCountForTesting
        controller.start()
        XCTAssertEqual(controller.windowCountForTesting, first)
        controller.stop()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PreviewOverlayControllerTests`
Expected: FAIL — compile error, "cannot find 'PreviewOverlayController' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/LeaveMyMacAlone/PreviewOverlayController.swift`:

```swift
import AppKit
import SwiftUI

/// Live, non-locking preview of the lock-screen dim. Purely visual: it never
/// engages the event tap, kiosk, sleep guard, or lock state machine. Shown while
/// the menu bar panel is open so the user can judge the opacity against their
/// real screen.
@MainActor
final class PreviewOverlayController {
    private let store: AppSettingsStore
    private var windows: [NSWindow] = []

    init(store: AppSettingsStore) {
        self.store = store
    }

    /// Number of live preview windows (0 when not previewing). Test hook.
    var windowCountForTesting: Int { windows.count }

    func start() {
        guard windows.isEmpty else { return }   // already previewing
        // Just below the menu bar panel (.popUpMenu) so the panel and its slider
        // stay on top and interactive, while the dim covers everything else.
        let level = NSWindow.Level(rawValue: Int(NSWindow.Level.popUpMenu.rawValue) - 1)
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = level
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = true        // never blocks input
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

            let host = NSHostingView(rootView: PreviewDimView(store: store))
            host.frame = window.contentLayoutRect
            host.autoresizingMask = [.width, .height]
            window.contentView = host

            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func stop() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }
}

/// Full-screen dim bound to the live opacity, with a small "Önizleme" badge so
/// the dimmed screen is clearly a preview and not an actual lock.
struct PreviewDimView: View {
    @ObservedObject var store: AppSettingsStore

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
                .opacity(store.overlayOpacity)
                .ignoresSafeArea()

            Label("Önizleme", systemImage: "lock.shield")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 6)
                .padding(.top, 64)
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter PreviewOverlayControllerTests`
Expected: PASS — 4 tests, 0 failures. (On a machine with no attached screens, `NSScreen.screens` is empty and the per-screen test trivially passes with 0 == 0.)

- [ ] **Step 5: Run the full suite to confirm no regressions**

Run: `swift test`
Expected: `Executed 21 tests, with 0 failures` (17 existing + 4 new).

- [ ] **Step 6: Commit**

```bash
git add Sources/LeaveMyMacAlone/PreviewOverlayController.swift Tests/LeaveMyMacAloneTests/PreviewOverlayControllerTests.swift
git commit -m "feat: add non-locking transparency preview overlay"
```

---

### Task 2: Wire the preview into the menu bar panel lifecycle

**Files:**
- Modify: `Sources/LeaveMyMacAlone/MenuBarController.swift`

**Interfaces:**
- Consumes: `PreviewOverlayController(store:)`, `.start()`, `.stop()` from Task 1.
- Produces: no new public surface; `MenuBarController` now drives the preview.

- [ ] **Step 1: Add the preview property and initialise it**

In `MenuBarController`, add the stored property next to the existing ones:

```swift
    private let statusItem: NSStatusItem
    private let preview: PreviewOverlayController
    private var panel: KeyablePanel?
```

And set it in `init(store:)` BEFORE `configureStatusButton()` (all stored properties must be initialised first):

```swift
    init(store: AppSettingsStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.preview = PreviewOverlayController(store: store)
        configureStatusButton()
    }
```

- [ ] **Step 2: Start the preview when the panel opens**

At the END of `openPanel()`, after `installDismissMonitors()`:

```swift
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        self.panel = panel
        installDismissMonitors()
        preview.start()          // live dim preview while the panel is open
    }
```

- [ ] **Step 3: Stop the preview when the panel closes**

At the START of `closePanel()`, before removing the monitors:

```swift
    private func closePanel() {
        preview.stop()           // revert the screen to normal
        if let monitor = globalClickMonitor { NSEvent.removeMonitor(monitor); globalClickMonitor = nil }
        if let monitor = localKeyMonitor { NSEvent.removeMonitor(monitor); localKeyMonitor = nil }
        statusItem.button?.highlight(false)
        panel?.orderOut(nil)
        panel = nil
    }
```

- [ ] **Step 4: Build and run the full test suite**

Run: `swift build && swift test`
Expected: build succeeds; `Executed 21 tests, with 0 failures`.

- [ ] **Step 5: Package and launch for manual verification**

Run: `./bundle.sh && open LeaveMyMacAlone.app`

Manual checklist (no permissions/locking needed):
1. Click the menu bar icon → the panel opens AND the screen dims live at the current opacity, with an "Önizleme" badge near the top.
2. Drag the Saydamlık slider → the dim updates live as you drag.
3. Click another app / the desktop through the dim → the click passes through (the preview never blocks input); the panel's transient dismiss closes the panel and the dim reverts.
4. Reopen, then press Escape or click "Şimdi Kilitle"/"Çıkış" → the dim reverts (and for "Şimdi Kilitle", the real lock shield then appears).

- [ ] **Step 6: Commit**

```bash
git add Sources/LeaveMyMacAlone/MenuBarController.swift
git commit -m "feat: live transparency preview while the menu bar panel is open"
```

---

## Self-Review

**1. Spec coverage:**
- Full-screen, live, non-locking preview → Task 1 (`PreviewOverlayController` windows, `ignoresMouseEvents`, no lock machinery) + Task 2 (panel lifecycle). ✓
- Dim only + "Önizleme" label, no lock UI → `PreviewDimView` (Task 1, Step 3). ✓
- Live updates as slider moves → `PreviewDimView` observes `store.overlayOpacity` (`@Published`). ✓
- Reverts when panel closes → `closePanel()` calls `preview.stop()` (Task 2, Step 3). ✓
- Below the panel, above apps/menu bar → level `.popUpMenu − 1` (Task 1, Step 3). ✓
- Multi-display → one window per `NSScreen` (Task 1, Step 3). ✓
- No-ghost-dim invariant → `stop()` clears all windows; lifecycle test (Task 1). ✓
- "Şimdi Kilitle"/"Çıkış" stop preview first → existing `SettingsView` buttons call `closePanel()` before `onLockNow()/onQuit()`. ✓

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"/uncoded steps. All code is complete. ✓

**3. Type consistency:** `PreviewOverlayController(store:)`, `start()`, `stop()`, `windowCountForTesting`, `PreviewDimView(store:)` are used identically in the test, the implementation, and the `MenuBarController` wiring. `AppSettingsStore.overlayOpacity` matches the existing declaration. ✓
