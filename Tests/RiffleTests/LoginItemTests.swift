import ServiceManagement
import XCTest
@testable import Riffle

/// "Launch at login" as chosen in Riffle: kept, and made again when macOS loses it. Never touches the real login item.
final class LoginItemTests: XCTestCase {
    /// Copies of the app as `LoginItem.thisCopy` names them: a place, and its folder's number on disk.
    private let installed = "/Applications/Riffle.app#4100"
    private let reinstalled = "/Applications/Riffle.app#5200"
    private let downloaded = "/Users/someone/Downloads/Riffle.app#4100"

    private func check(_ status: SMAppService.Status, wanted: Bool, for wantedCopy: String?) -> LoginItem.LaunchCheck {
        LoginItem.launchCheck(status: status, wanted: wanted, wantedFor: wantedCopy, thisCopy: installed)
    }

    func testOneThatsOnIsRememberedForThisCopy() {
        XCTAssertEqual(check(.enabled, wanted: true, for: installed), .remember)
        XCTAssertEqual(check(.enabled, wanted: true, for: downloaded), .remember)
        // Turned on before Riffle remembered the choice, or in System Settings.
        XCTAssertEqual(check(.enabled, wanted: false, for: nil), .remember)
    }

    func testOneMacOSLostWhenTheAppMovedOrWasReinstalledIsMadeAgain() {
        XCTAssertEqual(check(.notRegistered, wanted: true, for: downloaded), .restore)
        XCTAssertEqual(check(.notFound, wanted: true, for: downloaded), .restore)
        XCTAssertEqual(check(.notRegistered, wanted: true, for: reinstalled), .restore)
        // Wanted, without knowing for which copy: made again too.
        XCTAssertEqual(check(.notRegistered, wanted: true, for: nil), .restore)
    }

    func testOneTakenOffFromTheSameCopyStaysOff() {
        // Removed in System Settings: that's a choice as well, and it's remembered as one.
        XCTAssertEqual(check(.notRegistered, wanted: true, for: installed), .forget)
    }

    func testNothingHappensUnlessItWasWanted() {
        XCTAssertEqual(check(.notRegistered, wanted: false, for: downloaded), .nothing)
        XCTAssertEqual(check(.notFound, wanted: false, for: nil), .nothing)
    }

    func testOneWaitingForApprovalIsLeftAlone() {
        // System Settings was opened when it was chosen; it isn't opened again at every launch.
        XCTAssertEqual(check(.requiresApproval, wanted: true, for: downloaded), .nothing)
        XCTAssertEqual(check(.requiresApproval, wanted: true, for: installed), .nothing)
    }

    func testThisCopyIsItsPlaceAndItsFolder() {
        let copy = LoginItem.thisCopy
        XCTAssertTrue(copy.hasPrefix(Bundle.main.bundlePath + "#"), copy)
        XCTAssertFalse(copy.hasSuffix("#?"), "the folder's number couldn't be read")
        XCTAssertEqual(LoginItem.thisCopy, copy)
    }

    func testTheChoiceIsKeptForTheNextLaunch() throws {
        let suite = "riffle-tests-login-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        XCTAssertFalse(LoginItem.wish(in: store).wanted)
        XCTAssertNil(LoginItem.wish(in: store).copy)
        LoginItem.remember(true, for: downloaded, in: store)
        var wish = LoginItem.wish(in: store)
        XCTAssertTrue(wish.wanted)
        XCTAssertEqual(wish.copy, downloaded)
        // Then the app moves to Applications, and macOS forgets the login item.
        XCTAssertEqual(LoginItem.launchCheck(status: .notRegistered, wanted: wish.wanted, wantedFor: wish.copy, thisCopy: installed), .restore)
        LoginItem.remember(false, for: installed, in: store)
        wish = LoginItem.wish(in: store)
        XCTAssertFalse(wish.wanted)
        XCTAssertEqual(LoginItem.launchCheck(status: .notRegistered, wanted: wish.wanted, wantedFor: wish.copy, thisCopy: installed), .nothing)
    }
}
