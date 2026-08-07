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

    func testAssignedPullRequestsUsesTheRequestedAccountsScopedCredential() async throws {
        let expectedCollection = GitHubPullRequestCollection(pullRequests: [], totalCount: 0)
        let account = GitHubAccount(id: 7, login: "franz", name: nil, avatarURL: nil)
        let credentials = MockCredentialStore(values: [
            GitHubIntegration.credentialAccount(for: account.connectedAccountID): "scoped-token",
        ])
        let api = StubGitHubAPI(assignedPullRequestResults: [.success(expectedCollection)])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials
        )

        let collection = try await integration.assignedPullRequests(for: account)

        XCTAssertEqual(collection, expectedCollection)
        let requests = await api.assignedPullRequestRequests()
        XCTAssertEqual(requests, [PullRequestRequest(login: "franz", token: "scoped-token")])
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

        let restoredAccounts = try await integration.restoreAccounts()
        XCTAssertEqual(
            restoredAccounts,
            [GitHubAccountConnection(account: account, state: .connected)]
        )

        await api.finishOldValidation()
        let oldAccount = try await oldRestoration.value
        XCTAssertNil(oldAccount)

        let credentialValue = await credentials.stringValue(
            for: GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        )
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

    func testCanceledAuthorizationPersistenceFailureDoesNotPublishNeedsAttention() async throws {
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

        await integration.cancelAccountAuthorization(authorization)
        await credentials.finishSet()

        do {
            _ = try await completion.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: explicit authorization cancellation superseded persistence.
        }

        XCTAssertEqual(integration.summary.connectionState, .disconnected)
        XCTAssertEqual(integration.summary.detail, "Ready to connect")
    }

    func testCanceledReconnectRestoresPreviousTokenWhenAccountWriteFails() async throws {
        let original = GitHubAccount(id: 42, login: "original", name: nil, avatarURL: nil)
        let refreshed = GitHubAccount(id: 42, login: "refreshed", name: nil, avatarURL: nil)
        let credentialAccount = GitHubIntegration.credentialAccount(for: original.connectedAccountID)
        let credentials = MockCredentialStore(values: [credentialAccount: "old-token"])
        let accountStore = SuspendedFailingUpsertConnectedAccountStore(
            records: [original.connectedAccountRecord]
        )
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(
                deviceResults: [.success(testAuthorization)],
                pollResults: [.success(.authorized(token: "new-token"))],
                userResults: [.success(refreshed)]
            ),
            credentials: credentials,
            accountStore: accountStore,
            sleep: { _ in }
        )
        let authorization = try await integration.beginAccountAuthorization(
            reconnecting: original.connectedAccountID
        )
        let completion = Task {
            try await integration.completeAccountAuthorization(authorization)
        }
        await accountStore.waitUntilUpsertBegins()

        await integration.cancelAccountAuthorization(authorization)
        await accountStore.finishUpsert()

        do {
            _ = try await completion.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let storedToken = await credentials.stringValue(for: credentialAccount)
        let storedAccounts = await accountStore.accounts(for: .github)
        XCTAssertEqual(storedToken, "old-token")
        XCTAssertEqual(storedAccounts, [original.connectedAccountRecord])
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

    func testAutomaticRestoreDoesNotCancelAccountAuthorizationPolling() async throws {
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

        await MainActor.run { viewModel.addAccount(openURL: openURL) }
        let pollingStarted = try await waitUntil {
            await api.pollDidStart()
        }
        XCTAssertTrue(pollingStarted)

        await viewModel.restore()
        let stateAfterReappearance = await MainActor.run { viewModel.state }
        XCTAssertEqual(stateAfterReappearance, .authorizing(testAuthorization))

        await api.finishPoll()
        let connectionFinished = try await waitUntil {
            await MainActor.run {
                viewModel.accounts == [
                    GitHubAccountConnection(account: account, state: .connected),
                ]
            }
        }
        XCTAssertTrue(connectionFinished)
    }

    func testDismissingAuthorizationSheetPreservesInFlightAccountAuthorization() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let api = SuspendedPollingGitHubAPI(account: account)
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: MockCredentialStore(),
            sleep: { _ in }
        )
        let viewModel = await MainActor.run { GitHubViewModel(integration: integration) }

        await MainActor.run {
            viewModel.addAccount(presentAuthorizationURL: { _ in })
        }
        let pollingStarted = try await waitUntil {
            await api.pollDidStart()
        }
        XCTAssertTrue(pollingStarted)

        let stateAfterDismissal = await MainActor.run {
            let view = GitHubView(viewModel: viewModel)
            view.authorizationSheetDismissed()
            return viewModel.state
        }
        XCTAssertEqual(stateAfterDismissal, .authorizing(testAuthorization))

        await api.finishPoll()
        let connectionFinished = try await waitUntil {
            await MainActor.run {
                viewModel.accounts == [
                    GitHubAccountConnection(account: account, state: .connected),
                ]
            }
        }
        XCTAssertTrue(connectionFinished)
    }

    func testAddedAccountRouteShowsItsReconnectAuthorization() async throws {
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

        let view = await MainActor.run {
            GitHubView(
                viewModel: viewModel,
                addedAccountID: account.connectedAccountID
            )
        }
        await MainActor.run {
            view.connectPresentedAccount(openURL: openURL)
        }
        let pollingStarted = try await waitUntil {
            await api.pollDidStart()
        }
        XCTAssertTrue(pollingStarted)

        let presentationState = await MainActor.run { view.presentationState }
        XCTAssertEqual(presentationState, .authorizing(testAuthorization))

        await api.finishPoll()
        let connectionFinished = try await waitUntil {
            await MainActor.run { viewModel.activeAccountAuthorizationTarget == nil }
        }
        XCTAssertTrue(connectionFinished)
    }

    func testAddedAccountRouteDisconnectsItsPresentedAccount() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let credentialAccount = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let credentials = MockCredentialStore(values: [credentialAccount: "stored-token"])
        let accountStore = InMemoryConnectedAccountStore(records: [account.connectedAccountRecord])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(userResults: [.success(account)]),
            credentials: credentials,
            accountStore: accountStore
        )
        let viewModel = await MainActor.run { GitHubViewModel(integration: integration) }
        await viewModel.restore()
        let view = await MainActor.run {
            GitHubView(
                viewModel: viewModel,
                addedAccountID: account.connectedAccountID
            )
        }

        await view.disconnectPresentedAccount()

        let storedToken = await credentials.stringValue(for: credentialAccount)
        let records = await accountStore.accounts(for: .github)
        let (state, accounts) = await MainActor.run { (viewModel.state, viewModel.accounts) }
        XCTAssertNil(storedToken)
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(accounts.isEmpty)
        XCTAssertEqual(state, .disconnected)
    }

    func testMissingAccountRouteShowsReconnectFailure() async throws {
        let accountID = ConnectedAccountID(provider: .github, subject: "42")
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(deviceResults: [.failure(.server(503))]),
            credentials: MockCredentialStore()
        )
        let (viewModel, openURL) = await MainActor.run {
            (
                GitHubViewModel(integration: integration),
                OpenURLAction { _ in .handled }
            )
        }

        await MainActor.run {
            viewModel.reconnect(accountID, openURL: openURL)
        }
        let reconnectFailed = try await waitUntil {
            await MainActor.run {
                viewModel.activeAccountAuthorizationTarget == nil
                    && viewModel.state == .needsAttention(
                        GitHubConnectionError.server(503).localizedDescription
                    )
            }
        }
        XCTAssertTrue(reconnectFailed)

        let presentationState = await MainActor.run {
            GitHubView(viewModel: viewModel, accountID: accountID).presentationState
        }
        XCTAssertEqual(
            presentationState,
            .needsAttention(GitHubConnectionError.server(503).localizedDescription)
        )
    }

    func testAddAccountRouteIgnoresUnrelatedAccountFailure() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(),
            credentials: MockCredentialStore(),
            accountStore: InMemoryConnectedAccountStore(records: [account.connectedAccountRecord])
        )
        let viewModel = await MainActor.run { GitHubViewModel(integration: integration) }
        await viewModel.restore()

        let (addRouteState, accountRouteState) = await MainActor.run {
            (
                GitHubView(viewModel: viewModel).presentationState,
                GitHubView(
                    viewModel: viewModel,
                    accountID: account.connectedAccountID
                ).presentationState
            )
        }

        XCTAssertEqual(addRouteState, .disconnected)
        XCTAssertEqual(
            accountRouteState,
            .needsAttention(GitHubConnectionError.invalidToken.localizedDescription)
        )
    }

    func testValidationRetryDoesNotSupersedeUnrelatedAccountAuthorization() async throws {
        let failed = GitHubAccount(id: 7, login: "failed", name: nil, avatarURL: nil)
        let reconnecting = GitHubAccount(id: 42, login: "reconnecting", name: nil, avatarURL: nil)
        let api = ValidationRetryDuringAuthorizationGitHubAPI(
            reconnectingAccount: reconnecting
        )
        let credentials = MockCredentialStore(values: [
            GitHubIntegration.credentialAccount(for: failed.connectedAccountID): "failed-token",
            GitHubIntegration.credentialAccount(for: reconnecting.connectedAccountID): "connected-token",
        ])
        let accountStore = InMemoryConnectedAccountStore(records: [
            failed.connectedAccountRecord,
            reconnecting.connectedAccountRecord,
        ])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            accountStore: accountStore,
            sleep: { _ in }
        )
        let (viewModel, openURL) = await MainActor.run {
            (
                GitHubViewModel(integration: integration),
                OpenURLAction { _ in .handled }
            )
        }
        await viewModel.restore()

        await MainActor.run {
            viewModel.reconnect(reconnecting.connectedAccountID, openURL: openURL)
        }
        await api.waitUntilPollBegins()
        await MainActor.run {
            viewModel.retry(failed.connectedAccountID, openURL: openURL)
        }
        await api.finishPoll()

        let authorizationFinished = try await waitUntil {
            await MainActor.run { viewModel.activeAccountAuthorizationTarget == nil }
        }
        XCTAssertTrue(authorizationFinished)
        let accounts = await MainActor.run { viewModel.accounts }
        XCTAssertEqual(
            accounts,
            [
                GitHubAccountConnection(
                    account: failed,
                    state: .needsAttention,
                    message: GitHubConnectionError.server(503).localizedDescription,
                    recoveryAction: .validate
                ),
                GitHubAccountConnection(account: reconnecting, state: .connected),
            ]
        )
        let userTokens = await api.userTokens()
        XCTAssertEqual(userTokens, ["failed-token", "connected-token", "new-token"])
    }

    func testAddAccountFailureIsPresentedInsteadOfReturningToConnectScreen() async throws {
        let api = StubGitHubAPI(deviceResults: [.failure(.server(503))])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: MockCredentialStore()
        )
        let (viewModel, openURL) = await MainActor.run {
            (
                GitHubViewModel(integration: integration),
                OpenURLAction { _ in .handled }
            )
        }

        await MainActor.run { viewModel.addAccount(openURL: openURL) }
        let failurePresented = try await waitUntil {
            await MainActor.run {
                if case .needsAttention = viewModel.state { return true }
                return false
            }
        }

        XCTAssertTrue(failurePresented)
        let presentationState = await MainActor.run {
            GitHubView(viewModel: viewModel).presentationState
        }
        XCTAssertEqual(
            presentationState,
            .needsAttention(GitHubConnectionError.server(503).localizedDescription)
        )
    }

    func testSuccessfulAddAccountReportsIdentityForDestinationSelection() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(
                deviceResults: [.success(testAuthorization)],
                pollResults: [.success(.authorized(token: "new-token"))],
                userResults: [.success(account)]
            ),
            credentials: MockCredentialStore(),
            sleep: { _ in }
        )
        let (viewModel, openURL) = await MainActor.run {
            (
                GitHubViewModel(integration: integration),
                OpenURLAction { _ in .handled }
            )
        }
        let selectedDestination = expectation(description: "Select added account destination")

        await MainActor.run {
            viewModel.addAccount(openURL: openURL) { accountID in
                XCTAssertEqual(accountID, account.connectedAccountID)
                selectedDestination.fulfill()
            }
        }

        await fulfillment(of: [selectedDestination], timeout: 1)
        let accounts = await MainActor.run { viewModel.accounts }
        XCTAssertEqual(accounts, [GitHubAccountConnection(account: account, state: .connected)])
    }

    func testDuplicateAddShowsExplicitMessageWithoutMutatingExistingAccount() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let credentialAccount = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let api = StubGitHubAPI(
            deviceResults: [.success(testAuthorization)],
            pollResults: [.success(.authorized(token: "replacement-token"))],
            userResults: [.success(account), .success(account)]
        )
        let credentials = MockCredentialStore(values: [credentialAccount: "stored-token"])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            accountStore: InMemoryConnectedAccountStore(records: [account.connectedAccountRecord]),
            sleep: { _ in }
        )
        let (viewModel, openURL) = await MainActor.run {
            (
                GitHubViewModel(integration: integration),
                OpenURLAction { _ in .handled }
            )
        }
        await viewModel.restore()

        await MainActor.run { viewModel.addAccount(openURL: openURL) }
        let additionFinished = try await waitUntil {
            let authorizationFinished = await MainActor.run {
                viewModel.activeAccountAuthorizationTarget == nil
            }
            let userTokenCount = await api.userTokens().count
            return authorizationFinished && userTokenCount == 2
        }

        XCTAssertTrue(additionFinished)
        let revision = await MainActor.run {
            viewModel.dashboardRefreshRevision(for: account.connectedAccountID)
        }
        let accounts = await MainActor.run { viewModel.accounts }
        XCTAssertEqual(revision, 0)
        XCTAssertEqual(accounts, [GitHubAccountConnection(account: account, state: .connected)])
        let state = await MainActor.run { viewModel.state }
        XCTAssertEqual(
            state,
            .needsAttention(GitHubConnectionError.duplicateAccount.localizedDescription)
        )
        let storedToken = await credentials.stringValue(for: credentialAccount)
        XCTAssertEqual(storedToken, "stored-token")
    }

    func testFailedReconnectPreservesPreviouslyHealthyAccount() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let differentAccount = GitHubAccount(id: 84, login: "hubot", name: nil, avatarURL: nil)
        let accountStore = InMemoryConnectedAccountStore(records: [account.connectedAccountRecord])
        let credentials = MockCredentialStore(values: [
            GitHubIntegration.credentialAccount(for: account.connectedAccountID): "old-token",
        ])
        let api = StubGitHubAPI(
            deviceResults: [.success(testAuthorization)],
            pollResults: [.success(.authorized(token: "wrong-account-token"))],
            userResults: [.success(account), .success(differentAccount)]
        )
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            accountStore: accountStore,
            sleep: { _ in }
        )
        let (viewModel, openURL) = await MainActor.run {
            (
                GitHubViewModel(integration: integration),
                OpenURLAction { _ in .handled }
            )
        }
        await viewModel.restore()

        await MainActor.run {
            viewModel.reconnect(account.connectedAccountID, openURL: openURL)
        }
        let reconnectFinished = try await waitUntil {
            let validatedTokens = await api.userTokens()
            return await MainActor.run {
                validatedTokens.count == 2 && viewModel.activeAccountAuthorizationTarget == nil
            }
        }

        XCTAssertTrue(reconnectFinished)
        let (state, accounts) = await MainActor.run { (viewModel.state, viewModel.accounts) }
        XCTAssertEqual(state, .connected(account))
        XCTAssertEqual(accounts, [GitHubAccountConnection(account: account, state: .connected)])
        let storedToken = await credentials.stringValue(
            for: GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        )
        XCTAssertEqual(storedToken, "old-token")
    }

    func testTransientRestoreFailureRetriesStoredCredentialWithoutOAuth() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let credentialAccount = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let api = StubGitHubAPI(
            userResults: [.failure(.server(503)), .success(account)]
        )
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: MockCredentialStore(values: [credentialAccount: "stored-token"]),
            accountStore: InMemoryConnectedAccountStore(records: [account.connectedAccountRecord])
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
        let failedConnection = await MainActor.run { viewModel.accounts.first }
        XCTAssertEqual(failedConnection?.state, .needsAttention)
        XCTAssertEqual(failedConnection?.recoveryAction, .validate)

        await MainActor.run {
            viewModel.retry(account.connectedAccountID, openURL: openURL)
        }
        let retryFinished = try await waitUntil {
            await MainActor.run { viewModel.state == .connected(account) }
        }

        XCTAssertTrue(retryFinished)
        let deviceRequestCount = await api.deviceRequestCount()
        let userTokens = await api.userTokens()
        XCTAssertEqual(deviceRequestCount, 0)
        XCTAssertEqual(userTokens, ["stored-token", "stored-token"])
        XCTAssertTrue(openedURLs.values.isEmpty)
    }

    func testTransientLegacyRestoreFailureRetriesMigrationWithoutOAuth() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let api = StubGitHubAPI(
            userResults: [.failure(.server(503)), .success(account)]
        )
        let credentials = MockCredentialStore(initialValue: "legacy-token")
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            accountStore: InMemoryConnectedAccountStore()
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
        let failedState = await MainActor.run { viewModel.state }
        XCTAssertEqual(failedState, .needsAttention(GitHubConnectionError.server(503).localizedDescription))

        await MainActor.run {
            viewModel.retryAccountSetup(openURL: openURL)
        }
        let retryFinished = try await waitUntil {
            await MainActor.run { viewModel.state == .connected(account) }
        }

        XCTAssertTrue(retryFinished)
        let deviceRequestCount = await api.deviceRequestCount()
        let userTokens = await api.userTokens()
        XCTAssertEqual(deviceRequestCount, 0)
        XCTAssertEqual(userTokens, ["legacy-token", "legacy-token"])
        XCTAssertTrue(openedURLs.values.isEmpty)
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

    func testStaleDashboardAuthenticationFailureCannotResurrectDisconnectedState() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let credentialAccount = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(userResults: [.success(account)]),
            credentials: MockCredentialStore(values: [credentialAccount: "stored-token"]),
            accountStore: InMemoryConnectedAccountStore(records: [account.connectedAccountRecord])
        )
        let viewModel = await MainActor.run { GitHubViewModel(integration: integration) }
        await viewModel.restore()
        await viewModel.disconnect(account.connectedAccountID)

        await MainActor.run {
            viewModel.reportDashboardAuthenticationFailure(for: account.connectedAccountID)
        }

        let (state, accounts) = await MainActor.run { (viewModel.state, viewModel.accounts) }
        XCTAssertEqual(state, .disconnected)
        XCTAssertTrue(accounts.isEmpty)
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
        XCTAssertEqual(openedURLs.values, [testAuthorization.authorizationURL])

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

    func testMissingOAuthSecretReportsCompleteConfigurationRequirement() async {
        let integration = GitHubIntegration(
            clientID: "client-id",
            clientSecret: nil,
            api: GitHubAPI(),
            credentials: MockCredentialStore()
        )
        let viewModel = await MainActor.run { GitHubViewModel(integration: integration) }

        await viewModel.restore()

        let state = await MainActor.run { viewModel.state }
        XCTAssertEqual(
            state,
            .configurationRequired(GitHubConnectionError.missingOAuthConfiguration.localizedDescription)
        )
    }

    func testGlobalDisconnectCancelsActiveBrowserAuthorization() async throws {
        let api = StubGitHubAPI(deviceResults: [.success(testAuthorization)])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: MockCredentialStore()
        )
        let authorization = try await integration.beginAuthorization()

        try await integration.disconnect()

        let canceledAuthorizations = await api.canceledAuthorizations()
        XCTAssertEqual(canceledAuthorizations, [authorization])
        do {
            _ = try await integration.completeAuthorization(authorization)
            XCTFail("Expected disconnected authorization to be invalidated")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testMultipleAuthorizationsPersistDistinctProviderQualifiedCredentials() async throws {
        let first = GitHubAccount(id: 7, login: "franz", name: "Franz", avatarURL: nil)
        let second = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let firstAuthorization = testAuthorization
        let secondAuthorization = GitHubBrowserAuthorization(
            id: UUID(),
            authorizationURL: testAuthorization.authorizationURL
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

    func testDisconnectDuringLegacyValidationCannotRemigrateAccount() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let scopedKey = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let credentials = MockCredentialStore(values: [
            "github.oauth-token": "legacy-token",
            scopedKey: "scoped-token",
        ])
        let accountStore = InMemoryConnectedAccountStore(records: [account.connectedAccountRecord])
        let api = SuspendedUserGitHubAPI(account: account)
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            accountStore: accountStore
        )
        let restoration = Task {
            try await integration.restoreAccounts()
        }
        await api.waitUntilUserRequestBegins()

        try await integration.disconnect(accountID: account.connectedAccountID)
        await api.finishUserRequest()

        let restored = try await restoration.value
        let legacyToken = await credentials.stringValue(for: "github.oauth-token")
        let scopedToken = await credentials.stringValue(for: scopedKey)
        let records = await accountStore.accounts(for: .github)
        XCTAssertTrue(restored.isEmpty)
        XCTAssertNil(legacyToken)
        XCTAssertNil(scopedToken)
        XCTAssertTrue(records.isEmpty)
    }

    func testDisconnectRemovesLegacyCredentialBelongingToSameAccount() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let scopedKey = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let credentials = MockCredentialStore(values: [
            "github.oauth-token": "legacy-token",
            scopedKey: "scoped-token",
        ])
        let accountStore = InMemoryConnectedAccountStore(records: [account.connectedAccountRecord])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(userResults: [.success(account)]),
            credentials: credentials,
            accountStore: accountStore
        )

        try await integration.disconnect(accountID: account.connectedAccountID)

        let legacyToken = await credentials.stringValue(for: "github.oauth-token")
        let scopedToken = await credentials.stringValue(for: scopedKey)
        let records = await accountStore.accounts(for: .github)
        XCTAssertNil(legacyToken)
        XCTAssertNil(scopedToken)
        XCTAssertTrue(records.isEmpty)
    }

    func testDisconnectClearsObsoleteLegacyCredentialWithoutAffectingOtherScopedAccounts() async throws {
        let disconnected = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let otherAccount = GitHubAccount(id: 84, login: "hubot", name: nil, avatarURL: nil)
        let scopedKey = GitHubIntegration.credentialAccount(for: disconnected.connectedAccountID)
        let otherScopedKey = GitHubIntegration.credentialAccount(for: otherAccount.connectedAccountID)
        let credentials = MockCredentialStore(values: [
            "github.oauth-token": "other-account-token",
            scopedKey: "scoped-token",
            otherScopedKey: "other-scoped-token",
        ])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(),
            credentials: credentials,
            accountStore: InMemoryConnectedAccountStore(records: [
                disconnected.connectedAccountRecord,
                otherAccount.connectedAccountRecord,
            ])
        )

        try await integration.disconnect(accountID: disconnected.connectedAccountID)

        let legacyToken = await credentials.stringValue(for: "github.oauth-token")
        let scopedToken = await credentials.stringValue(for: scopedKey)
        let otherScopedToken = await credentials.stringValue(for: otherScopedKey)
        XCTAssertNil(legacyToken)
        XCTAssertNil(scopedToken)
        XCTAssertEqual(otherScopedToken, "other-scoped-token")
    }

    func testDisconnectPreservesPendingLegacyCredentialWithUnknownOwner() async throws {
        let scopedAccount = GitHubAccount(id: 7, login: "scoped", name: nil, avatarURL: nil)
        let scopedKey = GitHubIntegration.credentialAccount(for: scopedAccount.connectedAccountID)
        let credentials = MockCredentialStore(values: [
            "github.oauth-token": "pending-other-token",
            scopedKey: "scoped-token",
        ])
        let accountStore = InMemoryConnectedAccountStore(records: [scopedAccount.connectedAccountRecord])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(userResults: [
                .failure(.server(503)),
                .success(scopedAccount),
            ]),
            credentials: credentials,
            accountStore: accountStore
        )
        _ = try await integration.restoreAccounts()

        try await integration.disconnect(accountID: scopedAccount.connectedAccountID)

        let legacyToken = await credentials.stringValue(for: "github.oauth-token")
        let scopedToken = await credentials.stringValue(for: scopedKey)
        let records = await accountStore.accounts(for: .github)
        XCTAssertEqual(legacyToken, "pending-other-token")
        XCTAssertNil(scopedToken)
        XCTAssertTrue(records.isEmpty)
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

    func testDisconnectDuringRestoreCannotResurrectAccount() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let scopedKey = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let api = SuspendedUserGitHubAPI(account: account)
        let credentials = MockCredentialStore(values: [scopedKey: "stored-token"])
        let accountStore = InMemoryConnectedAccountStore(records: [account.connectedAccountRecord])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            accountStore: accountStore
        )
        let restore = Task { try await integration.restoreAccounts() }
        await api.waitUntilUserRequestBegins()

        try await integration.disconnect(accountID: account.connectedAccountID)
        await api.finishUserRequest()

        let restored = try await restore.value
        let records = await accountStore.accounts(for: .github)
        let scopedToken = await credentials.stringValue(for: scopedKey)
        XCTAssertTrue(restored.isEmpty)
        XCTAssertTrue(records.isEmpty)
        XCTAssertNil(scopedToken)
    }

    func testDisconnectDuringRestoreMetadataRefreshCannotResurrectAccount() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let scopedKey = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let credentials = MockCredentialStore(values: [scopedKey: "stored-token"])
        let accountStore = SuspendedSuccessfulUpsertConnectedAccountStore(
            records: [account.connectedAccountRecord]
        )
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(userResults: [.success(account)]),
            credentials: credentials,
            accountStore: accountStore
        )
        let restore = Task { try await integration.restoreAccounts() }
        await accountStore.waitUntilUpsertBegins()

        try await integration.disconnect(accountID: account.connectedAccountID)
        await accountStore.finishUpsert()

        let restored = try await restore.value
        let records = await accountStore.accounts(for: .github)
        let scopedToken = await credentials.stringValue(for: scopedKey)
        XCTAssertTrue(restored.isEmpty)
        XCTAssertTrue(records.isEmpty)
        XCTAssertNil(scopedToken)
    }

    func testRestoreSnapshotCannotResurrectAccountDisconnectedBeforeItsValidation() async throws {
        let first = GitHubAccount(id: 7, login: "first", name: nil, avatarURL: nil)
        let second = GitHubAccount(id: 42, login: "second", name: nil, avatarURL: nil)
        let api = SequencedSuspendedUserGitHubAPI()
        let credentials = MockCredentialStore(values: [
            GitHubIntegration.credentialAccount(for: first.connectedAccountID): "first-token",
            GitHubIntegration.credentialAccount(for: second.connectedAccountID): "second-token",
        ])
        let accountStore = InMemoryConnectedAccountStore(records: [
            first.connectedAccountRecord,
            second.connectedAccountRecord,
        ])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            accountStore: accountStore
        )
        let viewModel = await MainActor.run { GitHubViewModel(integration: integration) }

        let initialRestore = Task { await viewModel.restore() }
        await api.waitForRequest(count: 1)
        await api.finishRequest(at: 0, with: .success(first))
        await api.waitForRequest(count: 2)
        await api.finishRequest(at: 1, with: .success(second))
        await initialRestore.value

        let refresh = Task { await viewModel.restore() }
        await api.waitForRequest(count: 3)
        await viewModel.disconnect(second.connectedAccountID)
        await api.finishRequest(at: 2, with: .success(first))
        await refresh.value

        let requestCount = await api.requestCount()
        let accounts = await MainActor.run { viewModel.accounts }
        let records = await accountStore.accounts(for: .github)
        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(accounts, [GitHubAccountConnection(account: first, state: .connected)])
        XCTAssertEqual(records, [first.connectedAccountRecord])
    }

    func testRestoreResultCannotResurrectAccountDisconnectedDuringLaterValidation() async throws {
        let first = GitHubAccount(id: 7, login: "first", name: nil, avatarURL: nil)
        let second = GitHubAccount(id: 42, login: "second", name: nil, avatarURL: nil)
        let api = SequencedSuspendedUserGitHubAPI()
        let credentials = MockCredentialStore(values: [
            GitHubIntegration.credentialAccount(for: first.connectedAccountID): "first-token",
            GitHubIntegration.credentialAccount(for: second.connectedAccountID): "second-token",
        ])
        let accountStore = InMemoryConnectedAccountStore(records: [
            first.connectedAccountRecord,
            second.connectedAccountRecord,
        ])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            accountStore: accountStore
        )
        let viewModel = await MainActor.run { GitHubViewModel(integration: integration) }

        let restore = Task { await viewModel.restore() }
        await api.waitForRequest(count: 1)
        await api.finishRequest(at: 0, with: .success(first))
        await api.waitForRequest(count: 2)

        await viewModel.disconnect(first.connectedAccountID)
        await api.finishRequest(at: 1, with: .success(second))
        await restore.value

        let accounts = await MainActor.run { viewModel.accounts }
        let records = await accountStore.accounts(for: .github)
        XCTAssertEqual(accounts, [GitHubAccountConnection(account: second, state: .connected)])
        XCTAssertEqual(records, [second.connectedAccountRecord])
    }

    func testMalformedPersistedAccountMetadataSurfacesStorageFailure() async throws {
        let suiteName = "GitHubIntegrationTests.account-store-corruption.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: UserDefaultsConnectedAccountStore.key)
        let accountStore = UserDefaultsConnectedAccountStore(
            defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName))
        )
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(),
            credentials: MockCredentialStore(),
            accountStore: accountStore
        )

        do {
            _ = try await integration.restoreAccounts()
            XCTFail("Expected account storage failure")
        } catch let error as GitHubConnectionError {
            XCTAssertEqual(error, .accountStorage)
        }
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

    func testUnrelatedReconnectCannotSuppressSuccessfulDisconnectPresentation() async throws {
        let first = GitHubAccount(id: 7, login: "first", name: nil, avatarURL: nil)
        let second = GitHubAccount(id: 42, login: "second", name: nil, avatarURL: nil)
        let firstKey = GitHubIntegration.credentialAccount(for: first.connectedAccountID)
        let secondKey = GitHubIntegration.credentialAccount(for: second.connectedAccountID)
        let credentials = SuspendedConditionalRemovalCredentialStore(values: [
            firstKey: "first-token",
            secondKey: "second-token",
        ])
        let accountStore = InMemoryConnectedAccountStore(records: [
            first.connectedAccountRecord,
            second.connectedAccountRecord,
        ])
        let api = StubGitHubAPI(
            deviceResults: [.failure(.server(503))],
            userResults: [.success(first), .success(second)]
        )
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            accountStore: accountStore
        )
        let (viewModel, openURL) = await MainActor.run {
            (
                GitHubViewModel(integration: integration),
                OpenURLAction { _ in .handled }
            )
        }
        await viewModel.restore()

        let disconnection = Task {
            await viewModel.disconnect(first.connectedAccountID)
        }
        await credentials.waitUntilConditionalRemovalBegins()

        await MainActor.run {
            viewModel.reconnect(second.connectedAccountID, openURL: openURL)
        }
        let reconnectAttempted = try await waitUntil {
            await api.deviceRequestCount() == 1
        }
        XCTAssertTrue(reconnectAttempted)
        await credentials.finishConditionalRemoval()
        await disconnection.value

        let accounts = await MainActor.run { viewModel.accounts }
        let records = await accountStore.accounts(for: .github)
        let firstToken = await credentials.stringValue(for: firstKey)
        let secondToken = await credentials.stringValue(for: secondKey)
        XCTAssertEqual(accounts, [GitHubAccountConnection(account: second, state: .connected)])
        XCTAssertEqual(records, [second.connectedAccountRecord])
        XCTAssertNil(firstToken)
        XCTAssertEqual(secondToken, "second-token")
    }

    func testUnrelatedDisconnectPreservesActiveAuthorizationPresentation() async throws {
        let first = GitHubAccount(id: 7, login: "first", name: nil, avatarURL: nil)
        let second = GitHubAccount(id: 42, login: "second", name: nil, avatarURL: nil)
        let firstKey = GitHubIntegration.credentialAccount(for: first.connectedAccountID)
        let secondKey = GitHubIntegration.credentialAccount(for: second.connectedAccountID)
        let api = MultiAccountSuspendedPollingGitHubAPI(first: first, second: second)
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: MockCredentialStore(values: [
                firstKey: "first-token",
                secondKey: "second-token",
            ]),
            accountStore: InMemoryConnectedAccountStore(records: [
                first.connectedAccountRecord,
                second.connectedAccountRecord,
            ]),
            sleep: { _ in }
        )
        let (viewModel, openURL) = await MainActor.run {
            (
                GitHubViewModel(integration: integration),
                OpenURLAction { _ in .handled }
            )
        }
        await viewModel.restore()

        await MainActor.run {
            viewModel.reconnect(first.connectedAccountID, openURL: openURL)
        }
        await api.waitUntilPollBegins()
        let revisionDuringReconnect = await MainActor.run {
            viewModel.dashboardRefreshRevision(for: first.connectedAccountID)
        }

        await viewModel.disconnect(second.connectedAccountID)

        let presentation = await MainActor.run {
            GitHubView(viewModel: viewModel, accountID: first.connectedAccountID).presentationState
        }
        XCTAssertEqual(revisionDuringReconnect, 1)
        XCTAssertEqual(presentation, .authorizing(testAuthorization))
        await api.finishPoll()
    }

    func testReconnectRevisionAdvancesWhenAuthorizationIsCanceled() async throws {
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

        await MainActor.run {
            viewModel.reconnect(account.connectedAccountID, openURL: openURL)
        }
        let pollingStarted = try await waitUntil {
            await api.pollDidStart()
        }
        XCTAssertTrue(pollingStarted)
        let reconnectRevision = await MainActor.run {
            viewModel.dashboardRefreshRevision(for: account.connectedAccountID)
        }
        await MainActor.run { viewModel.cancelAccountAuthorization() }
        let canceledRevision = await MainActor.run {
            viewModel.dashboardRefreshRevision(for: account.connectedAccountID)
        }

        XCTAssertEqual(reconnectRevision, 1)
        XCTAssertEqual(canceledRevision, 2)
        await api.finishPoll()
    }

    func testUnauthorizedRefreshCannotDeleteTokenReplacedByReconnect() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let credentialAccount = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let credentials = SuspendedConditionalRemovalCredentialStore(
            values: [credentialAccount: "old-token"]
        )
        let accountStore = InMemoryConnectedAccountStore(records: [account.connectedAccountRecord])
        let api = RefreshThenReconnectGitHubAPI(account: account)
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            accountStore: accountStore,
            sleep: { _ in }
        )
        let refresh = Task {
            try await integration.authoredPullRequests(for: account)
        }
        await api.waitUntilRefreshBegins()
        await api.finishRefreshAsUnauthorized()
        await credentials.waitUntilConditionalRemovalBegins()

        let authorization = try await integration.beginAccountAuthorization(
            reconnecting: account.connectedAccountID
        )
        _ = try await integration.completeAccountAuthorization(authorization)
        await credentials.finishConditionalRemoval()

        do {
            _ = try await refresh.value
            XCTFail("Expected the stale refresh to be superseded")
        } catch is CancellationError {
            // Expected: reconnect replaced the credential used by the request.
        }
        let storedToken = await credentials.stringValue(for: credentialAccount)
        XCTAssertEqual(storedToken, "new-token")
    }

    func testReconnectStartedDuringDisconnectPreservesReplacementTokenAndRecord() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let credentialAccount = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let credentials = SuspendedConditionalRemovalCredentialStore(
            values: [credentialAccount: "old-token"]
        )
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

        let disconnection = Task {
            try await integration.disconnect(accountID: account.connectedAccountID)
        }
        await credentials.waitUntilConditionalRemovalBegins()

        let authorization = try await integration.beginAccountAuthorization(
            reconnecting: account.connectedAccountID
        )
        let reconnected = try await integration.completeAccountAuthorization(authorization)
        await credentials.finishConditionalRemoval()

        do {
            try await disconnection.value
            XCTFail("Expected the reconnect to supersede the older disconnect")
        } catch is CancellationError {
            // Expected.
        }
        let storedToken = await credentials.stringValue(for: credentialAccount)
        let records = await accountStore.accounts(for: .github)
        XCTAssertEqual(reconnected, GitHubAccountConnection(account: account, state: .connected))
        XCTAssertEqual(storedToken, "new-token")
        XCTAssertEqual(records, [account.connectedAccountRecord])
    }

    func testDisconnectDuringAuthorizationSnapshotCannotWriteOrphanedCredential() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let credentialAccount = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let credentials = SuspendedFirstReadCredentialStore(
            values: [credentialAccount: "old-token"]
        )
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
        await credentials.waitUntilFirstReadBegins()

        try await integration.disconnect(accountID: account.connectedAccountID)
        await credentials.finishFirstRead()

        do {
            _ = try await completion.value
            XCTFail("Expected disconnect to supersede the authorization snapshot")
        } catch is CancellationError {
            // Expected.
        }
        let storedToken = await credentials.stringValue(for: credentialAccount)
        let records = await accountStore.accounts(for: .github)
        XCTAssertNil(storedToken)
        XCTAssertTrue(records.isEmpty)
    }

    func testDisconnectRejectsOlderUntargetedAuthorizationCompletion() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let credentialAccount = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let credentials = MockCredentialStore(values: [credentialAccount: "old-token"])
        let accountStore = InMemoryConnectedAccountStore(records: [account.connectedAccountRecord])
        let api = SuspendedAuthorizationUserGitHubAPI(account: account)
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: api,
            credentials: credentials,
            accountStore: accountStore,
            sleep: { _ in }
        )
        let authorization = try await integration.beginAccountAuthorization()
        let completion = Task {
            try await integration.completeAccountAuthorization(authorization)
        }
        await api.waitUntilUserRequestBegins()

        try await integration.disconnect(accountID: account.connectedAccountID)
        await api.finishUserRequest()

        do {
            _ = try await completion.value
            XCTFail("Expected the later disconnect to supersede add-account completion")
        } catch is CancellationError {
            // Expected.
        }
        let storedToken = await credentials.stringValue(for: credentialAccount)
        let records = await accountStore.accounts(for: .github)
        XCTAssertNil(storedToken)
        XCTAssertTrue(records.isEmpty)
    }

    func testCanceledReconnectSupersedesDisconnectAndRestoresOriginalAccount() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let credentialAccount = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let credentials = SuspendedConditionalRemovalCredentialStore(
            values: [credentialAccount: "old-token"]
        )
        let accountStore = InMemoryConnectedAccountStore(records: [account.connectedAccountRecord])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(deviceResults: [.success(testAuthorization)]),
            credentials: credentials,
            accountStore: accountStore
        )

        let disconnection = Task {
            try await integration.disconnect(accountID: account.connectedAccountID)
        }
        await credentials.waitUntilConditionalRemovalBegins()

        let authorization = try await integration.beginAccountAuthorization(
            reconnecting: account.connectedAccountID
        )
        await integration.cancelAccountAuthorization(authorization)
        await credentials.finishConditionalRemoval()

        do {
            try await disconnection.value
            XCTFail("Expected reconnect intent to supersede the older disconnect")
        } catch is CancellationError {
            // Expected.
        }
        let storedToken = await credentials.stringValue(for: credentialAccount)
        let records = await accountStore.accounts(for: .github)
        XCTAssertEqual(storedToken, "old-token")
        XCTAssertEqual(records, [account.connectedAccountRecord])
    }

    func testNewerDisconnectDuringRollbackCannotRestoreOrphanedCredential() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let credentialAccount = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let credentials = SuspendedConditionalRemovalCredentialStore(
            values: [credentialAccount: "old-token"]
        )
        let accountStore = SuspendedRestoreConnectedAccountStore(
            records: [account.connectedAccountRecord]
        )
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(deviceResults: [.success(testAuthorization)]),
            credentials: credentials,
            accountStore: accountStore
        )
        let olderDisconnect = Task {
            try await integration.disconnect(accountID: account.connectedAccountID)
        }
        await credentials.waitUntilConditionalRemovalBegins()

        let authorization = try await integration.beginAccountAuthorization(
            reconnecting: account.connectedAccountID
        )
        await integration.cancelAccountAuthorization(authorization)
        await credentials.finishConditionalRemoval()
        await accountStore.waitUntilRestoreBegins()

        try await integration.disconnect(accountID: account.connectedAccountID)
        await accountStore.finishRestore()

        do {
            try await olderDisconnect.value
            XCTFail("Expected the reconnect intent to supersede the older disconnect")
        } catch is CancellationError {
            // Expected.
        }
        let storedToken = await credentials.stringValue(for: credentialAccount)
        let records = await accountStore.accounts(for: .github)
        XCTAssertNil(storedToken)
        XCTAssertTrue(records.isEmpty)
    }

    func testCredentialDeletionFailureRestoresRemovedAccountMetadata() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let credentialAccount = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let credentials = FailingConditionalRemovalCredentialStore(
            values: [credentialAccount: "stored-token"]
        )
        let accountStore = InMemoryConnectedAccountStore(records: [account.connectedAccountRecord])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(),
            credentials: credentials,
            accountStore: accountStore
        )

        do {
            try await integration.disconnect(accountID: account.connectedAccountID)
            XCTFail("Expected credential deletion failure")
        } catch let error as GitHubConnectionError {
            XCTAssertEqual(error, .credentialStorage)
        }

        let storedToken = await credentials.stringValue(for: credentialAccount)
        let records = await accountStore.accounts(for: .github)
        XCTAssertEqual(storedToken, "stored-token")
        XCTAssertEqual(records, [account.connectedAccountRecord])
    }

    func testRevokedCredentialDeletionFailureKeepsAccountVisibleForRecovery() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let credentialAccount = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let credentials = FailingConditionalRemovalCredentialStore(
            values: [credentialAccount: "revoked-token"]
        )
        let accountStore = InMemoryConnectedAccountStore(records: [account.connectedAccountRecord])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(userResults: [.failure(.unauthorized)]),
            credentials: credentials,
            accountStore: accountStore
        )

        let restored = try await integration.restoreAccounts()

        XCTAssertEqual(
            restored,
            [
                GitHubAccountConnection(
                    account: account,
                    state: .needsAttention,
                    message: GitHubConnectionError.credentialStorage.localizedDescription,
                    recoveryAction: .validate
                ),
            ]
        )
        let storedToken = await credentials.stringValue(for: credentialAccount)
        let records = await accountStore.accounts(for: .github)
        XCTAssertEqual(storedToken, "revoked-token")
        XCTAssertEqual(records, [account.connectedAccountRecord])
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

    func testDisconnectWhileCredentialWriteIsDelayedRemovesOrphanedToken() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let credentialAccount = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let credentials = SuspendedDelayedSetCredentialStore(
            values: [credentialAccount: "old-token"]
        )
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
            XCTFail("Expected disconnect to supersede the delayed credential write")
        } catch is CancellationError {
            // Expected.
        }
        let storedToken = await credentials.stringValue(for: credentialAccount)
        let records = await accountStore.accounts(for: .github)
        XCTAssertNil(storedToken)
        XCTAssertTrue(records.isEmpty)
    }

    func testDisconnectWhileAccountWriteIsDelayedRemovesOrphanedMetadata() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let credentialAccount = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let credentials = MockCredentialStore()
        let accountStore = SuspendedSuccessfulUpsertConnectedAccountStore()
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
        let authorization = try await integration.beginAccountAuthorization()
        let completion = Task {
            try await integration.completeAccountAuthorization(authorization)
        }
        await accountStore.waitUntilUpsertBegins()

        try await integration.disconnect(accountID: account.connectedAccountID)
        await accountStore.finishUpsert()

        do {
            _ = try await completion.value
            XCTFail("Expected disconnect to supersede the delayed account write")
        } catch is CancellationError {
            // Expected.
        }
        let storedToken = await credentials.stringValue(for: credentialAccount)
        let records = await accountStore.accounts(for: .github)
        XCTAssertNil(storedToken)
        XCTAssertTrue(records.isEmpty)
    }

    func testCanceledReconnectSupersedingDelayedAddRemovesOrphanedMetadata() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let credentialAccount = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let credentials = MockCredentialStore()
        let accountStore = SuspendedSuccessfulUpsertConnectedAccountStore()
        let secondAuthorization = GitHubBrowserAuthorization(
            id: UUID(),
            authorizationURL: testAuthorization.authorizationURL
        )
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(
                deviceResults: [.success(testAuthorization), .success(secondAuthorization)],
                pollResults: [.success(.authorized(token: "first-token"))],
                userResults: [.success(account)]
            ),
            credentials: credentials,
            accountStore: accountStore,
            sleep: { _ in }
        )
        let firstAuthorization = try await integration.beginAccountAuthorization()
        let firstCompletion = Task {
            try await integration.completeAccountAuthorization(firstAuthorization)
        }
        await accountStore.waitUntilUpsertBegins()

        let supersedingAuthorization = try await integration.beginAccountAuthorization(
            reconnecting: account.connectedAccountID
        )
        await integration.cancelAccountAuthorization(supersedingAuthorization)
        await accountStore.finishUpsert()

        do {
            _ = try await firstCompletion.value
            XCTFail("Expected the reconnect to supersede the delayed add")
        } catch is CancellationError {
            // Expected.
        }
        let storedToken = await credentials.stringValue(for: credentialAccount)
        let records = await accountStore.accounts(for: .github)
        XCTAssertNil(storedToken)
        XCTAssertTrue(records.isEmpty)
    }

    func testStaleAuthorizationRollbackCannotOverwriteNewerReconnect() async throws {
        let original = GitHubAccount(id: 42, login: "original", name: nil, avatarURL: nil)
        let failedAttempt = GitHubAccount(id: 42, login: "failed-attempt", name: nil, avatarURL: nil)
        let latest = GitHubAccount(id: 42, login: "latest", name: nil, avatarURL: nil)
        let credentialAccount = GitHubIntegration.credentialAccount(for: original.connectedAccountID)
        let credentials = SuspendedRollbackCredentialStore(
            values: [credentialAccount: "old-token"]
        )
        let accountStore = FailFirstUpsertConnectedAccountStore(
            records: [original.connectedAccountRecord]
        )
        let secondAuthorization = GitHubBrowserAuthorization(
            id: UUID(),
            authorizationURL: testAuthorization.authorizationURL
        )
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(
                deviceResults: [.success(testAuthorization), .success(secondAuthorization)],
                pollResults: [
                    .success(.authorized(token: "failed-token")),
                    .success(.authorized(token: "latest-token")),
                ],
                userResults: [.success(failedAttempt), .success(latest)]
            ),
            credentials: credentials,
            accountStore: accountStore,
            sleep: { _ in }
        )
        let firstAuthorization = try await integration.beginAccountAuthorization(
            reconnecting: original.connectedAccountID
        )
        let failedCompletion = Task {
            try await integration.completeAccountAuthorization(firstAuthorization)
        }
        await credentials.waitUntilRollbackBegins()

        let currentAuthorization = try await integration.beginAccountAuthorization(
            reconnecting: original.connectedAccountID
        )
        _ = try await integration.completeAccountAuthorization(currentAuthorization)
        await credentials.finishRollback()

        do {
            _ = try await failedCompletion.value
            XCTFail("Expected the first persistence attempt to fail")
        } catch let error as GitHubConnectionError {
            XCTAssertEqual(error, .credentialStorage)
        }
        let storedToken = await credentials.stringValue(for: credentialAccount)
        let records = await accountStore.accounts(for: .github)
        XCTAssertEqual(storedToken, "latest-token")
        XCTAssertEqual(records, [latest.connectedAccountRecord])
    }

    func testSupersededPersistenceFailureRemovesItsCredential() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let credentialAccount = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let credentials = MockCredentialStore()
        let accountStore = SuspendedFailingUpsertConnectedAccountStore()
        let secondAuthorization = GitHubBrowserAuthorization(
            id: UUID(),
            authorizationURL: testAuthorization.authorizationURL
        )
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(
                deviceResults: [.success(testAuthorization), .success(secondAuthorization)],
                pollResults: [.success(.authorized(token: "orphaned-token"))],
                userResults: [.success(account)]
            ),
            credentials: credentials,
            accountStore: accountStore,
            sleep: { _ in }
        )
        let authorization = try await integration.beginAccountAuthorization()
        let completion = Task {
            try await integration.completeAccountAuthorization(authorization)
        }
        await accountStore.waitUntilUpsertBegins()

        let supersedingAuthorization = try await integration.beginAccountAuthorization(
            reconnecting: account.connectedAccountID
        )
        await integration.cancelAccountAuthorization(supersedingAuthorization)
        await accountStore.finishUpsert()

        do {
            _ = try await completion.value
            XCTFail("Expected account persistence failure")
        } catch let error as GitHubConnectionError {
            XCTAssertEqual(error, .credentialStorage)
        }
        let storedToken = await credentials.stringValue(for: credentialAccount)
        let records = await accountStore.accounts(for: .github)
        XCTAssertNil(storedToken)
        XCTAssertTrue(records.isEmpty)
    }

    func testSupersededPersistenceCleanupFailureKeepsAccountVisibleForRecovery() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let credentialAccount = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let credentials = FailingConditionalRemovalCredentialStore(values: [:])
        let accountStore = SuspendedFailingUpsertConnectedAccountStore()
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(
                deviceResults: [.success(testAuthorization)],
                pollResults: [.success(.authorized(token: "recoverable-token"))],
                userResults: [.success(account)]
            ),
            credentials: credentials,
            accountStore: accountStore,
            sleep: { _ in }
        )
        let authorization = try await integration.beginAccountAuthorization()
        let completion = Task {
            try await integration.completeAccountAuthorization(authorization)
        }
        await accountStore.waitUntilUpsertBegins()

        do {
            try await integration.disconnect(accountID: account.connectedAccountID)
            XCTFail("Expected disconnect credential cleanup to fail")
        } catch let error as GitHubConnectionError {
            XCTAssertEqual(error, .credentialStorage)
        }
        await accountStore.finishUpsert()

        do {
            _ = try await completion.value
            XCTFail("Expected account persistence to fail")
        } catch let error as GitHubConnectionError {
            XCTAssertEqual(error, .credentialStorage)
        }
        let storedToken = await credentials.stringValue(for: credentialAccount)
        let records = await accountStore.accounts(for: .github)
        XCTAssertEqual(storedToken, "recoverable-token")
        XCTAssertEqual(records, [account.connectedAccountRecord])
    }

    func testNewerDisconnectPreventsOlderDisconnectFromRestoringAccount() async throws {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let credentialAccount = GitHubIntegration.credentialAccount(for: account.connectedAccountID)
        let credentials = SuspendedPostRemovalCredentialStore(
            values: [credentialAccount: "stored-token"]
        )
        let accountStore = InMemoryConnectedAccountStore(records: [account.connectedAccountRecord])
        let integration = GitHubIntegration(
            clientID: "client-id",
            api: StubGitHubAPI(),
            credentials: credentials,
            accountStore: accountStore
        )
        let olderDisconnect = Task {
            try await integration.disconnect(accountID: account.connectedAccountID)
        }
        await credentials.waitUntilFirstRemovalCompletes()

        try await integration.disconnect(accountID: account.connectedAccountID)
        await credentials.finishFirstRemoval()

        do {
            try await olderDisconnect.value
            XCTFail("Expected the newer disconnect to supersede the older operation")
        } catch is CancellationError {
            // Expected.
        }
        let storedToken = await credentials.stringValue(for: credentialAccount)
        let records = await accountStore.accounts(for: .github)
        XCTAssertNil(storedToken)
        XCTAssertTrue(records.isEmpty)
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

    func removeData(for account: String, ifMatches expectedData: Data) -> Bool {
        guard values[account] == expectedData else { return false }
        values.removeValue(forKey: account)
        return true
    }

    func stringValue() -> String? {
        let value = values["github.oauth-token"] ?? values.values.first
        return value.flatMap { String(data: $0, encoding: .utf8) }
    }

    func stringValue(for account: String) -> String? {
        values[account].flatMap { String(data: $0, encoding: .utf8) }
    }
}

private actor SuspendedConditionalRemovalCredentialStore: CredentialStoring {
    private var values: [String: Data]
    private var removalStartedWaiter: CheckedContinuation<Void, Never>?
    private var removalCompletion: CheckedContinuation<Void, Never>?

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

    func removeData(for account: String, ifMatches expectedData: Data) async -> Bool {
        guard values[account] == expectedData else { return false }
        removalStartedWaiter?.resume()
        removalStartedWaiter = nil
        await withCheckedContinuation { continuation in
            removalCompletion = continuation
        }
        guard values[account] == expectedData else { return false }
        values.removeValue(forKey: account)
        return true
    }

    func waitUntilConditionalRemovalBegins() async {
        guard removalCompletion == nil else { return }
        await withCheckedContinuation { continuation in
            removalStartedWaiter = continuation
        }
    }

    func finishConditionalRemoval() {
        removalCompletion?.resume()
        removalCompletion = nil
    }

    func stringValue(for account: String) -> String? {
        values[account].flatMap { String(data: $0, encoding: .utf8) }
    }
}

private actor SuspendedFirstReadCredentialStore: CredentialStoring {
    private var values: [String: Data]
    private var didSuspendRead = false
    private var readStartedWaiter: CheckedContinuation<Void, Never>?
    private var readCompletion: CheckedContinuation<Void, Never>?

    init(values: [String: String]) {
        self.values = values.mapValues { Data($0.utf8) }
    }

    func set(_ data: Data, for account: String) {
        values[account] = data
    }

    func data(for account: String) async -> Data? {
        let captured = values[account]
        if !didSuspendRead, captured != nil {
            didSuspendRead = true
            readStartedWaiter?.resume()
            readStartedWaiter = nil
            await withCheckedContinuation { continuation in
                readCompletion = continuation
            }
        }
        return captured
    }

    func removeData(for account: String) {
        values.removeValue(forKey: account)
    }

    func removeData(for account: String, ifMatches expectedData: Data) -> Bool {
        guard values[account] == expectedData else { return false }
        values.removeValue(forKey: account)
        return true
    }

    func waitUntilFirstReadBegins() async {
        guard readCompletion == nil else { return }
        await withCheckedContinuation { continuation in
            readStartedWaiter = continuation
        }
    }

    func finishFirstRead() {
        readCompletion?.resume()
        readCompletion = nil
    }

    func stringValue(for account: String) -> String? {
        values[account].flatMap { String(data: $0, encoding: .utf8) }
    }
}

private actor SuspendedDelayedSetCredentialStore: CredentialStoring {
    private var values: [String: Data]
    private var didSuspendSet = false
    private var setStartedWaiter: CheckedContinuation<Void, Never>?
    private var setCompletion: CheckedContinuation<Void, Never>?

    init(values: [String: String]) {
        self.values = values.mapValues { Data($0.utf8) }
    }

    func set(_ data: Data, for account: String) async {
        if !didSuspendSet {
            didSuspendSet = true
            setStartedWaiter?.resume()
            setStartedWaiter = nil
            await withCheckedContinuation { continuation in
                setCompletion = continuation
            }
        }
        values[account] = data
    }

    func data(for account: String) -> Data? {
        values[account]
    }

    func removeData(for account: String) {
        values.removeValue(forKey: account)
    }

    func removeData(for account: String, ifMatches expectedData: Data) -> Bool {
        guard values[account] == expectedData else { return false }
        values.removeValue(forKey: account)
        return true
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

    func stringValue(for account: String) -> String? {
        values[account].flatMap { String(data: $0, encoding: .utf8) }
    }
}

private actor SuspendedRollbackCredentialStore: CredentialStoring {
    private var values: [String: Data]
    private var didSuspendRollback = false
    private var rollbackStartedWaiter: CheckedContinuation<Void, Never>?
    private var rollbackCompletion: CheckedContinuation<Void, Never>?

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

    func removeData(for account: String, ifMatches expectedData: Data) -> Bool {
        guard values[account] == expectedData else { return false }
        values.removeValue(forKey: account)
        return true
    }

    func replaceData(
        for account: String,
        ifMatches expectedData: Data,
        with replacementData: Data?
    ) async -> Bool {
        guard values[account] == expectedData else { return false }
        values[account] = replacementData
        if !didSuspendRollback {
            didSuspendRollback = true
            rollbackStartedWaiter?.resume()
            rollbackStartedWaiter = nil
            await withCheckedContinuation { continuation in
                rollbackCompletion = continuation
            }
        }
        return true
    }

    func waitUntilRollbackBegins() async {
        guard rollbackCompletion == nil else { return }
        await withCheckedContinuation { continuation in
            rollbackStartedWaiter = continuation
        }
    }

    func finishRollback() {
        rollbackCompletion?.resume()
        rollbackCompletion = nil
    }

    func stringValue(for account: String) -> String? {
        values[account].flatMap { String(data: $0, encoding: .utf8) }
    }
}

private actor SuspendedPostRemovalCredentialStore: CredentialStoring {
    private var values: [String: Data]
    private var didSuspendRemoval = false
    private var removalCompletedWaiter: CheckedContinuation<Void, Never>?
    private var removalCompletion: CheckedContinuation<Void, Never>?

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

    func removeData(for account: String, ifMatches expectedData: Data) async -> Bool {
        guard values[account] == expectedData else { return false }
        values.removeValue(forKey: account)
        if !didSuspendRemoval {
            didSuspendRemoval = true
            removalCompletedWaiter?.resume()
            removalCompletedWaiter = nil
            await withCheckedContinuation { continuation in
                removalCompletion = continuation
            }
        }
        return true
    }

    func waitUntilFirstRemovalCompletes() async {
        guard removalCompletion == nil else { return }
        await withCheckedContinuation { continuation in
            removalCompletedWaiter = continuation
        }
    }

    func finishFirstRemoval() {
        removalCompletion?.resume()
        removalCompletion = nil
    }

    func stringValue(for account: String) -> String? {
        values[account].flatMap { String(data: $0, encoding: .utf8) }
    }
}

private actor SuspendedRestoreConnectedAccountStore: ConnectedAccountStoring {
    private var records: [ConnectedAccountRecord]
    private var didSuspendRestore = false
    private var restoreStartedWaiter: CheckedContinuation<Void, Never>?
    private var restoreCompletion: CheckedContinuation<Void, Never>?

    init(records: [ConnectedAccountRecord]) {
        self.records = records
    }

    func accounts(for provider: IntegrationProvider) -> [ConnectedAccountRecord] {
        records.filter { $0.id.provider == provider }.sorted { $0.id < $1.id }
    }

    func upsert(_ account: ConnectedAccountRecord) {
        records.removeAll { $0.id == account.id }
        records.append(account)
    }

    func upsertIfMissing(_ account: ConnectedAccountRecord) async -> Bool {
        guard !records.contains(where: { $0.id == account.id }) else { return false }
        records.append(account)
        if !didSuspendRestore {
            didSuspendRestore = true
            restoreStartedWaiter?.resume()
            restoreStartedWaiter = nil
            await withCheckedContinuation { continuation in
                restoreCompletion = continuation
            }
        }
        return true
    }

    func replace(
        _ expected: ConnectedAccountRecord,
        with replacement: ConnectedAccountRecord?
    ) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == expected.id }),
              records[index] == expected
        else {
            return false
        }
        if let replacement {
            records[index] = replacement
        } else {
            records.remove(at: index)
        }
        return true
    }

    func remove(_ id: ConnectedAccountID) {
        records.removeAll { $0.id == id }
    }

    func waitUntilRestoreBegins() async {
        guard restoreCompletion == nil else { return }
        await withCheckedContinuation { continuation in
            restoreStartedWaiter = continuation
        }
    }

    func finishRestore() {
        restoreCompletion?.resume()
        restoreCompletion = nil
    }
}

private actor FailFirstUpsertConnectedAccountStore: ConnectedAccountStoring {
    enum StoreError: Error {
        case firstUpsertFailed
    }

    private var records: [ConnectedAccountRecord]
    private var shouldFailUpsert = true

    init(records: [ConnectedAccountRecord]) {
        self.records = records
    }

    func accounts(for provider: IntegrationProvider) -> [ConnectedAccountRecord] {
        records.filter { $0.id.provider == provider }.sorted { $0.id < $1.id }
    }

    func upsert(_ account: ConnectedAccountRecord) throws {
        records.removeAll { $0.id == account.id }
        records.append(account)
        if shouldFailUpsert {
            shouldFailUpsert = false
            throw StoreError.firstUpsertFailed
        }
    }

    func upsertIfMissing(_ account: ConnectedAccountRecord) -> Bool {
        guard !records.contains(where: { $0.id == account.id }) else { return false }
        records.append(account)
        return true
    }

    func replace(
        _ expected: ConnectedAccountRecord,
        with replacement: ConnectedAccountRecord?
    ) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == expected.id }),
              records[index] == expected
        else {
            return false
        }
        if let replacement {
            records[index] = replacement
        } else {
            records.remove(at: index)
        }
        return true
    }

    func remove(_ id: ConnectedAccountID) {
        records.removeAll { $0.id == id }
    }
}

private actor SuspendedFailingUpsertConnectedAccountStore: ConnectedAccountStoring {
    enum StoreError: Error {
        case upsertFailed
    }

    private var records: [ConnectedAccountRecord] = []
    private var upsertStartedWaiter: CheckedContinuation<Void, Never>?
    private var upsertCompletion: CheckedContinuation<Void, Never>?

    init(records: [ConnectedAccountRecord] = []) {
        self.records = records
    }

    func accounts(for provider: IntegrationProvider) -> [ConnectedAccountRecord] {
        records.filter { $0.id.provider == provider }.sorted { $0.id < $1.id }
    }

    func upsert(_ account: ConnectedAccountRecord) async throws {
        upsertStartedWaiter?.resume()
        upsertStartedWaiter = nil
        await withCheckedContinuation { continuation in
            upsertCompletion = continuation
        }
        throw StoreError.upsertFailed
    }

    func upsertIfMissing(_ account: ConnectedAccountRecord) -> Bool {
        guard !records.contains(where: { $0.id == account.id }) else { return false }
        records.append(account)
        return true
    }

    func replace(
        _ expected: ConnectedAccountRecord,
        with replacement: ConnectedAccountRecord?
    ) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == expected.id }),
              records[index] == expected
        else {
            return false
        }
        if let replacement {
            records[index] = replacement
        } else {
            records.remove(at: index)
        }
        return true
    }

    func remove(_ id: ConnectedAccountID) {
        records.removeAll { $0.id == id }
    }

    func waitUntilUpsertBegins() async {
        guard upsertCompletion == nil else { return }
        await withCheckedContinuation { continuation in
            upsertStartedWaiter = continuation
        }
    }

    func finishUpsert() {
        upsertCompletion?.resume()
        upsertCompletion = nil
    }
}

private actor SuspendedSuccessfulUpsertConnectedAccountStore: ConnectedAccountStoring {
    private var records: [ConnectedAccountRecord]
    private var upsertIsSuspended = false
    private var upsertStartedWaiter: CheckedContinuation<Void, Never>?
    private var upsertCompletion: CheckedContinuation<Void, Never>?

    init(records: [ConnectedAccountRecord] = []) {
        self.records = records
    }

    func accounts(for provider: IntegrationProvider) -> [ConnectedAccountRecord] {
        records.filter { $0.id.provider == provider }.sorted { $0.id < $1.id }
    }

    func upsert(_ account: ConnectedAccountRecord) async {
        upsertIsSuspended = true
        upsertStartedWaiter?.resume()
        upsertStartedWaiter = nil
        await withCheckedContinuation { continuation in
            upsertCompletion = continuation
        }
        records.removeAll { $0.id == account.id }
        records.append(account)
    }

    func upsertIfMissing(_ account: ConnectedAccountRecord) -> Bool {
        guard !records.contains(where: { $0.id == account.id }) else { return false }
        records.append(account)
        return true
    }

    func replace(
        _ expected: ConnectedAccountRecord,
        with replacement: ConnectedAccountRecord?
    ) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == expected.id }),
              records[index] == expected
        else {
            return false
        }
        if let replacement {
            records[index] = replacement
        } else {
            records.remove(at: index)
        }
        return true
    }

    func remove(_ id: ConnectedAccountID) {
        records.removeAll { $0.id == id }
    }

    func waitUntilUpsertBegins() async {
        guard !upsertIsSuspended else { return }
        await withCheckedContinuation { continuation in
            upsertStartedWaiter = continuation
        }
    }

    func finishUpsert() {
        upsertCompletion?.resume()
        upsertCompletion = nil
    }
}

private actor FailingConditionalRemovalCredentialStore: CredentialStoring {
    enum StoreError: Error {
        case removalFailed
    }

    private var values: [String: Data]

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

    func removeData(for account: String, ifMatches expectedData: Data) throws -> Bool {
        guard values[account] == expectedData else { return false }
        throw StoreError.removalFailed
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

private let testAuthorization = GitHubBrowserAuthorization(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    authorizationURL: URL(string: "https://github.com/login/oauth/authorize")!
)

private struct PullRequestRequest: Equatable, Sendable {
    let login: String
    let token: String
}

private enum GitHubTokenPollResult: Equatable, Sendable {
    case pending
    case slowDown(interval: Int?)
    case authorized(token: String)
}

private actor StubGitHubAPI: GitHubAPIProviding, GitHubOAuthAuthorizing {
    private var deviceResults: [Result<GitHubBrowserAuthorization, GitHubAPIError>]
    private var pollResults: [Result<GitHubTokenPollResult, GitHubAPIError>]
    private var userResults: [Result<GitHubAccount, GitHubAPIError>]
    private var pullRequestResults: [Result<GitHubPullRequestCollection, GitHubAPIError>]
    private var assignedPullRequestResults: [Result<GitHubPullRequestCollection, GitHubAPIError>]
    private var capturedUserTokens: [String] = []
    private var capturedPullRequestRequests: [PullRequestRequest] = []
    private var capturedAssignedPullRequestRequests: [PullRequestRequest] = []
    private var capturedDeviceRequestCount = 0
    private var capturedPollRequestCount = 0
    private var capturedCanceledAuthorizations: [GitHubBrowserAuthorization] = []

    init(
        deviceResults: [Result<GitHubBrowserAuthorization, GitHubAPIError>] = [],
        pollResults: [Result<GitHubTokenPollResult, GitHubAPIError>] = [],
        userResults: [Result<GitHubAccount, GitHubAPIError>] = [],
        pullRequestResults: [Result<GitHubPullRequestCollection, GitHubAPIError>] = [],
        assignedPullRequestResults: [Result<GitHubPullRequestCollection, GitHubAPIError>] = []
    ) {
        self.deviceResults = deviceResults
        self.pollResults = pollResults
        self.userResults = userResults
        self.pullRequestResults = pullRequestResults
        self.assignedPullRequestResults = assignedPullRequestResults
    }

    func beginAuthorization(configuration: GitHubOAuthConfiguration) throws -> GitHubBrowserAuthorization {
        capturedDeviceRequestCount += 1
        return try deviceResults.removeFirst().get()
    }

    func completeAuthorization(_ authorization: GitHubBrowserAuthorization) throws -> String {
        while !pollResults.isEmpty {
            capturedPollRequestCount += 1
            switch try pollResults.removeFirst().get() {
            case .pending, .slowDown:
                continue
            case let .authorized(token):
                return token
            }
        }
        throw GitHubAPIError.malformedResponse
    }

    func cancelAuthorization(_ authorization: GitHubBrowserAuthorization) {
        capturedCanceledAuthorizations.append(authorization)
    }

    func authenticatedUser(token: String) throws -> GitHubAccount {
        capturedUserTokens.append(token)
        return try userResults.removeFirst().get()
    }

    func authoredPullRequests(login: String, token: String) throws -> GitHubPullRequestCollection {
        capturedPullRequestRequests.append(PullRequestRequest(login: login, token: token))
        return try pullRequestResults.removeFirst().get()
    }

    func assignedPullRequests(login: String, token: String) throws -> GitHubPullRequestCollection {
        capturedAssignedPullRequestRequests.append(PullRequestRequest(login: login, token: token))
        return try assignedPullRequestResults.removeFirst().get()
    }

    func userTokens() -> [String] {
        capturedUserTokens
    }

    func pullRequestRequests() -> [PullRequestRequest] {
        capturedPullRequestRequests
    }

    func assignedPullRequestRequests() -> [PullRequestRequest] {
        capturedAssignedPullRequestRequests
    }

    func deviceRequestCount() -> Int {
        capturedDeviceRequestCount
    }

    func pollRequestCount() -> Int {
        capturedPollRequestCount
    }

    func canceledAuthorizations() -> [GitHubBrowserAuthorization] {
        capturedCanceledAuthorizations
    }
}

private actor RefreshThenReconnectGitHubAPI: GitHubAPIProviding, GitHubOAuthAuthorizing {
    private let account: GitHubAccount
    private var refreshStartedWaiter: CheckedContinuation<Void, Never>?
    private var refreshCompletion: CheckedContinuation<Void, Never>?

    init(account: GitHubAccount) {
        self.account = account
    }

    func beginAuthorization(configuration: GitHubOAuthConfiguration) -> GitHubBrowserAuthorization {
        testAuthorization
    }

    func completeAuthorization(_ authorization: GitHubBrowserAuthorization) -> String {
        "new-token"
    }

    func cancelAuthorization(_ authorization: GitHubBrowserAuthorization) {}

    func authenticatedUser(token: String) -> GitHubAccount {
        account
    }

    func authoredPullRequests(login: String, token: String) async throws -> GitHubPullRequestCollection {
        refreshStartedWaiter?.resume()
        refreshStartedWaiter = nil
        await withCheckedContinuation { continuation in
            refreshCompletion = continuation
        }
        throw GitHubAPIError.unauthorized
    }

    func waitUntilRefreshBegins() async {
        guard refreshCompletion == nil else { return }
        await withCheckedContinuation { continuation in
            refreshStartedWaiter = continuation
        }
    }

    func finishRefreshAsUnauthorized() {
        refreshCompletion?.resume()
        refreshCompletion = nil
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

private actor SuspendedAuthorizationUserGitHubAPI: GitHubAPIProviding, GitHubOAuthAuthorizing {
    private let account: GitHubAccount
    private var userRequestWaiter: CheckedContinuation<Void, Never>?
    private var userRequestCompletion: CheckedContinuation<Void, Never>?

    init(account: GitHubAccount) {
        self.account = account
    }

    func beginAuthorization(configuration: GitHubOAuthConfiguration) -> GitHubBrowserAuthorization {
        testAuthorization
    }

    func completeAuthorization(_ authorization: GitHubBrowserAuthorization) -> String {
        "new-token"
    }

    func cancelAuthorization(_ authorization: GitHubBrowserAuthorization) {}

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

private actor ReconnectionGitHubAPI: GitHubAPIProviding, GitHubOAuthAuthorizing {
    private let account: GitHubAccount
    private var oldValidationWaiter: CheckedContinuation<Void, Never>?
    private var oldValidationCompletion: CheckedContinuation<Void, Never>?

    init(account: GitHubAccount) {
        self.account = account
    }

    func beginAuthorization(configuration: GitHubOAuthConfiguration) -> GitHubBrowserAuthorization {
        testAuthorization
    }

    func completeAuthorization(_ authorization: GitHubBrowserAuthorization) -> String {
        "new-token"
    }

    func cancelAuthorization(_ authorization: GitHubBrowserAuthorization) {}

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

private actor SuspendedAuthorizationAPI: GitHubAPIProviding, GitHubOAuthAuthorizing {
    private var didStartAuthorization = false
    private var authorizationCompletion: CheckedContinuation<Void, Never>?

    func beginAuthorization(configuration: GitHubOAuthConfiguration) async -> GitHubBrowserAuthorization {
        didStartAuthorization = true
        await withCheckedContinuation { continuation in
            authorizationCompletion = continuation
        }
        return testAuthorization
    }

    func completeAuthorization(_ authorization: GitHubBrowserAuthorization) throws -> String {
        throw CancellationError()
    }

    func cancelAuthorization(_ authorization: GitHubBrowserAuthorization) {}

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

private actor ValidationRetryDuringAuthorizationGitHubAPI: GitHubAPIProviding, GitHubOAuthAuthorizing {
    private let reconnectingAccount: GitHubAccount
    private var capturedUserTokens: [String] = []
    private var pollStartedWaiter: CheckedContinuation<Void, Never>?
    private var pollCompletion: CheckedContinuation<Void, Never>?

    init(reconnectingAccount: GitHubAccount) {
        self.reconnectingAccount = reconnectingAccount
    }

    func beginAuthorization(configuration: GitHubOAuthConfiguration) -> GitHubBrowserAuthorization {
        testAuthorization
    }

    func completeAuthorization(_ authorization: GitHubBrowserAuthorization) async -> String {
        pollStartedWaiter?.resume()
        pollStartedWaiter = nil
        await withCheckedContinuation { continuation in
            pollCompletion = continuation
        }
        return "new-token"
    }

    func cancelAuthorization(_ authorization: GitHubBrowserAuthorization) {}

    func authenticatedUser(token: String) throws -> GitHubAccount {
        capturedUserTokens.append(token)
        switch token {
        case "failed-token":
            throw GitHubAPIError.server(503)
        case "connected-token", "new-token":
            return reconnectingAccount
        default:
            throw GitHubAPIError.malformedResponse
        }
    }

    func waitUntilPollBegins() async {
        guard pollCompletion == nil else { return }
        await withCheckedContinuation { continuation in
            pollStartedWaiter = continuation
        }
    }

    func finishPoll() {
        pollCompletion?.resume()
        pollCompletion = nil
    }

    func userTokens() -> [String] {
        capturedUserTokens
    }
}

private actor SuspendedPollingGitHubAPI: GitHubAPIProviding, GitHubOAuthAuthorizing {
    private let account: GitHubAccount
    private var didStartPoll = false
    private var pollCompletion: CheckedContinuation<Void, Never>?

    init(account: GitHubAccount) {
        self.account = account
    }

    func beginAuthorization(configuration: GitHubOAuthConfiguration) -> GitHubBrowserAuthorization {
        testAuthorization
    }

    func completeAuthorization(_ authorization: GitHubBrowserAuthorization) async -> String {
        didStartPoll = true
        await withCheckedContinuation { continuation in
            pollCompletion = continuation
        }
        return "new-token"
    }

    func cancelAuthorization(_ authorization: GitHubBrowserAuthorization) {}

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

private actor MultiAccountSuspendedPollingGitHubAPI: GitHubAPIProviding, GitHubOAuthAuthorizing {
    private let first: GitHubAccount
    private let second: GitHubAccount
    private var pollStartedWaiter: CheckedContinuation<Void, Never>?
    private var pollCompletion: CheckedContinuation<Void, Never>?

    init(first: GitHubAccount, second: GitHubAccount) {
        self.first = first
        self.second = second
    }

    func beginAuthorization(configuration: GitHubOAuthConfiguration) -> GitHubBrowserAuthorization {
        testAuthorization
    }

    func completeAuthorization(_ authorization: GitHubBrowserAuthorization) async -> String {
        pollStartedWaiter?.resume()
        pollStartedWaiter = nil
        await withCheckedContinuation { continuation in
            pollCompletion = continuation
        }
        return "new-first-token"
    }

    func cancelAuthorization(_ authorization: GitHubBrowserAuthorization) {}

    func authenticatedUser(token: String) throws -> GitHubAccount {
        switch token {
        case "first-token", "new-first-token": first
        case "second-token": second
        default: throw GitHubAPIError.malformedResponse
        }
    }

    func waitUntilPollBegins() async {
        guard pollCompletion == nil else { return }
        await withCheckedContinuation { continuation in
            pollStartedWaiter = continuation
        }
    }

    func finishPoll() {
        pollCompletion?.resume()
        pollCompletion = nil
    }
}
