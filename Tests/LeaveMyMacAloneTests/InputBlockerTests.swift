import XCTest
@testable import LeaveMyMacAlone

/// Regression guard for the auth-mode leak: any teardown that goes through
/// stop() (the success / force-unlock / fail-safe paths) must leave the blocker
/// in full-swallow mode so the NEXT lock blocks input instead of passing it
/// through a visible-but-non-blocking "locked" screen.
@MainActor
final class InputBlockerTests: XCTestCase {

    func testFreshBlockerIsNotInAuthMode() {
        let blocker = InputBlocker()
        XCTAssertFalse(blocker.isAuthModeActiveForTesting)
    }

    func testBeginAuthModeEntersPassThrough() {
        let blocker = InputBlocker()
        blocker.beginAuthMode()
        XCTAssertTrue(blocker.isAuthModeActiveForTesting)
    }

    func testStopClearsAuthMode() {
        let blocker = InputBlocker()
        blocker.beginAuthMode()
        XCTAssertTrue(blocker.isAuthModeActiveForTesting)
        // The success / force / fail-safe teardowns call stop() directly; it must
        // re-arm full-swallow mode for the next lock.
        blocker.stop()
        XCTAssertFalse(blocker.isAuthModeActiveForTesting)
    }
}
