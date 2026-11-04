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
    private nonisolated(unsafe) static let fullScreenAttribute = "AXFullScreen" as CFString

    /// If the frontmost app (not us) has a focused window in native full-screen,
    /// take it out of full-screen. Returns whether it exited a full-screen window.
    @discardableResult
    @MainActor
    static func exitFrontmostFullScreen() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = front.processIdentifier
        guard pid != NSRunningApplication.current.processIdentifier else { return false }

        let app = AXUIElementCreateApplication(pid)
        // Cap how long a hung/unresponsive front app can block the lock path: the
        // AX messaging API is synchronous (~6s default per call) and this runs
        // before the shield is shown — fail fast to a no-op rather than leave the
        // screen uncovered for seconds.
        _ = AXUIElementSetMessagingTimeout(app, Float(0.5))

        guard let window = focusedWindow(of: app), isFullScreen(window) else { return false }

        return AXUIElementSetAttributeValue(window, fullScreenAttribute, kCFBooleanFalse) == .success
    }

    /// Takes every regular app's windows out of native full-screen. A full-screen Space
    /// the shield cannot cover must not outlive the lock, whether it sits on another
    /// display or one swipe away. On a dispatch queue because an unresponsive app can
    /// stall each AX call for up to the messaging timeout: that must block neither the
    /// main run loop, which the keyboard tap needs, nor the Swift concurrency pool.
    @MainActor
    static func exitEveryFullScreenInBackground() {
        let me = NSRunningApplication.current.processIdentifier
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
            .map(\.processIdentifier)
        DispatchQueue.global(qos: .userInitiated).async {
            for pid in pids { exitFullScreenWindows(ofPID: pid) }
        }
    }

    private static func exitFullScreenWindows(ofPID pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, Float(0.5))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for window in windows where isFullScreen(window) {
            AXUIElementSetAttributeValue(window, fullScreenAttribute, kCFBooleanFalse)
        }
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
