import XCTest
import AppKit
@testable import LeaveMyMacAlone

@MainActor
final class PreviewOverlayControllerTests: XCTestCase {
    func testFreshControllerHasNoWindows() {
        let controller = PreviewOverlayController(store: AppSettingsStore())
        XCTAssertEqual(controller.windowCountForTesting, 0)
    }

    func testStartCreatesOneWindowPerScreen() {
        let controller = PreviewOverlayController(store: AppSettingsStore())
        controller.start()
        XCTAssertEqual(controller.windowCountForTesting, NSScreen.screens.count)
        controller.stop()
    }

    func testStopRemovesAllWindows() {
        let controller = PreviewOverlayController(store: AppSettingsStore())
        controller.start()
        controller.stop()
        XCTAssertEqual(controller.windowCountForTesting, 0)
    }

    func testStartIsIdempotent() {
        let controller = PreviewOverlayController(store: AppSettingsStore())
        controller.start()
        let first = controller.windowCountForTesting
        controller.start()
        XCTAssertEqual(controller.windowCountForTesting, first)
        controller.stop()
    }
}
