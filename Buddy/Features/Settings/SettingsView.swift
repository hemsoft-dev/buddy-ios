import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
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
        }
    }
}

#Preview {
    SettingsView()
}
