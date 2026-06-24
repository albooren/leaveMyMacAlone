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

    private static let lockedOptions: NSApplication.PresentationOptions = [
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
