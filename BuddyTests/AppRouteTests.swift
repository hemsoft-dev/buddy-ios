import XCTest
@testable import Buddy

@MainActor
final class AppRouteTests: XCTestCase {
    func testParsesOAuthCallback() throws {
        let url = try XCTUnwrap(URL(string: "buddy://oauth/github?code=redacted"))

        XCTAssertEqual(AppRoute(url: url), .oauthCallback(provider: "github"))
    }

    func testRejectsUnknownScheme() throws {
        let url = try XCTUnwrap(URL(string: "https://oauth/github"))

        XCTAssertNil(AppRoute(url: url))
    }

    func testAccountSetupActionSelectsSettingsAndOpensAccounts() {
        let navigation = AppNavigation()

        navigation.openAccounts()

        XCTAssertEqual(navigation.selectedTab, .settings)
        XCTAssertEqual(navigation.settingsPath, [.accounts])
    }
}
