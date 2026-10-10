import XCTest
import AppKit
@testable import LeaveMyMacAlone

/// The drifting icon must bounce off the screen edges with its *visible* bounds,
/// not a square box around it, or it turns back before touching the edge.
@MainActor
final class BouncingIconContentTests: XCTestCase {
    func testEmojiIsTrimmedToItsInk() throws {
        let content = try XCTUnwrap(BouncingIconContent(icon: .emoji("🐱"), box: 144))
        // Drawn at the same type size as before (0.82 × box), minus the empty
        // line-height margin, so it is smaller than the box on both axes.
        XCTAssertLessThan(content.size.width, 144)
        XCTAssertLessThan(content.size.height, 144)
        XCTAssertGreaterThan(content.size.height, 144 * 0.6)

        let rep = try XCTUnwrap(bitmap(of: content.image))
        XCTAssertTrue(hasInk(rep, row: 0), "no empty margin above the emoji")
        XCTAssertTrue(hasInk(rep, row: rep.pixelsHigh - 1), "no empty margin below the emoji")
        XCTAssertTrue(hasInk(rep, column: 0), "no empty margin left of the emoji")
        XCTAssertTrue(hasInk(rep, column: rep.pixelsWide - 1), "no empty margin right of the emoji")
    }

    func testWideImageKeepsItsAspectRatio() throws {
        let wide = NSImage(size: NSSize(width: 313, height: 138))
        let content = try XCTUnwrap(BouncingIconContent(icon: .image(wide), box: 144))
        XCTAssertEqual(content.size.width, 144, accuracy: 0.001)
        XCTAssertEqual(content.size.height, 144 * 138 / 313, accuracy: 0.001)
    }

    func testBlankEmojiHasNoContent() {
        XCTAssertNil(BouncingIconContent(icon: .emoji(" "), box: 144))
    }

    // MARK: - Helpers

    private func bitmap(of image: NSImage) -> NSBitmapImageRep? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg)
    }

    private func hasInk(_ rep: NSBitmapImageRep, row: Int) -> Bool {
        (0..<rep.pixelsWide).contains { (rep.colorAt(x: $0, y: row)?.alphaComponent ?? 0) > 0 }
    }

    private func hasInk(_ rep: NSBitmapImageRep, column: Int) -> Bool {
        (0..<rep.pixelsHigh).contains { (rep.colorAt(x: column, y: $0)?.alphaComponent ?? 0) > 0 }
    }
}
