import LocalAuthentication

/// Touch ID with automatic password fallback. `.deviceOwnerAuthentication`
/// presents Touch ID first and falls back to the device password (and goes
/// straight to password on Macs with no Touch ID sensor).
final class Authenticator {

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

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            context.evaluatePolicy(.deviceOwnerAuthentication,
                                   localizedReason: reason) { success, _ in
                // Any non-success (cancel, failure, lockout) → false → re-lock.
                continuation.resume(returning: success)
            }
        }
    }
}
