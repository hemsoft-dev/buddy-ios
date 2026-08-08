import Foundation
import Observation

protocol GitHubPullRequestDetailProviding: Sendable {
    func pullRequestDetails(
        for pullRequest: GitHubPullRequest,
        account: GitHubAccount
    ) async throws -> GitHubPullRequestDetails
}

extension GitHubIntegration: GitHubPullRequestDetailProviding {}

struct GitHubPullRequestDetailKey: Hashable, Sendable {
    let accountID: ConnectedAccountID
    let repository: String
    let number: Int

    init(account: GitHubAccount, pullRequest: GitHubPullRequest) {
        accountID = account.connectedAccountID
        repository = pullRequest.repository
        number = pullRequest.number
    }
}

enum GitHubPullRequestDetailState: Equatable, Sendable {
    case idle
    case loading
    case loaded(GitHubPullRequestDetails)
    case refreshing(GitHubPullRequestDetails)
    case failed(GitHubPullRequestDetails?, GitHubPullRequestFailure)

    var details: GitHubPullRequestDetails? {
        switch self {
        case .idle, .loading:
            nil
        case let .loaded(details), let .refreshing(details):
            details
        case let .failed(details, _):
            details
        }
    }
}

enum GitHubPullRequestDetailCopy {
    static let navigationHint = "Opens pull request details in Buddy"

    static func diffAccessibilityLabel(_ details: GitHubPullRequestDetails) -> String {
        "Diff summary, \(details.changedFiles) changed files, \(details.changedLines) changed lines, " +
            "\(details.additions) additions, \(details.deletions) deletions"
    }
}

@MainActor
@Observable
final class GitHubPullRequestDetailStore {
    private struct InFlight {
        let generation: Int
        let task: Task<GitHubPullRequestDetails, Error>
    }

    private let provider: any GitHubPullRequestDetailProviding
    private var states: [GitHubPullRequestDetailKey: GitHubPullRequestDetailState] = [:]
    private var generations: [GitHubPullRequestDetailKey: Int] = [:]
    private var inFlight: [GitHubPullRequestDetailKey: InFlight] = [:]

    init(provider: any GitHubPullRequestDetailProviding = IntegrationCatalog.github) {
        self.provider = provider
    }

    func state(
        for pullRequest: GitHubPullRequest,
        account: GitHubAccount
    ) -> GitHubPullRequestDetailState {
        states[GitHubPullRequestDetailKey(account: account, pullRequest: pullRequest)] ?? .idle
    }

    func load(
        _ pullRequest: GitHubPullRequest,
        account: GitHubAccount,
        forceRefresh: Bool = false
    ) async {
        let key = GitHubPullRequestDetailKey(account: account, pullRequest: pullRequest)
        if !forceRefresh {
            if case .loaded = states[key] { return }
            if let existing = inFlight[key] {
                _ = try? await existing.task.value
                return
            }
        }

        inFlight[key]?.task.cancel()
        generations[key, default: 0] &+= 1
        let generation = generations[key, default: 0]
        let previous = states[key]?.details
        states[key] = previous.map(GitHubPullRequestDetailState.refreshing) ?? .loading

        let task = Task {
            try await provider.pullRequestDetails(for: pullRequest, account: account)
        }
        inFlight[key] = InFlight(generation: generation, task: task)

        do {
            let details = try await task.value
            guard generations[key] == generation else { return }
            inFlight.removeValue(forKey: key)
            states[key] = .loaded(details)
        } catch is CancellationError {
            guard generations[key] == generation else { return }
            inFlight.removeValue(forKey: key)
            states[key] = previous.map(GitHubPullRequestDetailState.loaded) ?? .idle
        } catch {
            guard generations[key] == generation else { return }
            inFlight.removeValue(forKey: key)
            states[key] = .failed(previous, Self.mapFailure(error))
            AppLogger.integrations.error("GitHub pull request detail refresh failed")
        }
    }

    func refresh(_ pullRequest: GitHubPullRequest, account: GitHubAccount) async {
        await load(pullRequest, account: account, forceRefresh: true)
    }

    func retry(_ pullRequest: GitHubPullRequest, account: GitHubAccount) async {
        await load(pullRequest, account: account, forceRefresh: true)
    }

    func cancel(_ pullRequest: GitHubPullRequest, account: GitHubAccount) {
        let key = GitHubPullRequestDetailKey(account: account, pullRequest: pullRequest)
        guard let request = inFlight.removeValue(forKey: key) else { return }
        generations[key, default: 0] = max(generations[key, default: 0], request.generation) + 1
        request.task.cancel()
        states[key] = states[key]?.details.map(GitHubPullRequestDetailState.loaded) ?? .idle
    }

    private static func mapFailure(_ error: Error) -> GitHubPullRequestFailure {
        guard let error = error as? GitHubConnectionError else {
            return error is URLError ? .offline : .unknown
        }
        return switch error {
        case .invalidToken: .authenticationRequired
        case .privateRepositoryAccessRequired: .repositoryAccessRequired
        case .networkUnavailable: .offline
        case .rateLimited: .rateLimited
        case .incompleteResults: .incompleteResults
        case .malformedResponse: .malformedResponse
        case .server: .server
        case .credentialStorage: .credentialStorage
        default: .unknown
        }
    }
}
