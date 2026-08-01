import SwiftUI
import XCTest
@testable import Buddy

final class GitHubIntegrationTests: XCTestCase {
    func testSuccessfulAuthorizationValidatesBeforePersistingAndReportsConnected() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: "The Octocat", avatarURL: nil)
        let api = StubGitHubAPI(
            deviceResults: [.success(testAuthorization)],
            pollResults: [.success(.authorized(token: "access-token"))],
            userResults: [.success(account)]
        )
        let credentials = MockCredentialStore()
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            sleep: { _ in }
        )
        let authorization = try await integration.beginAuthorization()

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
            deviceResults: [.success(testAuthorization)],
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
        let authorization = try await integration.beginAuthorization()

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

    func testCancellationDuringCredentialPersistenceRemovesNewToken() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let api = StubGitHubAPI(
            deviceResults: [.success(testAuthorization)],
            pollResults: [.success(.authorized(token: "new-token"))],
            userResults: [.success(account)]
        )
        let credentials = SuspendedCredentialStore()
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            sleep: { _ in }
        )
        let authorization = try await integration.beginAuthorization()
        let completion = Task {
            try await integration.completeAuthorization(authorization)
        }

        await credentials.waitUntilSetBegins()
        completion.cancel()
        await credentials.finishSet()

        do {
            _ = try await completion.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let credentialValue = await credentials.stringValue()
        XCTAssertNil(credentialValue)
        XCTAssertEqual(integration.summary.connectionState, .disconnected)
    }

    func testCancellationCleanupFailureReportsNeedsAttention() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let api = StubGitHubAPI(
            deviceResults: [.success(testAuthorization)],
            pollResults: [.success(.authorized(token: "new-token"))],
            userResults: [.success(account)]
        )
        let credentials = SuspendedCredentialStore(failRemoval: true)
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            sleep: { _ in }
        )
        let authorization = try await integration.beginAuthorization()
        let completion = Task {
            try await integration.completeAuthorization(authorization)
        }

        await credentials.waitUntilSetBegins()
        completion.cancel()
        await credentials.finishSet()

        do {
            _ = try await completion.value
            XCTFail("Expected credential cleanup failure")
        } catch let error as GitHubConnectionError {
            XCTAssertEqual(error, .credentialStorage)
        }

        XCTAssertEqual(integration.summary.connectionState, .needsAttention)
    }

    func testDisconnectPreventsStaleValidationFromRestoringConnectedState() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let api = SuspendedUserGitHubAPI(account: account)
        let credentials = MockCredentialStore(initialValue: "stored-token")
        let integration = GitHubIntegration(clientID: "client-id", api: api, credentials: credentials)
        let restoration = Task {
            try await integration.restoreAccount()
        }

        await api.waitUntilUserRequestBegins()
        try await integration.disconnect()
        await api.finishUserRequest()

        let restoredAccount = try await restoration.value
        let credentialValue = await credentials.stringValue()
        XCTAssertNil(restoredAccount)
        XCTAssertNil(credentialValue)
        XCTAssertEqual(integration.summary.connectionState, .disconnected)
    }

    func testDisconnectDuringRevokedTokenCleanupDoesNotPublishStaleFailure() async throws {
        let api = StubGitHubAPI(userResults: [.failure(.unauthorized)])
        let credentials = SuspendedRemovalCredentialStore(initialValue: "revoked-token")
        let integration = GitHubIntegration(clientID: "client-id", api: api, credentials: credentials)
        let restoration = Task {
            try await integration.restoreAccount()
        }

        await credentials.waitUntilRemovalBegins()
        let disconnection = Task {
            try await integration.disconnect()
        }
        await credentials.finishFirstRemoval()

        let restoredAccount = try await restoration.value
        try await disconnection.value
        XCTAssertNil(restoredAccount)
        XCTAssertEqual(integration.summary.connectionState, .disconnected)
    }

    func testSupersededConnectionTaskCannotOverwriteNewerConnectedState() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let api = SupersededConnectionAPI(account: account)
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: MockCredentialStore(),
            sleep: { _ in }
        )
        let (viewModel, openURL) = await MainActor.run {
            (
                GitHubViewModel(integration: integration),
                OpenURLAction { _ in .handled }
            )
        }

        await MainActor.run { viewModel.connect(openURL: openURL) }
        await api.waitUntilFirstAuthorizationBegins()
        await MainActor.run { viewModel.connect(openURL: openURL) }
        await api.waitUntilUserValidationCompletes()

        await api.finishFirstAuthorization()
        for _ in 0..<20 {
            await Task.yield()
        }

        let state = await MainActor.run { viewModel.state }
        XCTAssertEqual(state, .connected(account))
    }

    func testReconnectWaitsForCancellationCleanup() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let api = StubGitHubAPI(
            deviceResults: [.success(testAuthorization)],
            pollResults: [.success(.authorized(token: "new-token"))],
            userResults: [.success(account)]
        )
        let credentials = SuspendedRemovalCredentialStore(initialValue: "old-token")
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            sleep: { _ in }
        )
        let (viewModel, openURL) = await MainActor.run {
            (
                GitHubViewModel(integration: integration),
                OpenURLAction { _ in .handled }
            )
        }

        await MainActor.run { viewModel.cancel() }
        await credentials.waitUntilRemovalBegins()
        let cancelingState = await MainActor.run { viewModel.state }
        XCTAssertEqual(cancelingState, .loading)

        await MainActor.run { viewModel.connect(openURL: openURL) }
        for _ in 0..<20 {
            await Task.yield()
        }
        let requestsBeforeCleanup = await api.deviceRequestCount()
        XCTAssertEqual(requestsBeforeCleanup, 0)

        await credentials.finishFirstRemoval()
        for _ in 0..<100 {
            let isConnected = await MainActor.run { viewModel.state == .connected(account) }
            if isConnected {
                break
            }
            await Task.yield()
        }

        let finalState = await MainActor.run { viewModel.state }
        let finalRequestCount = await api.deviceRequestCount()
        XCTAssertEqual(finalState, .connected(account))
        XCTAssertEqual(finalRequestCount, 1)
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

private let testAuthorization = GitHubDeviceAuthorization(
    deviceCode: "device-code",
    userCode: "ABCD-EFGH",
    verificationURI: URL(string: "https://github.com/login/device")!,
    expiresIn: 900,
    interval: 5
)

private actor StubGitHubAPI: GitHubAPIProviding {
    private var deviceResults: [Result<GitHubDeviceAuthorization, GitHubAPIError>]
    private var pollResults: [Result<GitHubTokenPollResult, GitHubAPIError>]
    private var userResults: [Result<GitHubAccount, GitHubAPIError>]
    private var capturedUserTokens: [String] = []
    private var capturedDeviceRequestCount = 0

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
        capturedDeviceRequestCount += 1
        return try deviceResults.removeFirst().get()
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

    func deviceRequestCount() -> Int {
        capturedDeviceRequestCount
    }
}

private actor SuspendedCredentialStore: CredentialStoring {
    enum StoreError: Error {
        case removalFailed
    }

    private var value: Data?
    private let failRemoval: Bool
    private var setStartedWaiter: CheckedContinuation<Void, Never>?
    private var setCompletion: CheckedContinuation<Void, Never>?

    init(failRemoval: Bool = false) {
        self.failRemoval = failRemoval
    }

    func set(_ data: Data, for account: String) async {
        value = data
        setStartedWaiter?.resume()
        setStartedWaiter = nil

        await withCheckedContinuation { continuation in
            setCompletion = continuation
        }
    }

    func data(for account: String) -> Data? {
        value
    }

    func removeData(for account: String) throws {
        if failRemoval {
            throw StoreError.removalFailed
        }
        value = nil
    }

    func waitUntilSetBegins() async {
        guard setCompletion == nil else { return }

        await withCheckedContinuation { continuation in
            setStartedWaiter = continuation
        }
    }

    func finishSet() {
        setCompletion?.resume()
        setCompletion = nil
    }

    func stringValue() -> String? {
        value.flatMap { String(data: $0, encoding: .utf8) }
    }
}

private actor SuspendedUserGitHubAPI: GitHubAPIProviding {
    private let account: GitHubAccount
    private var userRequestWaiter: CheckedContinuation<Void, Never>?
    private var userRequestCompletion: CheckedContinuation<Void, Never>?

    init(account: GitHubAccount) {
        self.account = account
    }

    func requestDeviceAuthorization(clientID: String) throws -> GitHubDeviceAuthorization {
        throw GitHubAPIError.malformedResponse
    }

    func pollForAccessToken(clientID: String, deviceCode: String) throws -> GitHubTokenPollResult {
        throw GitHubAPIError.malformedResponse
    }

    func authenticatedUser(token: String) async -> GitHubAccount {
        userRequestWaiter?.resume()
        userRequestWaiter = nil

        await withCheckedContinuation { continuation in
            userRequestCompletion = continuation
        }
        return account
    }

    func waitUntilUserRequestBegins() async {
        guard userRequestCompletion == nil else { return }

        await withCheckedContinuation { continuation in
            userRequestWaiter = continuation
        }
    }

    func finishUserRequest() {
        userRequestCompletion?.resume()
        userRequestCompletion = nil
    }
}

private actor SuspendedRemovalCredentialStore: CredentialStoring {
    private var value: Data?
    private var didSuspendRemoval = false
    private var removalWaiter: CheckedContinuation<Void, Never>?
    private var removalCompletion: CheckedContinuation<Void, Never>?

    init(initialValue: String) {
        value = Data(initialValue.utf8)
    }

    func set(_ data: Data, for account: String) {
        value = data
    }

    func data(for account: String) -> Data? {
        value
    }

    func removeData(for account: String) async {
        if !didSuspendRemoval {
            didSuspendRemoval = true
            removalWaiter?.resume()
            removalWaiter = nil
            await withCheckedContinuation { continuation in
                removalCompletion = continuation
            }
        }
        value = nil
    }

    func waitUntilRemovalBegins() async {
        guard removalCompletion == nil else { return }
        await withCheckedContinuation { continuation in
            removalWaiter = continuation
        }
    }

    func finishFirstRemoval() {
        removalCompletion?.resume()
        removalCompletion = nil
    }
}

private actor SupersededConnectionAPI: GitHubAPIProviding {
    private let account: GitHubAccount
    private var authorizationRequestCount = 0
    private var firstAuthorizationWaiter: CheckedContinuation<Void, Never>?
    private var firstAuthorizationCompletion: CheckedContinuation<Void, Never>?
    private var userValidationWaiter: CheckedContinuation<Void, Never>?
    private var didValidateUser = false

    init(account: GitHubAccount) {
        self.account = account
    }

    func requestDeviceAuthorization(clientID: String) async -> GitHubDeviceAuthorization {
        authorizationRequestCount += 1
        if authorizationRequestCount == 1 {
            firstAuthorizationWaiter?.resume()
            firstAuthorizationWaiter = nil
            await withCheckedContinuation { continuation in
                firstAuthorizationCompletion = continuation
            }
            return GitHubDeviceAuthorization(
                deviceCode: "old-device-code",
                userCode: "OLD-CODE",
                verificationURI: testAuthorization.verificationURI,
                expiresIn: 900,
                interval: 5
            )
        }
        return testAuthorization
    }

    func pollForAccessToken(clientID: String, deviceCode: String) -> GitHubTokenPollResult {
        .authorized(token: "new-token")
    }

    func authenticatedUser(token: String) -> GitHubAccount {
        didValidateUser = true
        userValidationWaiter?.resume()
        userValidationWaiter = nil
        return account
    }

    func waitUntilFirstAuthorizationBegins() async {
        guard firstAuthorizationCompletion == nil else { return }
        await withCheckedContinuation { continuation in
            firstAuthorizationWaiter = continuation
        }
    }

    func finishFirstAuthorization() {
        firstAuthorizationCompletion?.resume()
        firstAuthorizationCompletion = nil
    }

    func waitUntilUserValidationCompletes() async {
        guard !didValidateUser else { return }
        await withCheckedContinuation { continuation in
            userValidationWaiter = continuation
        }
    }
}
