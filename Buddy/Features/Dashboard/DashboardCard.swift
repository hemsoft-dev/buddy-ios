import SwiftUI

struct DashboardCard: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let state: IntegrationConnectionState

    init(summary: IntegrationSummary) {
        id = summary.id
        title = summary.title
        detail = summary.detail
        systemImage = summary.systemImage
        tint = summary.tint
        state = summary.connectionState
    }
}
