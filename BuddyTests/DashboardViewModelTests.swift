import SwiftUI
import XCTest
@testable import Buddy

@MainActor
final class DashboardViewModelTests: XCTestCase {
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
