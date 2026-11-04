import AppKit
import LocalAuthentication
import SwiftUI
import LeaveMyMacAloneCore

// Borderless windows return false from canBecomeKey by default, which drops
// keyboard input. Override so the shield can become key.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // A click on the shield OUTSIDE the controls. The mouse is not tapped, so clicks
    // always reach here: while locked it flashes the "still locked" feedback, and
    // while authenticating it returns focus to the password field. Clicks on SwiftUI
    // controls are consumed by them and never reach this handler.
    var onInteract: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onInteract?() }
    override func rightMouseDown(with event: NSEvent) { onInteract?() }
    override func otherMouseDown(with event: NSEvent) { onInteract?() }
}

// With several displays only one shield window is key, so a click on another
// display's unlock button would otherwise be spent merely activating that window
// and the user would need a second click. Accepting first mouse delivers that first
// click straight to the SwiftUI button. Clicks landing outside any control still
// fall through to KeyableWindow.mouseDown.
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
    // Owner-set status for passers-by ("Toplantıdayım · Dönüş: 14:30"); nil = none.
    @Published var away: AwayStatus?
    // Icon drifting DVD-style across the shield; nil = none.
    @Published var floating: FloatingIcon?
    @Published var floatingSize: FloatingIconSize = .medium
    // The Touch ID / password panel; nil = the plain unlock button.
    @Published var auth: AuthPanelState?

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
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .glassSurface(Capsule(), interactive: true)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// The owner's status line(s) under "Kilitli": a headline and/or a return time.
private struct AwayStatusView: View {
    let status: AwayStatus

    var body: some View {
        VStack(spacing: 4) {
            if let headline = status.headline {
                headlineText(headline)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            if let returnTime = status.returnTime {
                Text("Dönüş: \(Text(returnTime, style: .time))")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.vertical, 4)
    }

    private func headlineText(_ headline: AwayStatus.Headline) -> Text {
        switch headline {
        case .custom(let text): return Text(verbatim: text)
        case .preset(let preset): return Text(preset.lockScreenTitle)
        }
    }
}

extension AwayPreset {
    /// Full sentence shown on the lock screen.
    var lockScreenTitle: LocalizedStringKey {
        switch self {
        case .none: return "Mesaj yok"
        case .meeting: return "Toplantıdayım"
        case .lunch: return "Öğle arasındayım"
        case .backSoon: return "Hemen dönerim"
        case .custom: return "Özel mesaj"
        }
    }

    /// Short label for the menu's chips.
    var chipTitle: LocalizedStringKey {
        switch self {
        case .none: return "Yok"
        case .meeting: return "Toplantıdayım"
        case .lunch: return "Öğle arası"
        case .backSoon: return "Hemen dönerim"
        case .custom: return "Özel mesaj"
        }
    }
}

// SwiftUI overlay: an adjustable dark tint plus a lock badge, live clock and an
// unlock button. Animates in on lock and out on unlock, driven by OverlayModel.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    let displayID: CGDirectDisplayID
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            Color.black
                .opacity(model.revealed ? model.opacity : 0)
                .ignoresSafeArea()

            if let icon = model.floating, model.revealed, !model.unlocking {
                BouncingIconView(icon: icon, size: model.floatingSize.lockScreenPoints, speed: 130)
                    .transition(.opacity)
            }

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

                if let away = model.away, !model.unlocking {
                    AwayStatusView(status: away)
                }

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date, style: .time)
                        .font(.system(size: 30, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }

                // Explicit unlock affordance under the clock. It opens the Touch ID /
                // password panel right here in the shield; with several displays the
                // panel appears on one and the others just stay covered.
                if let auth = model.auth {
                    if auth.displayID == displayID {
                        AuthPanelView(state: auth)
                            .padding(.top, 10)
                    }
                } else {
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
    // Invoked when the user clicks any shield window outside its controls. Wired by
    // AppController to the flash / refocus flow.
    private var onInteract: (() -> Void)?
    // Invoked by the overlay's "Kilidi Aç" button; wired to the begin-auth flow.
    private var onUnlock: (() -> Void)?
    // Window level of every shield: above everything, the whole time. Authentication
    // happens inside the shield, so nothing ever needs to show on top of it.
    private let shieldLevel = Int(CGShieldingWindowLevel())
    // The display whose unlock button was pressed; the auth panel opens there.
    private var pressedUnlockDisplay: CGDirectDisplayID?
    // Guards rebuilds so a queued screen-parameter notification that lands after
    // hide() cannot resurrect a ghost shield over the unlocked desktop.
    private var isShown = false
    // Pending exit fade and teardown; cancelled if a new lock arrives mid-animation.
    private var fadeWork: DispatchWorkItem?
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
              away: AwayStatus?,
              floating: FloatingIcon?,
              floatingSize: FloatingIconSize,
              onInteract: @escaping () -> Void,
              onUnlock: @escaping () -> Void) {
        // Abort any in-flight exit animation from a previous cycle.
        fadeWork?.cancel()
        fadeWork = nil
        dismissWork?.cancel()
        dismissWork = nil
        self.onInteract = onInteract
        self.onUnlock = onUnlock
        // Reset to the pre-entrance state; the entrance is sprung in below.
        model.auth = nil
        pressedUnlockDisplay = nil
        model.opacity = opacity
        model.away = away
        model.floating = floating
        model.floatingSize = floatingSize
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
        Foreground.take()
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
    /// Used after sleep/wake, a Space change, or another app taking the foreground.
    func reassert() {
        guard isShown else { return }
        rebuildWindows()
        if model.auth != nil {
            focusAuth()
        } else {
            Foreground.take()
        }
    }

    // MARK: - Auth panel

    /// Open the Touch ID / password panel inside the shield, on the display whose
    /// button was pressed (or the one under the cursor for the keyboard route).
    func presentAuth(biometricContext: LAContext?, actions: AuthPanelActions) {
        let mouse = NSEvent.mouseLocation
        let underCursor = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            .map(Self.displayID(of:))
        guard let display = [pressedUnlockDisplay, underCursor].compactMap({ $0 })
                .first(where: { windowsByDisplay[$0] != nil })
                ?? windowsByDisplay.keys.first else { return }
        model.auth = AuthPanelState(displayID: display,
                                    biometricContext: biometricContext,
                                    actions: actions)
        focusAuth()
    }

    /// Back to the plain unlock button.
    func dismissAuth() {
        model.auth = nil
        pressedUnlockDisplay = nil
    }

    /// Make the panel's window key so typing lands in the password field.
    func focusAuth() {
        guard let display = model.auth?.displayID, let window = windowsByDisplay[display] else { return }
        Foreground.take()
        window.makeKeyAndOrderFront(nil)
    }

    /// Take the keyboard back from another process's non-activating panel with a click
    /// at the cursor. Measured on macOS 27: making our window key again, re-activating
    /// and re-ordering it all leave the keyboard with the panel; only a click moves it.
    /// A shield covers every display at the top level, so the click can only land on us.
    func reclaimKeyboard() {
        guard isShown, model.auth != nil, let cursor = CGEvent(source: nil)?.location else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type,
                    mouseCursorPosition: cursor, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    /// Touch ID / Watch gave up (too many tries, lockout): only the password is left.
    func biometricsEnded() {
        model.auth?.biometricContext = nil
    }

    func setAuthVerifying(_ verifying: Bool) {
        model.auth?.isVerifying = verifying
    }

    /// Show why the password was not accepted: clear the field and shake the lock.
    func rejectPassword(_ message: AuthPanelMessage) {
        model.auth?.message = message
        model.auth?.clearToken &+= 1
        flashLocked()
    }

    /// Animate the overlay out, then tear the windows down. `success` plays the
    /// extra "lock opens then lifts away" flourish; otherwise it just fades.
    func hide(success: Bool = false) {
        guard isShown else { return }
        isShown = false
        dismissAuth()
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

        let fade = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                withAnimation(.easeIn(duration: self.exitDuration)) {
                    self.model.revealed = false
                }
            }
        }
        fadeWork = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDelay, execute: fade)

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
        fadeWork = nil
        dismissWork = nil
        model.unlocking = false
        model.revealed = false
    }

    private func rebuildWindows() {
        // A notification can be delivered after hide(); never cover an unlocked
        // desktop.
        guard isShown else { return }

        var live: [CGDirectDisplayID: KeyableWindow] = [:]
        for screen in NSScreen.screens {
            let id = Self.displayID(of: screen)
            let window = windowsByDisplay[id] ?? makeWindow(displayID: id, screen: screen)
            // Reused windows: keep their content view (and live clock); just
            // re-apply geometry, level and the recovery hook.
            window.level = NSWindow.Level(rawValue: shieldLevel)
            window.setFrame(screen.frame, display: true)
            window.onInteract = onInteract
            // hide() makes windows click-through for its fade; a re-lock may reuse them.
            window.ignoresMouseEvents = false
            window.orderFrontRegardless()
            live[id] = window
        }

        // Drop shields for displays that went away.
        for (id, window) in windowsByDisplay where live[id] == nil {
            window.orderOut(nil)
        }
        windowsByDisplay = live

        // The display showing the auth panel went away: move the panel.
        if let display = model.auth?.displayID, live[display] == nil, let other = live.keys.first {
            model.auth?.displayID = other
            focusAuth()
        }
    }

    private func makeWindow(displayID: CGDirectDisplayID, screen: NSScreen) -> KeyableWindow {
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
                                  displayID: displayID,
                                  onUnlock: { [weak self] in
                                      self?.pressedUnlockDisplay = displayID
                                      self?.onUnlock?()
                                  })
        )
        host.frame = window.contentLayoutRect
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        return window
    }

    /// Test hook: visible and taking clicks on every display.
    var isSolidForTesting: Bool {
        isShown && model.revealed && !windowsByDisplay.isEmpty
            && windowsByDisplay.values.allSatisfy { !$0.ignoresMouseEvents && $0.isVisible }
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }
}
