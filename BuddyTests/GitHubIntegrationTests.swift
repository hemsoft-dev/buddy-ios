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

    func testAuthoredPullRequestsUsesStoredTokenWithoutExposingItToDashboardCode() async throws {
        let pullRequest = GitHubPullRequest(
            id: 9,
            repository: "HemSoft/Buddy",
            number: 9,
            title: "Dashboard pull requests",
            isDraft: false,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            url: URL(string: "https://github.com/HemSoft/Buddy/pull/9")!
        )
        let expectedCollection = GitHubPullRequestCollection(
            pullRequests: [pullRequest],
            totalCount: 1
        )
        let api = StubGitHubAPI(pullRequestResults: [.success(expectedCollection)])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: MockCredentialStore(initialValue: "stored-token")
        )
        let account = GitHubAccount(id: 7, login: "franz", name: nil, avatarURL: nil)

        let collection = try await integration.authoredPullRequests(for: account)

        XCTAssertEqual(collection, expectedCollection)
        let requests = await api.pullRequestRequests()
        XCTAssertEqual(requests, [PullRequestRequest(login: "franz", token: "stored-token")])
    }

    func testUnauthorizedPullRequestRefreshRemovesCredentialAndRequestsRecovery() async throws {
        let api = StubGitHubAPI(pullRequestResults: [.failure(.unauthorized)])
        let credentials = MockCredentialStore(initialValue: "revoked-token")
        let integration = GitHubIntegration(clientID: "client-id", api: api, credentials: credentials)
        let account = GitHubAccount(id: 7, login: "franz", name: nil, avatarURL: nil)

        do {
            _ = try await integration.authoredPullRequests(for: account)
            XCTFail("Expected invalid token")
        } catch let error as GitHubConnectionError {
            XCTAssertEqual(error, .invalidToken)
        }

        let credentialValue = await credentials.stringValue()
        XCTAssertNil(credentialValue)
        XCTAssertEqual(integration.summary.connectionState, .needsAttention)
        XCTAssertEqual(integration.summary.detail, "Authorization expired")
    }

    func testIncompletePullRequestSearchMapsToRetryableConnectionError() async throws {
        let api = StubGitHubAPI(pullRequestResults: [.failure(.incompleteResults)])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: MockCredentialStore(initialValue: "stored-token")
        )
        let account = GitHubAccount(id: 7, login: "franz", name: nil, avatarURL: nil)

        do {
            _ = try await integration.authoredPullRequests(for: account)
            XCTFail("Expected incomplete results error")
        } catch let error as GitHubConnectionError {
            XCTAssertEqual(error, .incompleteResults)
            XCTAssertEqual(error.localizedDescription, "GitHub returned partial search results. Refresh to try again.")
        }
    }

    func testConcurrentRestoresShareOneValidationResult() async throws {
        let account = GitHubAccount(id: 7, login: "franz", name: nil, avatarURL: nil)
        let api = SequencedSuspendedUserGitHubAPI()
        let credentials = MockCredentialStore(initialValue: "stored-token")
        let integration = GitHubIntegration(clientID: "client-id", api: api, credentials: credentials)
        let earlierRestore = Task {
            try await integration.restoreAccount()
        }

        await api.waitForRequest(count: 1)
        let newerRestore = Task {
            try await integration.restoreAccount()
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        let requestCount = await api.requestCount()
        XCTAssertEqual(requestCount, 1)

        await api.finishRequest(at: 0, with: .success(account))
        let earlierAccount = try await earlierRestore.value
        let newerAccount = try await newerRestore.value
        let credentialValue = await credentials.stringValue()
        XCTAssertEqual(earlierAccount, account)
        XCTAssertEqual(newerAccount, account)
        XCTAssertEqual(credentialValue, "stored-token")
        XCTAssertEqual(integration.summary.connectionState, .connected)
    }

    func testRestoreAfterReconnectDoesNotJoinOldValidation() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let api = ReconnectionGitHubAPI(account: account)
        let credentials = MockCredentialStore(initialValue: "old-token")
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            sleep: { _ in }
        )
        let oldRestoration = Task {
            try await integration.restoreAccount()
        }

        await api.waitUntilOldValidationBegins()
        try await integration.disconnect()
        let authorization = try await integration.beginAuthorization()
        let reconnectedAccount = try await integration.completeAuthorization(authorization)
        XCTAssertEqual(reconnectedAccount, account)

        let restoredAccount = try await integration.restoreAccount()
        XCTAssertEqual(restoredAccount, account)

        await api.finishOldValidation()
        let oldAccount = try await oldRestoration.value
        XCTAssertNil(oldAccount)

        let credentialValue = await credentials.stringValue()
        XCTAssertEqual(credentialValue, "new-token")
        XCTAssertEqual(integration.summary.connectionState, .connected)
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

    func testRevokedTokenRemovalFailureReportsCredentialStorageError() async throws {
        let api = StubGitHubAPI(userResults: [.failure(.unauthorized)])
        let credentials = FailingRemovalCredentialStore(initialValue: "revoked-token")
        let integration = GitHubIntegration(clientID: "client-id", api: api, credentials: credentials)

        do {
            _ = try await integration.restoreAccount()
            XCTFail("Expected credential storage error")
        } catch let error as GitHubConnectionError {
            XCTAssertEqual(error, .credentialStorage)
        }

        let credentialValue = await credentials.stringValue()
        XCTAssertEqual(credentialValue, "revoked-token")
        XCTAssertEqual(integration.summary.connectionState, .needsAttention)
        XCTAssertEqual(integration.summary.detail, "Unable to remove authorization")
    }

    func testMalformedTokenRemovalFailureReportsCredentialStorageError() async throws {
        let credentials = FailingRemovalCredentialStore(initialData: Data([0xFF]))
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(),
            credentials: credentials
        )

        do {
            _ = try await integration.restoreAccount()
            XCTFail("Expected credential storage error")
        } catch let error as GitHubConnectionError {
            XCTAssertEqual(error, .credentialStorage)
        }

        let credentialData = await credentials.storedData()
        XCTAssertEqual(credentialData, Data([0xFF]))
        XCTAssertEqual(integration.summary.connectionState, .needsAttention)
        XCTAssertEqual(integration.summary.detail, "Unable to remove authorization")
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

    func testPollingSleepIsCappedAtAuthorizationExpiration() async throws {
        let authorization = GitHubDeviceAuthorization(
            deviceCode: "device-code",
            userCode: "ABCD-EFGH",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresIn: 1,
            interval: 30
        )
        let api = StubGitHubAPI(deviceResults: [.success(authorization)])
        let recorder = SleepRecorder()
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: MockCredentialStore(),
            sleep: { duration in
                try await recorder.recordAndSleep(duration)
            }
        )
        let startedAuthorization = try await integration.beginAuthorization()

        do {
            _ = try await integration.completeAuthorization(startedAuthorization)
            XCTFail("Expected expiration")
        } catch let error as GitHubConnectionError {
            XCTAssertEqual(error, .requestExpired)
        }

        let duration = await recorder.duration()
        let pollCount = await api.pollRequestCount()
        XCTAssertNotNil(duration)
        XCTAssertGreaterThan(duration ?? .zero, .zero)
        XCTAssertLessThanOrEqual(duration ?? .seconds(2), .seconds(1))
        XCTAssertEqual(pollCount, 0)
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

    func testSupersededCredentialPersistenceFailureDoesNotPublishNeedsAttention() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let api = StubGitHubAPI(
            deviceResults: [.success(testAuthorization)],
            pollResults: [.success(.authorized(token: "new-token"))],
            userResults: [.success(account)]
        )
        let credentials = SuspendedFailingSetCredentialStore()
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

        let persistenceStarted = try await waitUntil {
            await credentials.setDidStart()
        }
        XCTAssertTrue(persistenceStarted)

        try await integration.disconnect()
        await credentials.finishSet()

        do {
            _ = try await completion.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: the disconnect superseded the failed persistence operation.
        }

        XCTAssertEqual(integration.summary.connectionState, .disconnected)
        XCTAssertEqual(integration.summary.detail, "Ready to connect")
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

    func testRestoreWaitsForCredentialRemovalBeforeValidating() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let api = StubGitHubAPI(userResults: [.success(account)])
        let credentials = SuspendedRemovalCredentialStore(initialValue: "stored-token")
        let integration = GitHubIntegration(clientID: "client-id", api: api, credentials: credentials)
        let disconnection = Task {
            try await integration.disconnect()
        }

        await credentials.waitUntilRemovalBegins()
        let restoration = Task {
            try await integration.restoreAccount()
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        let tokensBeforeCleanup = await api.userTokens()
        XCTAssertEqual(tokensBeforeCleanup, [])

        await credentials.finishFirstRemoval()
        try await disconnection.value
        do {
            let restoredAccount = try await restoration.value
            XCTAssertNil(restoredAccount)
        } catch is CancellationError {
            // Cleanup's final generation invalidation may supersede the waiting restore.
        }
        let capturedTokens = await api.userTokens()
        let credentialValue = await credentials.stringValue()
        XCTAssertEqual(capturedTokens, [])
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
        let disconnectRemovalStarted = try await waitUntil {
            await credentials.removalAttemptCount() == 2
        }
        XCTAssertTrue(disconnectRemovalStarted)
        await credentials.finishFirstRemoval()

        let restoredAccount = try await restoration.value
        try await disconnection.value
        XCTAssertNil(restoredAccount)
        XCTAssertEqual(integration.summary.connectionState, .disconnected)
    }

    func testDisconnectSupersedesRevokedTokenRemovalFailure() async throws {
        let api = StubGitHubAPI(userResults: [.failure(.unauthorized)])
        let credentials = SuspendedRemovalCredentialStore(
            initialValue: "revoked-token",
            failFirstRemoval: true
        )
        let integration = GitHubIntegration(clientID: "client-id", api: api, credentials: credentials)
        let restoration = Task {
            try await integration.restoreAccount()
        }

        await credentials.waitUntilRemovalBegins()
        let disconnection = Task {
            try await integration.disconnect()
        }
        let disconnectRemovalStarted = try await waitUntil {
            await credentials.removalAttemptCount() == 2
        }
        XCTAssertTrue(disconnectRemovalStarted)
        await credentials.finishFirstRemoval()

        let restoredAccount = try await restoration.value
        try await disconnection.value
        XCTAssertNil(restoredAccount)
        XCTAssertEqual(integration.summary.connectionState, .disconnected)
        XCTAssertEqual(integration.summary.detail, "Ready to connect")
    }

    func testDisconnectDuringMalformedTokenCleanupDoesNotPublishStaleFailure() async throws {
        let credentials = SuspendedRemovalCredentialStore(initialData: Data([0xFF]))
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(),
            credentials: credentials
        )
        let restoration = Task {
            try await integration.restoreAccount()
        }

        await credentials.waitUntilRemovalBegins()
        let disconnection = Task {
            try await integration.disconnect()
        }
        let disconnectRemovalStarted = try await waitUntil {
            await credentials.removalAttemptCount() == 2
        }
        XCTAssertTrue(disconnectRemovalStarted)
        await credentials.finishFirstRemoval()

        let restoredAccount = try await restoration.value
        try await disconnection.value
        XCTAssertNil(restoredAccount)
        XCTAssertEqual(integration.summary.connectionState, .disconnected)
    }

    func testCanceledConnectionTaskCannotOverwriteNewerDisconnectedState() async throws {
        let api = SuspendedAuthorizationAPI()
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
        let authorizationStarted = try await waitUntil {
            await api.authorizationDidStart()
        }
        XCTAssertTrue(authorizationStarted)

        await MainActor.run { viewModel.cancel() }
        let cancellationFinished = try await waitUntil {
            await MainActor.run { viewModel.state == .disconnected }
        }
        XCTAssertTrue(cancellationFinished)

        await api.finishAuthorization()
        try await Task.sleep(for: .milliseconds(50))

        let state = await MainActor.run { viewModel.state }
        XCTAssertEqual(state, .disconnected)
    }

    func testAutomaticRestoreDoesNotCancelAuthorizationPolling() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let api = SuspendedPollingGitHubAPI(account: account)
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
        let pollingStarted = try await waitUntil {
            await api.pollDidStart()
        }
        XCTAssertTrue(pollingStarted)

        await viewModel.restore()
        let stateAfterReappearance = await MainActor.run { viewModel.state }
        XCTAssertEqual(stateAfterReappearance, .authorizing(testAuthorization))

        await api.finishPoll()
        let connectionFinished = try await waitUntil {
            await MainActor.run { viewModel.state == .connected(account) }
        }
        XCTAssertTrue(connectionFinished)
        let finalState = await MainActor.run { viewModel.state }
        XCTAssertEqual(finalState, .connected(account))
    }

    func testAutomaticRestoreRevalidatesStateAfterExternalCredentialRemoval() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let api = StubGitHubAPI(userResults: [.success(account)])
        let credentials = MockCredentialStore(initialValue: "stored-token")
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials
        )
        let viewModel = await MainActor.run { GitHubViewModel(integration: integration) }

        await viewModel.restore()
        let connectedState = await MainActor.run { viewModel.state }
        XCTAssertEqual(connectedState, .connected(account))

        await credentials.removeData(
            for: GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        )

        await viewModel.restore()
        let refreshedState = await MainActor.run { viewModel.state }
        XCTAssertEqual(
            refreshedState,
            .needsAttention(GitHubConnectionError.invalidToken.localizedDescription)
        )
    }

    func testDisconnectRetryRepeatsCredentialRemoval() async throws {
        let credentials = FailOnceRemovalCredentialStore(initialValue: "stored-token")
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(),
            credentials: credentials
        )
        let (viewModel, openURL) = await MainActor.run {
            (
                GitHubViewModel(integration: integration),
                OpenURLAction { _ in .handled }
            )
        }

        await viewModel.disconnect()
        let failedState = await MainActor.run { viewModel.state }
        guard case .needsAttention = failedState else {
            return XCTFail("Expected credential removal failure")
        }

        await MainActor.run { viewModel.retry(openURL: openURL) }
        let retryFinished = try await waitUntil {
            await MainActor.run { viewModel.state == .disconnected }
        }
        XCTAssertTrue(retryFinished)
        let attempts = await credentials.removalAttemptCount()
        let storedValue = await credentials.stringValue()
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(storedValue)
    }

    func testCancellationRetryRepeatsCredentialRemoval() async throws {
        let credentials = FailOnceRemovalCredentialStore(initialValue: "stored-token")
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(),
            credentials: credentials
        )
        let (viewModel, openURL) = await MainActor.run {
            (
                GitHubViewModel(integration: integration),
                OpenURLAction { _ in .handled }
            )
        }

        await MainActor.run { viewModel.cancel() }
        let cleanupFailed = try await waitUntil {
            await MainActor.run {
                if case .needsAttention = viewModel.state { return true }
                return false
            }
        }
        XCTAssertTrue(cleanupFailed)

        await MainActor.run { viewModel.retry(openURL: openURL) }
        let retryFinished = try await waitUntil {
            await MainActor.run { viewModel.state == .disconnected }
        }
        XCTAssertTrue(retryFinished)
        let attempts = await credentials.removalAttemptCount()
        let storedValue = await credentials.stringValue()
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(storedValue)
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
        let reconnectFinished = try await waitUntil {
            await MainActor.run { viewModel.state == .connected(account) }
        }
        XCTAssertTrue(reconnectFinished)

        let finalState = await MainActor.run { viewModel.state }
        let finalRequestCount = await api.deviceRequestCount()
        XCTAssertEqual(finalState, .connected(account))
        XCTAssertEqual(finalRequestCount, 1)
    }

    func testConfiguredClientIDRestoresConnectActionAndOpensVerificationURL() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let api = SuspendedPollingGitHubAPI(account: account)
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: MockCredentialStore(),
            sleep: { _ in }
        )
        let openedURLs = URLRecorder()
        let (viewModel, openURL) = await MainActor.run {
            (
                GitHubViewModel(integration: integration),
                OpenURLAction { url in
                    openedURLs.record(url)
                    return .handled
                }
            )
        }

        await viewModel.restore()
        let restoredState = await MainActor.run { viewModel.state }
        XCTAssertEqual(restoredState, .disconnected)

        await MainActor.run { viewModel.connect(openURL: openURL) }
        let pollingStarted = try await waitUntil {
            await api.pollDidStart()
        }
        XCTAssertTrue(pollingStarted)

        let authorizingState = await MainActor.run { viewModel.state }
        XCTAssertEqual(authorizingState, .authorizing(testAuthorization))
        XCTAssertEqual(openedURLs.values, [testAuthorization.verificationURI])

        await api.finishPoll()
        let connectionFinished = try await waitUntil {
            await MainActor.run { viewModel.state == .connected(account) }
        }
        XCTAssertTrue(connectionFinished)
    }

    func testDashboardPresentationTracksFirstConnectionAndLastDisconnection() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let api = StubGitHubAPI(
            deviceResults: [.success(testAuthorization)],
            pollResults: [.success(.authorized(token: "access-token"))],
            userResults: [.success(account)]
        )
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

        await viewModel.restore()
        let firstLaunchPresentation = await MainActor.run {
            DashboardPresentation(githubState: viewModel.state)
        }
        XCTAssertEqual(firstLaunchPresentation, .onboarding)

        await MainActor.run { viewModel.connect(openURL: openURL) }
        let connected = try await waitUntil {
            await MainActor.run { viewModel.state == .connected(account) }
        }
        XCTAssertTrue(connected)
        let connectedPresentation = await MainActor.run {
            DashboardPresentation(githubState: viewModel.state)
        }
        XCTAssertEqual(connectedPresentation, .connected(account))

        await viewModel.disconnect()
        let disconnectedPresentation = await MainActor.run {
            DashboardPresentation(githubState: viewModel.state)
        }
        XCTAssertEqual(disconnectedPresentation, .onboarding)
    }

    func testMissingClientIDRestoresConfigurationRequiredWithoutConnectAction() async {
        let integration = GitHubIntegration(
            clientID: nil,
            api: StubGitHubAPI(),
            credentials: MockCredentialStore()
        )
        let viewModel = await MainActor.run { GitHubViewModel(integration: integration) }

        await viewModel.restore()

        let state = await MainActor.run { viewModel.state }
        XCTAssertEqual(
            state,
            .configurationRequired(GitHubConnectionError.missingClientID.localizedDescription)
        )
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

    func testMultipleAuthorizationsPersistDistinctProviderQualifiedCredentials() async throws {
        let first = GitHubAccount(id: 7, login: "franz", name: "Franz", avatarURL: nil)
        let second = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let firstAuthorization = testAuthorization
        let secondAuthorization = GitHubDeviceAuthorization(
            deviceCode: "second-device-code",
            userCode: "IJKL-MNOP",
            verificationURI: testAuthorization.verificationURI,
            expiresIn: 900,
            interval: 5
        )
        let api = StubGitHubAPI(
            deviceResults: [.success(firstAuthorization), .success(secondAuthorization)],
            pollResults: [
                .success(.authorized(token: "first-token")),
                .success(.authorized(token: "second-token")),
            ],
            userResults: [.success(first), .success(second)]
        )
        let credentials = MockCredentialStore()
        let accountStore = InMemoryConnectedAccountStore()
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            accountStore: accountStore,
            sleep: { _ in }
        )

        let startedFirst = try await integration.beginAccountAuthorization()
        _ = try await integration.completeAccountAuthorization(startedFirst)
        let startedSecond = try await integration.beginAccountAuthorization()
        _ = try await integration.completeAccountAuthorization(startedSecond)

        let firstToken = await credentials.stringValue(
            for: GitHubIntegration.credentialAccount(for: first.connectedAccountID)
        )
        let secondToken = await credentials.stringValue(
            for: GitHubIntegration.credentialAccount(for: second.connectedAccountID)
        )
        XCTAssertEqual(firstToken, "first-token")
        XCTAssertEqual(secondToken, "second-token")
        let records = await accountStore.accounts(for: .github)
        XCTAssertEqual(records.map(\.id), [first.connectedAccountID, second.connectedAccountID])
    }

    func testLegacyCredentialMigratesToStableAccountKeyWithoutDisconnecting() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let credentials = MockCredentialStore(initialValue: "legacy-token")
        let accountStore = InMemoryConnectedAccountStore()
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(userResults: [.success(account)]),
            credentials: credentials,
            accountStore: accountStore
        )

        let restored = try await integration.restoreAccounts()

        XCTAssertEqual(restored, [GitHubAccountConnection(account: account, state: .connected)])
        let legacyToken = await credentials.stringValue(for: "github.oauth-token")
        let migratedToken = await credentials.stringValue(
            for: GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        )
        XCTAssertNil(legacyToken)
        XCTAssertEqual(migratedToken, "legacy-token")
    }

    func testLingeringLegacyCredentialNeverOverwritesNewerScopedCredential() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let scopedKey = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let credentials = MockCredentialStore(values: [
            "github.oauth-token": "old-legacy-token",
            scopedKey: "new-scoped-token",
        ])
        let accountStore = InMemoryConnectedAccountStore(records: [account.connectedAccountRecord])
        let api = StubGitHubAPI(userResults: [.success(account), .success(account)])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            accountStore: accountStore
        )

        let restored = try await integration.restoreAccounts()

        XCTAssertEqual(restored, [GitHubAccountConnection(account: account, state: .connected)])
        let scopedToken = await credentials.stringValue(for: scopedKey)
        let legacyToken = await credentials.stringValue(for: "github.oauth-token")
        let validatedTokens = await api.userTokens()
        XCTAssertEqual(scopedToken, "new-scoped-token")
        XCTAssertNil(legacyToken)
        XCTAssertEqual(validatedTokens, ["old-legacy-token", "new-scoped-token"])
    }

    func testRevokedAccountDoesNotInvalidateAnotherStoredAccount() async throws {
        let revoked = GitHubAccount(id: 7, login: "revoked", name: nil, avatarURL: nil)
        let healthy = GitHubAccount(id: 42, login: "healthy", name: nil, avatarURL: nil)
        let accountStore = InMemoryConnectedAccountStore(records: [
            revoked.connectedAccountRecord,
            healthy.connectedAccountRecord,
        ])
        let revokedKey = GitHubIntegration.credentialAccount(for: revoked.connectedAccountID)
        let healthyKey = GitHubIntegration.credentialAccount(for: healthy.connectedAccountID)
        let credentials = MockCredentialStore(values: [
            revokedKey: "revoked-token",
            healthyKey: "healthy-token",
        ])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(userResults: [.failure(.unauthorized), .success(healthy)]),
            credentials: credentials,
            accountStore: accountStore
        )

        let restored = try await integration.restoreAccounts()

        XCTAssertEqual(restored.map(\.id), [revoked.connectedAccountID, healthy.connectedAccountID])
        XCTAssertEqual(restored.map(\.state), [.needsAttention, .connected])
        let revokedToken = await credentials.stringValue(for: revokedKey)
        let healthyToken = await credentials.stringValue(for: healthyKey)
        XCTAssertNil(revokedToken)
        XCTAssertEqual(healthyToken, "healthy-token")
    }

    func testDisconnectAndRefreshAreIsolatedAcrossAccounts() async throws {
        let first = GitHubAccount(id: 7, login: "first", name: nil, avatarURL: nil)
        let second = GitHubAccount(id: 42, login: "second", name: nil, avatarURL: nil)
        let firstKey = GitHubIntegration.credentialAccount(for: first.connectedAccountID)
        let secondKey = GitHubIntegration.credentialAccount(for: second.connectedAccountID)
        let credentials = MockCredentialStore(values: [firstKey: "first-token", secondKey: "second-token"])
        let accountStore = InMemoryConnectedAccountStore(records: [
            first.connectedAccountRecord,
            second.connectedAccountRecord,
        ])
        let expected = GitHubPullRequestCollection(pullRequests: [], totalCount: 0)
        let api = StubGitHubAPI(pullRequestResults: [.success(expected)])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            accountStore: accountStore
        )

        async let disconnected: Void = integration.disconnect(accountID: first.connectedAccountID)
        async let refreshed = integration.authoredPullRequests(for: second)
        _ = try await (disconnected, refreshed)

        let firstToken = await credentials.stringValue(for: firstKey)
        let secondToken = await credentials.stringValue(for: secondKey)
        let requests = await api.pullRequestRequests()
        let records = await accountStore.accounts(for: .github)
        XCTAssertNil(firstToken)
        XCTAssertEqual(secondToken, "second-token")
        XCTAssertEqual(requests, [PullRequestRequest(login: "second", token: "second-token")])
        XCTAssertEqual(records, [second.connectedAccountRecord])
    }

    func testReconnectUpdatesOnlyTheTargetAccountCredential() async throws {
        let first = GitHubAccount(id: 7, login: "first-renamed", name: nil, avatarURL: nil)
        let second = GitHubAccount(id: 42, login: "second", name: nil, avatarURL: nil)
        let firstKey = GitHubIntegration.credentialAccount(for: first.connectedAccountID)
        let secondKey = GitHubIntegration.credentialAccount(for: second.connectedAccountID)
        let credentials = MockCredentialStore(values: [firstKey: "old-first", secondKey: "second-token"])
        let accountStore = InMemoryConnectedAccountStore(records: [
            GitHubAccount(id: 7, login: "first", name: nil, avatarURL: nil).connectedAccountRecord,
            second.connectedAccountRecord,
        ])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(
                deviceResults: [.success(testAuthorization)],
                pollResults: [.success(.authorized(token: "new-first"))],
                userResults: [.success(first)]
            ),
            credentials: credentials,
            accountStore: accountStore,
            sleep: { _ in }
        )

        let authorization = try await integration.beginAccountAuthorization(reconnecting: first.connectedAccountID)
        _ = try await integration.completeAccountAuthorization(authorization)

        let firstToken = await credentials.stringValue(for: firstKey)
        let secondToken = await credentials.stringValue(for: secondKey)
        let usernames = await accountStore.accounts(for: .github).map(\.username)
        XCTAssertEqual(firstToken, "new-first")
        XCTAssertEqual(secondToken, "second-token")
        XCTAssertEqual(usernames, ["first-renamed", "second"])
    }

    func testDisconnectDuringReconnectPersistenceCannotRestoreTheAccount() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let credentials = SuspendedCredentialStore()
        let accountStore = InMemoryConnectedAccountStore(records: [account.connectedAccountRecord])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(
                deviceResults: [.success(testAuthorization)],
                pollResults: [.success(.authorized(token: "new-token"))],
                userResults: [.success(account)]
            ),
            credentials: credentials,
            accountStore: accountStore,
            sleep: { _ in }
        )
        let authorization = try await integration.beginAccountAuthorization(
            reconnecting: account.connectedAccountID
        )
        let completion = Task {
            try await integration.completeAccountAuthorization(authorization)
        }

        await credentials.waitUntilSetBegins()
        try await integration.disconnect(accountID: account.connectedAccountID)
        await credentials.finishSet()

        do {
            _ = try await completion.value
            XCTFail("Expected disconnect to supersede reconnect persistence")
        } catch is CancellationError {
            // Expected.
        }
        let storedToken = await credentials.stringValue()
        let records = await accountStore.accounts(for: .github)
        XCTAssertNil(storedToken)
        XCTAssertEqual(records, [])
    }

    func testViewModelRestoresAllAccountsInDeterministicOrder() async throws {
        let later = GitHubAccount(id: 42, login: "later", name: nil, avatarURL: nil)
        let earlier = GitHubAccount(id: 7, login: "earlier", name: nil, avatarURL: nil)
        let accountStore = InMemoryConnectedAccountStore(records: [
            later.connectedAccountRecord,
            earlier.connectedAccountRecord,
        ])
        let credentials = MockCredentialStore(values: [
            GitHubIntegration.credentialAccount(for: later.connectedAccountID): "later-token",
            GitHubIntegration.credentialAccount(for: earlier.connectedAccountID): "earlier-token",
        ])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(userResults: [.success(earlier), .success(later)]),
            credentials: credentials,
            accountStore: accountStore
        )
        let viewModel = await MainActor.run { GitHubViewModel(integration: integration) }

        await viewModel.restore()

        let restored = await MainActor.run { viewModel.accounts }
        XCTAssertEqual(restored.map(\.account), [earlier, later])
        XCTAssertEqual(restored.map(\.state), [.connected, .connected])
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() {
                return true
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

private final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []

    func record(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        recordedURLs.append(url)
    }

    var values: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }
}

private actor MockCredentialStore: CredentialStoring {
    private var values: [String: Data]

    init(initialValue: String? = nil) {
        if let initialValue {
            values = ["github.oauth-token": Data(initialValue.utf8)]
        } else {
            values = [:]
        }
    }

    init(values: [String: String]) {
        self.values = values.mapValues { Data($0.utf8) }
    }

    func set(_ data: Data, for account: String) {
        values[account] = data
    }

    func data(for account: String) -> Data? {
        values[account]
    }

    func removeData(for account: String) {
        values.removeValue(forKey: account)
    }

    func stringValue() -> String? {
        let value = values["github.oauth-token"] ?? values.values.first
        return value.flatMap { String(data: $0, encoding: .utf8) }
    }

    func stringValue(for account: String) -> String? {
        values[account].flatMap { String(data: $0, encoding: .utf8) }
    }
}

private actor FailOnceRemovalCredentialStore: CredentialStoring {
    enum StoreError: Error {
        case removalFailed
    }

    private var value: Data?
    private var removalAttempts = 0

    init(initialValue: String) {
        value = Data(initialValue.utf8)
    }

    func set(_ data: Data, for account: String) {
        value = data
    }

    func data(for account: String) -> Data? {
        value
    }

    func removeData(for account: String) throws {
        removalAttempts += 1
        if removalAttempts == 1 {
            throw StoreError.removalFailed
        }
        value = nil
    }

    func removalAttemptCount() -> Int {
        removalAttempts
    }

    func stringValue() -> String? {
        value.flatMap { String(data: $0, encoding: .utf8) }
    }
}

private actor SleepRecorder {
    private var recordedDuration: Duration?

    func recordAndSleep(_ duration: Duration) async throws {
        recordedDuration = duration
        try await Task.sleep(for: duration)
    }

    func duration() -> Duration? {
        recordedDuration
    }
}

private let testAuthorization = GitHubDeviceAuthorization(
    deviceCode: "device-code",
    userCode: "ABCD-EFGH",
    verificationURI: URL(string: "https://github.com/login/device")!,
    expiresIn: 900,
    interval: 5
)

private struct PullRequestRequest: Equatable, Sendable {
    let login: String
    let token: String
}

private actor StubGitHubAPI: GitHubAPIProviding {
    private var deviceResults: [Result<GitHubDeviceAuthorization, GitHubAPIError>]
    private var pollResults: [Result<GitHubTokenPollResult, GitHubAPIError>]
    private var userResults: [Result<GitHubAccount, GitHubAPIError>]
    private var pullRequestResults: [Result<GitHubPullRequestCollection, GitHubAPIError>]
    private var capturedUserTokens: [String] = []
    private var capturedPullRequestRequests: [PullRequestRequest] = []
    private var capturedDeviceRequestCount = 0
    private var capturedPollRequestCount = 0

    init(
        deviceResults: [Result<GitHubDeviceAuthorization, GitHubAPIError>] = [],
        pollResults: [Result<GitHubTokenPollResult, GitHubAPIError>] = [],
        userResults: [Result<GitHubAccount, GitHubAPIError>] = [],
        pullRequestResults: [Result<GitHubPullRequestCollection, GitHubAPIError>] = []
    ) {
        self.deviceResults = deviceResults
        self.pollResults = pollResults
        self.userResults = userResults
        self.pullRequestResults = pullRequestResults
    }

    func requestDeviceAuthorization(clientID: String) throws -> GitHubDeviceAuthorization {
        capturedDeviceRequestCount += 1
        return try deviceResults.removeFirst().get()
    }

    func pollForAccessToken(clientID: String, deviceCode: String) throws -> GitHubTokenPollResult {
        capturedPollRequestCount += 1
        return try pollResults.removeFirst().get()
    }

    func authenticatedUser(token: String) throws -> GitHubAccount {
        capturedUserTokens.append(token)
        return try userResults.removeFirst().get()
    }

    func authoredPullRequests(login: String, token: String) throws -> GitHubPullRequestCollection {
        capturedPullRequestRequests.append(PullRequestRequest(login: login, token: token))
        return try pullRequestResults.removeFirst().get()
    }

    func userTokens() -> [String] {
        capturedUserTokens
    }

    func pullRequestRequests() -> [PullRequestRequest] {
        capturedPullRequestRequests
    }

    func deviceRequestCount() -> Int {
        capturedDeviceRequestCount
    }

    func pollRequestCount() -> Int {
        capturedPollRequestCount
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

private actor FailingRemovalCredentialStore: CredentialStoring {
    enum StoreError: Error {
        case removalFailed
    }

    private var value: Data?

    init(initialValue: String) {
        value = Data(initialValue.utf8)
    }

    init(initialData: Data) {
        value = initialData
    }

    func set(_ data: Data, for account: String) {
        value = data
    }

    func data(for account: String) -> Data? {
        value
    }

    func removeData(for account: String) throws {
        throw StoreError.removalFailed
    }

    func storedData() -> Data? {
        value
    }

    func stringValue() -> String? {
        value.flatMap { String(data: $0, encoding: .utf8) }
    }
}

private actor SuspendedFailingSetCredentialStore: CredentialStoring {
    enum StoreError: Error {
        case persistenceFailed
    }

    private var didStartSet = false
    private var setCompletion: CheckedContinuation<Void, Never>?

    func set(_ data: Data, for account: String) async throws {
        didStartSet = true
        await withCheckedContinuation { continuation in
            setCompletion = continuation
        }
        throw StoreError.persistenceFailed
    }

    func data(for account: String) -> Data? {
        nil
    }

    func removeData(for account: String) {}

    func setDidStart() -> Bool {
        didStartSet
    }

    func finishSet() {
        setCompletion?.resume()
        setCompletion = nil
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

private actor ReconnectionGitHubAPI: GitHubAPIProviding {
    private let account: GitHubAccount
    private var oldValidationWaiter: CheckedContinuation<Void, Never>?
    private var oldValidationCompletion: CheckedContinuation<Void, Never>?

    init(account: GitHubAccount) {
        self.account = account
    }

    func requestDeviceAuthorization(clientID: String) -> GitHubDeviceAuthorization {
        testAuthorization
    }

    func pollForAccessToken(clientID: String, deviceCode: String) -> GitHubTokenPollResult {
        .authorized(token: "new-token")
    }

    func authenticatedUser(token: String) async -> GitHubAccount {
        guard token == "old-token" else { return account }

        oldValidationWaiter?.resume()
        oldValidationWaiter = nil
        await withCheckedContinuation { continuation in
            oldValidationCompletion = continuation
        }
        return account
    }

    func waitUntilOldValidationBegins() async {
        guard oldValidationCompletion == nil else { return }
        await withCheckedContinuation { continuation in
            oldValidationWaiter = continuation
        }
    }

    func finishOldValidation() {
        oldValidationCompletion?.resume()
        oldValidationCompletion = nil
    }
}

private actor SequencedSuspendedUserGitHubAPI: GitHubAPIProviding {
    private var requestCompletions: [CheckedContinuation<Result<GitHubAccount, GitHubAPIError>, Never>?] = []
    private var requestWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func requestDeviceAuthorization(clientID: String) throws -> GitHubDeviceAuthorization {
        throw GitHubAPIError.malformedResponse
    }

    func pollForAccessToken(clientID: String, deviceCode: String) throws -> GitHubTokenPollResult {
        throw GitHubAPIError.malformedResponse
    }

    func authenticatedUser(token: String) async throws -> GitHubAccount {
        let requestIndex = requestCompletions.count
        requestCompletions.append(nil)
        requestWaiters.removeValue(forKey: requestIndex + 1)?.resume()
        let result = await withCheckedContinuation { continuation in
            requestCompletions[requestIndex] = continuation
        }
        return try result.get()
    }

    func waitForRequest(count: Int) async {
        guard requestCompletions.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters[count] = continuation
        }
    }

    func requestCount() -> Int {
        requestCompletions.count
    }

    func finishRequest(
        at index: Int,
        with result: Result<GitHubAccount, GitHubAPIError>
    ) {
        requestCompletions[index]?.resume(returning: result)
        requestCompletions[index] = nil
    }
}

private actor SuspendedRemovalCredentialStore: CredentialStoring {
    enum StoreError: Error {
        case removalFailed
    }

    private var value: Data?
    private let failFirstRemoval: Bool
    private var removalAttempts = 0
    private var removalWaiter: CheckedContinuation<Void, Never>?
    private var removalCompletion: CheckedContinuation<Void, Never>?

    init(initialValue: String, failFirstRemoval: Bool = false) {
        value = Data(initialValue.utf8)
        self.failFirstRemoval = failFirstRemoval
    }

    init(initialData: Data, failFirstRemoval: Bool = false) {
        value = initialData
        self.failFirstRemoval = failFirstRemoval
    }

    func set(_ data: Data, for account: String) {
        value = data
    }

    func data(for account: String) -> Data? {
        value
    }

    func removeData(for account: String) async throws {
        removalAttempts += 1
        if removalAttempts == 1 {
            removalWaiter?.resume()
            removalWaiter = nil
            await withCheckedContinuation { continuation in
                removalCompletion = continuation
            }
            if failFirstRemoval {
                throw StoreError.removalFailed
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

    func removalAttemptCount() -> Int {
        removalAttempts
    }

    func stringValue() -> String? {
        value.flatMap { String(data: $0, encoding: .utf8) }
    }
}

private actor SuspendedAuthorizationAPI: GitHubAPIProviding {
    private var didStartAuthorization = false
    private var authorizationCompletion: CheckedContinuation<Void, Never>?

    func requestDeviceAuthorization(clientID: String) async -> GitHubDeviceAuthorization {
        didStartAuthorization = true
        await withCheckedContinuation { continuation in
            authorizationCompletion = continuation
        }
        return testAuthorization
    }

    func pollForAccessToken(clientID: String, deviceCode: String) -> GitHubTokenPollResult {
        .pending
    }

    func authenticatedUser(token: String) -> GitHubAccount {
        GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
    }

    func authorizationDidStart() -> Bool {
        didStartAuthorization
    }

    func finishAuthorization() {
        authorizationCompletion?.resume()
        authorizationCompletion = nil
    }
}

private actor SuspendedPollingGitHubAPI: GitHubAPIProviding {
    private let account: GitHubAccount
    private var didStartPoll = false
    private var pollCompletion: CheckedContinuation<Void, Never>?

    init(account: GitHubAccount) {
        self.account = account
    }

    func requestDeviceAuthorization(clientID: String) -> GitHubDeviceAuthorization {
        testAuthorization
    }

    func pollForAccessToken(clientID: String, deviceCode: String) async -> GitHubTokenPollResult {
        didStartPoll = true
        await withCheckedContinuation { continuation in
            pollCompletion = continuation
        }
        return .authorized(token: "new-token")
    }

    func authenticatedUser(token: String) -> GitHubAccount {
        account
    }

    func pollDidStart() -> Bool {
        didStartPoll
    }

    func finishPoll() {
        pollCompletion?.resume()
        pollCompletion = nil
    }
}
