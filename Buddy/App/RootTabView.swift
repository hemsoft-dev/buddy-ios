import Observation
import SwiftUI

struct RootTabView: View {
    @State private var navigation = AppNavigation()
    @State private var githubViewModel = GitHubViewModel()

    var body: some View {
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
                    githubViewModel: githubViewModel
                )
            }
        }
        .tint(BuddyTheme.accent)
        .task {
            await githubViewModel.restore()
        }
        .onOpenURL { url in
            guard let route = AppRoute(url: url) else {
                AppLogger.routing.notice("Ignored unrecognized callback URL")
                return
            }

            AppLogger.routing.info("Received callback for \(route.provider, privacy: .public)")
        }
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
