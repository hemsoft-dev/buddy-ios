import SwiftUI

struct DashboardView: View {
    @State private var viewModel = DashboardViewModel(
        integrations: IntegrationCatalog.defaultIntegrations
    )
    @AppStorage("dashboard.github.account-card.expanded") private var isGitHubCardExpanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let githubViewModel: GitHubViewModel
    let openAccounts: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch DashboardPresentation(githubState: githubViewModel.state) {
                case .loading:
                    ProgressView("Checking account connections…")
                case .onboarding:
                    onboardingContent
                case .configurationRequired:
                    configurationRequiredContent
                case .authorizing:
                    authorizingContent
                case let .connected(account):
                    connectedContent(account)
                case let .needsAttention(message):
                    needsAttentionContent(message)
                }
            }
            .background(BuddyTheme.background)
            .navigationTitle("Buddy")
            .toolbar {
                if case let .connected(account) = githubViewModel.state {
                    ToolbarItem(placement: .topBarTrailing) {
                        if viewModel.githubState.isRefreshing {
                            ProgressView()
                                .accessibilityLabel("Refreshing GitHub pull requests")
                        } else {
                            Button("Refresh", systemImage: "arrow.clockwise") {
                                Task { await refreshPullRequests(for: account) }
                            }
                        }
                    }
                }
            }
        }
        .task(id: DashboardPresentation(githubState: githubViewModel.state)) {
            guard case let .connected(account) = githubViewModel.state else {
                return
            }
            await refreshPullRequests(for: account)
        }
    }

    private func connectedContent(_ account: GitHubAccount) -> some View {
        ScrollView {
            LazyVStack(spacing: BuddyTheme.Spacing.medium) {
                welcomeCard

                githubAccountCard(account)

                ForEach(viewModel.cards.filter { $0.id != "github" }) { card in
                    DashboardCardView(card: card)
                }
            }
            .padding(BuddyTheme.Spacing.medium)
        }
        .refreshable {
            await refreshPullRequests(for: account)
        }
    }

    private func githubAccountCard(_ account: GitHubAccount) -> some View {
        VStack(alignment: .leading, spacing: BuddyTheme.Spacing.medium) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy) {
                    isGitHubCardExpanded.toggle()
                }
            } label: {
                HStack(alignment: .top, spacing: BuddyTheme.Spacing.medium) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(BuddyTheme.accent)
                        .frame(width: 44, height: 44)
                        .background(BuddyTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: BuddyTheme.Spacing.xSmall) {
                        Text(account.name.flatMap { $0.isEmpty ? nil : $0 } ?? "GitHub")
                            .font(.headline)

                        Text("@\(account.login)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text(githubHeaderSummary)
                            .font(.caption)
                            .foregroundStyle(githubHeaderSummaryColor)

                        if let refreshedAt = viewModel.githubState.refreshedAt {
                            Text("Updated \(refreshedAt, style: .relative) ago")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer(minLength: BuddyTheme.Spacing.small)

                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isGitHubCardExpanded ? 0 : -90))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("GitHub account @\(account.login)")
            .accessibilityValue(isGitHubCardExpanded ? "Expanded, \(githubHeaderSummary)" : "Collapsed, \(githubHeaderSummary)")
            .accessibilityHint(isGitHubCardExpanded ? "Collapses pull requests" : "Expands pull requests")

            if isGitHubCardExpanded {
                Divider()
                githubAccountBody(account)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .buddyCard()
        .animation(reduceMotion ? nil : .snappy, value: isGitHubCardExpanded)
    }

    @ViewBuilder
    private func githubAccountBody(_ account: GitHubAccount) -> some View {
        switch viewModel.githubState {
        case .loading:
            HStack(spacing: BuddyTheme.Spacing.small) {
                ProgressView()
                Text("Loading authored pull requests…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case let .loaded(pullRequests, _):
            pullRequestContent(pullRequests)

        case let .refreshing(pullRequests, _):
            VStack(alignment: .leading, spacing: BuddyTheme.Spacing.medium) {
                HStack(spacing: BuddyTheme.Spacing.small) {
                    ProgressView()
                    Text("Refreshing pull requests…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !pullRequests.isEmpty {
                    pullRequestList(pullRequests)
                }
            }

        case let .failed(pullRequests, _, failure):
            VStack(alignment: .leading, spacing: BuddyTheme.Spacing.medium) {
                Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                Button(failure == .authenticationRequired ? "Reconnect in Settings" : "Try Again") {
                    if failure == .authenticationRequired {
                        openAccounts()
                    } else {
                        Task { await refreshPullRequests(for: account) }
                    }
                }
                .buttonStyle(.bordered)

                if !pullRequests.isEmpty {
                    pullRequestList(pullRequests)
                }
            }
        }
    }

    @ViewBuilder
    private func pullRequestContent(_ pullRequests: [GitHubPullRequest]) -> some View {
        if pullRequests.isEmpty {
            VStack(alignment: .leading, spacing: BuddyTheme.Spacing.small) {
                Label("No open pull requests", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text("@\(connectedAccountLogin) has no authored pull requests open right now.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            pullRequestList(pullRequests)
        }
    }

    private func pullRequestList(_ pullRequests: [GitHubPullRequest]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(pullRequests.enumerated()), id: \.element.id) { index, pullRequest in
                if index > 0 {
                    Divider()
                }
                pullRequestRow(pullRequest)
                    .padding(.vertical, BuddyTheme.Spacing.small)
            }
        }
    }

    private func pullRequestRow(_ pullRequest: GitHubPullRequest) -> some View {
        Link(destination: pullRequest.url) {
            HStack(alignment: .top, spacing: BuddyTheme.Spacing.small) {
                VStack(alignment: .leading, spacing: BuddyTheme.Spacing.xSmall) {
                    Text("\(pullRequest.repository) #\(pullRequest.number)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(pullRequest.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: BuddyTheme.Spacing.small) {
                        Label(pullRequest.isDraft ? "Draft" : "Open", systemImage: pullRequest.isDraft ? "pencil.circle" : "arrow.triangle.pull")
                        Text("Updated \(pullRequest.updatedAt, style: .relative) ago")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: BuddyTheme.Spacing.small)

                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(BuddyTheme.accent)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(pullRequest.repository) pull request \(pullRequest.number), \(pullRequest.title), \(pullRequest.isDraft ? "draft" : "open")")
        .accessibilityHint("Opens on GitHub")
    }

    private var githubHeaderSummary: String {
        let count = viewModel.githubState.pullRequests.count
        let result = "\(count) open pull request\(count == 1 ? "" : "s")"
        switch viewModel.githubState {
        case .loading:
            return "Loading pull requests"
        case .loaded:
            return result
        case .refreshing:
            return "Refreshing · \(result)"
        case .failed(_, _, .authenticationRequired):
            return "Reconnect required · \(result)"
        case .failed:
            return "Refresh warning · \(result)"
        }
    }

    private var githubHeaderSummaryColor: Color {
        if case .failed = viewModel.githubState { return .orange }
        return .secondary
    }

    private var connectedAccountLogin: String {
        if case let .connected(account) = githubViewModel.state {
            return account.login
        }
        return "your account"
    }

    private func refreshPullRequests(for account: GitHubAccount) async {
        let failure = await viewModel.refresh(account: account)
        if failure == .authenticationRequired {
            githubViewModel.reportDashboardAuthenticationFailure()
        }
    }

    private var onboardingContent: some View {
        ContentUnavailableView {
            Label("Bring Your Day Into Focus", systemImage: "sparkles.rectangle.stack.fill")
        } description: {
            Text("Buddy becomes useful after you connect an account. Start with GitHub, then return here for one calm view of what needs your attention.")
        } actions: {
            Button("Connect Accounts", action: openAccounts)
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens Accounts in Settings")
        }
        .padding(BuddyTheme.Spacing.medium)
    }

    private var configurationRequiredContent: some View {
        ContentUnavailableView {
            Label("Account Setup Is Unavailable", systemImage: "wrench.and.screwdriver.fill")
        } description: {
            Text("Buddy needs additional GitHub configuration before an account can be connected.")
        } actions: {
            Button("Open Account Settings", action: openAccounts)
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens Accounts in Settings")
        }
        .padding(BuddyTheme.Spacing.medium)
    }

    private var authorizingContent: some View {
        ContentUnavailableView {
            Label("Finish Connecting GitHub", systemImage: "person.badge.key.fill")
        } description: {
            Text("Complete authorization in GitHub. Buddy will show your dashboard as soon as the account is connected.")
        } actions: {
            Button("Continue in Settings", action: openAccounts)
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens Accounts in Settings")
        }
        .padding(BuddyTheme.Spacing.medium)
    }

    private func needsAttentionContent(_ message: String) -> some View {
        ContentUnavailableView {
            Label("GitHub Needs Attention", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(message)
        } actions: {
            Button("Review Account", action: openAccounts)
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens Accounts in Settings")
        }
        .padding(BuddyTheme.Spacing.medium)
    }

    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: BuddyTheme.Spacing.small) {
            Text("Your day at a glance")
                .font(.title2.weight(.semibold))

            Text("Connect the services you rely on, then check what needs your attention in one place.")
                .font(.body)
                .foregroundStyle(.secondary)

            if let lastUpdated = viewModel.lastUpdated {
                Text("Updated \(lastUpdated, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buddyCard()
        .accessibilityElement(children: .combine)
    }
}

enum DashboardPresentation: Hashable {
    case loading
    case onboarding
    case configurationRequired
    case authorizing
    case connected(GitHubAccount)
    case needsAttention(String)

    init(githubState: GitHubViewState) {
        switch githubState {
        case .loading:
            self = .loading
        case .disconnected:
            self = .onboarding
        case .configurationRequired:
            self = .configurationRequired
        case .authorizing:
            self = .authorizing
        case let .connected(account):
            self = .connected(account)
        case let .needsAttention(message):
            self = .needsAttention(message)
        }
    }
}

private struct DashboardCardView: View {
    let card: DashboardCard
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        layout
        .buddyCard()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var layout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: BuddyTheme.Spacing.medium) {
                icon

                HStack(alignment: .top, spacing: BuddyTheme.Spacing.small) {
                    labels
                    Spacer(minLength: BuddyTheme.Spacing.small)
                    stateIcon
                }
            }
        } else {
            HStack(spacing: BuddyTheme.Spacing.medium) {
                icon
                labels
                Spacer(minLength: BuddyTheme.Spacing.small)
                stateIcon
            }
        }
    }

    private var icon: some View {
        Image(systemName: card.systemImage)
            .font(.title2.weight(.semibold))
            .foregroundStyle(card.tint)
            .frame(width: 44, height: 44)
            .background(card.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: BuddyTheme.Spacing.xSmall) {
            Text(card.title)
                .font(.headline)

            Text(card.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var stateIcon: some View {
        Image(systemName: card.state.systemImage)
            .foregroundStyle(card.state.tint)
            .accessibilityLabel(card.state.accessibilityLabel)
    }
}

#Preview {
    DashboardView(githubViewModel: GitHubViewModel(), openAccounts: {})
}
