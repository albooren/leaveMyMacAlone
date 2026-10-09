import CoreText
import Foundation

/// What drifts around the lock screen, DVD-screensaver style. Raw values are persisted.
public enum FloatingIconKind: String, CaseIterable, Sendable {
    case none
    case emoji
    case image
}

/// How big the drifting icon is. Raw values are persisted.
public enum FloatingIconSize: String, CaseIterable, Sendable {
    case small
    case medium
    case large

    /// Edge length on the real lock screen.
    public var lockScreenPoints: Double {
        switch self {
        case .small: return 104
        case .medium: return 144
        case .large: return 200
        }
    }

    /// Edge length in the menu's mini preview (the preview is roughly a
    /// quarter-scale lock screen; never so small the icon is unreadable).
    public var previewPoints: Double {
        max(12, (lockScreenPoints * 0.23).rounded())
    }
}

/// DVD-screensaver motion along one axis: constant speed, reflecting off both
/// edges. Stateless (a triangle wave of elapsed time) so a view can compute the
/// position for any frame without carrying velocity state between frames.
public enum BounceMath {
    /// - Parameters:
    ///   - elapsed: seconds since the motion started.
    ///   - speed: points per second.
    ///   - travel: room to move along the axis (container size minus icon size).
    ///   - phase: starting offset in points, so each lock starts somewhere new.
    /// - Returns: offset from the near edge, always within `0...travel`.
    public static func position(elapsed: Double, speed: Double, travel: Double, phase: Double) -> Double {
        guard travel > 0 else { return 0 }
        let period = 2 * travel
        let distance = (phase + speed * elapsed).truncatingRemainder(dividingBy: period)
        let d = distance < 0 ? distance + period : distance
        return d <= travel ? d : period - d
    }
}

/// The "back in…" choices stepped through with − / +.
public enum ReturnTimeSteps {
    public static let minutes = [15, 30, 45, 60, 90, 120, 180, 240]
    public static let defaultMinutes = 30

    /// Longest duration that can be typed in by hand.
    public static let maxMinutes = 12 * 60

    /// The next step up; a value already past the last step (typed by hand) stays.
    public static func next(after value: Int) -> Int {
        minutes.first { $0 > value } ?? value
    }

    /// The next step down; a value already below the first step stays.
    public static func previous(before value: Int) -> Int {
        minutes.last { $0 < value } ?? value
    }

    /// A duration typed by hand: "50" → 50 minutes, "1:30" or "1.30" → 90.
    /// Nil if unreadable, zero, or longer than `maxMinutes`.
    public static func parseDuration(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).count == 2
            ? trimmed.split(separator: ":", omittingEmptySubsequences: false)
            : trimmed.split(separator: ".", omittingEmptySubsequences: false)
        let total: Int
        switch parts.count {
        case 1:
            guard let m = Int(parts[0]) else { return nil }
            total = m
        case 2:
            guard let h = Int(parts[0]), let m = Int(parts[1]), h >= 0, (0..<60).contains(m) else { return nil }
            total = h * 60 + m
        default:
            return nil
        }
        return (1...maxMinutes).contains(total) ? total : nil
    }

    /// 90 → (1, 30), for "1 sa 30 dk sonra".
    public static func split(_ value: Int) -> (hours: Int, minutes: Int) {
        (value / 60, value % 60)
    }
}

/// Every single-character emoji the system knows, for the in-panel picker.
///
/// Built from Unicode properties rather than a bundled list, so it needs no
/// data file. Faces come first, then the pictograph blocks. Searching matches
/// the (English) Unicode name: "cat", "pizza", "heart".
public enum EmojiCatalog {
    private struct Entry {
        let emoji: String
        let name: String
    }

    // Order = display order: faces & people, then the other pictograph blocks.
    private static let blocks: [ClosedRange<UInt32>] = [
        0x1F600...0x1F64F,   // emoticons (faces)
        0x1F910...0x1F9FF,   // supplemental symbols & pictographs
        0x1F300...0x1F5FF,   // misc symbols & pictographs
        0x1F680...0x1F6FF,   // transport & map
        0x1FA70...0x1FAFF,   // symbols & pictographs extended-A
        0x2600...0x27BF,     // misc symbols, dingbats
        0x2300...0x23FF,     // misc technical (⌚ ⏰ …)
        0x2B00...0x2BFF      // arrows & stars (⭐ …)
    ]

    private static let entries: [Entry] = {
        // Newer emoji than this macOS knows would draw as empty boxes; skip them.
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)
        func canDraw(_ scalar: Unicode.Scalar) -> Bool {
            let utf16 = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
            return CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count)
        }
        var seen = Set<String>()
        var result: [Entry] = []
        for block in blocks {
            for value in block {
                guard let scalar = Unicode.Scalar(value) else { continue }
                let props = scalar.properties
                // Skin-tone modifiers only make sense attached to another emoji.
                guard props.isEmoji, !props.isEmojiModifier, canDraw(scalar) else { continue }
                // Text-default symbols (❤, ☀) need VS16 to draw as emoji.
                let emoji = props.isEmojiPresentation ? String(scalar) : String(scalar) + "\u{FE0F}"
                guard seen.insert(emoji).inserted else { continue }
                result.append(Entry(emoji: emoji, name: (props.name ?? "").lowercased()))
            }
        }
        return result
    }()

    public static let all: [String] = entries.map(\.emoji)

    public static func search(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return entries.filter { $0.name.contains(q) }.map(\.emoji)
    }
}
