# Intruder Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture a front-camera photo when someone repeatedly interacts with the locked screen (a force-unlock attempt), gated by an opt-in Settings toggle.

**Architecture:** A pure, unit-tested counting/cooldown policy lives in `LeaveMyMacAloneCore`. An app-target coordinator (`IntruderCapture`) applies the policy, drives an `IntruderPhotographer` (AVFoundation behind a protocol), writes JPEGs, and posts an unlock notification. `AppController` feeds it the interaction/lock/unlock signals it already receives through its two `.locked` handlers — `InputBlocker` is unchanged.

**Tech Stack:** Swift 6, SwiftPM, AppKit/SwiftUI, AVFoundation, UserNotifications, XCTest.

## Global Constraints

- Swift tools 6.0; deployment target macOS 14; app is non-sandboxed (camera needs only `NSCameraUsageDescription` + runtime TCC, no entitlement).
- Capture policy constants (verbatim): `graceInteractions = 2`, `captureCooldown = 5` seconds. First capture on the **3rd** interaction; repeats throttled to one per 5 s.
- Counter resets on lock (fresh session) and on **successful** unlock; a **failed** auth does NOT reset. Interactions are counted **only in the `.locked` state** (auth-mode keystrokes never count).
- Photos: `~/Pictures/LeaveMyMacAlone/intruder-YYYY-MM-DD_HH-mm-ss.jpg` (POSIX/`en_US_POSIX` timestamp; collisions get `-2`, `-3`, … suffix).
- Toggle **default OFF**, placed directly under the "Prevent sleep while locked" toggle.
- Pure logic in `LeaveMyMacAloneCore`; AppKit/AVFoundation/UserNotifications only in the executable target.
- UI strings are Turkish literals (SwiftUI auto-localizes via `en.lproj/Localizable.strings`); add English entries for every new string.

---

### Task 1: IntruderCapturePolicy (pure logic, Core)

**Files:**
- Create: `Sources/LeaveMyMacAloneCore/IntruderCapturePolicy.swift`
- Test: `Tests/LeaveMyMacAloneTests/IntruderCapturePolicyTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public struct IntruderCapturePolicy` with
  `init(enabled: Bool)`, `mutating func setEnabled(_ on: Bool)`,
  `mutating func noteInteraction(now: Double) -> Bool`, `mutating func reset()`,
  and `public static let graceInteractions = 2`, `public static let captureCooldown: Double = 5`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LeaveMyMacAloneTests/IntruderCapturePolicyTests.swift`:

```swift
import XCTest
@testable import LeaveMyMacAloneCore

final class IntruderCapturePolicyTests: XCTestCase {

    func testFirstTwoInteractionsAreFree() {
        var p = IntruderCapturePolicy(enabled: true)
        XCTAssertFalse(p.noteInteraction(now: 0))   // 1st
        XCTAssertFalse(p.noteInteraction(now: 1))   // 2nd
    }

    func testThirdInteractionCaptures() {
        var p = IntruderCapturePolicy(enabled: true)
        _ = p.noteInteraction(now: 0)
        _ = p.noteInteraction(now: 1)
        XCTAssertTrue(p.noteInteraction(now: 2))    // 3rd → capture
    }

    func testCooldownSuppressesImmediateNextCapture() {
        var p = IntruderCapturePolicy(enabled: true)
        _ = p.noteInteraction(now: 0)
        _ = p.noteInteraction(now: 0)
        XCTAssertTrue(p.noteInteraction(now: 10))   // 3rd → capture at t=10
        XCTAssertFalse(p.noteInteraction(now: 12))  // +2s < 5s cooldown
    }

    func testCaptureResumesAfterCooldown() {
        var p = IntruderCapturePolicy(enabled: true)
        _ = p.noteInteraction(now: 0)
        _ = p.noteInteraction(now: 0)
        XCTAssertTrue(p.noteInteraction(now: 10))   // capture at t=10
        XCTAssertTrue(p.noteInteraction(now: 15))   // +5s ≥ cooldown → capture
    }

    func testResetReturnsToGraceState() {
        var p = IntruderCapturePolicy(enabled: true)
        _ = p.noteInteraction(now: 0)
        _ = p.noteInteraction(now: 1)
        _ = p.noteInteraction(now: 2)               // captured
        p.reset()
        XCTAssertFalse(p.noteInteraction(now: 3))   // 1st again → free
        XCTAssertFalse(p.noteInteraction(now: 4))   // 2nd → free
        XCTAssertTrue(p.noteInteraction(now: 5))    // 3rd → capture
    }

    func testDisabledNeverCaptures() {
        var p = IntruderCapturePolicy(enabled: false)
        for t in 0..<10 {
            XCTAssertFalse(p.noteInteraction(now: Double(t)))
        }
    }

    func testSetEnabledTogglesBehavior() {
        var p = IntruderCapturePolicy(enabled: false)
        _ = p.noteInteraction(now: 0)
        _ = p.noteInteraction(now: 1)
        XCTAssertFalse(p.noteInteraction(now: 2))   // disabled → no capture
        p.setEnabled(true)
        p.reset()
        _ = p.noteInteraction(now: 3)
        _ = p.noteInteraction(now: 4)
        XCTAssertTrue(p.noteInteraction(now: 5))    // enabled → 3rd captures
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter IntruderCapturePolicyTests`
Expected: FAIL to compile — "cannot find 'IntruderCapturePolicy' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/LeaveMyMacAloneCore/IntruderCapturePolicy.swift`:

```swift
/// Pure, side-effect-free policy deciding WHEN an intruder photo should be
/// taken. No Foundation/AppKit — `now` is supplied by the caller as monotonic
/// seconds so the cooldown is testable without a real clock.
///
/// Rules (design spec): the first `graceInteractions` interactions in a lock
/// session are free; the next one triggers the first capture; afterwards a new
/// capture fires only once `captureCooldown` seconds have elapsed since the
/// last. Disabled → never captures. `reset()` returns to the start-of-session
/// state (a fresh lock, or a successful unlock).
public struct IntruderCapturePolicy {
    public static let graceInteractions = 2
    public static let captureCooldown: Double = 5

    private var enabled: Bool
    private var interactionCount = 0
    private var lastCaptureAt: Double?

    public init(enabled: Bool) {
        self.enabled = enabled
    }

    public mutating func setEnabled(_ on: Bool) {
        enabled = on
    }

    /// Register one locked-state interaction occurring at `now` (monotonic
    /// seconds). Returns true if a photo should be captured.
    public mutating func noteInteraction(now: Double) -> Bool {
        guard enabled else { return false }            // disabled → don't count
        interactionCount += 1
        guard interactionCount > Self.graceInteractions else { return false }
        if let last = lastCaptureAt, now - last < Self.captureCooldown {
            return false
        }
        lastCaptureAt = now
        return true
    }

    /// Return to the start-of-session state.
    public mutating func reset() {
        interactionCount = 0
        lastCaptureAt = nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter IntruderCapturePolicyTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LeaveMyMacAloneCore/IntruderCapturePolicy.swift Tests/LeaveMyMacAloneTests/IntruderCapturePolicyTests.swift
git commit -m "feat: add IntruderCapturePolicy (grace + cooldown logic)"
```

---

### Task 2: IntruderPhotographer protocol + AVFoundation implementation

**Files:**
- Create: `Sources/LeaveMyMacAlone/IntruderPhotographer.swift`
- Create: `Sources/LeaveMyMacAlone/AVFoundationPhotographer.swift`
- Modify: `Package.swift` (add `AVFoundation` to the executable target's linked frameworks)

**Interfaces:**
- Consumes: nothing.
- Produces: `protocol IntruderPhotographer: Sendable { func capture() async -> Data? }`
  and `final class AVFoundationPhotographer: NSObject, IntruderPhotographer, @unchecked Sendable`.

- [ ] **Step 1: Add the protocol**

Create `Sources/LeaveMyMacAlone/IntruderPhotographer.swift`:

```swift
import Foundation

/// Hardware boundary for grabbing a single still photo. Returns JPEG-encoded
/// bytes, or nil when capture is impossible (no camera, lid closed, permission
/// denied, or any failure). Behind a protocol so the coordinator is testable
/// with a fake.
protocol IntruderPhotographer: Sendable {
    func capture() async -> Data?
}
```

- [ ] **Step 2: Add the AVFoundation implementation**

Create `Sources/LeaveMyMacAlone/AVFoundationPhotographer.swift`:

```swift
import AVFoundation
import Foundation

/// Single-shot front-camera photographer. Each call spins up its own capture
/// session, lets exposure settle, grabs one JPEG, then tears the session down —
/// so the camera LED only lights for the ~1 s of an actual capture, never the
/// whole lock. Returns nil on any failure (denied, no camera, lid closed).
final class AVFoundationPhotographer: NSObject, IntruderPhotographer, @unchecked Sendable {

    func capture() async -> Data? {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            return nil
        }
        guard let device = Self.frontCamera(),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return nil
        }

        let session = AVCaptureSession()
        session.sessionPreset = .photo
        guard session.canAddInput(input) else { return nil }
        session.addInput(input)

        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)

        session.startRunning()
        guard session.isRunning else { return nil }
        defer { session.stopRunning() }

        // Let auto-exposure / white-balance settle so the frame isn't black.
        try? await Task.sleep(for: .milliseconds(600))

        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            // AVCapturePhotoOutput retains the delegate until the capture
            // completes, so a local instance is enough.
            let delegate = PhotoCaptureDelegate { data in cont.resume(returning: data) }
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
        }
    }

    private static func frontCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .front)
        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
    }
}

/// Bridges the one-shot delegate callback to a continuation.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: @Sendable (Data?) -> Void
    init(completion: @escaping @Sendable (Data?) -> Void) {
        self.completion = completion
    }
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        completion(photo.fileDataRepresentation())
    }
}
```

- [ ] **Step 3: Link AVFoundation in Package.swift**

In `Package.swift`, change the executable target's `linkerSettings` array to include AVFoundation:

```swift
        .executableTarget(
            name: "LeaveMyMacAlone",
            dependencies: ["LeaveMyMacAloneCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation")
            ]
        ),
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds with no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/LeaveMyMacAlone/IntruderPhotographer.swift Sources/LeaveMyMacAlone/AVFoundationPhotographer.swift Package.swift
git commit -m "feat: add IntruderPhotographer protocol + AVFoundation front-camera capture"
```

---

### Task 3: IntruderCapture coordinator

**Files:**
- Create: `Sources/LeaveMyMacAlone/IntruderCapture.swift`
- Modify: `Package.swift` (add `UserNotifications` to linked frameworks)
- Test: `Tests/LeaveMyMacAloneTests/IntruderCaptureTests.swift`

**Interfaces:**
- Consumes: `IntruderCapturePolicy` (Task 1), `IntruderPhotographer` (Task 2).
- Produces: `@MainActor final class IntruderCapture` with
  `init(photographer: IntruderPhotographer, directory: URL = IntruderCapture.defaultDirectory)`,
  `func beginSession(enabled: Bool)`, `func endSession()`,
  `func registerInteraction() -> Bool`, `func performCapture() async`,
  `var capturedThisSession: Int { get }`, `func postUnlockNotification()`,
  `static var defaultDirectory: URL`, `static func openPhotosFolder()`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LeaveMyMacAloneTests/IntruderCaptureTests.swift`:

```swift
import XCTest
@testable import LeaveMyMacAlone

@MainActor
final class IntruderCaptureTests: XCTestCase {

    private struct FakePhotographer: IntruderPhotographer {
        let data: Data?
        func capture() async -> Data? { data }
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lmma-test-\(UUID().uuidString)", isDirectory: true)
    }

    func testGraceThenCaptureWritesFile() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cap = IntruderCapture(photographer: FakePhotographer(data: Data([0xFF, 0xD8, 0xFF])),
                                  directory: dir)
        cap.beginSession(enabled: true)

        XCTAssertFalse(cap.registerInteraction())   // 1st
        XCTAssertFalse(cap.registerInteraction())   // 2nd
        XCTAssertTrue(cap.registerInteraction())    // 3rd → capture

        await cap.performCapture()

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(cap.capturedThisSession, 1)
        XCTAssertTrue(files[0].hasPrefix("intruder-"))
        XCTAssertTrue(files[0].hasSuffix(".jpg"))
    }

    func testDisabledDoesNotCapture() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cap = IntruderCapture(photographer: FakePhotographer(data: Data([0xFF])),
                                  directory: dir)
        cap.beginSession(enabled: false)
        for _ in 0..<5 { XCTAssertFalse(cap.registerInteraction()) }
        XCTAssertEqual(cap.capturedThisSession, 0)
    }

    func testNilPhotoDoesNotIncrementCount() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cap = IntruderCapture(photographer: FakePhotographer(data: nil),
                                  directory: dir)
        cap.beginSession(enabled: true)
        _ = cap.registerInteraction()
        _ = cap.registerInteraction()
        _ = cap.registerInteraction()
        await cap.performCapture()
        XCTAssertEqual(cap.capturedThisSession, 0)
    }

    func testEndSessionResetsCounter() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cap = IntruderCapture(photographer: FakePhotographer(data: Data([0xFF])),
                                  directory: dir)
        cap.beginSession(enabled: true)
        _ = cap.registerInteraction()
        _ = cap.registerInteraction()
        cap.endSession()
        XCTAssertFalse(cap.registerInteraction())   // 1st again after reset
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter IntruderCaptureTests`
Expected: FAIL to compile — "cannot find 'IntruderCapture' in scope".

- [ ] **Step 3: Write the coordinator**

Create `Sources/LeaveMyMacAlone/IntruderCapture.swift`:

```swift
import AppKit
import Foundation
import UserNotifications
import LeaveMyMacAloneCore

/// Coordinates intruder-photo capture for one lock session: applies the pure
/// `IntruderCapturePolicy`, drives the injected `IntruderPhotographer`, writes
/// JPEGs to disk, and posts an unlock notification. `AppController` owns one
/// instance and feeds it interaction/lock/unlock signals.
@MainActor
final class IntruderCapture {

    private var policy: IntruderCapturePolicy
    private let photographer: IntruderPhotographer
    private let directory: URL
    private(set) var capturedThisSession = 0

    init(photographer: IntruderPhotographer,
         directory: URL = IntruderCapture.defaultDirectory) {
        self.photographer = photographer
        self.directory = directory
        self.policy = IntruderCapturePolicy(enabled: false)
    }

    /// `~/Pictures/LeaveMyMacAlone`.
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/LeaveMyMacAlone", isDirectory: true)
    }

    /// Start a fresh lock session.
    func beginSession(enabled: Bool) {
        policy.setEnabled(enabled)
        policy.reset()
        capturedThisSession = 0
    }

    /// End the session (called on a successful unlock).
    func endSession() {
        policy.reset()
    }

    /// Register one locked-state interaction. Returns true if the caller should
    /// kick off `performCapture()`.
    func registerInteraction() -> Bool {
        policy.noteInteraction(now: ProcessInfo.processInfo.systemUptime)
    }

    /// Grab one photo and save it. Safe to call from a detached Task; never throws.
    func performCapture() async {
        guard let jpeg = await photographer.capture() else { return }
        guard let url = writeJPEG(jpeg) else { return }
        capturedThisSession += 1
        NSLog("IntruderCapture: saved \(url.lastPathComponent)")
    }

    /// If any photos were captured this session, post a local notification.
    func postUnlockNotification() {
        guard capturedThisSession > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("İzinsiz giriş tespit edildi",
                                          comment: "Intruder notification title")
        content.body = String(
            format: NSLocalizedString("%d izinsiz giriş fotoğrafı çekildi.",
                                      comment: "Intruder notification body"),
            capturedThisSession)
        let request = UNNotificationRequest(
            identifier: "intruder-\(ProcessInfo.processInfo.systemUptime)",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Open the photos folder in Finder, creating it if needed (menu action).
    static func openPhotosFolder() {
        try? FileManager.default.createDirectory(at: defaultDirectory,
                                                 withIntermediateDirectories: true)
        NSWorkspace.shared.open(defaultDirectory)
    }

    // MARK: - Private

    private func writeJPEG(_ data: Data) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSLog("IntruderCapture: cannot create \(directory.path): \(error)")
            return nil
        }
        let url = uniqueURL(for: Self.timestamp())
        do {
            try data.write(to: url)
            return url
        } catch {
            NSLog("IntruderCapture: write failed: \(error)")
            return nil
        }
    }

    private func uniqueURL(for stamp: String) -> URL {
        let base = "intruder-\(stamp)"
        var candidate = directory.appendingPathComponent("\(base).jpg")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(n).jpg")
            n += 1
        }
        return candidate
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }
}
```

- [ ] **Step 4: Link UserNotifications in Package.swift**

In `Package.swift`, the executable target's `linkerSettings` array now reads:

```swift
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("UserNotifications")
            ]
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter IntruderCaptureTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/LeaveMyMacAlone/IntruderCapture.swift Tests/LeaveMyMacAloneTests/IntruderCaptureTests.swift Package.swift
git commit -m "feat: add IntruderCapture coordinator (policy + capture + save + notify)"
```

---

### Task 4: captureIntruderPhoto setting

**Files:**
- Modify: `Sources/LeaveMyMacAlone/AppSettingsStore.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `AppSettingsStore.captureIntruderPhoto: Bool` (`@Published`, default `false`)
  and `static let captureIntruderPhotoKey = "captureIntruderPhoto"`.

- [ ] **Step 1: Add the key constant**

In `Sources/LeaveMyMacAlone/AppSettingsStore.swift`, after the line
`static let preventSleepKey = "preventSleepWhileLocked"`, add:

```swift
    static let captureIntruderPhotoKey = "captureIntruderPhoto"
```

- [ ] **Step 2: Add the published property**

After the `preventSleepWhileLocked` property block (the closing `}` of its
`didSet`), add:

```swift
    /// Capture a front-camera photo when someone tries to force the lock open.
    /// Default off (opt-in, privacy-sensitive). Read at lock time.
    @Published var captureIntruderPhoto: Bool {
        didSet {
            UserDefaults.standard.set(captureIntruderPhoto, forKey: Self.captureIntruderPhotoKey)
        }
    }
```

- [ ] **Step 3: Initialize it in `init()`**

In `init()`, after the lines that set `preventSleepWhileLocked`, add:

```swift
        // Default off — capture is opt-in.
        let storedCapture = UserDefaults.standard.object(forKey: Self.captureIntruderPhotoKey) as? Bool
        captureIntruderPhoto = storedCapture ?? false
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds. (No unit test: this mirrors the existing untested
`preventSleepWhileLocked` UserDefaults pattern; behavior is verified by the
manual toggle test in Task 6.)

- [ ] **Step 5: Commit**

```bash
git add Sources/LeaveMyMacAlone/AppSettingsStore.swift
git commit -m "feat: add captureIntruderPhoto setting (default off)"
```

---

### Task 5: Wire IntruderCapture into AppController + Info.plist camera string

**Files:**
- Modify: `Sources/LeaveMyMacAlone/AppController.swift`
- Modify: `Resources/Info.plist`

**Interfaces:**
- Consumes: `IntruderCapture` (Task 3), `AVFoundationPhotographer` (Task 2),
  `AppSettingsStore.captureIntruderPhoto` (Task 4).
- Produces: nothing new for other tasks.

- [ ] **Step 1: Add the IntruderCapture property**

In `Sources/LeaveMyMacAlone/AppController.swift`, after the line
`private var machine = LockStateMachine()`, add:

```swift
    private let intruder = IntruderCapture(photographer: AVFoundationPhotographer())
```

- [ ] **Step 2: Begin a capture session when the lock engages**

In `lock()`, change the opening guard so a fresh session starts on a successful lock:

```swift
    func lock() {
        guard machine.lock() else { return } // ignore if not unlocked
        intruder.beginSession(enabled: store.captureIntruderPhoto)
```

(Insert the `intruder.beginSession(...)` line immediately after the existing guard.)

- [ ] **Step 3: Add the interaction funnel helper**

After the `handleBackgroundClick()` method's closing brace, add:

```swift
    /// Count one locked-state interaction; capture a photo if the policy says so.
    /// Capture runs detached so a slow camera never delays the lock/unlock path.
    private func noteIntruderInteraction() {
        if intruder.registerInteraction() {
            Task { @MainActor in await self.intruder.performCapture() }
        }
    }
```

- [ ] **Step 4: Register interactions from the two locked handlers**

In `handleUnlockButton()`, change the `.locked` case:

```swift
        case .locked:
            noteIntruderInteraction()
            requestUnlock()
```

In `handleBackgroundClick()`, change the `.locked` case:

```swift
        case .locked:
            noteIntruderInteraction()
            shield.flashLocked()
```

- [ ] **Step 5: Notify + reset on successful unlock**

In `finishAuth(success:)`, change the `if success {` branch to add the two
intruder calls after `sleepGuard.end()`:

```swift
        if success {
            _ = machine.authSucceeded()
            inputBlocker.stop()
            kiosk.disengage()
            shield.hide(success: true)   // play the unlock flourish, then tear down
            sleepGuard.end()
            intruder.postUnlockNotification()
            intruder.endSession()
        } else if inputBlocker.endAuthMode() {
```

- [ ] **Step 6: Add the camera usage string to Info.plist**

In `Resources/Info.plist`, after the `NSFaceIDUsageDescription` string element
(line ending `...Touch ID kullanılır.</string>`) and before the closing `</dict>`,
add:

```xml
    <key>NSCameraUsageDescription</key>
    <string>Kilidi açmaya çalışan kişinin fotoğrafını çekmek için kamera kullanılır.</string>
```

- [ ] **Step 7: Build + run the full test suite**

Run: `swift build && swift test`
Expected: Build succeeds; all tests pass (existing suite + Task 1 & Task 3 tests).

- [ ] **Step 8: Commit**

```bash
git add Sources/LeaveMyMacAlone/AppController.swift Resources/Info.plist
git commit -m "feat: wire intruder capture into lock/unlock flow + camera usage string"
```

---

### Task 6: Settings toggle, folder shortcut, permission priming + localization

**Files:**
- Modify: `Sources/LeaveMyMacAlone/MenuBarController.swift`
- Modify: `Resources/en.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `AppSettingsStore.captureIntruderPhoto` (Task 4), `IntruderCapture.openPhotosFolder()` (Task 3).
- Produces: nothing new for other tasks.

- [ ] **Step 1: Add AVFoundation + UserNotifications imports**

In `Sources/LeaveMyMacAlone/MenuBarController.swift`, after `import LeaveMyMacAloneCore`, add:

```swift
import AVFoundation
import UserNotifications
```

- [ ] **Step 2: Add the two callbacks to SettingsView**

In `struct SettingsView`, after the `let onSliderEditing: (Bool) -> Void` property, add:

```swift
    // Called when the user turns the intruder-capture toggle ON (prime perms).
    let onCaptureIntruderEnabled: () -> Void
    // Open the captured-photos folder in Finder.
    let onOpenIntruderPhotos: () -> Void
```

- [ ] **Step 3: Add the toggle UI under the sleep toggle**

In `SettingsView.body`, the sleep toggle is the `HStack` ending right before the
`Divider()` that precedes the actions row. Immediately after that sleep `HStack`'s
closing `}` and before that `Divider()`, insert:

```swift
            Divider()

            // Intruder capture: toggle + (when on) a shortcut to the photos folder.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("İzinsiz girişte fotoğraf çek")
                            .font(.subheadline.weight(.semibold))
                        Text("Kilidi açmaya çalışan kişinin ön kameradan fotoğrafını çeker.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: $store.captureIntruderPhoto)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                if store.captureIntruderPhoto {
                    Button("İzinsiz giriş fotoğraflarını aç", action: onOpenIntruderPhotos)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .onChange(of: store.captureIntruderPhoto) { _, newValue in
                if newValue { onCaptureIntruderEnabled() }
            }
```

- [ ] **Step 4: Wire the callbacks in `openPanel()`**

In `MenuBarController.openPanel()`, the `SettingsView(...)` initializer currently
ends with the `onSliderEditing:` argument. Add the two new arguments to that call
(after the `onSliderEditing` closure):

```swift
            onSliderEditing: { [weak self] editing in
                // Show the live preview only while the slider is being dragged.
                if editing { self?.preview.start() } else { self?.preview.stop() }
            },
            onCaptureIntruderEnabled: { [weak self] in self?.primeIntruderPermissions() },
            onOpenIntruderPhotos: { IntruderCapture.openPhotosFolder() }
        )
```

- [ ] **Step 5: Add the permission-priming method**

In `MenuBarController`, after `init(store:)`'s closing brace, add:

```swift
    /// When the user enables intruder capture, request Camera + Notification
    /// permission now (a calm moment) so the prompts never appear mid-intrusion.
    private func primeIntruderPermissions() {
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
```

- [ ] **Step 6: Add English localizations**

In `Resources/en.lproj/Localizable.strings`, under the
`/* --- Menu bar panel & lock screen (SwiftUI) --- */` section add:

```
"İzinsiz girişte fotoğraf çek" = "Capture intruder photo";
"Kilidi açmaya çalışan kişinin ön kameradan fotoğrafını çeker." = "Photographs whoever tries to unlock your Mac.";
"İzinsiz giriş fotoğraflarını aç" = "Open intruder photos";
```

And under the `/* --- Permission onboarding & alerts (AppKit) --- */` section add:

```
"İzinsiz giriş tespit edildi" = "Intruder detected";
"%d izinsiz giriş fotoğrafı çekildi." = "%d intruder photo(s) captured.";
```

- [ ] **Step 7: Build + full test suite**

Run: `swift build && swift test`
Expected: Build succeeds; all tests pass.

- [ ] **Step 8: Manual verification**

Run: `./bundle.sh` then launch the produced `.app`.
Verify:
1. Open the menu panel → a "İzinsiz girişte fotoğraf çek" toggle appears under the sleep toggle, default OFF.
2. Turn it ON → macOS prompts for Camera (and Notifications) permission; grant both. A "İzinsiz giriş fotoğraflarını aç" link appears.
3. Lock (⌃⌥⌘L). Press one key, then a second — no photo. Press a third interaction → the green camera LED blinks ~1 s and a JPEG lands in `~/Pictures/LeaveMyMacAlone/`.
4. Keep mashing → at most one photo per ~5 s.
5. Unlock with Touch ID/password → a notification reports the count; the counter resets for the next lock.
6. Click "İzinsiz giriş fotoğraflarını aç" → Finder opens the folder.
7. Turn the toggle OFF, lock, mash keys → no photos.

- [ ] **Step 9: Commit**

```bash
git add Sources/LeaveMyMacAlone/MenuBarController.swift Resources/en.lproj/Localizable.strings
git commit -m "feat: add intruder-capture settings toggle, folder shortcut, and permission priming"
```

---

## Self-Review

**Spec coverage:**
- Trigger C + 2-interaction grace + capture on 3rd → Task 1 (policy) + Task 5 (wiring). ✅
- 5 s cooldown / repeat (option B) → Task 1 (cooldown tests). ✅
- Counting paused in auth mode; reset on lock + successful unlock, not on failed auth → Task 5 (registration only in `.locked`; `beginSession` in `lock()`, `endSession` only in `finishAuth(success:true)`). ✅
- Lazy AVFoundation capture, LED only during capture → Task 2. ✅
- Storage `~/Pictures/LeaveMyMacAlone/intruder-*.jpg` + collision suffix → Task 3. ✅
- Opt-in toggle under sleep, default off → Task 4 + Task 6. ✅
- Permission priming on enable → Task 6. ✅
- Unlock notification + "open folder" menu → Task 3 (APIs) + Task 5 (post on unlock) + Task 6 (menu). ✅
- `NSCameraUsageDescription` + framework linking → Task 5 + Tasks 2/3. ✅
- InputBlocker unchanged → confirmed; no task touches it. ✅
- Localization for new strings → Task 6 Step 6. ✅

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every run step shows the command + expected result. ✅

**Type consistency:** `IntruderCapturePolicy.noteInteraction(now:)`/`reset()`/`setEnabled(_:)` used identically in Task 1 and Task 3. `IntruderCapture.registerInteraction()`/`performCapture()`/`beginSession(enabled:)`/`endSession()`/`postUnlockNotification()`/`capturedThisSession`/`openPhotosFolder()` defined in Task 3 and consumed with matching signatures in Tasks 5 & 6. `IntruderPhotographer.capture() async -> Data?` defined in Task 2, implemented (AVFoundation) in Task 2 and faked in Task 3. ✅
