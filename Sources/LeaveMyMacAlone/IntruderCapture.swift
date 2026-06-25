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
