import AppKit
import SwiftUI

// Borderless windows return false from canBecomeKey by default, which drops
// keyboard input. Override so the shield can become key.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // A click on the shield is a tap-independent unlock affordance. The event
    // tap normally drives unlocking, but while it is paused (during auth) or
    // dead, the covering window would otherwise be inert dead weight and could
    // strand the user (e.g. after a Cmd+Tab escape leaves the auth sheet
    // unreachable). In the .locked state the consuming tap swallows clicks
    // before they reach here, so this fires only when the tap is NOT consuming
    // — exactly when a recovery path is needed.
    var onInteract: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onInteract?() }
    override func rightMouseDown(with event: NSEvent) { onInteract?() }
    override func otherMouseDown(with event: NSEvent) { onInteract?() }
}

// SwiftUI overlay: an adjustable dark tint plus an always-visible lock badge
// and live clock, so even at low opacity the "locked" state is unmistakable.
struct OverlayView: View {
    let opacity: Double

    var body: some View {
        ZStack {
            Color.black.opacity(opacity).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 48, weight: .semibold))
                Text("Kilitli — açmak için dokun")
                    .font(.title3.weight(.medium))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date, style: .time)
                        .font(.system(size: 30, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 6)
        }
        // Non-zero hit area so the window registers clicks at any opacity.
        .contentShape(Rectangle())
    }
}

@MainActor
final class ShieldController {
    private var windows: [KeyableWindow] = []
    private var screenObserver: NSObjectProtocol?
    // Overwritten by show(opacity:) before any window is built; the literal is
    // only a placeholder so the property is initialised.
    private var currentOpacity: Double = 0.5
    // Tap-independent recovery hook invoked when the user clicks any shield
    // window. Wired by AppController to the unlock/re-present flow.
    private var onInteract: (() -> Void)?

    isolated deinit {
        if let token = screenObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func show(opacity: Double, onInteract: @escaping () -> Void) {
        currentOpacity = opacity
        self.onInteract = onInteract
        rebuildWindows()
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuildWindows() }
            }
        }
        // Allow the borderless app to become active so the window can be key.
        NSApp.activate()
        windows.first?.makeKeyAndOrderFront(nil)
    }

    func setOpacity(_ opacity: Double) {
        currentOpacity = opacity
        for window in windows {
            (window.contentView as? NSHostingView<OverlayView>)?
                .rootView = OverlayView(opacity: opacity)
        }
    }

    func hide() {
        if let token = screenObserver {
            NotificationCenter.default.removeObserver(token)
            screenObserver = nil
        }
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        onInteract = nil
    }

    private func rebuildWindows() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()

        // CGShieldingWindowLevel(): above normal apps, the Dock, and the menu
        // bar, but below the system auth sheet (the intended unlock path).
        let shieldLevel = Int(CGShieldingWindowLevel())

        for screen in NSScreen.screens {
            let window = KeyableWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = NSWindow.Level(rawValue: shieldLevel)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.setFrame(screen.frame, display: true)

            window.onInteract = onInteract

            let host = NSHostingView(rootView: OverlayView(opacity: currentOpacity))
            host.frame = window.contentLayoutRect
            host.autoresizingMask = [.width, .height]
            window.contentView = host

            window.orderFrontRegardless()
            windows.append(window)
        }
        windows.first?.makeKeyAndOrderFront(nil)
    }
}
