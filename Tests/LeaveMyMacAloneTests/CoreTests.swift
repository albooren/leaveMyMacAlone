import XCTest
@testable import LeaveMyMacAloneCore

final class CoreTests: XCTestCase {
    func testBundleIdentifier() {
        XCTAssertEqual(LeaveMyMacAloneCore.bundleIdentifier,
                       "com.alperenkisi.leavemymacalone")
    }
}
