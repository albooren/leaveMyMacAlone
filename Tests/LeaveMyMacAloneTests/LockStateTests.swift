import XCTest
@testable import LeaveMyMacAloneCore

final class LockStateTests: XCTestCase {
    func testStartsUnlocked() {
        let machine = LockStateMachine()
        XCTAssertEqual(machine.state, .unlocked)
    }

    func testLockFromUnlocked() {
        var machine = LockStateMachine()
        XCTAssertTrue(machine.lock())
        XCTAssertEqual(machine.state, .locked)
    }

    func testCannotLockWhenAlreadyLocked() {
        var machine = LockStateMachine()
        _ = machine.lock()
        XCTAssertFalse(machine.lock())
        XCTAssertEqual(machine.state, .locked)
    }

    func testBeginAuthFromLocked() {
        var machine = LockStateMachine()
        _ = machine.lock()
        XCTAssertTrue(machine.beginAuth())
        XCTAssertEqual(machine.state, .authenticating)
    }

    func testBeginAuthInvalidFromUnlocked() {
        var machine = LockStateMachine()
        XCTAssertFalse(machine.beginAuth())
        XCTAssertEqual(machine.state, .unlocked)
    }

    func testAuthSucceededReturnsToUnlocked() {
        var machine = LockStateMachine()
        _ = machine.lock()
        _ = machine.beginAuth()
        XCTAssertTrue(machine.authSucceeded())
        XCTAssertEqual(machine.state, .unlocked)
    }

    func testAuthFailedReturnsToLocked() {
        var machine = LockStateMachine()
        _ = machine.lock()
        _ = machine.beginAuth()
        XCTAssertTrue(machine.authFailed())
        XCTAssertEqual(machine.state, .locked)
    }

    func testAbortLockFromLocked() {
        var machine = LockStateMachine()
        _ = machine.lock()
        XCTAssertTrue(machine.abortLock())
        XCTAssertEqual(machine.state, .unlocked)
    }

    func testAbortLockInvalidFromUnlocked() {
        var machine = LockStateMachine()
        XCTAssertFalse(machine.abortLock())
        XCTAssertEqual(machine.state, .unlocked)
    }

    // A quit request (Cmd+Tab + Q, an Apple event) must never end a lock: quitting
    // removes the shield and the input block without any authentication.
    func testTerminationAllowedWhileUnlocked() {
        XCTAssertTrue(LockStateMachine().allowsTermination)
    }

    func testTerminationRefusedWhileLocked() {
        var machine = LockStateMachine()
        _ = machine.lock()
        XCTAssertFalse(machine.allowsTermination)
    }

    func testTerminationRefusedWhileAuthenticating() {
        var machine = LockStateMachine()
        _ = machine.lock()
        _ = machine.beginAuth()
        XCTAssertFalse(machine.allowsTermination)
    }

    func testTerminationAllowedAgainAfterUnlock() {
        var machine = LockStateMachine()
        _ = machine.lock()
        _ = machine.beginAuth()
        _ = machine.authSucceeded()
        XCTAssertTrue(machine.allowsTermination)
    }
}
