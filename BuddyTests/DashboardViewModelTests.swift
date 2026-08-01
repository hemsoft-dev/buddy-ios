import SwiftUI
import XCTest
@testable import Buddy

@MainActor
final class DashboardViewModelTests: XCTestCase {
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
        let provider = StubPullRequestProvider(results: [.success([older, newer])])
        let viewModel = DashboardViewModel(
            integrations: [],
            github: provider,
            now: { refreshDate }
        )

        let failure = await viewModel.refresh(account: testAccount)

        XCTAssertNil(failure)
        XCTAssertEqual(viewModel.githubState, .loaded([newer, older], refreshedAt: refreshDate))
    }

    func testGitHubDashboardRepresentsConnectedEmptyState() async {
        let refreshDate = Date(timeIntervalSince1970: 2_000)
        let provider = StubPullRequestProvider(results: [.success([])])
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
            .success([pullRequest]),
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
}

private let testAccount = GitHubAccount(id: 42, login: "octocat", name: nil, avatarURL: nil)

private func makePullRequest(id: Int, updatedAt: Date) -> GitHubPullRequest {
    GitHubPullRequest(
        id: id,
        repository: "HemSoft/Buddy",
        number: id,
        title: "Pull request \(id)",
        isDraft: false,
        updatedAt: updatedAt,
        url: URL(string: "https://github.com/HemSoft/Buddy/pull/\(id)")!
    )
}

private actor StubPullRequestProvider: GitHubPullRequestProviding {
    private var results: [Result<[GitHubPullRequest], GitHubConnectionError>]

    init(results: [Result<[GitHubPullRequest], GitHubConnectionError>]) {
        self.results = results
    }

    func authoredPullRequests(for _: GitHubAccount) throws -> [GitHubPullRequest] {
        try results.removeFirst().get()
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
