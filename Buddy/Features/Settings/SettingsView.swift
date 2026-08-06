import SwiftUI

enum SettingsRoute: Hashable {
    case accounts
    case github(ConnectedAccountID?)
}

struct SettingsView: View {
    @Binding var path: [SettingsRoute]
    let githubViewModel: GitHubViewModel

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: SettingsRoute.accounts) {
                        Label("Accounts", systemImage: "person.crop.circle.badge.gearshape")
                    }
                    .accessibilityHint("Manage connected services")
                }

                Section("Privacy") {
                    Label("Credentials stay in Keychain", systemImage: "key.fill")
                    Label("Dashboard cache stays on device", systemImage: "iphone")
                    Label("No AI or analytics", systemImage: "hand.raised.fill")
                }

                Section("About") {
                    LabeledContent("App", value: "Buddy")
                    LabeledContent("Version", value: AppConfiguration.current.versionDescription)
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .accounts:
                    AccountsSettingsView(githubViewModel: githubViewModel)
                case let .github(accountID):
                    GitHubView(viewModel: githubViewModel, accountID: accountID)
                }
            }
        }
    }
}

private struct AccountsSettingsView: View {
    let githubViewModel: GitHubViewModel

    var body: some View {
        List {
            Section {
                ForEach(githubViewModel.accounts) { connection in
                    NavigationLink(value: SettingsRoute.github(connection.id)) {
                        HStack(spacing: BuddyTheme.Spacing.medium) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .foregroundStyle(BuddyTheme.accent)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: BuddyTheme.Spacing.xSmall) {
                                Text("@\(connection.account.login)")
                                Text(connection.settingsStatus)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: BuddyTheme.Spacing.small)

                            Image(systemName: connection.settingsSystemImage)
                                .foregroundStyle(connection.settingsTint)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("GitHub @\(connection.account.login), \(connection.settingsStatus)")
                    .accessibilityHint("Manage this GitHub account")
                }

                NavigationLink(value: SettingsRoute.github(nil)) {
                    Label("Add account", systemImage: "person.crop.circle.badge.plus")
                }
                .accessibilityHint("Connect another GitHub account")
            } header: {
                Text("GitHub")
            } footer: {
                Text("Account credentials stay in this device's Keychain.")
            }
        }
        .navigationTitle("Accounts")
    }
}

private extension GitHubAccountConnection {
    var settingsStatus: String {
        switch state {
        case .connected: "Connected"
        case .disconnected: "Not connected"
        case .needsAttention: "Needs attention"
        }
    }

    var settingsSystemImage: String { state.systemImage }
    var settingsTint: Color { state.tint }
}

extension GitHubViewState {
    var settingsStatus: String {
        switch self {
        case .loading:
            "Checking connection"
        case .disconnected:
            "Not connected"
        case .configurationRequired:
            "Configuration required"
        case .authorizing:
            "Waiting for authorization"
        case let .connected(account):
            "Connected as @\(account.login)"
        case .needsAttention:
            "Needs attention"
        }
    }

    var settingsSystemImage: String {
        switch self {
        case .loading, .disconnected:
            "circle.dashed"
        case .configurationRequired, .needsAttention:
            "exclamationmark.triangle.fill"
        case .authorizing:
            "person.badge.key.fill"
        case .connected:
            "checkmark.circle.fill"
        }
    }

    var settingsTint: Color {
        switch self {
        case .connected:
            .green
        case .configurationRequired, .needsAttention:
            .orange
        case .authorizing:
            BuddyTheme.accent
        case .loading, .disconnected:
            .secondary
        }
    }
}

#Preview {
    SettingsView(path: .constant([]), githubViewModel: GitHubViewModel())
}
