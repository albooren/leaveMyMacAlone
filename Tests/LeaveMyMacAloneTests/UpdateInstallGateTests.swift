import XCTest
@testable import LeaveMyMacAloneCore

final class UpdateInstallGateTests: XCTestCase {
    func testInstallsImmediatelyWhenUnlocked() {
        var gate = UpdateInstallGate()
        XCTAssertTrue(gate.updateReady(isLocked: false))
        XCTAssertFalse(gate.hasPendingInstall)
    }

    func testDefersWhileLocked() {
        var gate = UpdateInstallGate()
        XCTAssertFalse(gate.updateReady(isLocked: true))
        XCTAssertTrue(gate.hasPendingInstall)
    }

    func testDeferredInstallRunsOnceWhenLockReleased() {
        var gate = UpdateInstallGate()
        _ = gate.updateReady(isLocked: true)
        XCTAssertTrue(gate.lockReleased())
        XCTAssertFalse(gate.hasPendingInstall)
        XCTAssertFalse(gate.lockReleased())
    }

    func testLockReleasedWithoutPendingUpdateDoesNothing() {
        var gate = UpdateInstallGate()
        XCTAssertFalse(gate.lockReleased())
    }
}
