import Foundation
import Observation

@MainActor
@Observable
final class DashboardViewModel {
    private(set) var cards: [DashboardCard]
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?

    private let integrations: [any IntegrationProviding]

    init(integrations: [any IntegrationProviding]) {
        self.integrations = integrations
        cards = integrations.map { DashboardCard(summary: $0.summary) }
    }

    func refresh() async {
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        var refreshedCards: [DashboardCard] = []

        for integration in integrations {
            do {
                let summary = try await integration.refresh()
                refreshedCards.append(DashboardCard(summary: summary))
            } catch {
                var summary = integration.summary
                summary.connectionState = .needsAttention
                summary.detail = "Refresh failed"
                refreshedCards.append(DashboardCard(summary: summary))
                AppLogger.integrations.error("Integration refresh failed")
            }
        }

        cards = refreshedCards
        lastUpdated = .now
    }
}
