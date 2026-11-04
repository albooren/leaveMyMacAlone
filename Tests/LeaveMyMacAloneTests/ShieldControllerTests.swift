import XCTest
@testable import LeaveMyMacAlone

@MainActor
final class ShieldControllerTests: XCTestCase {

    // A context menu draws above the shield and offers Paste, which could submit the
    // owner's clipboard as the password. These are the clicks that open one.
    func testRightClickOpensAContextMenu() {
        XCTAssertTrue(KeyableWindow.opensContextMenu(type: .rightMouseDown, modifiers: []))
    }

    func testControlClickOpensAContextMenu() {
        XCTAssertTrue(KeyableWindow.opensContextMenu(type: .leftMouseDown, modifiers: .control))
    }

    func testPlainClickDoesNotOpenAContextMenu() {
        XCTAssertFalse(KeyableWindow.opensContextMenu(type: .leftMouseDown, modifiers: []))
    }

    func testOtherModifiersDoNotOpenAContextMenu() {
        XCTAssertFalse(KeyableWindow.opensContextMenu(type: .leftMouseDown, modifiers: .shift))
    }

    func testKeyEventsDoNotOpenAContextMenu() {
        XCTAssertFalse(KeyableWindow.opensContextMenu(type: .keyDown, modifiers: .control))
    }

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
