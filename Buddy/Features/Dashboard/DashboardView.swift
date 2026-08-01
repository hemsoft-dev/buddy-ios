import SwiftUI

struct DashboardView: View {
    @State private var viewModel = DashboardViewModel(
        integrations: IntegrationCatalog.defaultIntegrations
    )
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
                case .connected:
                    connectedContent
                case let .needsAttention(message):
                    needsAttentionContent(message)
                }
            }
            .background(BuddyTheme.background)
            .navigationTitle("Buddy")
            .toolbar {
                if DashboardPresentation(githubState: githubViewModel.state) == .connected {
                    ToolbarItem(placement: .topBarTrailing) {
                        if viewModel.isRefreshing {
                            ProgressView()
                                .accessibilityLabel("Refreshing dashboards")
                        } else {
                            Button("Refresh", systemImage: "arrow.clockwise") {
                                Task { await viewModel.refresh() }
                            }
                        }
                    }
                }
            }
        }
        .task(id: DashboardPresentation(githubState: githubViewModel.state)) {
            guard DashboardPresentation(githubState: githubViewModel.state) == .connected else {
                return
            }
            await viewModel.refresh()
        }
    }

    private var connectedContent: some View {
        ScrollView {
            LazyVStack(spacing: BuddyTheme.Spacing.medium) {
                welcomeCard

                ForEach(viewModel.cards) { card in
                    DashboardCardView(card: card)
                }
            }
            .padding(BuddyTheme.Spacing.medium)
        }
        .refreshable {
            await viewModel.refresh()
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
    case connected
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
        case .connected:
            self = .connected
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
