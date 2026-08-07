import Foundation
import Observation

protocol GitHubPullRequestProviding: Sendable {
    func authoredPullRequests(for account: GitHubAccount) async throws -> GitHubPullRequestCollection
    func assignedPullRequests(for account: GitHubAccount) async throws -> GitHubPullRequestCollection
}

extension GitHubIntegration: GitHubPullRequestProviding {}

enum GitHubPullRequestSection: CaseIterable, Hashable, Sendable {
    case authored
    case assigned
}

enum DashboardGitHubPullRequestCopy {
    static func emptyStateDescription(
        login: String,
        section: GitHubPullRequestSection
    ) -> String {
        switch section {
        case .authored:
            "@\(login) has no public authored pull requests open right now. Buddy's current GitHub authorization is limited to public repositories."
        case .assigned:
            "No public open pull requests currently request a review from @\(login). Buddy's current GitHub authorization is limited to public repositories."
        }
    }

    static func accountSummary(
        authoredVisible: Int,
        authoredTotal: Int,
        assignedVisible: Int,
        assignedTotal: Int
    ) -> String {
        "\(countSummary(visible: authoredVisible, total: authoredTotal)) authored · " +
            "\(countSummary(visible: assignedVisible, total: assignedTotal)) assigned"
    }

    private static func countSummary(visible: Int, total: Int) -> String {
        total > visible ? "\(visible) of \(total)" : "\(visible)"
    }
}

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

struct GitHubPullRequestRepositoryGroup: Identifiable, Equatable, Sendable {
    let id: String
    let pullRequests: [GitHubPullRequest]

    static func grouped(_ pullRequests: [GitHubPullRequest]) -> [Self] {
        Dictionary(grouping: pullRequests, by: \.repository)
            .map { repository, pullRequests in
                Self(
                    id: repository,
                    pullRequests: pullRequests.sorted {
                        if $0.updatedAt != $1.updatedAt {
                            return $0.updatedAt > $1.updatedAt
                        }
                        return $0.id < $1.id
                    }
                )
            }
            .sorted {
                let left = $0.id.lowercased()
                let right = $1.id.lowercased()
                return left == right ? $0.id < $1.id : left < right
            }
    }
}

struct DashboardGitHubPullRequestTreeSnapshot: Equatable {
    let accountID: Int
    let section: GitHubPullRequestSection
    let repositories: [String]

    init?(
        accountID: Int,
        section: GitHubPullRequestSection = .authored,
        dataAccountID: Int?,
        state: GitHubPullRequestDashboardState
    ) {
        guard dataAccountID == accountID else { return nil }

        let pullRequests: [GitHubPullRequest]
        switch state {
        case .loading:
            return nil
        case let .loaded(loadedPullRequests, _):
            pullRequests = loadedPullRequests
        case let .refreshing(previousPullRequests, refreshedAt):
            guard refreshedAt != nil || !previousPullRequests.isEmpty else { return nil }
            pullRequests = previousPullRequests
        case let .failed(previousPullRequests, refreshedAt, _):
            guard refreshedAt != nil || !previousPullRequests.isEmpty else { return nil }
            pullRequests = previousPullRequests
        }

        self.accountID = accountID
        self.section = section
        repositories = GitHubPullRequestRepositoryGroup.grouped(pullRequests).map(\.id)
    }
}

struct DashboardGitHubPullRequestTreeExpansionState: Equatable {
    private struct SectionState: Equatable {
        var isExpanded = false
        var expandedRepositories: Set<String> = []
    }

    private struct AccountState: Equatable {
        var sections: [GitHubPullRequestSection: SectionState] = [:]
    }

    private var accounts: [Int: AccountState] = [:]

    func isPullRequestSectionExpanded(
        for accountID: Int,
        section: GitHubPullRequestSection = .authored
    ) -> Bool {
        accounts[accountID]?.sections[section]?.isExpanded ?? false
    }

    func isRepositoryExpanded(
        _ repository: String,
        for accountID: Int,
        section: GitHubPullRequestSection = .authored
    ) -> Bool {
        accounts[accountID]?.sections[section]?.expandedRepositories.contains(repository) ?? false
    }

    mutating func togglePullRequestSection(
        for accountID: Int,
        section: GitHubPullRequestSection = .authored
    ) {
        accounts[accountID, default: AccountState()]
            .sections[section, default: SectionState()].isExpanded.toggle()
    }

    mutating func toggleRepository(
        _ repository: String,
        for accountID: Int,
        section: GitHubPullRequestSection = .authored
    ) {
        if accounts[accountID, default: AccountState()]
            .sections[section, default: SectionState()].expandedRepositories.contains(repository) {
            accounts[accountID]?.sections[section]?.expandedRepositories.remove(repository)
        } else {
            accounts[accountID]?.sections[section, default: SectionState()]
                .expandedRepositories.insert(repository)
        }
    }

    mutating func reconcile(
        accountID: Int,
        section: GitHubPullRequestSection = .authored,
        repositories: [String]
    ) {
        accounts[accountID, default: AccountState()]
            .sections[section, default: SectionState()]
            .expandedRepositories.formIntersection(repositories)
    }
}

@MainActor
@Observable
final class DashboardViewModel {
    private struct RefreshKey: Hashable {
        let accountID: ConnectedAccountID
        let section: GitHubPullRequestSection
    }

    private(set) var cards: [DashboardCard]
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    private(set) var githubStates: [ConnectedAccountID: GitHubPullRequestDashboardState] = [:]
    private(set) var githubTotalCounts: [ConnectedAccountID: Int] = [:]
    private(set) var githubAssignedStates: [ConnectedAccountID: GitHubPullRequestDashboardState] = [:]
    private(set) var githubAssignedTotalCounts: [ConnectedAccountID: Int] = [:]
    private var githubRefreshesInFlight: Set<RefreshKey> = []

    private let integrations: [any IntegrationProviding]
    private let github: any GitHubPullRequestProviding
    private let now: @MainActor @Sendable () -> Date
    private(set) var githubAccountID: Int?
    private var githubRefreshGenerations: [RefreshKey: Int] = [:]

    var githubState: GitHubPullRequestDashboardState {
        guard let githubAccountID else { return .loading }
        let id = ConnectedAccountID(provider: .github, subject: String(githubAccountID))
        return githubStates[id] ?? .loading
    }

    var githubTotalCount: Int {
        guard let githubAccountID else { return 0 }
        let id = ConnectedAccountID(provider: .github, subject: String(githubAccountID))
        return githubTotalCounts[id] ?? 0
    }

    var isGitHubRefreshInFlight: Bool { !githubRefreshesInFlight.isEmpty }

    func githubState(
        for account: GitHubAccount,
        section: GitHubPullRequestSection = .authored
    ) -> GitHubPullRequestDashboardState {
        switch section {
        case .authored:
            githubStates[account.connectedAccountID] ?? .loading
        case .assigned:
            githubAssignedStates[account.connectedAccountID] ?? .loading
        }
    }

    func githubTotalCount(
        for account: GitHubAccount,
        section: GitHubPullRequestSection = .authored
    ) -> Int {
        switch section {
        case .authored:
            githubTotalCounts[account.connectedAccountID] ?? 0
        case .assigned:
            githubAssignedTotalCounts[account.connectedAccountID] ?? 0
        }
    }

    func githubRefreshedAt(for account: GitHubAccount) -> Date? {
        GitHubPullRequestSection.allCases
            .compactMap { githubState(for: account, section: $0).refreshedAt }
            .max()
    }

    func isGitHubRefreshInFlight(for account: GitHubAccount) -> Bool {
        githubRefreshesInFlight.contains { $0.accountID == account.connectedAccountID }
    }

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
        async let authoredFailure = refresh(account: account, section: .authored)
        async let assignedFailure = refresh(account: account, section: .assigned)
        let failures = await [authoredFailure, assignedFailure].compactMap { $0 }
        if failures.contains(.authenticationRequired) {
            for section in GitHubPullRequestSection.allCases {
                let state = githubState(for: account, section: section)
                setGitHubState(
                    .failed(
                        state.pullRequests,
                        refreshedAt: state.refreshedAt,
                        .authenticationRequired
                    ),
                    for: account.connectedAccountID,
                    section: section
                )
            }
            return .authenticationRequired
        }
        return failures.first
    }

    @discardableResult
    func refresh(
        account: GitHubAccount,
        section: GitHubPullRequestSection
    ) async -> GitHubPullRequestFailure? {
        let accountID = account.connectedAccountID
        let refreshKey = RefreshKey(accountID: accountID, section: section)
        githubAccountID = account.id
        guard !githubRefreshesInFlight.contains(refreshKey) else { return nil }

        githubRefreshGenerations[refreshKey, default: 0] &+= 1
        let refreshGeneration = githubRefreshGenerations[refreshKey]
        githubRefreshesInFlight.insert(refreshKey)
        defer {
            if githubRefreshGenerations[refreshKey] == refreshGeneration {
                githubRefreshesInFlight.remove(refreshKey)
            }
        }
        let previousState = githubState(for: account, section: section)
        let previousPullRequests = previousState.pullRequests
        let previousRefreshDate = previousState.refreshedAt
        setGitHubState(
            previousRefreshDate == nil && previousPullRequests.isEmpty
            ? .loading
            : .refreshing(previousPullRequests, refreshedAt: previousRefreshDate),
            for: accountID,
            section: section
        )

        do {
            let collection = switch section {
            case .authored:
                try await github.authoredPullRequests(for: account)
            case .assigned:
                try await github.assignedPullRequests(for: account)
            }
            let pullRequests = collection.pullRequests
                .sorted { $0.updatedAt > $1.updatedAt }
            guard githubRefreshGenerations[refreshKey] == refreshGeneration else { return nil }
            setGitHubTotalCount(collection.totalCount, for: accountID, section: section)
            setGitHubState(.loaded(pullRequests, refreshedAt: now()), for: accountID, section: section)
            return nil
        } catch is CancellationError {
            guard githubRefreshGenerations[refreshKey] == refreshGeneration else { return nil }
            if let previousRefreshDate {
                setGitHubState(
                    .loaded(previousPullRequests, refreshedAt: previousRefreshDate),
                    for: accountID,
                    section: section
                )
            } else {
                setGitHubState(.loading, for: accountID, section: section)
            }
            return nil
        } catch {
            guard githubRefreshGenerations[refreshKey] == refreshGeneration else { return nil }
            let failure = Self.mapGitHubFailure(error)
            setGitHubState(
                .failed(previousPullRequests, refreshedAt: previousRefreshDate, failure),
                for: accountID,
                section: section
            )
            AppLogger.integrations.error("GitHub pull request section refresh failed")
            return failure
        }
    }

    private func setGitHubState(
        _ state: GitHubPullRequestDashboardState,
        for accountID: ConnectedAccountID,
        section: GitHubPullRequestSection
    ) {
        switch section {
        case .authored:
            githubStates[accountID] = state
        case .assigned:
            githubAssignedStates[accountID] = state
        }
    }

    private func setGitHubTotalCount(
        _ count: Int,
        for accountID: ConnectedAccountID,
        section: GitHubPullRequestSection
    ) {
        switch section {
        case .authored:
            githubTotalCounts[accountID] = count
        case .assigned:
            githubAssignedTotalCounts[accountID] = count
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
        case .accountStorage, .accountMismatch:
            .unknown
        default:
            .unknown
        }
    }
}
