import SwiftUI

@propertyWrapper
struct DashboardGitHubCardExpansionStorage: DynamicProperty {
    static let legacyKey = "dashboard.github.account-card.expanded"
    static let key = "dashboard.github.account-card.expanded-accounts.v1"

    @AppStorage private var encodedAccountIDs: Data
    @AppStorage private var legacyValue: Bool

    init(store: UserDefaults? = nil) {
        _encodedAccountIDs = AppStorage(wrappedValue: Data(), Self.key, store: store)
        _legacyValue = AppStorage(wrappedValue: false, Self.legacyKey, store: store)
    }

    var wrappedValue: Set<ConnectedAccountID> {
        get {
            guard !encodedAccountIDs.isEmpty,
                  let ids = try? JSONDecoder().decode([ConnectedAccountID].self, from: encodedAccountIDs)
            else {
                return []
            }
            return Set(ids)
        }
        nonmutating set {
            encodedAccountIDs = (try? JSONEncoder().encode(newValue.sorted())) ?? Data()
        }
    }

    var projectedValue: Self { self }

    /// Applies the pre-multi-account preference to the first restored account once.
    /// A legacy `false` value needs no migration because new accounts default collapsed.
    nonmutating func migrateLegacyExpansion(to accountID: ConnectedAccountID?) {
        guard legacyValue else { return }
        guard wrappedValue.isEmpty else {
            legacyValue = false
            return
        }
        guard let accountID else { return }
        wrappedValue = [accountID]
        legacyValue = false
    }
}

struct DashboardView: View {
    @State private var viewModel = DashboardViewModel(
        integrations: IntegrationCatalog.defaultIntegrations
    )
    @DashboardGitHubCardExpansionStorage private var expandedGitHubAccountCards
    @State private var githubPullRequestTreeExpansion = DashboardGitHubPullRequestTreeExpansionState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let githubViewModel: GitHubViewModel
    let openAccounts: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch dashboardPresentation {
                case .loading:
                    ProgressView("Checking account connections…")
                case .onboarding:
                    onboardingContent
                case .configurationRequired:
                    configurationRequiredContent
                case .authorizing:
                    authorizingContent
                case .connected:
                    connectedContent(githubViewModel.accounts)
                case let .needsAttention(message):
                    needsAttentionContent(message)
                }
            }
            .background(BuddyTheme.background)
            .navigationTitle("Buddy")
            .toolbar {
                if !githubViewModel.accounts.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        if viewModel.isGitHubRefreshInFlight {
                            ProgressView()
                                .accessibilityLabel("Refreshing GitHub pull requests")
                        } else {
                            Button("Refresh", systemImage: "arrow.clockwise") {
                                Task { await refreshConnectedAccounts() }
                            }
                        }
                    }
                }
            }
        }
        .task(id: accountRefreshKey) {
            $expandedGitHubAccountCards.migrateLegacyExpansion(to: githubViewModel.accounts.first?.id)
            await refreshConnectedAccounts()
        }
    }

    private var accountRefreshKey: [String] {
        githubViewModel.accounts.map {
            "\($0.id.rawValue):\($0.state.rawValue):\(githubViewModel.dashboardRefreshRevision(for: $0.id))"
        }
    }

    private var dashboardPresentation: DashboardPresentation {
        if let account = githubViewModel.accounts.first?.account {
            return .connected(account)
        }
        return DashboardPresentation(githubState: githubViewModel.state)
    }

    private func connectedContent(_ connections: [GitHubAccountConnection]) -> some View {
        ScrollView {
            LazyVStack(spacing: BuddyTheme.Spacing.medium) {
                welcomeCard

                ForEach(connections) { connection in
                    githubAccountCard(connection)
                }

                ForEach(viewModel.cards.filter { $0.id != "github" }) { card in
                    DashboardCardView(card: card)
                }
            }
            .padding(BuddyTheme.Spacing.medium)
        }
        .refreshable {
            await refreshConnectedAccounts()
        }
    }

    private func githubAccountCard(_ connection: GitHubAccountConnection) -> some View {
        let account = connection.account
        let isExpanded = expandedGitHubAccountCards.contains(connection.id)
        let headerSummary = connection.state == .connected
            ? githubHeaderSummary(for: account)
            : "Needs attention"
        return VStack(alignment: .leading, spacing: BuddyTheme.Spacing.medium) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy) {
                    if isExpanded {
                        expandedGitHubAccountCards.remove(connection.id)
                    } else {
                        expandedGitHubAccountCards.insert(connection.id)
                    }
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

                        Text(headerSummary)
                            .font(.caption)
                            .foregroundStyle(connection.state == .connected ? githubHeaderSummaryColor(for: account) : .orange)

                        if let refreshedAt = viewModel.githubState(for: account).refreshedAt {
                            Text("Updated \(refreshedAt, style: .relative) ago")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer(minLength: BuddyTheme.Spacing.small)

                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("GitHub account @\(account.login)")
            .accessibilityValue("\(isExpanded ? "Expanded" : "Collapsed"), \(headerSummary)")
            .accessibilityHint(isExpanded ? "Collapses GitHub account details" : "Expands GitHub account details")

            if isExpanded {
                Divider()
                Group {
                    if connection.state == .connected {
                        githubAccountBody(account)
                    } else {
                        VStack(alignment: .leading, spacing: BuddyTheme.Spacing.small) {
                            Text(connection.message ?? "Reconnect this account in Settings.")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                            Button("Reconnect in Settings", action: openAccounts)
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .buddyCard()
        .animation(reduceMotion ? nil : .snappy, value: isExpanded)
    }

    private func githubAccountBody(_ account: GitHubAccount) -> some View {
        pullRequestSection(account)
    }

    private func pullRequestSection(_ account: GitHubAccount) -> some View {
        let isExpanded = githubPullRequestTreeExpansion.isPullRequestSectionExpanded(for: account.id)
        let snapshot = DashboardGitHubPullRequestTreeSnapshot(
            accountID: account.id,
            dataAccountID: account.id,
            state: viewModel.githubState(for: account)
        )

        return VStack(alignment: .leading, spacing: BuddyTheme.Spacing.medium) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy) {
                    githubPullRequestTreeExpansion.togglePullRequestSection(for: account.id)
                }
            } label: {
                HStack(spacing: BuddyTheme.Spacing.small) {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: BuddyTheme.Spacing.xSmall) {
                        Text("My open PRs")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(githubPullRequestSectionSummary(for: account))
                            .font(.caption)
                            .foregroundStyle(githubPullRequestSectionSummaryColor(for: account))
                    }

                    Spacer(minLength: BuddyTheme.Spacing.small)

                    if case .loading = viewModel.githubState(for: account) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    } else {
                        Text("\(viewModel.githubState(for: account).pullRequests.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, BuddyTheme.Spacing.small)
                            .padding(.vertical, BuddyTheme.Spacing.xSmall)
                            .background(.secondary.opacity(0.12), in: Capsule())
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("My open pull requests")
            .accessibilityValue("\(isExpanded ? "Expanded" : "Collapsed"), \(githubPullRequestSectionSummary(for: account))")
            .accessibilityHint(isExpanded ? "Collapses pull request status and repositories" : "Expands pull request status and repositories")

            if isExpanded {
                githubPullRequestSectionContent(account)
                    .padding(.leading, BuddyTheme.Spacing.medium)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: isExpanded)
        .onChange(of: snapshot, initial: true) { _, snapshot in
            guard let snapshot else { return }
            githubPullRequestTreeExpansion.reconcile(
                accountID: snapshot.accountID,
                repositories: snapshot.repositories
            )
        }
    }

    @ViewBuilder
    private func githubPullRequestSectionContent(_ account: GitHubAccount) -> some View {
        switch viewModel.githubState(for: account) {
        case .loading:
            HStack(spacing: BuddyTheme.Spacing.small) {
                ProgressView()
                Text("Loading authored pull requests…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case let .loaded(pullRequests, _):
            pullRequestContent(pullRequests, account: account)

        case let .refreshing(pullRequests, _):
            VStack(alignment: .leading, spacing: BuddyTheme.Spacing.medium) {
                HStack(spacing: BuddyTheme.Spacing.small) {
                    ProgressView()
                    Text("Refreshing pull requests…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !pullRequests.isEmpty {
                    repositoryGroupList(pullRequests, accountID: account.id)
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
                    repositoryGroupList(pullRequests, accountID: account.id)
                }
            }
        }
    }

    @ViewBuilder
    private func pullRequestContent(_ pullRequests: [GitHubPullRequest], account: GitHubAccount) -> some View {
        if pullRequests.isEmpty {
            VStack(alignment: .leading, spacing: BuddyTheme.Spacing.small) {
                Label("No open pull requests", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text("@\(account.login) has no public authored pull requests open right now. Buddy's current GitHub authorization is limited to public repositories.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            repositoryGroupList(pullRequests, accountID: account.id)
        }
    }

    private func repositoryGroupList(_ pullRequests: [GitHubPullRequest], accountID: Int) -> some View {
        let groups = GitHubPullRequestRepositoryGroup.grouped(pullRequests)

        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 {
                    Divider()
                }
                repositoryGroup(group, accountID: accountID)
                    .padding(.vertical, BuddyTheme.Spacing.small)
            }
        }
    }

    private func repositoryGroup(
        _ group: GitHubPullRequestRepositoryGroup,
        accountID: Int
    ) -> some View {
        let isExpanded = githubPullRequestTreeExpansion.isRepositoryExpanded(group.id, for: accountID)

        return VStack(alignment: .leading, spacing: BuddyTheme.Spacing.small) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy) {
                    githubPullRequestTreeExpansion.toggleRepository(group.id, for: accountID)
                }
            } label: {
                HStack(spacing: BuddyTheme.Spacing.small) {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .accessibilityHidden(true)

                    Text(group.id)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: BuddyTheme.Spacing.small)

                    Text("\(group.pullRequests.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.id), \(pullRequestCountDescription(group.pullRequests.count))")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapses pull requests for this repository" : "Expands pull requests for this repository")

            if isExpanded {
                pullRequestList(group.pullRequests)
                    .padding(.leading, BuddyTheme.Spacing.medium)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: isExpanded)
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

    private func githubPullRequestSectionSummary(for account: GitHubAccount) -> String {
        let state = viewModel.githubState(for: account)
        let count = state.pullRequests.count
        let countDescription = "\(count) visible pull request\(count == 1 ? "" : "s")"

        return switch state {
        case .loading:
            "Loading"
        case .loaded:
            countDescription
        case .refreshing:
            "Refreshing · \(countDescription)"
        case .failed(_, _, .authenticationRequired):
            "Reconnect required · \(countDescription)"
        case .failed:
            "Refresh warning · \(countDescription)"
        }
    }

    private func githubPullRequestSectionSummaryColor(for account: GitHubAccount) -> Color {
        if case .failed = viewModel.githubState(for: account) {
            return .orange
        }
        return .secondary
    }

    private func pullRequestCountDescription(_ count: Int) -> String {
        "\(count) pull request\(count == 1 ? "" : "s")"
    }

    private func githubHeaderSummary(for account: GitHubAccount) -> String {
        let state = viewModel.githubState(for: account)
        let count = state.pullRequests.count
        let totalCount = viewModel.githubTotalCount(for: account)
        let result = totalCount > count
            ? "\(count) of \(totalCount) public open pull requests"
            : "\(count) public open pull request\(count == 1 ? "" : "s")"
        switch state {
        case .loading:
            return "Loading public pull requests"
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

    private func githubHeaderSummaryColor(for account: GitHubAccount) -> Color {
        if case .failed = viewModel.githubState(for: account) { return .orange }
        return .secondary
    }

    private func refreshPullRequests(for account: GitHubAccount) async {
        let failure = await viewModel.refresh(account: account)
        if failure == .authenticationRequired {
            githubViewModel.reportDashboardAuthenticationFailure(for: account.connectedAccountID)
        }
    }

    private func refreshConnectedAccounts() async {
        let accounts = githubViewModel.accounts
            .filter { $0.state == .connected }
            .map(\.account)
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { await refreshPullRequests(for: account) }
            }
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
