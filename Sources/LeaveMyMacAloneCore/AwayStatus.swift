import Foundation

/// The "where am I" choice shown on the lock screen. Raw values are persisted.
public enum AwayPreset: String, CaseIterable, Sendable {
    case none
    case meeting
    case lunch
    case backSoon
    case custom
}

/// What the lock screen tells a passer-by: a short headline and, optionally,
/// when the owner expects to be back. Resolved once, at lock time, from the
/// user's settings.
public struct AwayStatus: Equatable, Sendable {
    public enum Headline: Equatable, Sendable {
        case preset(AwayPreset)   // localized by the app
        case custom(String)
    }

    public static let maxCustomLength = 80

    public let headline: Headline?
    public let returnTime: Date?

    public init(headline: Headline?, returnTime: Date?) {
        self.headline = headline
        self.returnTime = returnTime
    }

    /// Returns nil when there is nothing to show. `returnInMinutes` <= 0 means
    /// "don't say". The return time is rounded up to the next 5 minutes so it
    /// reads like something a person would write ("12:40", not "12:37").
    public static func resolve(preset: AwayPreset,
                               customText: String,
                               returnInMinutes: Int,
                               lockedAt: Date,
                               calendar: Calendar = .current) -> AwayStatus? {
        let headline: Headline?
        switch preset {
        case .none:
            headline = nil   // no message, but a return time can still be shown
        case .custom:
            let text = String(customText.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maxCustomLength))
            headline = text.isEmpty ? nil : .custom(text)
        case .meeting, .lunch, .backSoon:
            headline = .preset(preset)
        }

        let returnTime = returnInMinutes > 0
            ? roundedUpToFiveMinutes(lockedAt.addingTimeInterval(TimeInterval(returnInMinutes * 60)),
                                     calendar: calendar)
            : nil

        guard headline != nil || returnTime != nil else { return nil }
        return AwayStatus(headline: headline, returnTime: returnTime)
    }

    private static func roundedUpToFiveMinutes(_ date: Date, calendar: Calendar) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = parts.minute ?? 0
        let hasSeconds = calendar.component(.second, from: date) > 0
        let needsBump = minute % 5 != 0 || hasSeconds
        parts.minute = needsBump ? (minute / 5 + 1) * 5 : minute
        return calendar.date(from: parts) ?? date
    }
}
