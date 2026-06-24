/// Overlay opacity model. Clamped to a range that always lets the user see
/// through enough to watch the background task, while signalling "locked".
public enum Transparency {
    public static let range: ClosedRange<Double> = 0.0...0.85
    public static let defaultOpacity: Double = 0.5

    public static func clamp(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
