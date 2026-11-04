import AppKit
import ApplicationServices

/// Brings this app to the front. The kiosk options only hold while we are the active
/// app, so a lock depends on this actually working.
///
/// `NSApp.activate()` is just a request: since macOS 14 it is refused when another
/// app is frontmost and nothing yielded to us (measured on macOS 27). Setting our own
/// AXFrontmost is honoured, and needs only the Accessibility grant a lock already
/// requires. `activate()` stays first as the polite path.
@MainActor
enum Foreground {
    static func take() {
        NSApp.activate()
        let me = AXUIElementCreateApplication(getpid())
        let result = AXUIElementSetAttributeValue(me, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if result != .success {
            NSLog("Foreground: could not set AXFrontmost (\(result.rawValue))")
        }
    }
}
