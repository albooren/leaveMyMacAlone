import SwiftUI

// Liquid Glass with a fallback. The app still supports macOS 14–15, where the
// Liquid Glass APIs don't exist: there the same surfaces use a material plus an
// optional tint, which is how the app looked before.

extension View {
    /// A glass surface in `shape`. `tint` colors it (e.g. a selected chip);
    /// `interactive` makes it react to the pointer — only for controls.
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S,
                                tint: Color? = nil,
                                interactive: Bool = false,
                                fallback: Material = .ultraThinMaterial) -> some View {
        if #available(macOS 26, *) {
            // The tint is also laid in as a fill: glass tints are desaturated in
            // windows that aren't active (this panel never activates the app),
            // and a selected/prominent control must stay clearly colored.
            self
                .background(tint ?? .clear, in: shape)
                .glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background(tint ?? .clear, in: shape)
                .background(fallback, in: shape)
        }
    }

    @available(macOS 26, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

/// Groups neighbouring glass elements so they render (and blend) together.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

extension View {
    /// Wraps this view in a `GlassGroup`.
    func glassGrouped(spacing: CGFloat = 8) -> some View {
        GlassGroup(spacing: spacing) { self }
    }
}
