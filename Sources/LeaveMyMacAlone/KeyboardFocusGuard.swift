import ApplicationServices
import Foundation

/// Takes the keyboard back if another process gets it while the password field is up.
///
/// A launcher (Raycast, Alfred) has a non-activating panel that can take the keyboard
/// without activating: we stay frontmost, AppKit reports no change, and Secure Event
/// Input stays on, so the event tap can't see the typing. Blind typing would then run in
/// the launcher, behind the shield. The kiosk turns global hot keys off, but a panel can
/// also open from a mouse button or a gesture, which nothing here blocks. Nothing
/// notifies us of this, so the guard polls who holds keyboard focus, system-wide.
///
/// It fails closed: anything but a positive answer that we hold the keyboard counts as
/// losing it, because an app with poor accessibility support answers with an error.
/// Reacting by mistake costs nothing: the shield just takes key status again.
///
/// Only runs while the auth panel is open. Secure Event Input is what blinds the tap,
/// and giving it up instead would expose the password to anything monitoring keys.
final class KeyboardFocusGuard: @unchecked Sendable {
    private static let pollInterval: DispatchTimeInterval = .milliseconds(50)
    // A focus fight must not turn into a stream of window changes.
    private static let minimumReactionGap: DispatchTimeInterval = .milliseconds(200)
    private let queue = DispatchQueue(label: "com.alperenkisi.leavemymacalone.focusguard")
    private var timer: DispatchSourceTimer?
    private var nextReactionAllowed = DispatchTime.now() // only touched on `queue`

    func start(onForeignFocus: @escaping @MainActor @Sendable () -> Void) {
        stop()
        let me = getpid()
        let system = AXUIElementCreateSystemWide()
        // Short: this runs every poll and must not back up behind a hung app.
        AXUIElementSetMessagingTimeout(system, 0.2)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [self] in
            guard Self.keyboardOwner(system) != me,
                  DispatchTime.now() >= nextReactionAllowed else { return }
            nextReactionAllowed = .now() + Self.minimumReactionGap
            Task { @MainActor in onForeignFocus() }
        }
        timer.resume()
        self.timer = timer
    }

    private static func keyboardOwner(_ system: AXUIElement) -> pid_t? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var owner: pid_t = 0
        return AXUIElementGetPid(focused as! AXUIElement, &owner) == .success ? owner : nil
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
