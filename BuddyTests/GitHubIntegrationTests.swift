import XCTest
@testable import Buddy

final class GitHubIntegrationTests: XCTestCase {
    func testSuccessfulAuthorizationValidatesBeforePersistingAndReportsConnected() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: "The Octocat", avatarURL: nil)
        let api = StubGitHubAPI(pollResults: [.success(.authorized(token: "access-token"))], userResults: [.success(account)])
        let credentials = MockCredentialStore()
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            sleep: { _ in }
        )
        let authorization = GitHubDeviceAuthorization(
            deviceCode: "device-code",
            userCode: "ABCD-EFGH",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresIn: 900,
            interval: 5
        )

        let connectedAccount = try await integration.completeAuthorization(authorization)

        XCTAssertEqual(connectedAccount, account)
        let credentialValue = await credentials.stringValue()
        let capturedTokens = await api.userTokens()
        XCTAssertEqual(credentialValue, "access-token")
        XCTAssertEqual(integration.summary.connectionState, .connected)
        XCTAssertEqual(integration.summary.detail, "@octocat")
        XCTAssertEqual(capturedTokens, ["access-token"])
    }

    func testRelaunchRestoresAndValidatesStoredConnection() async throws {
        let account = GitHubAccount(id: 7, login: "franz", name: nil, avatarURL: nil)
        let api = StubGitHubAPI(userResults: [.success(account)])
        let credentials = MockCredentialStore(initialValue: "stored-token")
        let integration = GitHubIntegration(clientID: "client-id", api: api, credentials: credentials)

        let restoredAccount = try await integration.restoreAccount()
        let capturedTokens = await api.userTokens()
        XCTAssertEqual(restoredAccount, account)
        XCTAssertEqual(integration.summary.connectionState, .connected)
        XCTAssertEqual(capturedTokens, ["stored-token"])
    }

    func testRevokedTokenIsRemovedAndReportsNeedsAttention() async throws {
        let api = StubGitHubAPI(userResults: [.failure(.unauthorized)])
        let credentials = MockCredentialStore(initialValue: "revoked-token")
        let integration = GitHubIntegration(clientID: "client-id", api: api, credentials: credentials)

        do {
            _ = try await integration.restoreAccount()
            XCTFail("Expected invalid token")
        } catch let error as GitHubConnectionError {
            XCTAssertEqual(error, .invalidToken)
        }

        let credentialValue = await credentials.stringValue()
        XCTAssertNil(credentialValue)
        XCTAssertEqual(integration.summary.connectionState, .needsAttention)
    }

    func testFailedIdentityValidationDoesNotPersistToken() async throws {
        let api = StubGitHubAPI(
            pollResults: [.success(.authorized(token: "unvalidated-token"))],
            userResults: [.failure(.malformedResponse)]
        )
        let credentials = MockCredentialStore()
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            sleep: { _ in }
        )
        let authorization = GitHubDeviceAuthorization(
            deviceCode: "device-code",
            userCode: "ABCD-EFGH",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresIn: 900,
            interval: 5
        )

        do {
            _ = try await integration.completeAuthorization(authorization)
            XCTFail("Expected malformed response")
        } catch let error as GitHubConnectionError {
            XCTAssertEqual(error, .malformedResponse)
        }

        let credentialValue = await credentials.stringValue()
        XCTAssertNil(credentialValue)
        XCTAssertEqual(integration.summary.connectionState, .needsAttention)
    }

    func testDisconnectRemovesCredentialAndReportsDisconnected() async throws {
        let credentials = MockCredentialStore(initialValue: "stored-token")
        let integration = GitHubIntegration(clientID: "client-id", api: StubGitHubAPI(), credentials: credentials)

        try await integration.disconnect()

        let credentialValue = await credentials.stringValue()
        XCTAssertNil(credentialValue)
        XCTAssertEqual(integration.summary.connectionState, .disconnected)
    }

    func testMissingClientIDProducesClearNeedsAttentionState() async throws {
        let integration = GitHubIntegration(clientID: nil, api: StubGitHubAPI(), credentials: MockCredentialStore())

        do {
            _ = try await integration.beginAuthorization()
            XCTFail("Expected missing client ID")
        } catch let error as GitHubConnectionError {
            XCTAssertEqual(error, .missingClientID)
        }

        XCTAssertEqual(integration.summary.connectionState, .needsAttention)
    }
}

private actor MockCredentialStore: CredentialStoring {
    private var value: Data?

    init(initialValue: String? = nil) {
        value = initialValue.map { Data($0.utf8) }
    }

    func set(_ data: Data, for account: String) {
        value = data
    }

    func data(for account: String) -> Data? {
        value
    }

    func removeData(for account: String) {
        value = nil
    }

    func stringValue() -> String? {
        value.flatMap { String(data: $0, encoding: .utf8) }
    }
}

private actor StubGitHubAPI: GitHubAPIProviding {
    private var deviceResults: [Result<GitHubDeviceAuthorization, GitHubAPIError>]
    private var pollResults: [Result<GitHubTokenPollResult, GitHubAPIError>]
    private var userResults: [Result<GitHubAccount, GitHubAPIError>]
    private var capturedUserTokens: [String] = []

    init(
        deviceResults: [Result<GitHubDeviceAuthorization, GitHubAPIError>] = [],
        pollResults: [Result<GitHubTokenPollResult, GitHubAPIError>] = [],
        userResults: [Result<GitHubAccount, GitHubAPIError>] = []
    ) {
        self.deviceResults = deviceResults
        self.pollResults = pollResults
        self.userResults = userResults
    }

    func requestDeviceAuthorization(clientID: String) throws -> GitHubDeviceAuthorization {
        try deviceResults.removeFirst().get()
    }

    func pollForAccessToken(clientID: String, deviceCode: String) throws -> GitHubTokenPollResult {
        try pollResults.removeFirst().get()
    }

    func authenticatedUser(token: String) throws -> GitHubAccount {
        capturedUserTokens.append(token)
        return try userResults.removeFirst().get()
    }

    func userTokens() -> [String] {
        capturedUserTokens
    }
}
