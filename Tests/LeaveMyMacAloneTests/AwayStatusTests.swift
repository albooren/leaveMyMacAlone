import XCTest
@testable import LeaveMyMacAloneCore

final class AwayStatusTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: hour, minute: minute))!
    }

    func testNonePresetWithoutReturnShowsNothing() {
        XCTAssertNil(AwayStatus.resolve(preset: .none, customText: "x", returnInMinutes: 0,
                                        lockedAt: date(14, 0), calendar: calendar))
    }

    func testNonePresetStillShowsReturnTime() {
        let status = AwayStatus.resolve(preset: .none, customText: "x", returnInMinutes: 30,
                                        lockedAt: date(14, 0), calendar: calendar)
        XCTAssertEqual(status, AwayStatus(headline: nil, returnTime: date(14, 30)))
    }

    func testPresetWithoutReturnTime() {
        let status = AwayStatus.resolve(preset: .meeting, customText: "", returnInMinutes: 0,
                                        lockedAt: date(14, 0), calendar: calendar)
        XCTAssertEqual(status, AwayStatus(headline: .preset(.meeting), returnTime: nil))
    }

    func testReturnTimeRoundsUpToFiveMinutes() {
        let status = AwayStatus.resolve(preset: .lunch, customText: "", returnInMinutes: 30,
                                        lockedAt: date(12, 7), calendar: calendar)
        XCTAssertEqual(status?.returnTime, date(12, 40))
    }

    func testReturnTimeOnFiveMinuteBoundaryStays() {
        let status = AwayStatus.resolve(preset: .lunch, customText: "", returnInMinutes: 15,
                                        lockedAt: date(12, 15), calendar: calendar)
        XCTAssertEqual(status?.returnTime, date(12, 30))
    }

    func testReturnTimeRollsOverTheHour() {
        let status = AwayStatus.resolve(preset: .backSoon, customText: "", returnInMinutes: 15,
                                        lockedAt: date(12, 43), calendar: calendar)
        XCTAssertEqual(status?.returnTime, date(13, 0))
    }

    func testCustomTextIsTrimmedAndCapped() {
        let long = "  " + String(repeating: "a", count: 200) + "  "
        let status = AwayStatus.resolve(preset: .custom, customText: long, returnInMinutes: 0,
                                        lockedAt: date(9, 0), calendar: calendar)
        XCTAssertEqual(status?.headline, .custom(String(repeating: "a", count: AwayStatus.maxCustomLength)))
    }

    func testBlankCustomTextWithoutReturnShowsNothing() {
        XCTAssertNil(AwayStatus.resolve(preset: .custom, customText: "   ", returnInMinutes: 0,
                                        lockedAt: date(9, 0), calendar: calendar))
    }

    func testBlankCustomTextWithReturnShowsOnlyReturnTime() {
        let status = AwayStatus.resolve(preset: .custom, customText: " ", returnInMinutes: 60,
                                        lockedAt: date(9, 0), calendar: calendar)
        XCTAssertEqual(status, AwayStatus(headline: nil, returnTime: date(10, 0)))
    }
}
