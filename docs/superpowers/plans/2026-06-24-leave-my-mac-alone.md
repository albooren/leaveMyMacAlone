# Leave My Mac Alone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu-bar app that, on launch, keeps the Mac awake and drops a transparent full-screen kiosk lock so coworkers cannot touch the machine while a background task runs; the owner unlocks with Touch ID / password.

**Architecture:** Swift Package Manager project with a pure, unit-tested core library (`LeaveMyMacAloneCore`: transparency clamp + lock state machine) and an AppKit/SwiftUI executable (`LeaveMyMacAlone`) that orchestrates IOKit power assertions, a CGEventTap input blocker, NSApplication kiosk presentation options, per-screen shielding windows, a Carbon global hotkey, and a LocalAuthentication unlock. A `bundle.sh` script hand-assembles and ad-hoc-signs a `.app` (no Xcode project, no Homebrew).

**Tech Stack:** Swift 6.2 (Swift 6 language mode), AppKit, SwiftUI, LocalAuthentication, IOKit.pwr_mgt, CoreGraphics (CGEventTap), Carbon.HIToolbox, XCTest.

## Global Constraints

- Platform floor `LSMinimumSystemVersion` 14.0; built/verified on macOS 26.5 (Apple Silicon), Xcode 26.2, Swift 6.2.3.
- Package: `swift-tools-version:6.0` → Swift 6 language mode (strict concurrency). All code must compile clean under it.
- Build tooling: Swift Package Manager + a bash bundle script ONLY. No Xcode project, no Homebrew, no third-party dependencies.
- Bundle identifier: `com.alperenkisi.leavemymacalone`. Executable/product name: `LeaveMyMacAlone`. App display name: `Leave My Mac Alone`.
- App is **non-sandboxed** (entitlement `com.apple.security.app-sandbox` = `false`) and **ad-hoc signed** (`codesign --sign -`) with the hardened runtime.
- App is a menu-bar accessory: `LSUIElement` = `true` in Info.plist **and** `NSApp.setActivationPolicy(.accessory)` in code.
- Runtime permissions the user must grant once: **Accessibility** and **Input Monitoring** (both, for the consuming CGEventTap). Ad-hoc rebuilds change the cdhash → the grant resets and must be re-given.
- SSH recovery (kiosk lock release if the app hangs): `ssh <user>@<mac> 'killall LeaveMyMacAlone'`; requires macOS **Remote Login** enabled beforehand.
- All user-facing UI strings are Turkish.
- Kiosk lockdown is "stop a pranking coworker," NOT security-grade. Honest limitations (documented, not fixed): closing the lid on a bare laptop still sleeps; holding the power button still hard-powers-off; the OS login/screensaver secure path sits above a session event tap.

---

### Task 1: Project scaffold (Package, core namespace, build + test green)

**Files:**
- Create: `Package.swift`
- Create: `Sources/LeaveMyMacAloneCore/LeaveMyMacAloneCore.swift`
- Create: `Sources/LeaveMyMacAlone/main.swift`
- Create: `Tests/LeaveMyMacAloneTests/CoreTests.swift`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `enum LeaveMyMacAloneCore { static let bundleIdentifier: String }`; an executable target `LeaveMyMacAlone` linking AppKit/SwiftUI/LocalAuthentication/IOKit/Carbon; a test target `LeaveMyMacAloneTests` that `@testable import LeaveMyMacAloneCore`.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LeaveMyMacAlone",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "LeaveMyMacAloneCore"
        ),
        .executableTarget(
            name: "LeaveMyMacAlone",
            dependencies: ["LeaveMyMacAloneCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon")
            ]
        ),
        .testTarget(
            name: "LeaveMyMacAloneTests",
            dependencies: ["LeaveMyMacAloneCore"]
        )
    ]
)
```

- [ ] **Step 2: Write the core namespace file**

`Sources/LeaveMyMacAloneCore/LeaveMyMacAloneCore.swift`:

```swift
public enum LeaveMyMacAloneCore {
    public static let bundleIdentifier = "com.alperenkisi.leavemymacalone"
}
```

- [ ] **Step 3: Write a minimal executable entry point (stub; replaced in Task 12)**

`Sources/LeaveMyMacAlone/main.swift`:

```swift
import AppKit

// Minimal bootstrap so the executable target compiles.
// Replaced by the real AppDelegate/AppController bootstrap in Task 12.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
```

- [ ] **Step 4: Write the scaffold test**

`Tests/LeaveMyMacAloneTests/CoreTests.swift`:

```swift
import XCTest
@testable import LeaveMyMacAloneCore

final class CoreTests: XCTestCase {
    func testBundleIdentifier() {
        XCTAssertEqual(LeaveMyMacAloneCore.bundleIdentifier,
                       "com.alperenkisi.leavemymacalone")
    }
}
```

- [ ] **Step 5: Build and run tests to verify green**

Run: `swift build && swift test`
Expected: build succeeds; test run reports `Test Suite 'All tests' passed`, `1 test`, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "feat: scaffold SwiftPM package with core namespace"
```

---

### Task 2: Transparency model (Core, TDD)

**Files:**
- Create: `Sources/LeaveMyMacAloneCore/Transparency.swift`
- Create: `Tests/LeaveMyMacAloneTests/TransparencyTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum Transparency { static let range: ClosedRange<Double> /* 0.0...0.85 */; static let defaultOpacity: Double /* 0.5 */; static func clamp(_ value: Double) -> Double }`. Used by `AppSettingsStore` (Task 4) and `SettingsView` (Task 11).

- [ ] **Step 1: Write the failing test**

`Tests/LeaveMyMacAloneTests/TransparencyTests.swift`:

```swift
import XCTest
@testable import LeaveMyMacAloneCore

final class TransparencyTests: XCTestCase {
    func testClampWithinRangeReturnsSameValue() {
        XCTAssertEqual(Transparency.clamp(0.5), 0.5)
    }

    func testClampBelowRangeReturnsLowerBound() {
        XCTAssertEqual(Transparency.clamp(-1.0), 0.0)
    }

    func testClampAboveRangeReturnsUpperBound() {
        XCTAssertEqual(Transparency.clamp(2.0), 0.85)
    }

    func testDefaultOpacityIsWithinRange() {
        XCTAssertTrue(Transparency.range.contains(Transparency.defaultOpacity))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TransparencyTests`
Expected: FAIL — compile error "cannot find 'Transparency' in scope".

- [ ] **Step 3: Write the implementation**

`Sources/LeaveMyMacAloneCore/Transparency.swift`:

```swift
/// Overlay opacity model. Clamped to a range that always lets the user see
/// through enough to watch the background task, while signalling "locked".
public enum Transparency {
    public static let range: ClosedRange<Double> = 0.0...0.85
    public static let defaultOpacity: Double = 0.5

    public static func clamp(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TransparencyTests`
Expected: PASS — 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/LeaveMyMacAloneCore/Transparency.swift Tests/LeaveMyMacAloneTests/TransparencyTests.swift
git commit -m "feat: add transparency clamp model"
```

---

### Task 3: Lock state machine (Core, TDD)

**Files:**
- Create: `Sources/LeaveMyMacAloneCore/LockState.swift`
- Create: `Tests/LeaveMyMacAloneTests/LockStateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum LockState: Equatable { case unlocked, locked, authenticating }`
  - `struct LockStateMachine { var state: LockState { get } /* private(set) */; init(); mutating func lock() -> Bool; mutating func beginAuth() -> Bool; mutating func authSucceeded() -> Bool; mutating func authFailed() -> Bool }`. Each mutator returns `true` if the transition was legal (and applied), `false` otherwise (state unchanged). Used by `AppController` (Task 12).

- [ ] **Step 1: Write the failing test**

`Tests/LeaveMyMacAloneTests/LockStateTests.swift`:

```swift
import XCTest
@testable import LeaveMyMacAloneCore

final class LockStateTests: XCTestCase {
    func testStartsUnlocked() {
        let machine = LockStateMachine()
        XCTAssertEqual(machine.state, .unlocked)
    }

    func testLockFromUnlocked() {
        var machine = LockStateMachine()
        XCTAssertTrue(machine.lock())
        XCTAssertEqual(machine.state, .locked)
    }

    func testCannotLockWhenAlreadyLocked() {
        var machine = LockStateMachine()
        _ = machine.lock()
        XCTAssertFalse(machine.lock())
        XCTAssertEqual(machine.state, .locked)
    }

    func testBeginAuthFromLocked() {
        var machine = LockStateMachine()
        _ = machine.lock()
        XCTAssertTrue(machine.beginAuth())
        XCTAssertEqual(machine.state, .authenticating)
    }

    func testBeginAuthInvalidFromUnlocked() {
        var machine = LockStateMachine()
        XCTAssertFalse(machine.beginAuth())
        XCTAssertEqual(machine.state, .unlocked)
    }

    func testAuthSucceededReturnsToUnlocked() {
        var machine = LockStateMachine()
        _ = machine.lock()
        _ = machine.beginAuth()
        XCTAssertTrue(machine.authSucceeded())
        XCTAssertEqual(machine.state, .unlocked)
    }

    func testAuthFailedReturnsToLocked() {
        var machine = LockStateMachine()
        _ = machine.lock()
        _ = machine.beginAuth()
        XCTAssertTrue(machine.authFailed())
        XCTAssertEqual(machine.state, .locked)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LockStateTests`
Expected: FAIL — compile error "cannot find 'LockStateMachine' in scope".

- [ ] **Step 3: Write the implementation**

`Sources/LeaveMyMacAloneCore/LockState.swift`:

```swift
public enum LockState: Equatable {
    case unlocked
    case locked
    case authenticating
}

/// Coordinates the lock lifecycle. Transitions:
/// unlocked --lock--> locked --beginAuth--> authenticating
/// authenticating --authSucceeded--> unlocked
/// authenticating --authFailed--> locked
/// Illegal transitions are rejected (return false, state unchanged).
public struct LockStateMachine {
    public private(set) var state: LockState

    public init() {
        state = .unlocked
    }

    public mutating func lock() -> Bool {
        guard state == .unlocked else { return false }
        state = .locked
        return true
    }

    public mutating func beginAuth() -> Bool {
        guard state == .locked else { return false }
        state = .authenticating
        return true
    }

    public mutating func authSucceeded() -> Bool {
        guard state == .authenticating else { return false }
        state = .unlocked
        return true
    }

    public mutating func authFailed() -> Bool {
        guard state == .authenticating else { return false }
        state = .locked
        return true
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LockStateTests`
Expected: PASS — 7 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/LeaveMyMacAloneCore/LockState.swift Tests/LeaveMyMacAloneTests/LockStateTests.swift
git commit -m "feat: add lock state machine"
```

---

> **Note on Tasks 4–12 (app layer):** These build AppKit/SwiftUI/system-integration components that cannot be meaningfully unit-tested (NSStatusItem, CGEventTap, IOKit assertions, LAContext). Their automated gate is **`swift build` compiling clean under Swift 6**. Behavioral verification is consolidated into the end-to-end manual checklist in Task 14. Do NOT fabricate mock unit tests for these.

---

### Task 4: AppSettingsStore (persisted overlay opacity)

**Files:**
- Create: `Sources/LeaveMyMacAlone/AppSettingsStore.swift`

**Interfaces:**
- Consumes: `Transparency.clamp`, `Transparency.defaultOpacity` (Task 2).
- Produces: `@MainActor final class AppSettingsStore: ObservableObject { @Published var overlayOpacity: Double; var onOpacityChange: ((Double) -> Void)?; init() }`. `overlayOpacity` is clamped on set and persisted to `UserDefaults` key `"overlayOpacity"`; `onOpacityChange` fires (on the main actor) after each committed change. Used by `MenuBarController` (Task 11) and `AppController` (Task 12).

- [ ] **Step 1: Write the implementation**

`Sources/LeaveMyMacAlone/AppSettingsStore.swift`:

```swift
import Foundation
import Combine
import LeaveMyMacAloneCore

/// Observable, persisted settings. `overlayOpacity` is clamped to
/// Transparency.range on every set and mirrored to UserDefaults.
@MainActor
final class AppSettingsStore: ObservableObject {

    static let opacityKey = "overlayOpacity"

    /// Notified on every committed change so a live consumer (the shield
    /// window) can update its alpha while the user drags the slider.
    var onOpacityChange: ((Double) -> Void)?

    @Published var overlayOpacity: Double {
        didSet {
            let clamped = Transparency.clamp(overlayOpacity)
            // Re-assign once if clamping changed the value; the guard below
            // prevents infinite recursion through didSet.
            if clamped != overlayOpacity {
                overlayOpacity = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.opacityKey)
            onOpacityChange?(clamped)
        }
    }

    init() {
        // object(forKey:) (not double(forKey:)) so a missing key is
        // distinguishable from a stored 0.0.
        let stored = UserDefaults.standard.object(forKey: Self.opacityKey) as? Double
        overlayOpacity = Transparency.clamp(stored ?? Transparency.defaultOpacity)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: build succeeds, no warnings.

- [ ] **Step 3: Commit**

```bash
git add Sources/LeaveMyMacAlone/AppSettingsStore.swift
git commit -m "feat: add persisted overlay opacity store"
```

---

### Task 5: SleepGuard (IOKit power assertions)

**Files:**
- Create: `Sources/LeaveMyMacAlone/SleepGuard.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `final class SleepGuard { func begin(); func end() }`. `begin()` acquires a display-sleep assertion (keeps screen on AND blocks idle system sleep) plus an explicit idle-system-sleep assertion; both idempotent. `end()` releases them. Used by `AppController` (Task 12).

- [ ] **Step 1: Write the implementation**

`Sources/LeaveMyMacAlone/SleepGuard.swift`:

```swift
import Foundation
import IOKit.pwr_mgt

/// Holds IOKit power assertions to keep the display awake and prevent idle
/// system sleep while the overlay is shown / a background task runs.
///
/// LIMITATION: assertions only block *idle* sleep. They do NOT prevent
/// lid-close (clamshell) sleep on a bare laptop, Apple menu > Sleep, low
/// battery, or thermal sleep.
final class SleepGuard {

    private var displayAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var systemAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var displayHeld = false
    private var systemHeld = false

    private let reason = "Showing lock overlay while a background task runs" as CFString

    /// Acquire both assertions. Safe to call repeatedly (no-op if already held).
    func begin() {
        let level = IOPMAssertionLevel(kIOPMAssertionLevelOn) // 255

        // Keeps the screen ON; per IOPMLib.h this also prevents idle system sleep.
        if !displayHeld {
            var id = IOPMAssertionID(0)
            let rc = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                level,
                reason,
                &id)
            if rc == kIOReturnSuccess {
                displayAssertionID = id
                displayHeld = true
            } else {
                NSLog("SleepGuard: display assertion failed: \(String(format: "0x%08x", rc))")
            }
        }

        // Explicit idle-system-sleep assertion (belt-and-suspenders).
        if !systemHeld {
            var id = IOPMAssertionID(0)
            let rc = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                level,
                reason,
                &id)
            if rc == kIOReturnSuccess {
                systemAssertionID = id
                systemHeld = true
            } else {
                NSLog("SleepGuard: system assertion failed: \(String(format: "0x%08x", rc))")
            }
        }
    }

    /// Release both assertions. Safe to call repeatedly.
    func end() {
        if displayHeld {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = IOPMAssertionID(0)
            displayHeld = false
        }
        if systemHeld {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = IOPMAssertionID(0)
            systemHeld = false
        }
    }

    deinit { end() }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/LeaveMyMacAlone/SleepGuard.swift
git commit -m "feat: add IOKit sleep guard"
```

---

### Task 6: ShieldController (per-screen transparent overlay windows)

**Files:**
- Create: `Sources/LeaveMyMacAlone/ShieldController.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `final class KeyableWindow: NSWindow` (overrides `canBecomeKey`/`canBecomeMain` → true).
  - `struct OverlayView: View` (internal; takes `let opacity: Double`).
  - `@MainActor final class ShieldController { func show(opacity: Double); func setOpacity(_ opacity: Double); func hide() }`. Covers every `NSScreen` at `CGShieldingWindowLevel()`, rebuilds on screen-parameter changes. Used by `AppController` (Task 12).

- [ ] **Step 1: Write the implementation**

`Sources/LeaveMyMacAlone/ShieldController.swift`:

```swift
import AppKit
import SwiftUI

// Borderless windows return false from canBecomeKey by default, which drops
// keyboard input. Override so the shield can become key.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// SwiftUI overlay: an adjustable dark tint plus an always-visible lock badge
// and live clock, so even at low opacity the "locked" state is unmistakable.
struct OverlayView: View {
    let opacity: Double

    var body: some View {
        ZStack {
            Color.black.opacity(opacity).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 48, weight: .semibold))
                Text("Kilitli — açmak için dokun")
                    .font(.title3.weight(.medium))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date, style: .time)
                        .font(.system(size: 30, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 6)
        }
        // Non-zero hit area so the window registers clicks at any opacity.
        .contentShape(Rectangle())
    }
}

@MainActor
final class ShieldController {
    private var windows: [KeyableWindow] = []
    private var screenObserver: NSObjectProtocol?
    // Overwritten by show(opacity:) before any window is built; the literal is
    // only a placeholder so the property is initialised.
    private var currentOpacity: Double = 0.5

    deinit {
        if let token = screenObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func show(opacity: Double) {
        currentOpacity = opacity
        rebuildWindows()
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuildWindows() }
            }
        }
        // Allow the borderless app to become active so the window can be key.
        NSApp.activate()
        windows.first?.makeKeyAndOrderFront(nil)
    }

    func setOpacity(_ opacity: Double) {
        currentOpacity = opacity
        for window in windows {
            (window.contentView as? NSHostingView<OverlayView>)?
                .rootView = OverlayView(opacity: opacity)
        }
    }

    func hide() {
        if let token = screenObserver {
            NotificationCenter.default.removeObserver(token)
            screenObserver = nil
        }
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }

    private func rebuildWindows() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()

        // CGShieldingWindowLevel(): above normal apps, the Dock, and the menu
        // bar, but below the system auth sheet (the intended unlock path).
        let shieldLevel = Int(CGShieldingWindowLevel())

        for screen in NSScreen.screens {
            let window = KeyableWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = NSWindow.Level(rawValue: shieldLevel)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.setFrame(screen.frame, display: true)

            let host = NSHostingView(rootView: OverlayView(opacity: currentOpacity))
            host.frame = window.contentLayoutRect
            host.autoresizingMask = [.width, .height]
            window.contentView = host

            window.orderFrontRegardless()
            windows.append(window)
        }
        windows.first?.makeKeyAndOrderFront(nil)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: build succeeds. (If a strict-concurrency diagnostic appears on the `MainActor.assumeIsolated` line, confirm the observer `queue: .main` is present — it guarantees main-thread delivery, making `assumeIsolated` valid.)

- [ ] **Step 3: Commit**

```bash
git add Sources/LeaveMyMacAlone/ShieldController.swift
git commit -m "feat: add per-screen transparent shield windows"
```

---

### Task 7: InputBlocker (CGEventTap consuming all input)

**Files:**
- Create: `Sources/LeaveMyMacAlone/InputBlocker.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `final class InputBlocker { func start(onFirstInteraction: @escaping () -> Void); func pause(); func resume(); func stop(); static func hasRequiredPermissions() -> Bool; static func requestPermissions() }`. `start` installs an active session tap that swallows all keyboard/mouse events and calls `onFirstInteraction` (dispatched to the main thread) on the first event; `pause`/`resume` toggle consumption (used so the password fallback can be typed during auth). Used by `AppController` (Task 12).

- [ ] **Step 1: Write the implementation**

`Sources/LeaveMyMacAlone/InputBlocker.swift`:

```swift
import Cocoa
import CoreGraphics
import ApplicationServices

/// Consuming (.defaultTap) session-level CGEventTap that swallows all
/// keyboard and mouse input while the Mac is locked.
///
/// PERMISSIONS: a consuming tap is gated by Input Monitoring (TCC ListenEvent)
/// and may additionally need Accessibility. We request both but never treat a
/// preflight as a hard gate — the authoritative test is whether the tap is
/// actually live (CGEvent.tapIsEnabled).
final class InputBlocker {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onFirstInteraction: (() -> Void)?
    private var firstInteractionFired = false

    // MARK: - Permissions

    /// True only if BOTH privileges that a consuming tap can need are present.
    static func hasRequiredPermissions() -> Bool {
        CGPreflightListenEventAccess() && AXIsProcessTrusted()
    }

    /// Trigger both system permission prompts (no-op if already granted).
    static func requestPermissions() {
        _ = ensureInputMonitoringPermission()
        _ = ensureAccessibilityPermission(prompt: true)
    }

    @discardableResult
    static func ensureInputMonitoringPermission() -> Bool {
        if CGPreflightListenEventAccess() { return true }
        return CGRequestListenEventAccess()
    }

    @discardableResult
    static func ensureAccessibilityPermission(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Lifecycle

    func start(onFirstInteraction: @escaping () -> Void) {
        guard eventTap == nil else { return }
        self.onFirstInteraction = onFirstInteraction
        self.firstInteractionFired = false

        guard installTap() else {
            NSLog("InputBlocker: tapCreate failed (grant Input Monitoring AND Accessibility).")
            return
        }
    }

    @discardableResult
    private func installTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else {
                return Unmanaged.passUnretained(event)
            }
            let blocker = Unmanaged<InputBlocker>.fromOpaque(refcon).takeUnretainedValue()
            return blocker.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) else {
            return false
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // A non-nil tap is NOT a guarantee it is live.
        guard CGEvent.tapIsEnabled(tap: tap) else {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
            return false
        }

        self.eventTap = tap
        self.runLoopSource = src
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable if the system disabled us; fully reinstall if that fails.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                if !CGEvent.tapIsEnabled(tap: tap) {
                    teardownTap()
                    _ = installTap()
                }
            }
            return nil
        }

        if !firstInteractionFired {
            firstInteractionFired = true
            DispatchQueue.main.async { [weak self] in
                self?.onFirstInteraction?()
            }
        }

        // Swallow every event while locked.
        return nil
    }

    func pause() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
    }

    func resume() {
        guard let tap = eventTap else { return }
        firstInteractionFired = false
        CGEvent.tapEnable(tap: tap, enable: true)
        if !CGEvent.tapIsEnabled(tap: tap) {
            teardownTap()
            _ = installTap()
        }
    }

    private func teardownTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    func stop() {
        teardownTap()
        onFirstInteraction = nil
        firstInteractionFired = false
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/LeaveMyMacAlone/InputBlocker.swift
git commit -m "feat: add consuming CGEventTap input blocker"
```

---

### Task 8: KioskMode (NSApplication presentation options)

**Files:**
- Create: `Sources/LeaveMyMacAlone/KioskMode.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `@MainActor final class KioskMode { func engage(); func disengage() }`. `engage()` promotes to `.regular`, activates, and sets a validated kiosk presentation bitmask; `disengage()` restores `presentationOptions = []` and the prior activation policy. Used by `AppController` (Task 12).

- [ ] **Step 1: Write the implementation**

`Sources/LeaveMyMacAlone/KioskMode.swift`:

```swift
import AppKit

/// Kiosk lockdown via NSApplication.presentationOptions: disables Cmd+Tab,
/// Cmd+Opt+Esc (force quit), logout/restart/shutdown, and hides Dock + menu bar.
///
/// The combination below is the documented valid set: every disable* flag and
/// hideMenuBar require hideDock, which is present. An invalid combination would
/// raise an (uncatchable) NSInvalidArgumentException, so do not edit the set
/// without re-checking the mutual-requirement rules.
@MainActor
final class KioskMode {

    private var savedPolicy: NSApplication.ActivationPolicy?
    private var isEngaged = false

    private static let lockedOptions: NSApplicationPresentationOptions = [
        .hideDock,
        .hideMenuBar,
        .disableProcessSwitching,
        .disableForceQuit,
        .disableSessionTermination,
        .disableHideApplication,
        .disableAppleMenu
    ]

    func engage() {
        guard !isEngaged else { return }
        let app = NSApplication.shared

        // An .accessory/LSUIElement app cannot own presentationOptions and is
        // never frontmost; promote to .regular and activate first.
        savedPolicy = app.activationPolicy()
        if app.activationPolicy() != .regular {
            app.setActivationPolicy(.regular)
        }
        app.activate() // non-deprecated form (macOS 14+)

        app.presentationOptions = Self.lockedOptions
        isEngaged = true
    }

    func disengage() {
        guard isEngaged else { return }
        let app = NSApplication.shared

        app.presentationOptions = [] // always restore to empty

        if let policy = savedPolicy, policy != app.activationPolicy() {
            app.setActivationPolicy(policy) // back to .accessory
        }
        savedPolicy = nil
        isEngaged = false
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/LeaveMyMacAlone/KioskMode.swift
git commit -m "feat: add kiosk presentation-options lockdown"
```

---

### Task 9: Authenticator (Touch ID / password unlock)

**Files:**
- Create: `Sources/LeaveMyMacAlone/Authenticator.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `final class Authenticator { func authenticate(reason: String) async -> Bool }`. Presents Touch ID with automatic password fallback via `LAPolicy.deviceOwnerAuthentication`; returns `true` only on success. Used by `AppController` (Task 12). The async/continuation form is used deliberately to avoid `@Sendable` closure-capture friction with the `@MainActor` caller.

- [ ] **Step 1: Write the implementation**

`Sources/LeaveMyMacAlone/Authenticator.swift`:

```swift
import LocalAuthentication

/// Touch ID with automatic password fallback. `.deviceOwnerAuthentication`
/// presents Touch ID first and falls back to the device password (and goes
/// straight to password on Macs with no Touch ID sensor).
final class Authenticator {

    func authenticate(reason: String) async -> Bool {
        // Fresh context per attempt: an LAContext caches its result and reuse
        // can silently skip the prompt.
        let context = LAContext()
        context.localizedFallbackTitle = "Parolayı Gir"

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication,
                                        error: &policyError) else {
            // No password/biometry configured.
            return false
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            context.evaluatePolicy(.deviceOwnerAuthentication,
                                   localizedReason: reason) { success, _ in
                // Any non-success (cancel, failure, lockout) → false → re-lock.
                continuation.resume(returning: success)
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/LeaveMyMacAlone/Authenticator.swift
git commit -m "feat: add Touch ID / password authenticator"
```

---

### Task 10: GlobalHotKey (Carbon ⌃⌥⌘L)

**Files:**
- Create: `Sources/LeaveMyMacAlone/GlobalHotKey.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `final class GlobalHotKey { init(onPressed: @escaping () -> Void) }`. Registers a system-wide ⌃⌥⌘L hotkey (no Accessibility permission needed) and calls `onPressed` on the main thread when fired; unregisters on `deinit`. Used by `AppController` (Task 12).

- [ ] **Step 1: Write the implementation**

`Sources/LeaveMyMacAlone/GlobalHotKey.swift`:

```swift
import Carbon.HIToolbox  // RegisterEventHotKey, InstallEventHandler, kVK_ANSI_L, controlKey...
import AppKit

/// System-wide hot key (⌃⌥⌘L) via Carbon. No Accessibility/TCC permission
/// required (registers with the WindowServer rather than tapping events).
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPressed: () -> Void

    init(onPressed: @escaping () -> Void) {
        self.onPressed = onPressed

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C4D4D41) /* 'LMMA' */, id: 1)

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var firedID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &firedID)
                guard status == noErr else { return status }

                let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                if firedID.id == 1 {
                    DispatchQueue.main.async { me.onPressed() }
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &handlerRef)

        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let err = RegisterEventHotKey(
            UInt32(kVK_ANSI_L), // 0x25
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0, // kEventHotKeyNoOptions
            &hotKeyRef)
        if err != noErr {
            NSLog("GlobalHotKey: RegisterEventHotKey failed: \(err)")
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/LeaveMyMacAlone/GlobalHotKey.swift
git commit -m "feat: add Carbon global re-lock hotkey"
```

---

### Task 11: MenuBarController (status item + popover settings)

**Files:**
- Create: `Sources/LeaveMyMacAlone/MenuBarController.swift`

**Interfaces:**
- Consumes: `AppSettingsStore` (Task 4), `Transparency.range` (Task 2).
- Produces:
  - `struct SettingsView: View` (slider bound to `store.overlayOpacity` over `Transparency.range`, "Şimdi Kilitle" + "Çıkış" buttons).
  - `@MainActor final class MenuBarController { var onLockNow: () -> Void; var onQuit: () -> Void; init(store: AppSettingsStore) }`. Creates the status item + transient popover. Used by `AppController` (Task 12).

- [ ] **Step 1: Write the implementation**

`Sources/LeaveMyMacAlone/MenuBarController.swift`:

```swift
import AppKit
import SwiftUI
import LeaveMyMacAloneCore

struct SettingsView: View {
    @ObservedObject var store: AppSettingsStore
    let onLockNow: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Saydamlık")
                .font(.headline)

            Slider(value: $store.overlayOpacity, in: Transparency.range)

            Text(String(format: "Opaklık: %.0f%%", store.overlayOpacity * 100))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            Button("Şimdi Kilitle", action: onLockNow)
            Button("Çıkış", action: onQuit)
        }
        .padding(20)
        .frame(width: 260)
    }
}

@MainActor
final class MenuBarController {

    var onLockNow: () -> Void = {}
    var onQuit: () -> Void = {}

    private let store: AppSettingsStore
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    init(store: AppSettingsStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        configureStatusButton()
        configurePopover()
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "lock.shield",
                               accessibilityDescription: "LeaveMyMacAlone")
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(togglePopover(_:))
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        let root = SettingsView(
            store: store,
            onLockNow: { [weak self] in self?.onLockNow() },
            onQuit: { [weak self] in self?.onQuit() }
        )
        popover.contentViewController = NSHostingController(rootView: root)
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/LeaveMyMacAlone/MenuBarController.swift
git commit -m "feat: add menu-bar status item with settings popover"
```

---

### Task 12: AppController orchestration + bootstrap

**Files:**
- Create: `Sources/LeaveMyMacAlone/AppController.swift`
- Modify: `Sources/LeaveMyMacAlone/main.swift` (replace the Task 1 stub)

**Interfaces:**
- Consumes: `LockStateMachine` (Task 3), `AppSettingsStore` (Task 4), `SleepGuard` (Task 5), `ShieldController` (Task 6), `InputBlocker` (Task 7), `KioskMode` (Task 8), `Authenticator` (Task 9), `GlobalHotKey` (Task 10), `MenuBarController` (Task 11).
- Produces: `@MainActor final class AppController { init(); func start(); func lock() }`. Orchestrates the full lock/unlock lifecycle and is owned by `AppDelegate` in `main.swift`.

**Concurrency note:** Callbacks from the non-isolated components (`InputBlocker`, `GlobalHotKey`, `AppSettingsStore.onOpacityChange`) are delivered on the main thread but typed as plain `() -> Void`. Each is wrapped in `Task { @MainActor in ... }` so the hop into `@MainActor` methods is explicit and compiles under Swift 6 strict concurrency.

- [ ] **Step 1: Write the orchestrator**

`Sources/LeaveMyMacAlone/AppController.swift`:

```swift
import AppKit
import LeaveMyMacAloneCore

/// Owns every subsystem and coordinates lock → authenticate → unlock.
@MainActor
final class AppController {
    private let store = AppSettingsStore()
    private let sleepGuard = SleepGuard()
    private let shield = ShieldController()
    private let inputBlocker = InputBlocker()
    private let kiosk = KioskMode()
    private let authenticator = Authenticator()
    private var machine = LockStateMachine()

    private var menuBar: MenuBarController?
    private var hotKey: GlobalHotKey?

    func start() {
        NSApp.setActivationPolicy(.accessory)

        let menu = MenuBarController(store: store)
        menu.onLockNow = { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.lock() }
        }
        menu.onQuit = {
            NSApp.terminate(nil)
        }
        menuBar = menu

        hotKey = GlobalHotKey(onPressed: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.lock() }
        })

        store.onOpacityChange = { [weak self] opacity in
            guard let self else { return }
            Task { @MainActor in self.shield.setOpacity(opacity) }
        }

        // First run cannot auto-lock: granting Accessibility/Input Monitoring
        // requires reaching System Settings, which a kiosk lock would hide.
        if InputBlocker.hasRequiredPermissions() {
            lock()
        } else {
            InputBlocker.requestPermissions()
            showPermissionsAlert()
        }
    }

    func lock() {
        guard machine.lock() else { return } // ignore if not unlocked
        sleepGuard.begin()
        shield.show(opacity: store.overlayOpacity)
        kiosk.engage()
        inputBlocker.start(onFirstInteraction: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.requestUnlock() }
        })
    }

    private func requestUnlock() {
        guard machine.beginAuth() else { return }
        // Stop consuming so the password fallback can be typed in the sheet.
        inputBlocker.pause()
        Task { @MainActor in
            let ok = await authenticator.authenticate(
                reason: "Mac'in kilidini açmak için kimliğini doğrula")
            if ok {
                _ = machine.authSucceeded()
                inputBlocker.stop()
                kiosk.disengage()
                shield.hide()
                sleepGuard.end()
            } else {
                _ = machine.authFailed()
                inputBlocker.resume() // re-arm for the next interaction
            }
        }
    }

    private func showPermissionsAlert() {
        let alert = NSAlert()
        alert.messageText = "İzin gerekli"
        alert.informativeText = """
        LeaveMyMacAlone girişi engelleyebilmek için iki izne ihtiyaç duyar. \
        Sistem Ayarları > Gizlilik ve Güvenlik bölümünden:
        • Erişilebilirlik (Accessibility)
        • Giriş İzleme (Input Monitoring)
        izinlerini ver. Sonra menü çubuğundaki kalkan simgesinden \
        "Şimdi Kilitle" ile kilitle.
        """
        alert.addButton(withTitle: "Sistem Ayarları'nı Aç")
        alert.addButton(withTitle: "Tamam")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
```

- [ ] **Step 2: Replace `main.swift` with the real bootstrap**

`Sources/LeaveMyMacAlone/main.swift` (full replacement):

```swift
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

- [ ] **Step 3: Build to verify the whole app compiles**

Run: `swift build`
Expected: build succeeds, no warnings. (If a concurrency error appears on a callback assignment, confirm each cross-component callback uses the `guard let self … Task { @MainActor in … }` wrapper shown above.)

- [ ] **Step 4: Run the full test suite to confirm core still green**

Run: `swift test`
Expected: PASS — all core tests (Transparency + LockState + scaffold) pass, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/LeaveMyMacAlone/AppController.swift Sources/LeaveMyMacAlone/main.swift
git commit -m "feat: wire lock/unlock orchestration and app bootstrap"
```

---

### Task 13: Packaging (Info.plist, entitlements, bundle.sh, README) and signed .app

**Files:**
- Create: `Resources/Info.plist`
- Create: `Resources/LeaveMyMacAlone.entitlements`
- Create: `bundle.sh`
- Create: `README.md`

**Interfaces:**
- Consumes: the built executable from `swift build -c release`.
- Produces: a signed `LeaveMyMacAlone.app` in the repo root (gitignored) plus user-facing docs.

- [ ] **Step 1: Write `Resources/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>LeaveMyMacAlone</string>
    <key>CFBundleIdentifier</key>
    <string>com.alperenkisi.leavemymacalone</string>
    <key>CFBundleName</key>
    <string>LeaveMyMacAlone</string>
    <key>CFBundleDisplayName</key>
    <string>Leave My Mac Alone</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Alperen Kisi. All rights reserved.</string>
    <key>NSFaceIDUsageDescription</key>
    <string>Mac'in kilidini açmak için Touch ID kullanılır.</string>
</dict>
</plist>
```

- [ ] **Step 2: Write `Resources/LeaveMyMacAlone.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Explicitly OUT of the App Sandbox: a consuming CGEventTap requires the
         Accessibility/Input Monitoring TCC grants, which the sandbox forbids. -->
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
```

- [ ] **Step 3: Write `bundle.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="LeaveMyMacAlone"
BUNDLE_ID="com.alperenkisi.leavemymacalone"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1) Build the executable in release.
swift build -c release

# 2) Locate the built binary (robust to arch/triple changes).
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="${BIN_DIR}/${APP_NAME}"
if [[ ! -x "${BIN}" ]]; then
    echo "error: built executable not found at ${BIN}" >&2
    exit 1
fi

# 3) Assemble the .app bundle layout.
APP="${ROOT}/${APP_NAME}.app"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"

cp "${BIN}" "${APP}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP}/Contents/MacOS/${APP_NAME}"
cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"

# Validate the plist before signing.
plutil -lint "${APP}/Contents/Info.plist"

# 4) Ad-hoc codesign with entitlements + hardened runtime.
codesign --force --deep \
    --sign - \
    --entitlements "${ROOT}/Resources/${APP_NAME}.entitlements" \
    --options runtime \
    --identifier "${BUNDLE_ID}" \
    "${APP}"

# 5) Verify signature and show the cdhash (changes every rebuild → TCC reset).
codesign --verify --strict --verbose=2 "${APP}"
codesign -dvvv "${APP}" 2>&1 | grep -i 'CDHash='

echo "Built: ${APP}"
```

- [ ] **Step 4: Write `README.md`**

````markdown
# Leave My Mac Alone

Sen masandan uzaklaşırken Mac arkada çalışmaya devam etsin, ama kimse
klavye/fareye dokunup müdahale edemesin. Çalıştırınca ekran uyumaz, üzerine
saydam bir kilit katmanı düşer; açmak için Touch ID / parola gerekir.

## Gereksinimler
- macOS 14+ (macOS 26 üzerinde geliştirildi/doğrulandı), Apple Silicon
- Xcode Command Line Tools (Swift 6.2)
- SSH ile kurtarma için: Sistem Ayarları > Genel > Paylaşım > **Uzaktan Oturum
  Açma (Remote Login)** açık olmalı (kilit donarsa makineyi kurtarmak için).

## Kurulum
```bash
./bundle.sh
open .            # LeaveMyMacAlone.app oluşur; Applications'a taşıyabilirsin
```

## İlk çalıştırma (bir kez)
1. `LeaveMyMacAlone.app`'i çalıştır.
2. İzin uyarısı çıkar. Sistem Ayarları > Gizlilik ve Güvenlik bölümünden
   **hem Erişilebilirlik (Accessibility) hem Giriş İzleme (Input Monitoring)**
   listesine `LeaveMyMacAlone`'u ekle ve aç.
3. Menü çubuğundaki kalkan simgesinden **"Şimdi Kilitle"** ile kilitle.

İzinler verildikten sonra, uygulamayı her açtığında **anında kilitlenir**.

## Kullanım
- **Kilitle:** uygulamayı aç (otomatik), menü çubuğundan "Şimdi Kilitle", veya
  global kısayol **⌃⌥⌘L**.
- **Aç:** kilit ekranına dokun/klavyeye bas → Touch ID (veya parola).
- **Saydamlık:** menü çubuğu simgesi > kaydıracı (kilitliyken değil, açıkken
  ayarla; değer kalıcıdır).
- **Çıkış:** menü çubuğu simgesi > "Çıkış".

## Donarsa kurtarma (SSH kill switch)
Başka bir cihazdan:
```bash
ssh <kullanıcı>@<mac-ip> 'killall LeaveMyMacAlone'
```
Süreç ölünce kiosk modu ve giriş engeli anında kalkar.

## Dürüst sınırlamalar
- Çıplak laptopta **kapağı kapatmak** yine uyutur (donanımsal clamshell).
  Kapağı açık tut veya harici ekran + güç bağla.
- **Güç tuşuna basılı tutmak** donanımdan kapatır (yazılım engelleyemez).
- **Ad-hoc imza** nedeniyle her `./bundle.sh` (yeniden derleme) sonrası
  Accessibility/Input Monitoring iznini tekrar vermen gerekebilir. Bir kez
  derleyip çok kez çalıştırırsan sorun olmaz.
- Bu, şakacı bir iş arkadaşını durdurur; güvenlik-sınıfı bir kilit değildir.
````

- [ ] **Step 5: Make the script executable and build the bundle**

Run: `chmod +x bundle.sh && ./bundle.sh`
Expected: ends with `CDHash=...` line and `Built: .../LeaveMyMacAlone.app`; no codesign errors.

- [ ] **Step 6: Verify the signature and bundle metadata**

Run: `codesign -dvvv "LeaveMyMacAlone.app" 2>&1 | grep -E 'Identifier|flags'`
Expected: `Identifier=com.alperenkisi.leavemymacalone` and a flags line including `adhoc` and `runtime`.

Run: `plutil -p "LeaveMyMacAlone.app/Contents/Info.plist" | grep -E 'LSUIElement|CFBundleIdentifier'`
Expected: `"LSUIElement" => 1` and `"CFBundleIdentifier" => "com.alperenkisi.leavemymacalone"`.

- [ ] **Step 7: Commit**

```bash
git add Resources bundle.sh README.md
git commit -m "feat: add app bundle packaging, entitlements, and docs"
```

---

### Task 14: End-to-end manual verification

**Files:**
- Create: `docs/superpowers/verification-2026-06-24.md` (record results)

**Interfaces:**
- Consumes: the signed `LeaveMyMacAlone.app` from Task 13.
- Produces: a recorded pass/fail checklist. This is the behavioral acceptance gate for the app-layer components (Tasks 4–12) that cannot be unit-tested.

**Pre-req reminder:** Enable **Remote Login** first (so the SSH escape hatch exists before you trust the lock). Have a second device on the same network with SSH access ready.

- [ ] **Step 1: First-run permission flow**

Run: `open LeaveMyMacAlone.app`
Expected: no Dock icon; a `lock.shield` icon appears in the menu bar; an "İzin gerekli" alert appears (first run). Grant **Accessibility** and **Input Monitoring** to `LeaveMyMacAlone` in System Settings.
Record: did both permission rows appear and toggle on?

- [ ] **Step 2: Lock + input blocking**

From the menu-bar icon choose **"Şimdi Kilitle"** (or relaunch the app).
Expected: a transparent dark overlay with a 🔒 badge + live clock covers the screen; Dock and menu bar hidden.
Try each and confirm it is blocked / has no effect: typing, clicking, **Cmd+Tab**, **Cmd+Space** (Spotlight), **Ctrl+↑** (Mission Control), **Cmd+Opt+Esc** (Force Quit), the keyboard, the trackpad.
Record: which inputs were blocked; note any that leaked.

- [ ] **Step 3: Unlock (Touch ID / password)**

Press a key or click the overlay.
Expected: the system Touch ID / password sheet appears **above** the overlay; authenticating dismisses the overlay, restores Dock/menu bar; the menu-bar icon remains.
Then press **Cancel** on a fresh unlock attempt.
Expected: the overlay stays (re-locked); a subsequent interaction re-presents the prompt.
Record: Touch ID worked? password fallback worked? cancel re-locked?

- [ ] **Step 4: Re-lock hotkey**

While unlocked, press **⌃⌥⌘L**.
Expected: the Mac locks again immediately.
Record: did the hotkey lock?

- [ ] **Step 5: Sleep prevention**

While locked, run from the second device (or before locking, in a terminal): `pmset -g assertions | grep -E 'PreventUserIdleDisplaySleep|PreventUserIdleSystemSleep'`
Expected: both assertions are listed with a count ≥ 1.
Leave the Mac untouched past its normal display-sleep timeout.
Expected: the screen stays on and the overlay stays visible.
Record: assertions present? screen stayed awake?

- [ ] **Step 6: Multi-display (if available)**

With a second display connected, lock the Mac.
Expected: every display is covered by the overlay. Disconnect/reconnect a display while locked.
Expected: the overlay rebuilds to cover the current display set.
Record: all displays covered? rebuild worked? (Skip + note if single-display only.)

- [ ] **Step 7: SSH kill switch**

While locked, from the second device: `ssh <user>@<mac> 'killall LeaveMyMacAlone'`
Expected: the process dies; the overlay disappears; Dock, menu bar, Cmd+Tab, and Force Quit all work normally again (the system restores presentation options on process exit).
Record: did killall fully restore the machine?

- [ ] **Step 8: Record results and commit**

Write the pass/fail outcome of Steps 1–7 (with notes on any leaked inputs or limitations observed) into `docs/superpowers/verification-2026-06-24.md`.

```bash
git add docs/superpowers/verification-2026-06-24.md
git commit -m "docs: record end-to-end manual verification results"
```

---

## Plan Self-Review

**Spec coverage:** Maksimum kilit (kiosk + event tap + force-quit) → Tasks 7, 8; SSH kurtarma → Task 13 README + Task 14 Step 7; ayarlanabilir saydamlık → Tasks 2, 4, 6, 11; anında kilit + menü çubuğu + ⌃⌥⌘L → Tasks 10, 11, 12; Touch ID/parola → Task 9; uyku engeli → Task 5; Core test edilebilirlik → Tasks 2, 3; dürüst sınırlamalar → Task 5 (clamshell), Task 13 README. All spec sections map to tasks.

**Type consistency:** `Transparency.range/.defaultOpacity/.clamp` consistent across Tasks 2/4/6/11. `AppSettingsStore.overlayOpacity` + `onOpacityChange` consistent across Tasks 4/11/12. `LockStateMachine.lock()/beginAuth()/authSucceeded()/authFailed()` consistent across Tasks 3/12. Each subsystem's `show/setOpacity/hide`, `start/pause/resume/stop`, `engage/disengage`, `begin/end`, `authenticate(reason:) async`, `init(onPressed:)` match between their producing task and `AppController` (Task 12).

**Known residual risks (verified during research, flagged for the implementer):**
- Ad-hoc signing resets Accessibility/Input Monitoring on every rebuild (Task 13 README documents re-granting). Optional hardening: a stable self-signed cert avoids this.
- The exact Input-Monitoring-vs-Accessibility requirement for a consuming session tap is not crisply documented; Task 1's `hasRequiredPermissions()` checks both, and Task 14 Step 2 empirically confirms blocking.
- `presentationOptions` are app-scoped and the kiosk set must not be edited without re-checking validity (Task 8 comment); the event tap is the primary enforcement, so a relaxed kiosk still protects.
````
