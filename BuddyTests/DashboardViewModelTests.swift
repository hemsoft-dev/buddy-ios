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
        XCTAssertEqual(DashboardPresentation(githubState: .connected(account)), .connected)
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
