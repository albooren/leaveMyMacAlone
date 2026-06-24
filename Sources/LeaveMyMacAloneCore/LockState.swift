public enum LockState: Equatable {
    case unlocked
    case locked
    case authenticating
}

/// Coordinates the lock lifecycle. Transitions:
/// unlocked --lock--> locked --beginAuth--> authenticating
/// authenticating --authSucceeded--> unlocked
/// authenticating --authFailed--> locked
/// Illegal transitions are rejected (return false, state unchanged).
public struct LockStateMachine {
    public private(set) var state: LockState

    public init() {
        state = .unlocked
    }

    public mutating func lock() -> Bool {
        guard state == .unlocked else { return false }
        state = .locked
        return true
    }

    public mutating func beginAuth() -> Bool {
        guard state == .locked else { return false }
        state = .authenticating
        return true
    }

    public mutating func authSucceeded() -> Bool {
        guard state == .authenticating else { return false }
        state = .unlocked
        return true
    }

    public mutating func authFailed() -> Bool {
        guard state == .authenticating else { return false }
        state = .locked
        return true
    }
}
