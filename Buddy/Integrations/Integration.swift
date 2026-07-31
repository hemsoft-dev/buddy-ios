import SwiftUI

protocol IntegrationProviding: Sendable {
    var summary: IntegrationSummary { get }
    func refresh() async throws -> IntegrationSummary
}

struct IntegrationSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    var detail: String
    let systemImage: String
    let tint: Color
    var connectionState: IntegrationConnectionState
}

enum IntegrationConnectionState: String, Equatable, Sendable {
    case connected
    case disconnected
    case needsAttention

    var systemImage: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .disconnected: "circle.dashed"
        case .needsAttention: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .connected: .green
        case .disconnected: .secondary
        case .needsAttention: .orange
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .connected: "Connected"
        case .disconnected: "Not connected"
        case .needsAttention: "Needs attention"
        }
    }
}

enum IntegrationCatalog {
    static let defaultIntegrations: [any IntegrationProviding] = [GitHubIntegration()]
}
