import LocalAuthentication

/// Touch ID with automatic password fallback. `.deviceOwnerAuthentication`
/// presents Touch ID first and falls back to the device password (and goes
/// straight to password on Macs with no Touch ID sensor).
///
/// `@MainActor`: the in-flight `LAContext` is retained so `cancel()` can
/// `invalidate()` it (panic re-lock, re-present, watchdog timeout). All access
/// to `activeContext` therefore happens on the main actor; the `evaluatePolicy`
/// completion runs on an arbitrary thread but only resumes the continuation,
/// which hops back to the awaiting main-actor caller.
@MainActor
final class Authenticator {

    private var activeContext: LAContext?

    func authenticate(reason: String) async -> Bool {
        // Fresh context per attempt: an LAContext caches its result and reuse
        // can silently skip the prompt.
        let context = LAContext()
        context.localizedFallbackTitle = "Parolayı Gir"

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication,
                                        error: &policyError) else {
            // No password/biometry configured.
            return false
        }

        activeContext = context
        // Clear only if still ours: an overlapping re-present may have already
        // installed a newer context that must not be wiped by this call's exit.
        defer { if activeContext === context { activeContext = nil } }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            context.evaluatePolicy(.deviceOwnerAuthentication,
                                   localizedReason: reason) { success, _ in
                // Any non-success (cancel, failure, lockout, invalidate) → false.
                continuation.resume(returning: success)
            }
        }
    }

    /// Abort any in-flight evaluation. `invalidate()` fires the `evaluatePolicy`
    /// completion with `success == false`, which resumes the awaiting
    /// continuation — so the caller MUST guard against acting on a superseded
    /// result (see AppController's auth epoch). Safe to call when idle.
    func cancel() {
        activeContext?.invalidate()
        activeContext = nil
    }
}
