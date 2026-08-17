import Foundation
import Observation

enum GitHubStatusPresentationStyle: String, CaseIterable, Identifiable, Sendable {
    case alert
    case banner

    var id: Self { self }
    var title: String {
        switch self {
        case .alert: "Alert"
        case .banner: "Scrolling banner"
        }
    }
}

enum GitHubStatusPreferenceKey {
    static let monitoringEnabled = "githubStatus.monitoringEnabled"
    static let presentationStyle = "githubStatus.presentationStyle"
    static let presentedIncidentIdentities = "githubStatus.presentedIncidentIdentities.v1"
}

struct GitHubStatusPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var monitoringEnabled: Bool {
        get { defaults.bool(forKey: GitHubStatusPreferenceKey.monitoringEnabled) }
        nonmutating set { defaults.set(newValue, forKey: GitHubStatusPreferenceKey.monitoringEnabled) }
    }

    var presentationStyle: GitHubStatusPresentationStyle {
        get {
            defaults.string(forKey: GitHubStatusPreferenceKey.presentationStyle)
                .flatMap(GitHubStatusPresentationStyle.init(rawValue:)) ?? .alert
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: GitHubStatusPreferenceKey.presentationStyle) }
    }
}

@MainActor
@Observable
final class GitHubStatusMonitor {
    private(set) var currentIncident: GitHubStatusIncident?
    private(set) var pendingAlert: GitHubStatusIncident?

    private let service: any GitHubStatusFetching
    private let defaults: UserDefaults
    private var isRefreshing = false

    init(
        service: any GitHubStatusFetching = GitHubStatusService(),
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.defaults = defaults
    }

    func refresh(isEnabled: Bool, style: GitHubStatusPresentationStyle) async {
        guard isEnabled else {
            disable()
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let activeIncidents = try await service.fetchActiveIncidents()
            let activeIdentities = Set(activeIncidents.map(\.identity))
            var presentedIdentities = storedPresentedIdentities.intersection(activeIdentities)
            currentIncident = activeIncidents.first

            guard style == .alert else {
                pendingAlert = nil
                storePresentedIdentities(presentedIdentities)
                return
            }

            guard !activeIncidents.isEmpty else {
                pendingAlert = nil
                storePresentedIdentities(presentedIdentities)
                return
            }

            guard pendingAlert == nil else {
                storePresentedIdentities(presentedIdentities)
                return
            }

            if let incident = activeIncidents.first(where: { !presentedIdentities.contains($0.identity) }) {
                pendingAlert = incident
                presentedIdentities.insert(incident.identity)
            }
            storePresentedIdentities(presentedIdentities)
        } catch is CancellationError {
            return
        } catch {
            AppLogger.integrations.debug("GitHub Status refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func dismissAlert() {
        pendingAlert = nil
    }

    func disable() {
        currentIncident = nil
        pendingAlert = nil
    }

    private var storedPresentedIdentities: Set<String> {
        guard let data = defaults.data(forKey: GitHubStatusPreferenceKey.presentedIncidentIdentities),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return Set(values)
    }

    private func storePresentedIdentities(_ identities: Set<String>) {
        let data = try? JSONEncoder().encode(identities.sorted())
        defaults.set(data, forKey: GitHubStatusPreferenceKey.presentedIncidentIdentities)
    }
}
