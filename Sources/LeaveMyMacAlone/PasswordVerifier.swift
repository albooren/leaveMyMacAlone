import Foundation
import OpenDirectory

enum PasswordCheck: Equatable, Sendable {
    case accepted
    /// The password is wrong.
    case rejected
    /// It couldn't be checked (locked or expired account, directory unavailable), which
    /// says nothing about whether it was right.
    case unavailable
}

protocol PasswordVerifying: Sendable {
    func verify(_ password: String) async -> PasswordCheck
}

/// Checks the password of the logged-in account through OpenDirectory, with no UI.
/// The password is only passed to the check: never stored, logged or sent anywhere.
struct OpenDirectoryPasswordVerifier: PasswordVerifying {
    private static let credentialsInvalidCode = 5000 // kODErrorCredentialsInvalid

    func verify(_ password: String) async -> PasswordCheck {
        guard !password.isEmpty else { return .rejected }
        // A plain dispatch queue: the call blocks, sometimes for a while, and must stay
        // off both the main thread (the keyboard tap runs there, and the system disables
        // a tap that is too slow) and the Swift concurrency pool.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.check(password))
            }
        }
    }

    static func classify(errorCode: Int) -> PasswordCheck {
        errorCode == credentialsInvalidCode ? .rejected : .unavailable
    }

    private static func check(_ password: String) -> PasswordCheck {
        do {
            let node = try ODNode(session: ODSession.default(),
                                  type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers,
                                         name: NSUserName(),
                                         attributes: nil)
            try record.verifyPassword(password)
            return .accepted
        } catch {
            let code = (error as NSError).code
            NSLog("PasswordVerifier: not accepted (OpenDirectory code \(code))")
            return classify(errorCode: code)
        }
    }
}

#if DEBUG
/// Lets the end-to-end test drive a real unlock without the account password.
/// Compiled out of release builds, so a shipped app can never honour it.
private struct FixedPasswordVerifier: PasswordVerifying {
    let expected: String

    func verify(_ password: String) async -> PasswordCheck {
        password == expected ? .accepted : .rejected
    }
}
#endif

func makePasswordVerifier() -> any PasswordVerifying {
    #if DEBUG
    if let expected = ProcessInfo.processInfo.environment["LMMA_TEST_PASSWORD"], !expected.isEmpty {
        return FixedPasswordVerifier(expected: expected)
    }
    #endif
    return OpenDirectoryPasswordVerifier()
}
