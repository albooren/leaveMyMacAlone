import Foundation
import Combine
import LeaveMyMacAloneCore

/// Observable, persisted settings. `overlayOpacity` is clamped to
/// Transparency.range on every set and mirrored to UserDefaults.
@MainActor
final class AppSettingsStore: ObservableObject {

    static let opacityKey = "overlayOpacity"
    static let preventSleepKey = "preventSleepWhileLocked"

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

    init() {
        // object(forKey:) (not double(forKey:)) so a missing key is
        // distinguishable from a stored 0.0.
        let stored = UserDefaults.standard.object(forKey: Self.opacityKey) as? Double
        overlayOpacity = Transparency.clamp(stored ?? Transparency.defaultOpacity)

        // Default on (preserve the prior always-prevent-sleep behaviour).
        let storedSleep = UserDefaults.standard.object(forKey: Self.preventSleepKey) as? Bool
        preventSleepWhileLocked = storedSleep ?? true
    }
}
