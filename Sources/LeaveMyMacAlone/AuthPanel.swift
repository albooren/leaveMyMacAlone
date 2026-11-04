import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI

struct AuthPanelActions {
    /// The Touch ID view is in a window, so evaluating cannot raise a system alert.
    let biometricViewReady: () -> Void
    let submitPassword: (String) -> Void
    let cancel: () -> Void
}

enum AuthPanelMessage: Equatable {
    case wrongPassword
    case retryLater(seconds: Int)
    case cannotVerify
}

/// The unlock panel's content, shown inside the shield on one display.
struct AuthPanelState {
    var displayID: CGDirectDisplayID
    var biometricContext: LAContext?
    let actions: AuthPanelActions
    var isVerifying = false
    var message: AuthPanelMessage?
    /// Bumped to clear the password field.
    var clearToken = 0
}

/// Touch ID and password inside our own window. Staying in-process is the point: we
/// remain the active app while the password is typed, so the kiosk keeps Cmd+Tab and
/// Force Quit off even though the secure field blinds the event tap.
struct AuthPanelView: View {
    let state: AuthPanelState

    var body: some View {
        VStack(spacing: 12) {
            if let context = state.biometricContext {
                BiometricIconView(laContext: context, onReady: state.actions.biometricViewReady)
                    .frame(width: 44, height: 44)
            }
            Text(prompt)
                .font(.headline)
            PasswordField(isEnabled: !state.isVerifying,
                          clearToken: state.clearToken,
                          onSubmit: state.actions.submitPassword,
                          onCancel: state.actions.cancel)
                .frame(width: 240, height: 24)
            if let message = state.message {
                Text(messageKey(message))
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
            Button(action: state.actions.cancel) {
                Text("Vazgeç")
            }
            .buttonStyle(GlassButtonStyle())
        }
        .padding(20)
        .glassSurface(RoundedRectangle(cornerRadius: 22))
    }

    private var prompt: LocalizedStringKey {
        guard let context = state.biometricContext else { return "Parolanı gir" }
        return context.biometryType == .touchID
            ? "Touch ID'ye dokun veya parolanı gir"
            : "Apple Watch'ı onayla veya parolanı gir"
    }

    private func messageKey(_ message: AuthPanelMessage) -> LocalizedStringKey {
        switch message {
        case .wrongPassword: return "Parola yanlış"
        case .retryLater(let seconds): return "Çok fazla deneme. \(seconds) sn sonra tekrar dene."
        case .cannotVerify:
            return "Parola şu an doğrulanamadı. Touch ID'yi dene; olmazsa güç düğmesini basılı tutup yeniden başlat."
        }
    }
}

/// Hosts the `LAAuthenticationView` and reports when it has reached a window.
private struct BiometricIconView: NSViewRepresentable {
    let laContext: LAContext
    let onReady: () -> Void

    func makeNSView(context: Context) -> BiometricHostView {
        BiometricHostView(laContext: laContext, onReady: onReady)
    }

    func updateNSView(_ view: BiometricHostView, context: Context) {}
}

private final class BiometricHostView: NSView {
    private var onReady: (() -> Void)?

    init(laContext: LAContext, onReady: @escaping () -> Void) {
        self.onReady = onReady
        super.init(frame: .zero)
        let icon = LAAuthenticationView(context: laContext, controlSize: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let ready = onReady else { return }
        onReady = nil
        DispatchQueue.main.async { ready() }
    }
}

/// A real `NSSecureTextField`: AppKit turns Secure Event Input on and off for it, and
/// the password stays out of SwiftUI state. Pasting doesn't work, on purpose: a passer-by
/// could otherwise submit whatever is on the clipboard, which might be the owner's
/// password. The app has no Edit menu to provide Cmd+V, and KeyableWindow drops the clicks
/// that would open the field's context menu.
private struct PasswordField: NSViewRepresentable {
    let isEnabled: Bool
    let clearToken: Int
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> FocusingSecureField {
        let field = FocusingSecureField()
        field.placeholderString = NSLocalizedString("Parola", comment: "Password field placeholder")
        field.setAccessibilityLabel(field.placeholderString)
        field.appearance = NSAppearance(named: .darkAqua)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: FocusingSecureField, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastClearToken != clearToken {
            context.coordinator.lastClearToken = clearToken
            field.stringValue = ""
        }
        field.isEnabled = isEnabled
        if isEnabled { field.takeFocus() }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PasswordField
        var lastClearToken = 0

        init(parent: PasswordField) {
            self.parent = parent
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let password = control.stringValue
                control.stringValue = ""
                parent.onSubmit(password)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                control.stringValue = ""
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

private final class FocusingSecureField: NSSecureTextField {
    // Going through a loss of the foreground, another display's shield can come back as
    // the key window instead of the panel's, and nothing announces that. Typing would be
    // lost and Secure Event Input stay off. This is the panel's only input, so it just
    // keeps checking while it is on screen.
    private static let focusCheckInterval: TimeInterval = 0.1
    private var focusTimer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTimer?.invalidate()
        focusTimer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: Self.focusCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.takeFocus() }
        }
        RunLoop.main.add(timer, forMode: .common)
        focusTimer = timer
        DispatchQueue.main.async { [weak self] in self?.takeFocus() }
    }

    func takeFocus() {
        guard let window, isEnabled, NSApp.isActive else { return }
        if !window.isKeyWindow { window.makeKey() }
        if let editor = currentEditor(), window.firstResponder === editor { return }
        window.makeFirstResponder(self)
        // Taking focus selects everything, so the next key would replace what is typed.
        currentEditor()?.selectedRange = NSRange(location: stringValue.utf16.count, length: 0)
    }
}
