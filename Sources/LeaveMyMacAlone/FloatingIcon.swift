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

/// Draws one icon.
struct FloatingIconGlyph: View {
    let icon: FloatingIcon
    let size: CGFloat

    var body: some View {
        switch icon {
        case .emoji(let emoji):
            Text(verbatim: emoji)
                .font(.system(size: size * 0.82))
                .frame(width: size, height: size)
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
    }
}

/// The icon drifting across its container like the old DVD screensaver:
/// straight lines at constant speed, bouncing off every edge. Each axis has its
/// own speed so the path doesn't repeat quickly; each appearance starts at a
/// random spot. Never intercepts clicks.
struct BouncingIconView: View {
    let icon: FloatingIcon
    let size: CGFloat
    /// Points per second along x; y moves at ~0.73× so the path wanders.
    let speed: CGFloat

    @State private var start = Date()
    @State private var phase = (x: Double.random(in: 0...2000), y: Double.random(in: 0...2000))

    var body: some View {
        GeometryReader { proxy in
            // 30 fps is visually smooth for this and halves the cost of a lock
            // screen that may stay up for hours.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSince(start)
                let x = BounceMath.position(elapsed: t, speed: speed,
                                            travel: proxy.size.width - size, phase: phase.x)
                let y = BounceMath.position(elapsed: t, speed: speed * 0.73,
                                            travel: proxy.size.height - size, phase: phase.y)
                FloatingIconGlyph(icon: icon, size: size)
                    .position(x: x + size / 2, y: y + size / 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
