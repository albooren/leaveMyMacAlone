/// Slows down password guessing at the lock screen. The system's own auth prompt
/// did this for us; the in-shield password field has to do it itself. `now` is
/// supplied as monotonic seconds so the timing is testable without a real clock.
///
/// The first `freeAttempts` failures are free (typos happen); each failure after
/// that imposes a `lockoutSeconds` wait. Only a successful unlock clears the count,
/// so cancelling and re-opening the panel does not reset it.
public struct PasswordAttemptPolicy {
    public static let freeAttempts = 4
    public static let lockoutSeconds: Double = 30

    private var failures = 0
    private var lockedUntil: Double?

    public init() {}

    public mutating func noteFailure(now: Double) {
        failures += 1
        if failures > Self.freeAttempts {
            lockedUntil = now + Self.lockoutSeconds
        }
    }

    /// Seconds left before another attempt is allowed (0 = may try now).
    public func retryDelay(now: Double) -> Double {
        guard let lockedUntil else { return 0 }
        return max(0, lockedUntil - now)
    }

    public mutating func reset() {
        failures = 0
        lockedUntil = nil
    }
}
