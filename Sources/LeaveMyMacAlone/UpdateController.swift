import AppKit
import Combine
import Sparkle
import LeaveMyMacAloneCore

/// Silent auto-update via Sparkle. Checks the appcast in the background,
/// downloads + verifies (EdDSA + Developer ID) new versions, and installs them
/// with a relaunch — but never while the Mac is locked: a relaunch would drop
/// the lock, so a ready update is held until the lock releases.
@MainActor
final class UpdateController: NSObject, ObservableObject {

    /// Mirrors Sparkle's own persisted "check + download automatically" pair so
    /// the menu toggle can bind to it.
    @Published var automaticallyUpdates: Bool {
        didSet {
            updater.automaticallyChecksForUpdates = automaticallyUpdates
            updater.automaticallyDownloadsUpdates = automaticallyUpdates
        }
    }

    private let isLocked: () -> Bool
    private var gate = UpdateInstallGate()
    private var pendingInstall: (() -> Void)?
    // Implicitly unwrapped: the controller needs `self` as its delegate, so it
    // is created after super.init().
    private var controller: SPUStandardUpdaterController!

    private var updater: SPUUpdater { controller.updater }

    /// The running version, for display ("v1.2.0").
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    init(isLocked: @escaping () -> Bool) {
        self.isLocked = isLocked
        self.automaticallyUpdates = true
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        // Sparkle persists the user's choice; Info.plist only sets the default.
        automaticallyUpdates = updater.automaticallyChecksForUpdates
            && updater.automaticallyDownloadsUpdates
    }

    /// "Şimdi kontrol et" — a user-initiated check with Sparkle's standard UI.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Called when the lock fully releases; installs an update held during it.
    func lockDidRelease() {
        guard gate.lockReleased(), let install = pendingInstall else { return }
        pendingInstall = nil
        install()
    }
}

extension UpdateController: SPUUpdaterDelegate {
    /// No update checks (and thus no Sparkle UI) while locked or authenticating:
    /// a window over / under the shield would either be unreachable or leak past it.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard isLocked() else { return }
        throw NSError(domain: "LeaveMyMacAlone.Update", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Update checks are paused while the Mac is locked."
        ])
    }

    /// A silently downloaded update is ready. Take control of installing it
    /// (return true) so a menu-bar app that rarely quits still updates promptly:
    /// install + relaunch now, or as soon as the lock releases.
    func updater(_ updater: SPUUpdater,
                 willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        if gate.updateReady(isLocked: isLocked()) {
            immediateInstallHandler()
        } else {
            pendingInstall = immediateInstallHandler
        }
        return true
    }
}

extension UpdateController: @preconcurrency SPUStandardUserDriverDelegate {
    // Menu-bar (LSUIElement) app: let Sparkle use gentle reminders for any
    // scheduled update it does show, instead of stealing focus. (Sparkle calls
    // this delegate on the main thread; the protocol just isn't annotated.)
    var supportsGentleScheduledUpdateReminders: Bool { true }
}
