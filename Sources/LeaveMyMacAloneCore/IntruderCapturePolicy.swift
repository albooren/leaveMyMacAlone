/// Pure, side-effect-free policy deciding WHEN an intruder photo should be
/// taken. No Foundation/AppKit — `now` is supplied by the caller as monotonic
/// seconds so the cooldown is testable without a real clock.
///
/// Rules (design spec): the first `graceInteractions` interactions in a lock
/// session are free; the next one triggers the first capture; afterwards a new
/// capture fires only once `captureCooldown` seconds have elapsed since the
/// last. Disabled → never captures. `reset()` returns to the start-of-session
/// state (a fresh lock, or a successful unlock).
public struct IntruderCapturePolicy {
    public static let graceInteractions = 2
    public static let captureCooldown: Double = 5

    private var enabled: Bool
    private var interactionCount = 0
    private var lastCaptureAt: Double?

    public init(enabled: Bool) {
        self.enabled = enabled
    }

    public mutating func setEnabled(_ on: Bool) {
        enabled = on
    }

    /// Register one locked-state interaction occurring at `now` (monotonic
    /// seconds). Returns true if a photo should be captured.
    public mutating func noteInteraction(now: Double) -> Bool {
        guard enabled else { return false }            // disabled → don't count
        interactionCount += 1
        guard interactionCount > Self.graceInteractions else { return false }
        if let last = lastCaptureAt, now - last < Self.captureCooldown {
            return false
        }
        lastCaptureAt = now
        return true
    }

    /// Return to the start-of-session state.
    public mutating func reset() {
        interactionCount = 0
        lastCaptureAt = nil
    }
}
