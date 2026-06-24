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
    // Keyed by CGDirectDisplayID so a screen-parameter change can be applied as
    // a diff (add new displays, drop departed ones) instead of tearing every
    // window down and rebuilding — which left a coverage gap, dropped the live
    // clock, and thrashed the key window on each event.
    private var windowsByDisplay: [CGDirectDisplayID: KeyableWindow] = [:]
    private var screenObserver: NSObjectProtocol?
    // Overwritten by show(opacity:) before any window is built; the literal is
    // only a placeholder so the property is initialised.
    private var currentOpacity: Double = 0.5
    // Tap-independent recovery hook invoked when the user clicks any shield
    // window. Wired by AppController to the unlock/re-present flow.
    private var onInteract: (() -> Void)?
    // Guards rebuilds so a queued screen-parameter notification that lands after
    // hide() cannot resurrect a ghost shield over the unlocked desktop.
    private var isShown = false

    isolated deinit {
        if let token = screenObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func show(opacity: Double, onInteract: @escaping () -> Void) {
        currentOpacity = opacity
        self.onInteract = onInteract
        isShown = true
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
        windowsByDisplay.first?.value.makeKeyAndOrderFront(nil)
    }

    func setOpacity(_ opacity: Double) {
        currentOpacity = opacity
        for window in windowsByDisplay.values {
            (window.contentView as? NSHostingView<OverlayView>)?
                .rootView = OverlayView(opacity: opacity)
        }
    }

    /// Re-raise existing shields and re-take activation without rebuilding.
    /// Used after sleep/wake or a session switch, where a session-level overlay
    /// can be displaced behind other windows.
    func reassert() {
        guard isShown else { return }
        rebuildWindows()
        NSApp.activate()
    }

    func hide() {
        isShown = false
        if let token = screenObserver {
            NotificationCenter.default.removeObserver(token)
            screenObserver = nil
        }
        for window in windowsByDisplay.values { window.orderOut(nil) }
        windowsByDisplay.removeAll()
        onInteract = nil
    }

    private func rebuildWindows() {
        // A notification can be delivered after hide(); never cover an unlocked
        // desktop.
        guard isShown else { return }

        // CGShieldingWindowLevel(): above normal apps, the Dock, and the menu
        // bar, but below the system auth sheet (the intended unlock path).
        let shieldLevel = Int(CGShieldingWindowLevel())

        var live: [CGDirectDisplayID: KeyableWindow] = [:]
        for screen in NSScreen.screens {
            let id = Self.displayID(of: screen)
            let window = windowsByDisplay[id] ?? makeWindow(level: shieldLevel, screen: screen)
            // Reused windows: keep their content view (and live clock); just
            // re-apply geometry, level and the recovery hook.
            window.level = NSWindow.Level(rawValue: shieldLevel)
            window.setFrame(screen.frame, display: true)
            window.onInteract = onInteract
            window.orderFrontRegardless()
            live[id] = window
        }

        // Drop shields for displays that went away.
        for (id, window) in windowsByDisplay where live[id] == nil {
            window.orderOut(nil)
        }
        windowsByDisplay = live
    }

    private func makeWindow(level: Int, screen: NSScreen) -> KeyableWindow {
        let window = KeyableWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let host = NSHostingView(rootView: OverlayView(opacity: currentOpacity))
        host.frame = window.contentLayoutRect
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        return window
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }
}
