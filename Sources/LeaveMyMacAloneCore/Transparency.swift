/// Overlay opacity model. Clamped from fully transparent (0.0) to fully opaque
/// (1.0); at 1.0 the dim completely hides the screen behind the lock UI.
public enum Transparency {
    public static let range: ClosedRange<Double> = 0.0...1.0
    public static let defaultOpacity: Double = 0.5

    public static func clamp(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
