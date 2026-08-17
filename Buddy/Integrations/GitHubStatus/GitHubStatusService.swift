import Foundation

protocol GitHubStatusFetching: Sendable {
    func fetchActiveIncidents() async throws -> [GitHubStatusIncident]
}

struct GitHubStatusService: GitHubStatusFetching {
    static let unresolvedIncidentsURL = URL(
        string: "https://www.githubstatus.com/api/v2/incidents/unresolved.json"
    )!

    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func fetchActiveIncidents() async throws -> [GitHubStatusIncident] {
        var request = URLRequest(url: Self.unresolvedIncidentsURL)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, _) = try await httpClient.data(for: request)
        let response = try JSONDecoder.githubStatus.decode(GitHubStatusResponse.self, from: data)
        return response.incidents
            .compactMap(\.qualifiedIncident)
            .sorted(by: GitHubStatusIncident.priorityOrder)
    }
}

struct GitHubStatusIncident: Equatable, Identifiable, Sendable {
    let id: String
    let updateID: String
    let title: String
    let status: String
    let impact: String
    let affectedComponents: [String]
    let updatedAt: Date
    let detailsURL: URL

    var identity: String { "\(id):\(updateID)" }

    var summary: String {
        var parts = [impact.capitalized, status.replacingOccurrences(of: "_", with: " ").capitalized]
        if !affectedComponents.isEmpty {
            parts.append("Affected: \(affectedComponents.joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
    }

    var accessibilityDescription: String {
        "GitHub Status incident. \(title). \(summary). Updated \(updatedAt.formatted(date: .abbreviated, time: .shortened))."
    }

    fileprivate static func priorityOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        let priorities = ["critical": 3, "major": 2, "minor": 1]
        let lhsPriority = priorities[lhs.impact.lowercased(), default: 0]
        let rhsPriority = priorities[rhs.impact.lowercased(), default: 0]
        if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
        return lhs.updatedAt > rhs.updatedAt
    }
}

private struct GitHubStatusResponse: Decodable {
    let incidents: [Incident]

    struct Incident: Decodable {
        let id: String
        let name: String
        let status: String
        let impact: String
        let updatedAt: Date
        let incidentUpdates: [Update]
        let components: [Component]

        enum CodingKeys: String, CodingKey {
            case id, name, status, impact, components
            case updatedAt = "updated_at"
            case incidentUpdates = "incident_updates"
        }

        var qualifiedIncident: GitHubStatusIncident? {
            let normalizedStatus = status.lowercased()
            let normalizedImpact = impact.lowercased()
            guard !["resolved", "completed", "scheduled"].contains(normalizedStatus),
                  ["minor", "major", "critical"].contains(normalizedImpact)
            else {
                return nil
            }

            let latestUpdate = incidentUpdates.max { $0.updatedAt < $1.updatedAt }
            guard let detailsURL = URL(string: "https://www.githubstatus.com/incidents/\(id)") else {
                return nil
            }
            return GitHubStatusIncident(
                id: id,
                updateID: latestUpdate?.id ?? "incident-\(updatedAt.timeIntervalSince1970)",
                title: name,
                status: latestUpdate?.status ?? status,
                impact: impact,
                affectedComponents: components
                    .filter { $0.status.lowercased() != "operational" }
                    .map(\.name)
                    .sorted(),
                updatedAt: latestUpdate?.updatedAt ?? updatedAt,
                detailsURL: detailsURL
            )
        }
    }

    struct Update: Decodable {
        let id: String
        let status: String
        let updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id, status
            case updatedAt = "updated_at"
        }
    }

    struct Component: Decodable {
        let name: String
        let status: String
    }
}

private extension JSONDecoder {
    static var githubStatus: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid GitHub Status timestamp: \(value)"
            )
        }
        return decoder
    }
}
