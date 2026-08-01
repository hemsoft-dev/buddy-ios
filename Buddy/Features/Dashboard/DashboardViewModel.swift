import Foundation
import Observation

protocol GitHubPullRequestProviding: Sendable {
    func authoredPullRequests(for account: GitHubAccount) async throws -> GitHubPullRequestCollection
}

extension GitHubIntegration: GitHubPullRequestProviding {}

enum GitHubPullRequestFailure: Equatable, Sendable {
    case authenticationRequired
    case offline
    case rateLimited
    case incompleteResults
    case malformedResponse
    case server
    case credentialStorage
    case unknown

    var message: String {
        switch self {
        case .authenticationRequired:
            "GitHub authorization expired. Reconnect the account in Settings."
        case .offline:
            "Buddy is offline. Previously loaded pull requests remain available."
        case .rateLimited:
            "GitHub's request limit was reached. Try refreshing again later."
        case .incompleteResults:
            "GitHub returned partial search results. Refresh to try again."
        case .malformedResponse:
            "GitHub returned an unexpected response. Try again in a moment."
        case .server:
            "GitHub is temporarily unavailable. Try again later."
        case .credentialStorage:
            "Buddy couldn't read the GitHub authorization from Keychain."
        case .unknown:
            "Pull requests couldn't be refreshed. Try again."
        }
    }
}

enum GitHubPullRequestDashboardState: Equatable, Sendable {
    case loading
    case loaded([GitHubPullRequest], refreshedAt: Date)
    case refreshing([GitHubPullRequest], refreshedAt: Date?)
    case failed([GitHubPullRequest], refreshedAt: Date?, GitHubPullRequestFailure)

    var pullRequests: [GitHubPullRequest] {
        switch self {
        case .loading:
            []
        case let .loaded(pullRequests, _),
             let .refreshing(pullRequests, _),
             let .failed(pullRequests, _, _):
            pullRequests
        }
    }

    var refreshedAt: Date? {
        switch self {
        case .loading:
            nil
        case let .loaded(_, refreshedAt):
            refreshedAt
        case let .refreshing(_, refreshedAt),
             let .failed(_, refreshedAt, _):
            refreshedAt
        }
    }

}

@MainActor
@Observable
final class DashboardViewModel {
    private(set) var cards: [DashboardCard]
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    private(set) var githubState = GitHubPullRequestDashboardState.loading
    private(set) var githubTotalCount = 0
    private(set) var isGitHubRefreshInFlight = false

    private let integrations: [any IntegrationProviding]
    private let github: any GitHubPullRequestProviding
    private let now: @MainActor @Sendable () -> Date
    private var githubAccountID: Int?
    private var githubRefreshGeneration = 0

    init(
        integrations: [any IntegrationProviding],
        github: any GitHubPullRequestProviding = IntegrationCatalog.github,
        now: @escaping @MainActor @Sendable () -> Date = { .now }
    ) {
        self.integrations = integrations
        self.github = github
        self.now = now
        cards = integrations.map { DashboardCard(summary: $0.summary) }
    }

    @discardableResult
    func refresh(account: GitHubAccount) async -> GitHubPullRequestFailure? {
        let accountChanged = githubAccountID != account.id
        if accountChanged {
            githubAccountID = account.id
            githubState = .loading
            githubTotalCount = 0
        }
        guard !isGitHubRefreshInFlight || accountChanged else { return nil }

        let requestedAccountID = account.id
        githubRefreshGeneration &+= 1
        let refreshGeneration = githubRefreshGeneration
        isGitHubRefreshInFlight = true
        defer {
            if githubRefreshGeneration == refreshGeneration {
                isGitHubRefreshInFlight = false
            }
        }
        let previousPullRequests = githubState.pullRequests
        let previousRefreshDate = githubState.refreshedAt
        githubState = previousRefreshDate == nil && previousPullRequests.isEmpty
            ? .loading
            : .refreshing(previousPullRequests, refreshedAt: previousRefreshDate)

        do {
            let collection = try await github.authoredPullRequests(for: account)
            let pullRequests = collection.pullRequests
                .sorted { $0.updatedAt > $1.updatedAt }
            guard githubAccountID == requestedAccountID,
                  githubRefreshGeneration == refreshGeneration
            else { return nil }
            githubTotalCount = collection.totalCount
            githubState = .loaded(pullRequests, refreshedAt: now())
            return nil
        } catch is CancellationError {
            guard githubAccountID == requestedAccountID,
                  githubRefreshGeneration == refreshGeneration
            else { return nil }
            if let previousRefreshDate {
                githubState = .loaded(previousPullRequests, refreshedAt: previousRefreshDate)
            } else {
                githubState = .loading
            }
            return nil
        } catch {
            guard githubAccountID == requestedAccountID,
                  githubRefreshGeneration == refreshGeneration
            else { return nil }
            let failure = Self.mapGitHubFailure(error)
            githubState = .failed(
                previousPullRequests,
                refreshedAt: previousRefreshDate,
                failure
            )
            AppLogger.integrations.error("GitHub pull request refresh failed")
            return failure
        }
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

    private static func mapGitHubFailure(_ error: Error) -> GitHubPullRequestFailure {
        guard let error = error as? GitHubConnectionError else {
            return error is URLError ? .offline : .unknown
        }

        return switch error {
        case .invalidToken:
            .authenticationRequired
        case .networkUnavailable:
            .offline
        case .rateLimited:
            .rateLimited
        case .incompleteResults:
            .incompleteResults
        case .malformedResponse:
            .malformedResponse
        case .server:
            .server
        case .credentialStorage:
            .credentialStorage
        default:
            .unknown
        }
    }
}
