import XCTest
@testable import LeaveMyMacAloneCore

final class BounceMathTests: XCTestCase {
    func testStartsAtPhase() {
        XCTAssertEqual(BounceMath.position(elapsed: 0, speed: 100, travel: 300, phase: 50), 50, accuracy: 0.001)
    }

    func testMovesForwardUntilTheEdge() {
        XCTAssertEqual(BounceMath.position(elapsed: 2, speed: 100, travel: 300, phase: 0), 200, accuracy: 0.001)
        XCTAssertEqual(BounceMath.position(elapsed: 3, speed: 100, travel: 300, phase: 0), 300, accuracy: 0.001)
    }

    func testReflectsOffTheFarEdge() {
        XCTAssertEqual(BounceMath.position(elapsed: 4, speed: 100, travel: 300, phase: 0), 200, accuracy: 0.001)
    }

    func testReflectsOffTheNearEdgeAndRepeats() {
        XCTAssertEqual(BounceMath.position(elapsed: 6, speed: 100, travel: 300, phase: 0), 0, accuracy: 0.001)
        XCTAssertEqual(BounceMath.position(elapsed: 7, speed: 100, travel: 300, phase: 0), 100, accuracy: 0.001)
    }

    func testStaysInsideTravelForLongRuns() {
        for second in stride(from: 0.0, through: 36_000, by: 137.3) {
            let p = BounceMath.position(elapsed: second, speed: 173, travel: 1180, phase: 411)
            XCTAssertTrue((0...1180).contains(p), "\(p) at \(second)s")
        }
    }

    func testZeroTravelPinsToZero() {
        XCTAssertEqual(BounceMath.position(elapsed: 5, speed: 100, travel: 0, phase: 0), 0)
    }
}

final class ReturnTimeStepsTests: XCTestCase {
    func testStepsUpAndDown() {
        XCTAssertEqual(ReturnTimeSteps.next(after: 30), 45)
        XCTAssertEqual(ReturnTimeSteps.previous(before: 30), 15)
        XCTAssertEqual(ReturnTimeSteps.next(after: 60), 90)
    }

    func testClampsAtTheEnds() {
        XCTAssertEqual(ReturnTimeSteps.previous(before: 15), 15)
        XCTAssertEqual(ReturnTimeSteps.next(after: 240), 240)
    }

    func testOffGridValueSnapsToNeighbour() {
        XCTAssertEqual(ReturnTimeSteps.next(after: 50), 60)
        XCTAssertEqual(ReturnTimeSteps.previous(before: 50), 45)
    }

    func testParsesTypedMinutes() {
        XCTAssertEqual(ReturnTimeSteps.parseDuration("50"), 50)
        XCTAssertEqual(ReturnTimeSteps.parseDuration(" 5 "), 5)
    }

    func testParsesHoursColonMinutes() {
        XCTAssertEqual(ReturnTimeSteps.parseDuration("1:30"), 90)
        XCTAssertEqual(ReturnTimeSteps.parseDuration("2.15"), 135)
        XCTAssertEqual(ReturnTimeSteps.parseDuration("0:45"), 45)
    }

    func testRejectsInvalidOrOutOfRangeDurations() {
        XCTAssertNil(ReturnTimeSteps.parseDuration(""))
        XCTAssertNil(ReturnTimeSteps.parseDuration("abc"))
        XCTAssertNil(ReturnTimeSteps.parseDuration("0"))
        XCTAssertNil(ReturnTimeSteps.parseDuration("1:75"))
        XCTAssertNil(ReturnTimeSteps.parseDuration("13:00"))   // over 12 hours
        XCTAssertNil(ReturnTimeSteps.parseDuration("-5"))
    }

    func testSplitsIntoHoursAndMinutes() {
        XCTAssertTrue(ReturnTimeSteps.split(90) == (1, 30))
        XCTAssertTrue(ReturnTimeSteps.split(45) == (0, 45))
        XCTAssertTrue(ReturnTimeSteps.split(120) == (2, 0))
    }
}

final class EmojiCatalogTests: XCTestCase {
    func testContainsCommonEmoji() {
        for emoji in ["😀", "🍔", "🐱", "🚀", "☕", "❤️", "🦄"] {
            XCTAssertTrue(EmojiCatalog.all.contains(emoji), emoji)
        }
    }

    func testFacesComeFirst() {
        XCTAssertEqual(EmojiCatalog.all.first, "😀")
    }

    func testExcludesNonStandaloneScalars() {
        XCTAssertFalse(EmojiCatalog.all.contains("🇹"))   // regional indicator
        XCTAssertFalse(EmojiCatalog.all.contains("🏽"))   // skin-tone modifier
    }

    func testHasNoDuplicatesAndIsLarge() {
        XCTAssertEqual(Set(EmojiCatalog.all).count, EmojiCatalog.all.count)
        XCTAssertGreaterThan(EmojiCatalog.all.count, 1000)
    }

    func testSearchesByName() {
        XCTAssertTrue(EmojiCatalog.search("cat").contains("🐱"))
        XCTAssertTrue(EmojiCatalog.search("  HAMBURGER ").contains("🍔"))
        XCTAssertFalse(EmojiCatalog.search("hamburger").contains("😀"))
    }

    func testEmptySearchReturnsEverything() {
        XCTAssertEqual(EmojiCatalog.search("").count, EmojiCatalog.all.count)
    }
}

final class FloatingIconSizeTests: XCTestCase {
    func testSizesGrowInOrder() {
        let points = FloatingIconSize.allCases.map(\.lockScreenPoints)
        XCTAssertEqual(points, points.sorted())
        XCTAssertEqual(FloatingIconSize.allCases.count, 3)
    }

    func testSizesAreLargeEnoughToNotice() {
        XCTAssertEqual(FloatingIconSize.small.lockScreenPoints, 104)
        XCTAssertEqual(FloatingIconSize.medium.lockScreenPoints, 144)
        XCTAssertEqual(FloatingIconSize.large.lockScreenPoints, 200)
    }

    func testPreviewIsAScaledDownLockScreen() {
        for size in FloatingIconSize.allCases {
            XCTAssertLessThan(size.previewPoints, size.lockScreenPoints)
            XCTAssertGreaterThanOrEqual(size.previewPoints, 12)
        }
    }
}
