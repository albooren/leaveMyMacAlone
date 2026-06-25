import XCTest
@testable import LeaveMyMacAlone

@MainActor
final class IntruderCaptureTests: XCTestCase {

    private struct FakePhotographer: IntruderPhotographer {
        let data: Data?
        func capture() async -> Data? { data }
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lmma-test-\(UUID().uuidString)", isDirectory: true)
    }

    func testGraceThenCaptureWritesFile() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cap = IntruderCapture(photographer: FakePhotographer(data: Data([0xFF, 0xD8, 0xFF])),
                                  directory: dir)
        cap.beginSession(enabled: true)

        XCTAssertFalse(cap.registerInteraction())   // 1st
        XCTAssertFalse(cap.registerInteraction())   // 2nd
        XCTAssertTrue(cap.registerInteraction())    // 3rd → capture

        await cap.performCapture()

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(cap.capturedThisSession, 1)
        XCTAssertTrue(files[0].hasPrefix("intruder-"))
        XCTAssertTrue(files[0].hasSuffix(".jpg"))
    }

    func testDisabledDoesNotCapture() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cap = IntruderCapture(photographer: FakePhotographer(data: Data([0xFF])),
                                  directory: dir)
        cap.beginSession(enabled: false)
        for _ in 0..<5 { XCTAssertFalse(cap.registerInteraction()) }
        XCTAssertEqual(cap.capturedThisSession, 0)
    }

    func testNilPhotoDoesNotIncrementCount() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cap = IntruderCapture(photographer: FakePhotographer(data: nil),
                                  directory: dir)
        cap.beginSession(enabled: true)
        _ = cap.registerInteraction()
        _ = cap.registerInteraction()
        _ = cap.registerInteraction()
        await cap.performCapture()
        XCTAssertEqual(cap.capturedThisSession, 0)
    }

    func testEndSessionResetsCounter() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cap = IntruderCapture(photographer: FakePhotographer(data: Data([0xFF])),
                                  directory: dir)
        cap.beginSession(enabled: true)
        _ = cap.registerInteraction()
        _ = cap.registerInteraction()
        cap.endSession()
        XCTAssertFalse(cap.registerInteraction())   // 1st again after reset
    }
}
