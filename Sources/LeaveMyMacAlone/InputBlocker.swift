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
    private var onFirstInteraction: (@Sendable () -> Void)?
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
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Lifecycle

    func start(onFirstInteraction: @escaping @Sendable () -> Void) {
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
        var mask: CGEventMask = 0
        mask |= (1 << CGEventType.keyDown.rawValue)
        mask |= (1 << CGEventType.keyUp.rawValue)
        mask |= (1 << CGEventType.flagsChanged.rawValue)
        mask |= (1 << CGEventType.leftMouseDown.rawValue)
        mask |= (1 << CGEventType.leftMouseUp.rawValue)
        mask |= (1 << CGEventType.rightMouseDown.rawValue)
        mask |= (1 << CGEventType.rightMouseUp.rawValue)
        mask |= (1 << CGEventType.otherMouseDown.rawValue)
        mask |= (1 << CGEventType.otherMouseUp.rawValue)
        mask |= (1 << CGEventType.mouseMoved.rawValue)
        mask |= (1 << CGEventType.leftMouseDragged.rawValue)
        mask |= (1 << CGEventType.rightMouseDragged.rawValue)
        mask |= (1 << CGEventType.otherMouseDragged.rawValue)
        mask |= (1 << CGEventType.scrollWheel.rawValue)

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
            let cb = onFirstInteraction
            DispatchQueue.main.async {
                cb?()
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
