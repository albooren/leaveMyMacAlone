import Cocoa
import CoreGraphics
import ApplicationServices

/// Consuming (.defaultTap) session-level CGEventTap that blocks the KEYBOARD
/// while the Mac is locked. The mouse is intentionally NOT tapped, so the cursor
/// keeps working and clicks flow to the full-screen shield (which covers every
/// display at the top window level — a click can only ever land on the shield,
/// never an app behind it). App/Space switching is held off by the kiosk's
/// presentation options while we are frontmost. During authentication the tap
/// passes plain typing to the password screen and swallows only escape
/// shortcuts.
///
/// PERMISSIONS: a consuming tap is gated by Input Monitoring (TCC ListenEvent)
/// and may additionally need Accessibility. We request both but never treat a
/// preflight as a hard gate — the authoritative test is whether the tap is
/// actually live (CGEvent.tapIsEnabled).
final class InputBlocker {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    // While true the tap stays live but only swallows escape shortcuts, letting
    // plain typing through to the auth sheet (see handle / isEscapeShortcut).
    private var authMode = false
    // Keyboard hooks for the locked state (the keyboard is swallowed regardless):
    // Space/Return begin auth (like the "Kilidi Aç" button); any other key fires
    // the "still locked" flash.
    private var onUnlockKey: (@Sendable () -> Void)?
    private var onLockedKey: (@Sendable () -> Void)?

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
    func start(onUnlockKey: @escaping @Sendable () -> Void,
               onLockedKey: @escaping @Sendable () -> Void) -> Bool {
        guard eventTap == nil else { return true }   // already running
        self.onUnlockKey = onUnlockKey
        self.onLockedKey = onLockedKey
        // A fresh lock MUST start in full-block mode. authMode is only cleared
        // by endAuthMode(), but the success/fail-safe teardowns all call stop()
        // directly — so without this reset a prior auth cycle would leave
        // authMode == true and the next lock would pass the keyboard straight
        // through. Re-arm defensively here.
        self.authMode = false
        guard installTap() else {
            self.onUnlockKey = nil
            self.onLockedKey = nil
            NSLog("InputBlocker: tapCreate failed (grant Input Monitoring AND Accessibility).")
            return false
        }
        return true
    }

    @discardableResult
    private func installTap() -> Bool {
        // Keyboard only: the mouse is deliberately left untapped so the cursor
        // works and clicks reach the shield UI. The shield (top window level,
        // covering every display) keeps those clicks off the apps behind it, and
        // the kiosk's presentation options block App/Space switching, so the
        // keyboard is the only stream we must intercept.
        var mask: CGEventMask = 0
        mask |= (1 << CGEventType.keyDown.rawValue)
        mask |= (1 << CGEventType.keyUp.rawValue)
        mask |= (1 << CGEventType.flagsChanged.rawValue)

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

        // Only keyboard events reach this tap (the mask is keyboard-only). During
        // authentication the tap stays LIVE so the lock keeps blocking the
        // escape shortcuts that would otherwise let a passer-by act or strand
        // the owner, while plain typing reaches the separate-process auth screen
        // so the password can be entered.
        if authMode {
            return Self.isEscapeShortcut(type: type, event: event)
                ? nil                                // swallow the escape
                : Unmanaged.passUnretained(event)    // deliver to the password screen
        }

        // Locked: the keyboard is always swallowed (the mouse is untapped, so the
        // cursor and the shield button keep working). On a real key press,
        // Space/Return begin auth — same as the "Kilidi Aç" button — and any
        // other key flashes the lock badge so the user learns the way out.
        // Autorepeat (key held down) is ignored so holding a key doesn't spam.
        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            let cb = Self.isUnlockKey(event) ? onUnlockKey : onLockedKey
            DispatchQueue.main.async { cb?() }
        }
        return nil
    }

    /// Space, Return or keypad Enter — the keyboard equivalents of pressing the
    /// "Kilidi Aç" button.
    private static func isUnlockKey(_ event: CGEvent) -> Bool {
        switch event.getIntegerValueField(.keyboardEventKeycode) {
        case 0x31, 0x24, 0x4C:   // Space · Return · keypad Enter
            return true
        default:
            return false
        }
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
        return ensureLive()
    }

    /// Test hook: whether the tap is in pass-through (auth) mode. A fresh lock
    /// must always read false here, regardless of how the prior cycle ended.
    var isAuthModeActiveForTesting: Bool { authMode }

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
        authMode = false
        onUnlockKey = nil
        onLockedKey = nil
    }
}
