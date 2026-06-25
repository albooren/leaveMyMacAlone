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
    private let notificationDelegate = ForegroundNotificationPresenter()
    private(set) var capturedThisSession = 0

    init(photographer: IntruderPhotographer,
         directory: URL = IntruderCapture.defaultDirectory) {
        self.photographer = photographer
        self.directory = directory
        self.policy = IntruderCapturePolicy(enabled: false)
    }

    /// Install the notification delegate so intruder banners appear even when we
    /// are the active app at unlock, and tapping one opens the photos folder. Call
    /// once at app startup — NOT from `init`, since `UNUserNotificationCenter
    /// .current()` traps in non-app contexts such as unit tests (no bundle id).
    func installNotificationDelegate() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
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

    /// Grab one photo and save it. Call via a plain `Task { }` from a
    /// `@MainActor` context (the class is @MainActor-isolated and not Sendable,
    /// so `Task.detached` would not compile); never throws.
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
            identifier: "intruder-\(UUID().uuidString)",
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

/// Lets intruder notifications appear even when LeaveMyMacAlone is the active app
/// at unlock time — macOS suppresses a foreground app's notification banners
/// unless its delegate opts in via `willPresent`.
private final class ForegroundNotificationPresenter: NSObject,
                                                     UNUserNotificationCenterDelegate,
                                                     @unchecked Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// Tapping the intruder notification (banner or Notification Center) opens
    /// the captured-photos folder in Finder.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in IntruderCapture.openPhotosFolder() }
        }
        completionHandler()
    }
}
