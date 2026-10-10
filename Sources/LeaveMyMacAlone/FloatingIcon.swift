import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LeaveMyMacAloneCore

/// A resolved lock-screen icon, ready to draw.
enum FloatingIcon {
    case emoji(String)
    case image(NSImage)
}

/// The user's own floating image. Imported once into Application Support
/// (downscaled PNG), so the original can move or be deleted.
enum FloatingImageStore {
    /// Longest edge in pixels: 2× the largest size it is drawn at.
    private static let maxPixels = CGFloat(FloatingIconSize.large.lockScreenPoints * 2)

    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LeaveMyMacAlone", isDirectory: true)
            .appendingPathComponent("floating-image.png")
    }

    static func load() -> NSImage? {
        NSImage(contentsOf: url)
    }

    /// Asks for an image file and imports it. Returns the chosen file's name,
    /// or nil if the user cancelled or the file couldn't be read.
    @MainActor
    static func chooseAndImport() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = NSLocalizedString("Kilit ekranında hareket edecek görseli seç",
                                          comment: "Image picker message")
        NSApp.activate()
        guard panel.runModal() == .OK, let source = panel.url else { return nil }
        do {
            try importImage(from: source)
            return source.lastPathComponent
        } catch {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Görsel eklenemedi", comment: "Image import failed title")
            alert.informativeText = NSLocalizedString("Bu dosya okunamadı. PNG, JPEG veya HEIC bir görsel dene.",
                                                      comment: "Image import failed body")
            alert.runModal()
            return nil
        }
    }

    private static func importImage(from source: URL) throws {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// What the drifting icon draws, sized to its *visible* bounds so it bounces off
/// the screen edges instead of off an invisible square around it. An emoji is
/// rasterized and trimmed to its ink (a glyph's line height leaves empty space
/// above and below it); an image keeps its aspect ratio inside the box.
struct BouncingIconContent {
    let image: NSImage
    let size: CGSize

    @MainActor
    init?(icon: FloatingIcon, box: CGFloat) {
        switch icon {
        case .emoji(let emoji):
            // Same type size the lock screen has always used for emoji.
            guard let trimmed = Self.trimmedEmoji(emoji, pointSize: box * 0.82) else { return nil }
            image = trimmed
            size = trimmed.size
        case .image(let picture):
            let fit = IconFit.size(width: picture.size.width, height: picture.size.height, box: box)
            guard fit.width > 0, fit.height > 0 else { return nil }
            image = picture
            size = CGSize(width: fit.width, height: fit.height)
        }
    }

    @MainActor private static var emojiCache: [String: NSImage] = [:]

    /// The emoji drawn at 2× and cropped to its non-transparent pixels.
    @MainActor
    private static func trimmedEmoji(_ emoji: String, pointSize: CGFloat) -> NSImage? {
        let key = "\(emoji)|\(pointSize)"
        if let cached = emojiCache[key] { return cached }

        let scale: CGFloat = 2
        let side = Int((pointSize * 1.6 * scale).rounded(.up))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        let text = NSAttributedString(string: emoji,
                                      attributes: [.font: NSFont.systemFont(ofSize: pointSize * scale)])
        let textSize = text.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        text.draw(at: NSPoint(x: (CGFloat(side) - textSize.width) / 2,
                              y: (CGFloat(side) - textSize.height) / 2))
        NSGraphicsContext.restoreGraphicsState()

        guard let ink = inkBounds(of: rep),
              let cropped = rep.cgImage?.cropping(to: ink) else { return nil }
        let image = NSImage(cgImage: cropped,
                            size: NSSize(width: ink.width / scale, height: ink.height / scale))
        emojiCache[key] = image
        return image
    }

    /// Smallest pixel rect (top-left origin) holding every non-transparent pixel.
    private static func inkBounds(of rep: NSBitmapImageRep) -> CGRect? {
        guard let data = rep.bitmapData else { return nil }
        let width = rep.pixelsWide, height = rep.pixelsHigh, stride = rep.bytesPerRow
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where data[y * stride + x * 4 + 3] > 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

/// The icon drifting across its container like the old DVD screensaver:
/// straight lines at constant speed, bouncing off every edge. Each axis has its
/// own speed so the path doesn't repeat quickly; each appearance starts at a
/// random spot. Never intercepts clicks.
struct BouncingIconView: View {
    let icon: FloatingIcon
    /// The box the icon is fitted into; it bounces with its visible size.
    let size: CGFloat
    /// Points per second along x; y moves at ~0.73× so the path wanders.
    let speed: CGFloat

    @State private var start = Date()
    @State private var phase = (x: Double.random(in: 0...2000), y: Double.random(in: 0...2000))

    var body: some View {
        if let content = BouncingIconContent(icon: icon, box: size) {
            GeometryReader { proxy in
                // 30 fps is visually smooth for this and halves the cost of a lock
                // screen that may stay up for hours.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSince(start)
                    let x = BounceMath.position(elapsed: t, speed: speed,
                                                travel: proxy.size.width - content.size.width,
                                                phase: phase.x)
                    let y = BounceMath.position(elapsed: t, speed: speed * 0.73,
                                                travel: proxy.size.height - content.size.height,
                                                phase: phase.y)
                    Image(nsImage: content.image)
                        .resizable()
                        .frame(width: content.size.width, height: content.size.height)
                        .position(x: x + content.size.width / 2, y: y + content.size.height / 2)
                }
            }
            // Reach the very top on notched displays too: the shield covers the
            // whole screen, menu bar area included.
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
