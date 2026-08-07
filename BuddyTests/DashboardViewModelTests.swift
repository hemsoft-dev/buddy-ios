import SwiftUI
import XCTest
@testable import Buddy

@MainActor
final class DashboardViewModelTests: XCTestCase {
    func testGitHubCardDefaultsToCollapsedWithoutStoredPreference() throws {
        let suiteName = "DashboardViewModelTests.default.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preference = DashboardGitHubCardExpansionStorage(store: defaults)

        XCTAssertTrue(preference.wrappedValue.isEmpty)
    }

    func testGitHubCardPersistsExplicitExpansionChoice() throws {
        let suiteName = "DashboardViewModelTests.persistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstAccountID = ConnectedAccountID(provider: .github, subject: "42")
        let secondAccountID = ConnectedAccountID(provider: .github, subject: "84")
        let preference = DashboardGitHubCardExpansionStorage(store: defaults)
        preference.wrappedValue = [firstAccountID]

        let recreatedPreference = DashboardGitHubCardExpansionStorage(store: defaults)

        XCTAssertEqual(recreatedPreference.wrappedValue, [firstAccountID])
        XCTAssertFalse(recreatedPreference.wrappedValue.contains(secondAccountID))
    }

    func testGitHubCardExpansionStaysIsolatedAcrossAccountsAndStorageRecreation() throws {
        let suiteName = "DashboardViewModelTests.multi-account-persistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstAccountID = ConnectedAccountID(provider: .github, subject: "42")
        let secondAccountID = ConnectedAccountID(provider: .github, subject: "84")

        let preference = DashboardGitHubCardExpansionStorage(store: defaults)
        preference.wrappedValue = [firstAccountID]
        var changed = preference.wrappedValue
        changed.remove(firstAccountID)
        changed.insert(secondAccountID)
        preference.wrappedValue = changed

        let recreatedPreference = DashboardGitHubCardExpansionStorage(store: defaults)
        XCTAssertFalse(recreatedPreference.wrappedValue.contains(firstAccountID))
        XCTAssertTrue(recreatedPreference.wrappedValue.contains(secondAccountID))
    }

    func testGitHubCardMigratesLegacyExpansionToFirstAccountOnly() throws {
        let suiteName = "DashboardViewModelTests.legacy-persistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstAccountID = ConnectedAccountID(provider: .github, subject: "42")
        let secondAccountID = ConnectedAccountID(provider: .github, subject: "84")
        defaults.set(true, forKey: DashboardGitHubCardExpansionStorage.legacyKey)

        let preference = DashboardGitHubCardExpansionStorage(store: defaults)
        preference.migrateLegacyExpansion(to: firstAccountID)

        let recreatedPreference = DashboardGitHubCardExpansionStorage(store: defaults)
        XCTAssertEqual(recreatedPreference.wrappedValue, [firstAccountID])
        XCTAssertFalse(recreatedPreference.wrappedValue.contains(secondAccountID))
        XCTAssertFalse(defaults.bool(forKey: DashboardGitHubCardExpansionStorage.legacyKey))
    }

    func testPullRequestRepositoryGroupsSortRepositoriesAndRecentActivity() {
        let groups = GitHubPullRequestRepositoryGroup.grouped([
            makePullRequest(
                id: 1,
                repository: "HemSoft/Zebra",
                updatedAt: Date(timeIntervalSince1970: 300)
            ),
            makePullRequest(
                id: 2,
                repository: "HemSoft/alpha",
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            makePullRequest(
                id: 3,
                repository: "HemSoft/alpha",
                updatedAt: Date(timeIntervalSince1970: 200)
            ),
        ])

        XCTAssertEqual(groups.map(\.id), ["HemSoft/alpha", "HemSoft/Zebra"])
        XCTAssertEqual(groups[0].pullRequests.map(\.id), [3, 2])
        XCTAssertEqual(groups[1].pullRequests.map(\.id), [1])
    }

    func testPullRequestAccountSummaryPreservesBoundedSearchTotals() {
        XCTAssertEqual(
            DashboardGitHubPullRequestCopy.accountSummary(
                authoredVisible: 50,
                authoredTotal: 72,
                assignedVisible: 2,
                assignedTotal: 2
            ),
            "50 of 72 authored · 2 assigned"
        )
    }

    func testPullRequestAccountHeaderRemainsLoadingUntilBothSectionsResolve() {
        XCTAssertEqual(
            DashboardGitHubPullRequestCopy.accountHeaderSummary(
                authoredState: .loaded(
                    [makePullRequest(
                        id: 1,
                        repository: "HemSoft/Buddy",
                        updatedAt: Date(timeIntervalSince1970: 100)
                    )],
                    refreshedAt: Date(timeIntervalSince1970: 100)
                ),
                authoredTotal: 1,
                assignedState: .loading,
                assignedTotal: 0
            ),
            "Loading pull requests"
        )
    }

    func testPullRequestAccountHeaderKeepsLoadingAheadOfOrdinaryFailure() {
        XCTAssertEqual(
            DashboardGitHubPullRequestCopy.accountHeaderSummary(
                authoredState: .failed([], refreshedAt: nil, .server),
                authoredTotal: 0,
                assignedState: .loading,
                assignedTotal: 0
            ),
            "Loading pull requests"
        )
    }

    func testPullRequestAccountHeaderKeepsAuthenticationFailureAheadOfLoading() {
        XCTAssertEqual(
            DashboardGitHubPullRequestCopy.accountHeaderSummary(
                authoredState: .failed([], refreshedAt: nil, .authenticationRequired),
                authoredTotal: 0,
                assignedState: .loading,
                assignedTotal: 0
            ),
            "Reconnect required · 0 authored · 0 assigned"
        )
    }

    func testAssignedEmptyStateDisclosesPublicRepositoryLimit() {
        let description = DashboardGitHubPullRequestCopy.emptyStateDescription(
            login: "octocat",
            section: .assigned
        )

        XCTAssertTrue(description.contains("No public open pull requests"))
        XCTAssertTrue(description.contains("@octocat"))
        XCTAssertTrue(description.contains("limited to public repositories"))
    }

    func testPullRequestTreeExpansionSurvivesRefreshForExistingRepositories() {
        var expansion = DashboardGitHubPullRequestTreeExpansionState()
        expansion.reconcile(accountID: testAccount.id, repositories: ["HemSoft/Buddy", "HemSoft/Other"])
        expansion.togglePullRequestSection(for: testAccount.id)
        expansion.toggleRepository("HemSoft/Buddy", for: testAccount.id)

        expansion.reconcile(accountID: testAccount.id, repositories: ["HemSoft/Buddy", "HemSoft/New"])

        XCTAssertTrue(expansion.isPullRequestSectionExpanded(for: testAccount.id))
        XCTAssertTrue(expansion.isRepositoryExpanded("HemSoft/Buddy", for: testAccount.id))
        XCTAssertFalse(expansion.isRepositoryExpanded("HemSoft/New", for: testAccount.id))

        expansion.reconcile(accountID: testAccount.id, repositories: ["HemSoft/New"])
        expansion.reconcile(accountID: testAccount.id, repositories: ["HemSoft/Buddy", "HemSoft/New"])

        XCTAssertFalse(expansion.isRepositoryExpanded("HemSoft/Buddy", for: testAccount.id))
    }

    func testPullRequestTreeExpansionDoesNotLeakBetweenAccounts() {
        let secondAccountID = 84
        var expansion = DashboardGitHubPullRequestTreeExpansionState()
        expansion.reconcile(accountID: testAccount.id, repositories: ["HemSoft/Buddy"])
        expansion.togglePullRequestSection(for: testAccount.id)
        expansion.toggleRepository("HemSoft/Buddy", for: testAccount.id)

        expansion.reconcile(accountID: secondAccountID, repositories: ["HemSoft/Buddy"])

        XCTAssertFalse(expansion.isPullRequestSectionExpanded(for: secondAccountID))
        XCTAssertFalse(expansion.isRepositoryExpanded("HemSoft/Buddy", for: secondAccountID))
        XCTAssertTrue(expansion.isPullRequestSectionExpanded(for: testAccount.id))
        XCTAssertTrue(expansion.isRepositoryExpanded("HemSoft/Buddy", for: testAccount.id))
    }

    func testPullRequestTreeExpansionDoesNotLeakBetweenAuthoredAndAssignedSections() {
        var expansion = DashboardGitHubPullRequestTreeExpansionState()
        expansion.reconcile(
            accountID: testAccount.id,
            section: .assigned,
            repositories: ["HemSoft/Buddy"]
        )
        expansion.togglePullRequestSection(for: testAccount.id, section: .assigned)
        expansion.toggleRepository("HemSoft/Buddy", for: testAccount.id, section: .assigned)

        expansion.reconcile(
            accountID: testAccount.id,
            section: .authored,
            repositories: ["HemSoft/Buddy"]
        )

        XCTAssertTrue(expansion.isPullRequestSectionExpanded(for: testAccount.id, section: .assigned))
        XCTAssertTrue(expansion.isRepositoryExpanded("HemSoft/Buddy", for: testAccount.id, section: .assigned))
        XCTAssertFalse(expansion.isPullRequestSectionExpanded(for: testAccount.id, section: .authored))
        XCTAssertFalse(expansion.isRepositoryExpanded("HemSoft/Buddy", for: testAccount.id, section: .authored))
    }

    func testPullRequestTreeDoesNotReconcileTransientAccountSwitchData() throws {
        let refreshDate = Date(timeIntervalSince1970: 500)
        let secondAccountID = 84
        let firstAccountPullRequest = makePullRequest(
            id: 1,
            repository: "HemSoft/Buddy",
            updatedAt: refreshDate
        )
        let secondAccountPullRequest = makePullRequest(
            id: 2,
            repository: "HemSoft/Other",
            updatedAt: refreshDate
        )
        var expansion = DashboardGitHubPullRequestTreeExpansionState()
        expansion.reconcile(accountID: testAccount.id, repositories: [firstAccountPullRequest.repository])
        expansion.togglePullRequestSection(for: testAccount.id)
        expansion.toggleRepository(firstAccountPullRequest.repository, for: testAccount.id)

        let staleFirstAccountSnapshot = DashboardGitHubPullRequestTreeSnapshot(
            accountID: secondAccountID,
            dataAccountID: testAccount.id,
            state: .loaded([firstAccountPullRequest], refreshedAt: refreshDate)
        )
        let secondAccountLoadingSnapshot = DashboardGitHubPullRequestTreeSnapshot(
            accountID: secondAccountID,
            dataAccountID: secondAccountID,
            state: .loading
        )
        let staleSecondAccountSnapshot = DashboardGitHubPullRequestTreeSnapshot(
            accountID: testAccount.id,
            dataAccountID: secondAccountID,
            state: .loaded([secondAccountPullRequest], refreshedAt: refreshDate)
        )
        let returningAccountLoadingSnapshot = DashboardGitHubPullRequestTreeSnapshot(
            accountID: testAccount.id,
            dataAccountID: testAccount.id,
            state: .loading
        )

        XCTAssertNil(staleFirstAccountSnapshot)
        XCTAssertNil(secondAccountLoadingSnapshot)
        XCTAssertNil(staleSecondAccountSnapshot)
        XCTAssertNil(returningAccountLoadingSnapshot)
        XCTAssertTrue(expansion.isPullRequestSectionExpanded(for: testAccount.id))
        XCTAssertTrue(expansion.isRepositoryExpanded(firstAccountPullRequest.repository, for: testAccount.id))

        let refreshedFirstAccountSnapshot = try XCTUnwrap(
            DashboardGitHubPullRequestTreeSnapshot(
                accountID: testAccount.id,
                dataAccountID: testAccount.id,
                state: .loaded([firstAccountPullRequest], refreshedAt: refreshDate)
            )
        )
        expansion.reconcile(
            accountID: refreshedFirstAccountSnapshot.accountID,
            repositories: refreshedFirstAccountSnapshot.repositories
        )

        XCTAssertTrue(expansion.isPullRequestSectionExpanded(for: testAccount.id))
        XCTAssertTrue(expansion.isRepositoryExpanded(firstAccountPullRequest.repository, for: testAccount.id))
    }

    func testDashboardPresentationDistinguishesAccountLifecycleStates() {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let authorization = GitHubDeviceAuthorization(
            deviceCode: "device-code",
            userCode: "ABCD-EFGH",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresIn: 900,
            interval: 5
        )

        XCTAssertEqual(DashboardPresentation(githubState: .loading), .loading)
        XCTAssertEqual(DashboardPresentation(githubState: .disconnected), .onboarding)
        XCTAssertEqual(
            DashboardPresentation(githubState: .configurationRequired("Missing client ID")),
            .configurationRequired
        )
        XCTAssertEqual(
            DashboardPresentation(githubState: .authorizing(authorization)),
            .authorizing
        )
        XCTAssertEqual(DashboardPresentation(githubState: .connected(account)), .connected(account))
        XCTAssertEqual(
            DashboardPresentation(githubState: .needsAttention("Authorization expired")),
            .needsAttention("Authorization expired")
        )
    }

    func testSettingsStatusRepresentsEveryGitHubState() {
        let account = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)
        let authorization = GitHubDeviceAuthorization(
            deviceCode: "device-code",
            userCode: "ABCD-EFGH",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresIn: 900,
            interval: 5
        )

        XCTAssertEqual(GitHubViewState.loading.settingsStatus, "Checking connection")
        XCTAssertEqual(GitHubViewState.disconnected.settingsStatus, "Not connected")
        XCTAssertEqual(
            GitHubViewState.configurationRequired("Missing client ID").settingsStatus,
            "Configuration required"
        )
        XCTAssertEqual(
            GitHubViewState.authorizing(authorization).settingsStatus,
            "Waiting for authorization"
        )
        XCTAssertEqual(GitHubViewState.connected(account).settingsStatus, "Connected as @octocat")
        XCTAssertEqual(GitHubViewState.needsAttention("Expired").settingsStatus, "Needs attention")
    }

    func testRefreshUsesLatestIntegrationSummary() async {
        let integration = MockIntegration()
        let viewModel = DashboardViewModel(integrations: [integration])

        XCTAssertEqual(viewModel.cards.first?.detail, "Waiting")
        XCTAssertNil(viewModel.lastUpdated)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.cards.first?.detail, "Up to date")
        XCTAssertEqual(viewModel.cards.first?.state, .connected)
        XCTAssertNotNil(viewModel.lastUpdated)
        XCTAssertFalse(viewModel.isRefreshing)
    }

    func testRepeatedRefreshReplacesCardsWithCurrentIntegrationState() async {
        let integration = SequencedIntegration()
        let viewModel = DashboardViewModel(integrations: [integration])

        await viewModel.refresh()
        XCTAssertEqual(viewModel.cards.first?.detail, "@octocat")
        XCTAssertEqual(viewModel.cards.first?.state, .connected)

        await viewModel.refresh()
        XCTAssertEqual(viewModel.cards.first?.detail, "Ready to connect")
        XCTAssertEqual(viewModel.cards.first?.state, .disconnected)
        let refreshCount = await integration.refreshCount()
        XCTAssertEqual(refreshCount, 2)
    }

    func testGitHubDashboardLoadsConnectedResultsInRecentActivityOrder() async {
        let refreshDate = Date(timeIntervalSince1970: 1_000)
        let older = makePullRequest(id: 1, updatedAt: Date(timeIntervalSince1970: 100))
        let newer = makePullRequest(id: 2, updatedAt: Date(timeIntervalSince1970: 200))
        let provider = StubPullRequestProvider(results: [.success(collection([older, newer], totalCount: 72))])
        let viewModel = DashboardViewModel(
            integrations: [],
            github: provider,
            now: { refreshDate }
        )

        let failure = await viewModel.refresh(account: testAccount)

        XCTAssertNil(failure)
        XCTAssertEqual(viewModel.githubState, .loaded([newer, older], refreshedAt: refreshDate))
        XCTAssertEqual(viewModel.githubTotalCount, 72)
    }

    func testGitHubDashboardRepresentsConnectedEmptyState() async {
        let refreshDate = Date(timeIntervalSince1970: 2_000)
        let provider = StubPullRequestProvider(results: [.success(collection([]))])
        let viewModel = DashboardViewModel(
            integrations: [],
            github: provider,
            now: { refreshDate }
        )

        await viewModel.refresh(account: testAccount)

        XCTAssertEqual(viewModel.githubState, .loaded([], refreshedAt: refreshDate))
    }

    func testGitHubDashboardRefreshFailurePreservesPreviouslyLoadedResults() async {
        let refreshDate = Date(timeIntervalSince1970: 3_000)
        let pullRequest = makePullRequest(id: 1, updatedAt: refreshDate)
        let provider = StubPullRequestProvider(results: [
            .success(collection([pullRequest])),
            .failure(.networkUnavailable),
        ])
        let viewModel = DashboardViewModel(
            integrations: [],
            github: provider,
            now: { refreshDate }
        )
        await viewModel.refresh(account: testAccount)

        let failure = await viewModel.refresh(account: testAccount)

        XCTAssertEqual(failure, .offline)
        XCTAssertEqual(
            viewModel.githubState,
            .failed([pullRequest], refreshedAt: refreshDate, .offline)
        )
    }

    func testGitHubDashboardMapsUnauthorizedRefreshToRecoveryState() async {
        let provider = StubPullRequestProvider(results: [.failure(.invalidToken)])
        let viewModel = DashboardViewModel(integrations: [], github: provider)

        let failure = await viewModel.refresh(account: testAccount)

        XCTAssertEqual(failure, .authenticationRequired)
        XCTAssertEqual(
            viewModel.githubState,
            .failed([], refreshedAt: nil, .authenticationRequired)
        )
    }

    func testGitHubDashboardPropagatesAuthenticationFailureToCanceledSiblingSection() async {
        let viewModel = DashboardViewModel(
            integrations: [],
            github: RevokedCredentialRaceProvider()
        )

        let failure = await viewModel.refresh(account: testAccount)

        XCTAssertEqual(failure, .authenticationRequired)
        XCTAssertEqual(
            viewModel.githubState(for: testAccount, section: .authored),
            .failed([], refreshedAt: nil, .authenticationRequired)
        )
        XCTAssertEqual(
            viewModel.githubState(for: testAccount, section: .assigned),
            .failed([], refreshedAt: nil, .authenticationRequired)
        )
    }

    func testGitHubDashboardSurfacesIncompleteSearchAsRetryableFailure() async {
        let provider = StubPullRequestProvider(results: [.failure(.incompleteResults)])
        let viewModel = DashboardViewModel(integrations: [], github: provider)

        let failure = await viewModel.refresh(account: testAccount)

        XCTAssertEqual(failure, .incompleteResults)
        XCTAssertEqual(
            viewModel.githubState,
            .failed([], refreshedAt: nil, .incompleteResults)
        )
    }

    func testGitHubDashboardDoesNotReuseResultsAcrossAccounts() async {
        let refreshDate = Date(timeIntervalSince1970: 4_000)
        let firstAccountPullRequest = makePullRequest(id: 1, updatedAt: refreshDate)
        let provider = StubPullRequestProvider(results: [
            .success(collection([firstAccountPullRequest])),
            .failure(.networkUnavailable),
        ])
        let viewModel = DashboardViewModel(
            integrations: [],
            github: provider,
            now: { refreshDate }
        )
        await viewModel.refresh(account: testAccount)
        let secondAccount = GitHubAccount(id: 84, login: "hubot", name: nil, avatarURL: nil)

        let failure = await viewModel.refresh(account: secondAccount)

        XCTAssertEqual(failure, .offline)
        XCTAssertEqual(viewModel.githubState, .failed([], refreshedAt: nil, .offline))
        XCTAssertEqual(viewModel.githubTotalCount, 0)
    }

    func testGitHubDashboardRetainsIndependentStateForMultipleAccountCards() async {
        let refreshDate = Date(timeIntervalSince1970: 4_500)
        let firstPullRequest = makePullRequest(id: 1, updatedAt: refreshDate)
        let secondPullRequest = makePullRequest(
            id: 2,
            repository: "HemSoft/Other",
            updatedAt: refreshDate
        )
        let secondAccount = GitHubAccount(id: 84, login: "hubot", name: nil, avatarURL: nil)
        let provider = StubPullRequestProvider(results: [
            .success(collection([firstPullRequest], totalCount: 3)),
            .success(collection([secondPullRequest], totalCount: 1)),
        ])
        let viewModel = DashboardViewModel(
            integrations: [],
            github: provider,
            now: { refreshDate }
        )

        await viewModel.refresh(account: testAccount)
        await viewModel.refresh(account: secondAccount)

        XCTAssertEqual(
            viewModel.githubState(for: testAccount),
            .loaded([firstPullRequest], refreshedAt: refreshDate)
        )
        XCTAssertEqual(
            viewModel.githubState(for: secondAccount),
            .loaded([secondPullRequest], refreshedAt: refreshDate)
        )
        XCTAssertEqual(viewModel.githubTotalCount(for: testAccount), 3)
        XCTAssertEqual(viewModel.githubTotalCount(for: secondAccount), 1)
    }

    func testGitHubDashboardLoadsIndependentAssignedReviewResultsForMultipleAccounts() async {
        let refreshDate = Date(timeIntervalSince1970: 4_750)
        let sharedPullRequest = makePullRequest(id: 20, updatedAt: refreshDate)
        let firstAssigned = makePullRequest(
            id: 21,
            repository: "HemSoft/First",
            updatedAt: refreshDate.addingTimeInterval(-10)
        )
        let secondAssigned = makePullRequest(
            id: 22,
            repository: "HemSoft/Second",
            updatedAt: refreshDate.addingTimeInterval(10)
        )
        let secondAccount = GitHubAccount(id: 84, login: "hubot", name: nil, avatarURL: nil)
        let provider = SectionedPullRequestProvider(
            authored: [
                testAccount.id: [.success(collection([]))],
                secondAccount.id: [.success(collection([]))],
            ],
            assigned: [
                testAccount.id: [.success(collection([firstAssigned, sharedPullRequest], totalCount: 2))],
                secondAccount.id: [.success(collection([secondAssigned, sharedPullRequest], totalCount: 2))],
            ]
        )
        let viewModel = DashboardViewModel(integrations: [], github: provider, now: { refreshDate })

        await viewModel.refresh(account: testAccount)
        await viewModel.refresh(account: secondAccount)

        XCTAssertEqual(
            viewModel.githubState(for: testAccount, section: .assigned),
            .loaded([sharedPullRequest, firstAssigned], refreshedAt: refreshDate)
        )
        XCTAssertEqual(
            viewModel.githubState(for: secondAccount, section: .assigned),
            .loaded([secondAssigned, sharedPullRequest], refreshedAt: refreshDate)
        )
        XCTAssertEqual(viewModel.githubTotalCount(for: testAccount, section: .assigned), 2)
        XCTAssertEqual(viewModel.githubTotalCount(for: secondAccount, section: .assigned), 2)
    }

    func testAssignedReviewRefreshFailurePreservesOnlyThatAccountsStaleResults() async {
        let firstDate = Date(timeIntervalSince1970: 4_800)
        let assigned = makePullRequest(id: 20, updatedAt: firstDate)
        let provider = SectionedPullRequestProvider(
            authored: [testAccount.id: [
                .success(collection([])),
                .success(collection([])),
            ]],
            assigned: [testAccount.id: [
                .success(collection([assigned])),
                .failure(.rateLimited),
            ]]
        )
        let viewModel = DashboardViewModel(integrations: [], github: provider, now: { firstDate })
        await viewModel.refresh(account: testAccount)

        let failure = await viewModel.refresh(account: testAccount)

        XCTAssertEqual(failure, .rateLimited)
        XCTAssertEqual(
            viewModel.githubState(for: testAccount, section: .assigned),
            .failed([assigned], refreshedAt: firstDate, .rateLimited)
        )
        XCTAssertEqual(
            viewModel.githubState(for: testAccount, section: .authored),
            .loaded([], refreshedAt: firstDate)
        )
    }

    func testGitHubDashboardAccountTimestampUsesNewestSectionRefresh() async {
        let authoredDate = Date(timeIntervalSince1970: 4_900)
        let assignedDate = Date(timeIntervalSince1970: 5_000)
        let clock = MutableTestClock(now: authoredDate)
        let provider = SectionedPullRequestProvider(
            authored: [testAccount.id: [.success(collection([]))]],
            assigned: [testAccount.id: [.success(collection([]))]]
        )
        let viewModel = DashboardViewModel(
            integrations: [],
            github: provider,
            now: { clock.now }
        )

        await viewModel.refresh(account: testAccount, section: .authored)
        clock.now = assignedDate
        await viewModel.refresh(account: testAccount, section: .assigned)

        XCTAssertEqual(viewModel.githubRefreshedAt(for: testAccount), assignedDate)
    }

    func testGitHubDashboardBlocksDuplicateInitialRefreshes() async {
        let pullRequest = makePullRequest(id: 1, updatedAt: Date(timeIntervalSince1970: 5_000))
        let provider = SuspendedPullRequestProvider()
        let viewModel = DashboardViewModel(integrations: [], github: provider)
        let initialRefresh = Task {
            await viewModel.refresh(account: testAccount)
        }
        await provider.waitUntilRequested()

        let duplicateFailure = await viewModel.refresh(account: testAccount)

        XCTAssertNil(duplicateFailure)
        XCTAssertTrue(viewModel.isGitHubRefreshInFlight)
        let requestCount = await provider.requestCount()
        XCTAssertEqual(requestCount, 1)

        await provider.finish(with: collection([pullRequest]))
        _ = await initialRefresh.value
        XCTAssertFalse(viewModel.isGitHubRefreshInFlight)
        XCTAssertEqual(viewModel.githubState.pullRequests, [pullRequest])
    }
}

private let testAccount = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)

@MainActor
private final class MutableTestClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private func makePullRequest(
    id: Int,
    repository: String = "HemSoft/Buddy",
    updatedAt: Date
) -> GitHubPullRequest {
    GitHubPullRequest(
        id: id,
        repository: repository,
        number: id,
        title: "Pull request \(id)",
        isDraft: false,
        updatedAt: updatedAt,
        url: URL(string: "https://github.com/HemSoft/Buddy/pull/\(id)")!
    )
}

private func collection(
    _ pullRequests: [GitHubPullRequest],
    totalCount: Int? = nil
) -> GitHubPullRequestCollection {
    GitHubPullRequestCollection(
        pullRequests: pullRequests,
        totalCount: totalCount ?? pullRequests.count
    )
}

private actor StubPullRequestProvider: GitHubPullRequestProviding {
    private var results: [Result<GitHubPullRequestCollection, GitHubConnectionError>]

    init(results: [Result<GitHubPullRequestCollection, GitHubConnectionError>]) {
        self.results = results
    }

    func authoredPullRequests(for _: GitHubAccount) throws -> GitHubPullRequestCollection {
        try results.removeFirst().get()
    }

    func assignedPullRequests(for _: GitHubAccount) -> GitHubPullRequestCollection {
        GitHubPullRequestCollection(pullRequests: [], totalCount: 0)
    }
}

private actor SuspendedPullRequestProvider: GitHubPullRequestProviding {
    private var capturedRequestCount = 0
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<GitHubPullRequestCollection, Never>?

    func authoredPullRequests(for _: GitHubAccount) async -> GitHubPullRequestCollection {
        capturedRequestCount += 1
        requestWaiter?.resume()
        requestWaiter = nil
        return await withCheckedContinuation { continuation in
            completion = continuation
        }
    }

    func assignedPullRequests(for _: GitHubAccount) -> GitHubPullRequestCollection {
        GitHubPullRequestCollection(pullRequests: [], totalCount: 0)
    }

    func waitUntilRequested() async {
        guard capturedRequestCount == 0 else { return }
        await withCheckedContinuation { continuation in
            requestWaiter = continuation
        }
    }

    func finish(with result: GitHubPullRequestCollection) {
        completion?.resume(returning: result)
        completion = nil
    }

    func requestCount() -> Int {
        capturedRequestCount
    }
}

private actor SectionedPullRequestProvider: GitHubPullRequestProviding {
    private var authored: [Int: [Result<GitHubPullRequestCollection, GitHubConnectionError>]]
    private var assigned: [Int: [Result<GitHubPullRequestCollection, GitHubConnectionError>]]

    init(
        authored: [Int: [Result<GitHubPullRequestCollection, GitHubConnectionError>]],
        assigned: [Int: [Result<GitHubPullRequestCollection, GitHubConnectionError>]]
    ) {
        self.authored = authored
        self.assigned = assigned
    }

    func authoredPullRequests(for account: GitHubAccount) throws -> GitHubPullRequestCollection {
        guard var results = authored[account.id], !results.isEmpty else {
            return GitHubPullRequestCollection(pullRequests: [], totalCount: 0)
        }
        let result = results.removeFirst()
        authored[account.id] = results
        return try result.get()
    }

    func assignedPullRequests(for account: GitHubAccount) throws -> GitHubPullRequestCollection {
        guard var results = assigned[account.id], !results.isEmpty else {
            return GitHubPullRequestCollection(pullRequests: [], totalCount: 0)
        }
        let result = results.removeFirst()
        assigned[account.id] = results
        return try result.get()
    }
}

private actor RevokedCredentialRaceProvider: GitHubPullRequestProviding {
    func authoredPullRequests(for _: GitHubAccount) throws -> GitHubPullRequestCollection {
        throw GitHubConnectionError.invalidToken
    }

    func assignedPullRequests(for _: GitHubAccount) throws -> GitHubPullRequestCollection {
        throw CancellationError()
    }
}

private struct MockIntegration: IntegrationProviding {
    let summary = IntegrationSummary(
        id: "mock",
        title: "Mock",
        detail: "Waiting",
        systemImage: "square",
        tint: .blue,
        connectionState: .disconnected
    )

    func refresh() async throws -> IntegrationSummary {
        IntegrationSummary(
            id: "mock",
            title: "Mock",
            detail: "Up to date",
            systemImage: "square",
            tint: .blue,
            connectionState: .connected
        )
    }
}

private actor SequencedIntegration: IntegrationProviding {
    nonisolated let summary = IntegrationSummary(
        id: "github",
        title: "GitHub",
        detail: "Ready to connect",
        systemImage: "chevron.left.forwardslash.chevron.right",
        tint: .primary,
        connectionState: .disconnected
    )

    private var summaries = [
        IntegrationSummary(
            id: "github",
            title: "GitHub",
            detail: "@octocat",
            systemImage: "chevron.left.forwardslash.chevron.right",
            tint: .primary,
            connectionState: .connected
        ),
        IntegrationSummary(
            id: "github",
            title: "GitHub",
            detail: "Ready to connect",
            systemImage: "chevron.left.forwardslash.chevron.right",
            tint: .primary,
            connectionState: .disconnected
        ),
    ]
    private var capturedRefreshCount = 0

    func refresh() throws -> IntegrationSummary {
        capturedRefreshCount += 1
        return summaries.removeFirst()
    }

    func refreshCount() -> Int {
        capturedRefreshCount
    }
}
