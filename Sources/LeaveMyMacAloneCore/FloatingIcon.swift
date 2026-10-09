import Foundation

/// What drifts around the lock screen, DVD-screensaver style. Raw values are persisted.
public enum FloatingIconKind: String, CaseIterable, Sendable {
    case none
    case emoji
    case image
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

    public static func next(after value: Int) -> Int {
        minutes.first { $0 > value } ?? minutes[minutes.count - 1]
    }

    public static func previous(before value: Int) -> Int {
        minutes.last { $0 < value } ?? minutes[0]
    }

    /// 90 → (1, 30), for "1 sa 30 dk sonra".
    public static func split(_ value: Int) -> (hours: Int, minutes: Int) {
        (value / 60, value % 60)
    }
}

/// Picks an emoji out of whatever the system character palette typed into a field.
public enum EmojiInput {
    public static func firstEmoji(in text: String) -> String? {
        text.first(where: isEmoji).map(String.init)
    }

    private static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return false }
        // Digits, '#' and '*' have the Emoji property but are plain text unless
        // followed by the emoji variation selector / keycap.
        if first.properties.isEmojiPresentation { return true }
        return first.properties.isEmoji && scalars.count > 1
    }
}
