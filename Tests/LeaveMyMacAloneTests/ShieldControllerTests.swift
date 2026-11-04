import XCTest
@testable import LeaveMyMacAlone

@MainActor
final class ShieldControllerTests: XCTestCase {

    private func show(_ shield: ShieldController) {
        shield.show(opacity: 0, away: nil, floating: nil, floatingSize: .medium,
                    onInteract: {}, onUnlock: {})
    }

    // Locking again while the unlock animation runs reuses the windows hide() made
    // click-through, and its pending fade would hide the overlay: the state would say
    // locked over a visible, clickable desktop.
    func testRelockDuringUnlockAnimationLeavesASolidShield() async throws {
        let shield = ShieldController()
        show(shield)
        shield.hide(success: true)
        show(shield)
        try await Task.sleep(for: .seconds(1.2)) // longer than the whole exit animation
        XCTAssertTrue(shield.isSolidForTesting)
        shield.hide()
    }
}
