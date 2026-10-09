import Foundation
import Combine
import LeaveMyMacAloneCore

/// Observable, persisted settings. `overlayOpacity` is clamped to
/// Transparency.range on every set and mirrored to UserDefaults.
@MainActor
final class AppSettingsStore: ObservableObject {

    static let opacityKey = "overlayOpacity"
    static let preventSleepKey = "preventSleepWhileLocked"
    static let captureIntruderPhotoKey = "captureIntruderPhoto"
    static let pauseMediaKey = "pauseMediaOnLock"
    static let awayPresetKey = "awayPreset"
    static let awayCustomTextKey = "awayCustomText"
    static let awayReturnMinutesKey = "awayReturnMinutes"

    /// Notified on every committed change so a live consumer (the shield
    /// window) can update its alpha while the user drags the slider.
    var onOpacityChange: ((Double) -> Void)?

    @Published var overlayOpacity: Double {
        didSet {
            let clamped = Transparency.clamp(overlayOpacity)
            // Re-assign once if clamping changed the value; the guard below
            // prevents infinite recursion through didSet.
            if clamped != overlayOpacity {
                overlayOpacity = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.opacityKey)
            onOpacityChange?(clamped)
        }
    }

    /// Keep the Mac awake (display + idle system sleep) while it is locked.
    /// Default on; when off, the Mac may sleep while locked (the lock resumes on
    /// wake). Only consulted at lock time.
    @Published var preventSleepWhileLocked: Bool {
        didSet {
            UserDefaults.standard.set(preventSleepWhileLocked, forKey: Self.preventSleepKey)
        }
    }

    /// Capture a front-camera photo when someone tries to force the lock open.
    /// Default off (opt-in, privacy-sensitive). Read at lock time.
    @Published var captureIntruderPhoto: Bool {
        didSet {
            UserDefaults.standard.set(captureIntruderPhoto, forKey: Self.captureIntruderPhotoKey)
        }
    }

    /// Pause playing audio/video when locking. Default on.
    @Published var pauseMediaOnLock: Bool {
        didSet {
            UserDefaults.standard.set(pauseMediaOnLock, forKey: Self.pauseMediaKey)
        }
    }

    /// Lock-screen status message ("Toplantıdayım"). Read at lock time.
    @Published var awayPreset: AwayPreset {
        didSet {
            UserDefaults.standard.set(awayPreset.rawValue, forKey: Self.awayPresetKey)
        }
    }

    /// Free text for the `.custom` preset.
    @Published var awayCustomText: String {
        didSet {
            UserDefaults.standard.set(awayCustomText, forKey: Self.awayCustomTextKey)
        }
    }

    /// "Back in N minutes", counted from the moment of locking; 0 = don't say.
    @Published var awayReturnMinutes: Int {
        didSet {
            UserDefaults.standard.set(awayReturnMinutes, forKey: Self.awayReturnMinutesKey)
        }
    }

    init() {
        // object(forKey:) (not double(forKey:)) so a missing key is
        // distinguishable from a stored 0.0.
        let stored = UserDefaults.standard.object(forKey: Self.opacityKey) as? Double
        overlayOpacity = Transparency.clamp(stored ?? Transparency.defaultOpacity)

        // Default on (preserve the prior always-prevent-sleep behaviour).
        let storedSleep = UserDefaults.standard.object(forKey: Self.preventSleepKey) as? Bool
        preventSleepWhileLocked = storedSleep ?? true

        // Default off — capture is opt-in.
        let storedCapture = UserDefaults.standard.object(forKey: Self.captureIntruderPhotoKey) as? Bool
        captureIntruderPhoto = storedCapture ?? false

        let storedPause = UserDefaults.standard.object(forKey: Self.pauseMediaKey) as? Bool
        pauseMediaOnLock = storedPause ?? true

        let storedPreset = UserDefaults.standard.string(forKey: Self.awayPresetKey)
        awayPreset = storedPreset.flatMap(AwayPreset.init(rawValue:)) ?? .none
        awayCustomText = UserDefaults.standard.string(forKey: Self.awayCustomTextKey) ?? ""
        awayReturnMinutes = UserDefaults.standard.integer(forKey: Self.awayReturnMinutesKey)
    }

    /// The lock-screen message for a lock starting now (nil = show none).
    func awayStatus(lockedAt: Date = Date()) -> AwayStatus? {
        AwayStatus.resolve(preset: awayPreset, customText: awayCustomText,
                           returnInMinutes: awayReturnMinutes, lockedAt: lockedAt)
    }
}
