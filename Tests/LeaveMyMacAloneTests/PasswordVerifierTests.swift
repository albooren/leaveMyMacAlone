import XCTest
@testable import LeaveMyMacAlone

/// Only the path that never reaches OpenDirectory is tested here. A unit test must
/// not send wrong passwords for the real account: each one counts as a failed login.
final class PasswordVerifierTests: XCTestCase {

    func testEmptyPasswordIsRejectedWithoutAskingTheDirectory() async {
        let result = await OpenDirectoryPasswordVerifier().verify("")
        XCTAssertEqual(result, .rejected)
    }

    // Only invalid credentials mean "wrong password". Any other directory error (a
    // locked or expired account, the directory being unavailable) must not tell the
    // owner their correct password is wrong, or count towards the attempt limit.
    func testInvalidCredentialsAreAWrongPassword() {
        XCTAssertEqual(OpenDirectoryPasswordVerifier.classify(errorCode: 5000), .rejected)
    }

    func testOtherDirectoryErrorsAreNotAWrongPassword() {
        XCTAssertEqual(OpenDirectoryPasswordVerifier.classify(errorCode: 5304), .unavailable)
        XCTAssertEqual(OpenDirectoryPasswordVerifier.classify(errorCode: 2100), .unavailable)
    }
}
