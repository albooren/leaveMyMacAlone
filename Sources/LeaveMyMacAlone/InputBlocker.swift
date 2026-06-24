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
    // While true the tap stays live but only swallows escape shortcuts, letting
    // plain input through to the auth sheet (see handle / isEscapeShortcut).
    private var authMode = false

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

    @discardableResult
    func start(onFirstInteraction: @escaping @Sendable () -> Void) -> Bool {
        guard eventTap == nil else { return true }   // already running
        self.onFirstInteraction = onFirstInteraction
        self.firstInteractionFired = false
        guard installTap() else {
            self.onFirstInteraction = nil
            NSLog("InputBlocker: tapCreate failed (grant Input Monitoring AND Accessibility).")
            return false
        }
        return true
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

        // During authentication the tap stays LIVE (it is not paused) so the
        // lock keeps blocking the escapes that would otherwise let a passer-by
        // act or strand the owner, while plain typing/clicks still reach the
        // separate-process auth sheet so the password can be entered.
        if authMode {
            return Self.isEscapeShortcut(type: type, event: event)
                ? nil                                // swallow the escape
                : Unmanaged.passUnretained(event)    // deliver to the sheet
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

    /// App/Space-switching and launcher shortcuts that must stay blocked even
    /// while the auth sheet is up. Keyboard-only: all mouse/scroll passes so the
    /// sheet (and the shield's click-to-recover) stay usable. Conservative
    /// denylist — anything not listed (incl. ⌘A/⌘C/⌘V and plain typing) passes
    /// through to the password field.
    private static func isEscapeShortcut(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown || type == .keyUp else { return false }
        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let cmd = flags.contains(.maskCommand)
        let ctrl = flags.contains(.maskControl)
        let opt = flags.contains(.maskAlternate)

        if cmd {
            switch keyCode {
            case 0x30, 0x32, 0x31: return true  // Tab (app switch) · ` (window cycle) · Space (Spotlight)
            default: break
            }
        }
        if cmd && opt && keyCode == 0x35 { return true }      // ⌥⌘Esc → Force Quit
        if ctrl {
            switch keyCode {
            case 0x7B, 0x7C, 0x7D, 0x7E: return true          // Ctrl+arrows → Spaces / Mission Control
            default: break
            }
        }
        return false
    }

    /// Enter authentication mode: the tap stays live but only swallows escape
    /// shortcuts; plain input reaches the auth sheet.
    func beginAuthMode() {
        authMode = true
    }

    /// Leave authentication mode: resume swallowing all input and re-arm the
    /// first-interaction trigger. Returns whether the tap is live afterwards;
    /// false means the caller must fail safe rather than show a non-blocking lock.
    @discardableResult
    func endAuthMode() -> Bool {
        authMode = false
        firstInteractionFired = false
        return ensureLive()
    }

    /// True if the tap exists and is currently enabled.
    func isLive() -> Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Ensure the tap is installed and enabled; reinstall if it died. Returns
    /// the resulting liveness. Used to re-arm after sleep/wake or a session
    /// switch where a session-level tap can be torn down by the system.
    @discardableResult
    func ensureLive() -> Bool {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            if CGEvent.tapIsEnabled(tap: tap) { return true }
            teardownTap()
        }
        return installTap()
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
