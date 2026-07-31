import SwiftUI

struct RootTabView: View {
    @State private var selection = AppTab.home

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "rectangle.grid.2x2.fill", value: .home) {
                DashboardView()
            }

            Tab("GitHub", systemImage: "chevron.left.forwardslash.chevron.right", value: .github) {
                GitHubView()
            }

            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                SettingsView()
            }
        }
        .tint(BuddyTheme.accent)
        .onOpenURL { url in
            guard let route = AppRoute(url: url) else {
                AppLogger.routing.notice("Ignored unrecognized callback URL")
                return
            }

            AppLogger.routing.info("Received callback for \(route.provider, privacy: .public)")
        }
    }
}

private enum AppTab: Hashable {
    case home
    case github
    case settings
}

#Preview {
    RootTabView()
}
