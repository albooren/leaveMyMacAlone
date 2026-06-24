import AppKit
import SwiftUI

/// Live, non-locking preview of the lock-screen dim. Purely visual: it never
/// engages the event tap, kiosk, sleep guard, or lock state machine. Shown while
/// the menu bar panel is open so the user can judge the opacity against their
/// real screen.
@MainActor
final class PreviewOverlayController {
    private let store: AppSettingsStore
    private var windows: [NSWindow] = []

    init(store: AppSettingsStore) {
        self.store = store
    }

    /// Number of live preview windows (0 when not previewing). Test hook.
    var windowCountForTesting: Int { windows.count }

    func start() {
        guard windows.isEmpty else { return }   // already previewing
        // Just below the menu bar panel (.popUpMenu) so the panel and its slider
        // stay on top and interactive, while the dim covers everything else.
        let level = NSWindow.Level(rawValue: Int(NSWindow.Level.popUpMenu.rawValue) - 1)
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = level
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = true        // never blocks input
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

            let host = NSHostingView(rootView: PreviewDimView(store: store))
            host.frame = window.contentLayoutRect
            host.autoresizingMask = [.width, .height]
            window.contentView = host

            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func stop() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }
}

/// Full-screen dim bound to the live opacity, with a small "Önizleme" badge so
/// the dimmed screen is clearly a preview and not an actual lock.
struct PreviewDimView: View {
    @ObservedObject var store: AppSettingsStore

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
                .opacity(store.overlayOpacity)
                .ignoresSafeArea()

            Label("Önizleme", systemImage: "lock.shield")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 6)
                .padding(.top, 64)
        }
    }
}
