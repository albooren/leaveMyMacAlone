import XCTest
@testable import LeaveMyMacAloneCore

final class IntruderCapturePolicyTests: XCTestCase {

    func testFirstTwoInteractionsAreFree() {
        var p = IntruderCapturePolicy(enabled: true)
        XCTAssertFalse(p.noteInteraction(now: 0))   // 1st
        XCTAssertFalse(p.noteInteraction(now: 1))   // 2nd
    }

    func testThirdInteractionCaptures() {
        var p = IntruderCapturePolicy(enabled: true)
        _ = p.noteInteraction(now: 0)
        _ = p.noteInteraction(now: 1)
        XCTAssertTrue(p.noteInteraction(now: 2))    // 3rd → capture
    }

    func testCooldownSuppressesImmediateNextCapture() {
        var p = IntruderCapturePolicy(enabled: true)
        _ = p.noteInteraction(now: 0)
        _ = p.noteInteraction(now: 0)
        XCTAssertTrue(p.noteInteraction(now: 10))   // 3rd → capture at t=10
        XCTAssertFalse(p.noteInteraction(now: 12))  // +2s < 5s cooldown
    }

    func testCaptureResumesAfterCooldown() {
        var p = IntruderCapturePolicy(enabled: true)
        _ = p.noteInteraction(now: 0)
        _ = p.noteInteraction(now: 0)
        XCTAssertTrue(p.noteInteraction(now: 10))   // capture at t=10
        XCTAssertTrue(p.noteInteraction(now: 15))   // +5s ≥ cooldown → capture
    }

    func testResetReturnsToGraceState() {
        var p = IntruderCapturePolicy(enabled: true)
        _ = p.noteInteraction(now: 0)
        _ = p.noteInteraction(now: 1)
        _ = p.noteInteraction(now: 2)               // captured
        p.reset()
        XCTAssertFalse(p.noteInteraction(now: 3))   // 1st again → free
        XCTAssertFalse(p.noteInteraction(now: 4))   // 2nd → free
        XCTAssertTrue(p.noteInteraction(now: 5))    // 3rd → capture
    }

    func testDisabledNeverCaptures() {
        var p = IntruderCapturePolicy(enabled: false)
        for t in 0..<10 {
            XCTAssertFalse(p.noteInteraction(now: Double(t)))
        }
    }

    func testSetEnabledTogglesBehavior() {
        var p = IntruderCapturePolicy(enabled: false)
        _ = p.noteInteraction(now: 0)
        _ = p.noteInteraction(now: 1)
        XCTAssertFalse(p.noteInteraction(now: 2))   // disabled → no capture
        p.setEnabled(true)
        p.reset()
        _ = p.noteInteraction(now: 3)
        _ = p.noteInteraction(now: 4)
        XCTAssertTrue(p.noteInteraction(now: 5))    // enabled → 3rd captures
    }
}
