import SwiftUI

struct DashboardView: View {
    @State private var viewModel = DashboardViewModel(
        integrations: IntegrationCatalog.defaultIntegrations
    )

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: BuddyTheme.Spacing.medium) {
                    welcomeCard

                    ForEach(viewModel.cards) { card in
                        DashboardCardView(card: card)
                    }
                }
                .padding(BuddyTheme.Spacing.medium)
            }
            .background(BuddyTheme.background)
            .navigationTitle("Buddy")
            .refreshable {
                await viewModel.refresh()
            }
            .toolbar {
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
    DashboardView()
}
