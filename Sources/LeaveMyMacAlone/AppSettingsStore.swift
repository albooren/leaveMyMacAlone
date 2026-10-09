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
    static let awayPresetKey = "awayPreset"
    static let awayCustomTextKey = "awayCustomText"
    static let awayReturnMinutesKey = "awayReturnMinutes"
    static let awayReturnEnabledKey = "awayReturnEnabled"
    static let floatingKindKey = "floatingIconKind"
    static let floatingEmojiKey = "floatingEmoji"
    static let floatingImageNameKey = "floatingImageName"

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

    /// Show "Dönüş: 14:30" on the lock screen.
    @Published var awayReturnEnabled: Bool {
        didSet {
            UserDefaults.standard.set(awayReturnEnabled, forKey: Self.awayReturnEnabledKey)
        }
    }

    /// "Back in N minutes", counted from the moment of locking (a ReturnTimeSteps value).
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

        let storedPreset = UserDefaults.standard.string(forKey: Self.awayPresetKey)
        awayPreset = storedPreset.flatMap(AwayPreset.init(rawValue:)) ?? .none
        awayCustomText = UserDefaults.standard.string(forKey: Self.awayCustomTextKey) ?? ""
        // Before the on/off switch existed, 0 minutes meant "off".
        let storedMinutes = UserDefaults.standard.integer(forKey: Self.awayReturnMinutesKey)
        let storedEnabled = UserDefaults.standard.object(forKey: Self.awayReturnEnabledKey) as? Bool
        awayReturnEnabled = storedEnabled ?? (storedMinutes > 0)
        awayReturnMinutes = storedMinutes > 0 ? storedMinutes : ReturnTimeSteps.defaultMinutes

        let storedKind = UserDefaults.standard.string(forKey: Self.floatingKindKey)
        floatingKind = storedKind.flatMap(FloatingIconKind.init(rawValue:)) ?? .none
        floatingEmoji = UserDefaults.standard.string(forKey: Self.floatingEmojiKey) ?? "☕"
        floatingImageName = UserDefaults.standard.string(forKey: Self.floatingImageNameKey)
    }

    /// What drifts around the lock screen.
    @Published var floatingKind: FloatingIconKind {
        didSet {
            UserDefaults.standard.set(floatingKind.rawValue, forKey: Self.floatingKindKey)
        }
    }

    /// The emoji used when `floatingKind == .emoji`.
    @Published var floatingEmoji: String {
        didSet {
            UserDefaults.standard.set(floatingEmoji, forKey: Self.floatingEmojiKey)
        }
    }

    /// Original file name of the imported image (for display); nil = none imported.
    /// Re-set on every import so views reload the image.
    @Published var floatingImageName: String? {
        didSet {
            UserDefaults.standard.set(floatingImageName, forKey: Self.floatingImageNameKey)
        }
    }

    /// The icon to show for a lock starting now (nil = nothing drifts).
    func floatingIcon() -> FloatingIcon? {
        switch floatingKind {
        case .none: return nil
        case .emoji: return .emoji(floatingEmoji)
        case .image: return FloatingImageStore.load().map(FloatingIcon.image)
        }
    }

    /// The lock-screen message for a lock starting now (nil = show none).
    func awayStatus(lockedAt: Date = Date()) -> AwayStatus? {
        AwayStatus.resolve(preset: awayPreset, customText: awayCustomText,
                           returnInMinutes: awayReturnEnabled ? awayReturnMinutes : 0,
                           lockedAt: lockedAt)
    }
}
