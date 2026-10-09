/// Decides when a downloaded update may be installed. Installing relaunches the
/// app, which would tear down an active lock — so an update that becomes ready
/// while the Mac is locked (or authenticating) is held until the lock releases.
public struct UpdateInstallGate {
    public private(set) var hasPendingInstall = false

    public init() {}

    /// An update finished downloading. Returns true if it should be installed
    /// now; otherwise it is held until `lockReleased()`.
    public mutating func updateReady(isLocked: Bool) -> Bool {
        guard isLocked else { return true }
        hasPendingInstall = true
        return false
    }

    /// The lock was released. Returns true (once) if a held update should now
    /// be installed.
    public mutating func lockReleased() -> Bool {
        guard hasPendingInstall else { return false }
        hasPendingInstall = false
        return true
    }
}
