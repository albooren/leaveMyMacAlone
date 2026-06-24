import XCTest
@testable import LeaveMyMacAloneCore

final class TransparencyTests: XCTestCase {
    func testClampWithinRangeReturnsSameValue() {
        XCTAssertEqual(Transparency.clamp(0.5), 0.5)
    }

    func testClampBelowRangeReturnsLowerBound() {
        XCTAssertEqual(Transparency.clamp(-1.0), 0.0)
    }

    func testClampAboveRangeReturnsUpperBound() {
        XCTAssertEqual(Transparency.clamp(2.0), 0.85)
    }

    func testDefaultOpacityIsWithinRange() {
        XCTAssertTrue(Transparency.range.contains(Transparency.defaultOpacity))
    }
}
