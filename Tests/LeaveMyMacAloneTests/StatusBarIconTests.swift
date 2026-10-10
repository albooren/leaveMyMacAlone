import XCTest
import AppKit
@testable import LeaveMyMacAlone

final class StatusBarIconTests: XCTestCase {
    func testIconIsTemplateSoTheMenuBarTintsIt() {
        XCTAssertTrue(StatusBarIcon.make().isTemplate)
    }

    func testIconIsMenuBarSized() {
        XCTAssertEqual(StatusBarIcon.make().size, NSSize(width: 18, height: 18))
    }

    func testIconHasAnAccessibilityDescription() {
        XCTAssertEqual(StatusBarIcon.make().accessibilityDescription, "Leave My Mac Alone")
    }

    /// The shield body is solid, the keyhole is cut out, and the shackle's
    /// unfinished part is faded — sampled at 2x so each point is unambiguous.
    func testShieldKeyholeAndFadedShackle() throws {
        let rep = try XCTUnwrap(render(StatusBarIcon.make(), scale: 2))
        func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            // Glyph coordinates are a 20-unit, top-left-origin grid drawn into 18 pt.
            let px = Int(x * 0.9 * 2), py = Int(y * 0.9 * 2)
            return rep.colorAt(x: px, y: py)?.alphaComponent ?? 0
        }
        XCTAssertGreaterThan(alpha(7, 15), 0.9, "shield body is solid")
        XCTAssertLessThan(alpha(10, 12), 0.1, "keyhole is cut out")
        XCTAssertGreaterThan(alpha(7, 7.5), 0.9, "finished shackle part is solid")
        let faded = alpha(13, 7.5)
        XCTAssertGreaterThan(faded, 0.2, "unfinished shackle part is still visible")
        XCTAssertLessThan(faded, 0.5, "unfinished shackle part is faded")
    }

    private func render(_ image: NSImage, scale: CGFloat) -> NSBitmapImageRep? {
        let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
