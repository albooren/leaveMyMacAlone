import LocalAuthentication

/// Touch ID shown inside the shield. The system's own auth prompt is deliberately not
/// used: it runs in another process, which takes the foreground from us and with it
/// every kiosk protection, and its password field blinds the event tap. A context
/// attached to an `LAAuthenticationView` evaluates without any system window, so we
/// stay frontmost throughout. Passwords are handled by `PasswordVerifying`.
///
/// `@MainActor`: the in-flight `LAContext` is retained so `cancel()` can invalidate
/// it. The `evaluatePolicy` reply runs on an arbitrary thread but only resumes the
/// continuation, which hops back to the awaiting main-actor caller.
@MainActor
final class Authenticator {

    // Touch ID, or a paired Apple Watch. Both show in the embedded view.
    private static let policy = LAPolicy.deviceOwnerAuthenticationWithBiometricsOrWatch

    private var activeContext: LAContext?

    /// A fresh context if Touch ID or a Watch can be used right now; nil otherwise (no
    /// sensor, no enrolled finger, biometry locked out). The password still works then.
    func makeBiometricContext() -> LAContext? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(Self.policy, error: &error) else {
            return nil
        }
        activeContext = context
        return context
    }

    /// Start waiting for a finger. Call only once the context's
    /// `LAAuthenticationView` is in a window: without one, the system falls back to
    /// its standard alert.
    func evaluate(_ context: LAContext, reason: String) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            context.evaluatePolicy(Self.policy, localizedReason: reason) { success, _ in
                // Any non-success (cancel, failure, lockout, invalidate) → false.
                continuation.resume(returning: success)
            }
        }
    }

    /// Abort any in-flight evaluation. `invalidate()` fires the reply with `false`,
    /// so the caller must guard against acting on a superseded result (see
    /// AppController's auth epoch). Safe to call when idle.
    func cancel() {
        activeContext?.invalidate()
        activeContext = nil
    }
}
