import AppKit
import SwiftUI

// Borderless windows return false from canBecomeKey by default, which drops
// keyboard input. Override so the shield can become key.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // A click on the shield OUTSIDE the unlock button. The mouse is not tapped,
    // so clicks always reach here: while locked it flashes the "still locked"
    // feedback, and while authenticating it re-presents a buried auth sheet
    // (tap-independent recovery, so a covering window can never strand the user).
    // Clicks on the SwiftUI button are consumed by the button and never reach
    // this handler.
    var onInteract: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onInteract?() }
    override func rightMouseDown(with event: NSEvent) { onInteract?() }
    override func otherMouseDown(with event: NSEvent) { onInteract?() }
}

// The shield is rarely the key window while the auth sheet is up, so a click on
// the unlock button would otherwise be spent merely activating the window and
// the user would need a second click. Accepting first mouse delivers that first
// click straight to the SwiftUI button. Clicks landing outside any control still
// fall through to KeyableWindow.mouseDown (the recovery affordance).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// Drives the overlay's appearance and its entrance/exit animation. A single
// instance is shared by every per-display OverlayView so they animate in
// lock-step. Mutated only on the main actor (by ShieldController).
final class OverlayModel: ObservableObject {
    @Published var opacity: Double   // dim strength when fully revealed
    @Published var revealed: Bool    // false → pre-entrance (transparent, scaled-down, blurred)
    @Published var unlocking: Bool   // true → "lock opens and lifts away" flourish
    // Incremented to make the lock badge shake + grow ("still locked" feedback)
    // when the user clicks anywhere other than the unlock button.
    @Published var shakeToken: Int

    init(opacity: Double) {
        self.opacity = opacity
        self.revealed = false
        self.unlocking = false
        self.shakeToken = 0
    }
}

// Animatable pair for the lock-badge shake: horizontal wobble + a brief grow.
private struct LockShake {
    var x: CGFloat = 0
    var scale: CGFloat = 1
}

// Theme-matching unlock button: a frosted-glass capsule with a white label,
// instead of the system accent (blue) prominent style which clashes with the
// dark, dimmed lock overlay.
private struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.30), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// SwiftUI overlay: an adjustable dark tint plus a lock badge, live clock and an
// unlock button. Animates in on lock and out on unlock, driven by OverlayModel.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            Color.black
                .opacity(model.revealed ? model.opacity : 0)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: model.unlocking ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 48, weight: .semibold))
                    // Morphs the closed lock into an open one on a successful unlock.
                    .contentTransition(.symbolEffect(.replace))
                    // Shake + grow whenever shakeToken changes, to underline that
                    // it is still locked and the button is the way out.
                    .keyframeAnimator(initialValue: LockShake(), trigger: model.shakeToken) { view, value in
                        view.scaleEffect(value.scale).offset(x: value.x)
                    } keyframes: { _ in
                        KeyframeTrack(\.x) {
                            SpringKeyframe(-14, duration: 0.07)
                            SpringKeyframe(12, duration: 0.07)
                            SpringKeyframe(-9, duration: 0.07)
                            SpringKeyframe(7, duration: 0.07)
                            SpringKeyframe(0, duration: 0.08)
                        }
                        KeyframeTrack(\.scale) {
                            CubicKeyframe(1.3, duration: 0.16)
                            CubicKeyframe(1.0, duration: 0.20)
                        }
                    }

                Text(statusText)
                    .font(.title3.weight(.medium))

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date, style: .time)
                        .font(.system(size: 30, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }

                // Explicit unlock affordance under the clock. Brings up the
                // password / Touch ID screen on top of the dimmed overlay.
                Button(action: onUnlock) {
                    Label("Kilidi Aç", systemImage: "lock.open.fill")
                }
                .buttonStyle(GlassButtonStyle())
                .padding(.top, 10)
                // Recede the button as the lock opens; it has no role during the
                // exit flourish.
                .opacity(model.unlocking ? 0 : 1)
                .disabled(model.unlocking)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 6)
            .scaleEffect(contentScale)
            .blur(radius: model.revealed ? 0 : 12)
            .opacity(model.revealed ? 1 : 0)
        }
        // Non-zero hit area so the window registers clicks at any opacity.
        .contentShape(Rectangle())
    }

    // Ternary of two string literals would be inferred as a (verbatim, non-
    // localized) String; typing it as LocalizedStringKey keeps it localizable.
    private var statusText: LocalizedStringKey {
        model.unlocking ? "Açılıyor…" : "Kilitli"
    }

    // 0.85 settling in on lock · 1.0 at rest · 1.12 lifting away on unlock.
    private var contentScale: CGFloat {
        if model.unlocking { return 1.12 }
        return model.revealed ? 1.0 : 0.85
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
    // Shared animation/appearance state for every shield's OverlayView.
    private let model = OverlayModel(opacity: 0.5)
    // Tap-independent recovery hook invoked when the user clicks any shield
    // window. Wired by AppController to the unlock/re-present flow.
    private var onInteract: (() -> Void)?
    // Invoked by the overlay's "Kilidi Aç" button; wired to the same
    // begin-auth / re-present flow as a shield click.
    private var onUnlock: (() -> Void)?
    // Window level applied to every shield. Defaults to the full shielding level
    // (covers everything). While authenticating it drops just below the system
    // auth dialog (see lowerBelowAuthDialog) so the password screen is usable on
    // top. Persisted here so reassert()/rebuild keep the right level.
    private var currentLevel = Int(CGShieldingWindowLevel())
    // Guards rebuilds so a queued screen-parameter notification that lands after
    // hide() cannot resurrect a ghost shield over the unlocked desktop.
    private var isShown = false
    // Pending exit teardown; cancelled if a new lock arrives mid-animation.
    private var dismissWork: DispatchWorkItem?

    // Animation timings (seconds).
    private let unlockHoldDuration = 0.32   // lock-opens beat before the fade-out
    private let exitDuration = 0.45

    isolated deinit {
        if let token = screenObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func show(opacity: Double,
              onInteract: @escaping () -> Void,
              onUnlock: @escaping () -> Void) {
        // Abort any in-flight exit animation from a previous cycle.
        dismissWork?.cancel()
        dismissWork = nil
        self.onInteract = onInteract
        self.onUnlock = onUnlock
        // A fresh lock starts in the locked state → full shielding level.
        currentLevel = Int(CGShieldingWindowLevel())
        // Reset to the pre-entrance state; the entrance is sprung in below.
        model.opacity = opacity
        model.unlocking = false
        model.revealed = false
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
        // Let the transparent first frame render, then spring the overlay in.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isShown else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                    self.model.revealed = true
                }
            }
        }
    }

    func setOpacity(_ opacity: Double) {
        model.opacity = opacity
    }

    /// Shake + grow the lock badge to reinforce that the Mac is still locked
    /// (the user clicked somewhere other than the unlock button).
    func flashLocked() {
        model.shakeToken &+= 1
    }

    /// Re-raise existing shields and re-take activation without rebuilding.
    /// Used after sleep/wake or a session switch, where a session-level overlay
    /// can be displaced behind other windows.
    func reassert() {
        guard isShown else { return }
        rebuildWindows()
        NSApp.activate()
    }

    /// Drop the shield to just below the system authentication dialog. macOS
    /// presents the `.deviceOwnerAuthentication` UI at the screen-saver level
    /// (1000); the full shielding level (~2.1e9) sits far above it, which is why
    /// the password screen was being buried behind the dimmed overlay. One below
    /// screen-saver keeps the shield above the menu bar, Dock and every app
    /// window while letting the auth dialog show on top.
    func lowerBelowAuthDialog() {
        applyLevel(Int(NSWindow.Level.screenSaver.rawValue) - 1)
    }

    /// Restore the full shielding level (covers everything). Used when returning
    /// to the plain locked state, where no auth dialog should show through.
    func raiseToFullShield() {
        applyLevel(Int(CGShieldingWindowLevel()))
    }

    private func applyLevel(_ level: Int) {
        currentLevel = level
        for window in windowsByDisplay.values {
            window.level = NSWindow.Level(rawValue: level)
            window.orderFrontRegardless()
        }
    }

    /// Animate the overlay out, then tear the windows down. `success` plays the
    /// extra "lock opens then lifts away" flourish; a plain (e.g. fail-safe)
    /// dismissal just fades.
    func hide(success: Bool = false) {
        guard isShown else { return }
        isShown = false
        if let token = screenObserver {
            NotificationCenter.default.removeObserver(token)
            screenObserver = nil
        }
        // Let clicks fall through to the desktop while the shield fades away.
        for window in windowsByDisplay.values { window.ignoresMouseEvents = true }

        var fadeDelay = 0.0
        if success {
            withAnimation(.snappy(duration: unlockHoldDuration)) {
                model.unlocking = true
            }
            fadeDelay = unlockHoldDuration
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                withAnimation(.easeIn(duration: self.exitDuration)) {
                    self.model.revealed = false
                }
            }
        }

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finishHide() }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDelay + exitDuration + 0.02,
                                      execute: work)
    }

    private func finishHide() {
        for window in windowsByDisplay.values { window.orderOut(nil) }
        windowsByDisplay.removeAll()
        onInteract = nil
        onUnlock = nil
        dismissWork = nil
        model.unlocking = false
        model.revealed = false
    }

    private func rebuildWindows() {
        // A notification can be delivered after hide(); never cover an unlocked
        // desktop.
        guard isShown else { return }

        // Use the currently-selected level: the full shielding level when
        // locked, or just-below-the-auth-dialog while authenticating (the auth
        // dialog actually sits at the screen-saver level, well below the full
        // shielding level — see lowerBelowAuthDialog).
        let shieldLevel = currentLevel

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

        let host = FirstMouseHostingView(
            rootView: OverlayView(model: model,
                                  onUnlock: { [weak self] in self?.onUnlock?() })
        )
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
