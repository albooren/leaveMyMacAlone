import XCTest
@testable import LeaveMyMacAloneCore

final class PasswordAttemptPolicyTests: XCTestCase {

    func testNoWaitBeforeAnyFailure() {
        XCTAssertEqual(PasswordAttemptPolicy().retryDelay(now: 100), 0)
    }

    func testFreeAttemptsAreNotDelayed() {
        var policy = PasswordAttemptPolicy()
        for _ in 0..<PasswordAttemptPolicy.freeAttempts {
            policy.noteFailure(now: 100)
        }
        XCTAssertEqual(policy.retryDelay(now: 100), 0)
    }

    func testFailureBeyondFreeAttemptsImposesTheWait() {
        var policy = PasswordAttemptPolicy()
        for _ in 0...PasswordAttemptPolicy.freeAttempts {
            policy.noteFailure(now: 100)
        }
        XCTAssertEqual(policy.retryDelay(now: 100), PasswordAttemptPolicy.lockoutSeconds)
    }

    func testWaitCountsDownWithTime() {
        var policy = PasswordAttemptPolicy()
        for _ in 0...PasswordAttemptPolicy.freeAttempts {
            policy.noteFailure(now: 100)
        }
        XCTAssertEqual(policy.retryDelay(now: 110), PasswordAttemptPolicy.lockoutSeconds - 10)
    }

    func testWaitEndsAfterTheLockout() {
        var policy = PasswordAttemptPolicy()
        for _ in 0...PasswordAttemptPolicy.freeAttempts {
            policy.noteFailure(now: 100)
        }
        XCTAssertEqual(policy.retryDelay(now: 100 + PasswordAttemptPolicy.lockoutSeconds), 0)
    }

    func testEveryFurtherFailureImposesTheWaitAgain() {
        var policy = PasswordAttemptPolicy()
        for _ in 0...PasswordAttemptPolicy.freeAttempts {
            policy.noteFailure(now: 100)
        }
        let later = 100 + PasswordAttemptPolicy.lockoutSeconds
        policy.noteFailure(now: later)
        XCTAssertEqual(policy.retryDelay(now: later), PasswordAttemptPolicy.lockoutSeconds)
    }

    func testResetClearsFailures() {
        var policy = PasswordAttemptPolicy()
        for _ in 0...PasswordAttemptPolicy.freeAttempts {
            policy.noteFailure(now: 100)
        }
        policy.reset()
        XCTAssertEqual(policy.retryDelay(now: 100), 0)
    }
}
