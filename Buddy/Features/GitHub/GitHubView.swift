import SwiftUI

struct GitHubView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Connect GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            } description: {
                Text("GitHub will be Buddy's first external dashboard. Authorization and account details will stay on this device.")
            } actions: {
                Button("Connection setup coming next") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
            }
            .navigationTitle("GitHub")
        }
    }
}

#Preview {
    GitHubView()
}
