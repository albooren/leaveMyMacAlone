import AppKit

/// The menu bar glyph: the app icon's shield-as-lock-body with its progress
/// shackle, in one color. It's a template image, so macOS tints it white or
/// black to match the menu bar; only the shape and alpha survive, which is why
/// the shackle's unfinished part is drawn faded instead of green.
enum StatusBarIcon {
    private static let side: CGFloat = 18
    /// Paths are authored on a 20-unit grid (origin top-left).
    private static let grid: CGFloat = 20
    /// Share of the shackle drawn solid; the rest is faded.
    private static let progressLength: CGFloat = 8
    private static let fadedAlpha: CGFloat = 0.35

    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "LeaveMyMacAlone"
        return image
    }

    private static func draw() {
        let transform = NSAffineTransform()
        transform.scale(by: side / grid)
        transform.concat()

        let shackle = shacklePath()
        NSColor.black.withAlphaComponent(fadedAlpha).setStroke()
        shackle.stroke()
        shackle.setLineDash([progressLength, grid * 2], count: 2, phase: 0)
        NSColor.black.setStroke()
        shackle.stroke()

        NSColor.black.set()
        let shield = shieldPath()
        shield.fill()
        shield.stroke()

        // Punch the keyhole out of the shield.
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: 8.7, y: 10.7, width: 2.6, height: 2.6)).fill()
        NSBezierPath(roundedRect: NSRect(x: 9.35, y: 12.3, width: 1.3, height: 2.7),
                     xRadius: 0.65, yRadius: 0.65).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    /// Starts at the bottom of the left leg so the solid part grows clockwise.
    private static func shacklePath() -> NSBezierPath {
        let path = NSBezierPath()
        let k: CGFloat = 1.657 // 3 × the cubic circle constant 0.5523
        path.move(to: NSPoint(x: 7, y: 9.5))
        path.line(to: NSPoint(x: 7, y: 6.6))
        path.curve(to: NSPoint(x: 10, y: 3.6),
                   controlPoint1: NSPoint(x: 7, y: 6.6 - k), controlPoint2: NSPoint(x: 10 - k, y: 3.6))
        path.curve(to: NSPoint(x: 13, y: 6.6),
                   controlPoint1: NSPoint(x: 10 + k, y: 3.6), controlPoint2: NSPoint(x: 13, y: 6.6 - k))
        path.line(to: NSPoint(x: 13, y: 9.5))
        path.lineWidth = 2
        path.lineCapStyle = .round
        return path
    }

    private static func shieldPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 10, y: 8.2))
        path.line(to: NSPoint(x: 15, y: 9.8))
        path.line(to: NSPoint(x: 15, y: 12.2))
        path.curve(to: NSPoint(x: 10, y: 18.1),
                   controlPoint1: NSPoint(x: 15, y: 15.2), controlPoint2: NSPoint(x: 12.9, y: 17.1))
        path.curve(to: NSPoint(x: 5, y: 12.2),
                   controlPoint1: NSPoint(x: 7.1, y: 17.1), controlPoint2: NSPoint(x: 5, y: 15.2))
        path.line(to: NSPoint(x: 5, y: 9.8))
        path.close()
        path.lineWidth = 1
        path.lineJoinStyle = .round
        return path
    }
}
