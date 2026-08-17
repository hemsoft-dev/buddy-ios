import Observation
import SwiftUI

struct RootTabView: View {
    @State private var navigation = AppNavigation()
    @State private var githubViewModel = GitHubViewModel()
    @State private var githubStatusMonitor = GitHubStatusMonitor()
    @AppStorage(GitHubStatusPreferenceKey.monitoringEnabled)
    private var githubStatusMonitoringEnabled = false
    @AppStorage(GitHubStatusPreferenceKey.presentationStyle)
    private var githubStatusPresentationStyleRawValue = GitHubStatusPresentationStyle.alert.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            if githubStatusMonitoringEnabled,
               githubStatusPresentationStyle == .banner,
               let incident = githubStatusMonitor.currentIncident {
                GitHubStatusBanner(incident: incident)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            TabView(selection: $navigation.selectedTab) {
                Tab("Home", systemImage: "rectangle.grid.2x2.fill", value: .home) {
                    DashboardView(
                        githubViewModel: githubViewModel,
                        openAccounts: navigation.openAccounts
                    )
                }

                Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                    SettingsView(
                        path: $navigation.settingsPath,
                        githubViewModel: githubViewModel,
                        githubStatusMonitoringEnabled: $githubStatusMonitoringEnabled,
                        githubStatusPresentationStyle: githubStatusPresentationStyleBinding
                    )
                }
            }
            .tint(BuddyTheme.accent)
        }
        .task {
            await githubViewModel.restore()
        }
        .task(id: statusMonitorTaskID) {
            guard githubStatusMonitoringEnabled else {
                githubStatusMonitor.disable()
                return
            }
            await refreshGitHubStatus()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                await refreshGitHubStatus()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, githubStatusMonitoringEnabled else { return }
            Task { await refreshGitHubStatus() }
        }
        .alert(
            "GitHub Status incident",
            isPresented: pendingAlertBinding,
            presenting: githubStatusMonitor.pendingAlert
        ) { incident in
            Button("Open GitHub Status") {
                openURL(incident.detailsURL)
                githubStatusMonitor.dismissAlert()
            }
            Button("Dismiss", role: .cancel) {
                githubStatusMonitor.dismissAlert()
            }
        } message: { incident in
            Text("\(incident.title)\n\(incident.summary)\nUpdated \(incident.updatedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        .onOpenURL { url in
            guard let route = AppRoute(url: url) else {
                AppLogger.routing.notice("Ignored unrecognized callback URL")
                return
            }

            AppLogger.routing.info("Received callback for \(route.provider, privacy: .public)")
        }
    }

    private var githubStatusPresentationStyle: GitHubStatusPresentationStyle {
        GitHubStatusPresentationStyle(rawValue: githubStatusPresentationStyleRawValue) ?? .alert
    }

    private var githubStatusPresentationStyleBinding: Binding<GitHubStatusPresentationStyle> {
        Binding(
            get: { githubStatusPresentationStyle },
            set: { githubStatusPresentationStyleRawValue = $0.rawValue }
        )
    }

    private var pendingAlertBinding: Binding<Bool> {
        Binding(
            get: {
                githubStatusMonitoringEnabled &&
                    githubStatusPresentationStyle == .alert &&
                    githubStatusMonitor.pendingAlert != nil
            },
            set: { isPresented in
                if !isPresented { githubStatusMonitor.dismissAlert() }
            }
        )
    }

    private var statusMonitorTaskID: String {
        "\(githubStatusMonitoringEnabled):\(githubStatusPresentationStyle.rawValue)"
    }

    private func refreshGitHubStatus() async {
        await githubStatusMonitor.refresh(
            isEnabled: githubStatusMonitoringEnabled,
            style: githubStatusPresentationStyle
        )
    }
}

enum AppTab: Hashable {
    case home
    case settings
}

@MainActor
@Observable
final class AppNavigation {
    var selectedTab = AppTab.home
    var settingsPath: [SettingsRoute] = []

    func openAccounts() {
        settingsPath = [.accounts]
        selectedTab = .settings
    }
}

#Preview {
    RootTabView()
}
