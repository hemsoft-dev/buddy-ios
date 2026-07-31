import SwiftUI

struct GitHubIntegration: IntegrationProviding {
    let summary = IntegrationSummary(
        id: "github",
        title: "GitHub",
        detail: "Ready to connect",
        systemImage: "chevron.left.forwardslash.chevron.right",
        tint: .primary,
        connectionState: .disconnected
    )

    func refresh() async throws -> IntegrationSummary {
        summary
    }
}
