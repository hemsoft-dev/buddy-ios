import Observation
import SwiftUI

struct GitHubView: View {
    @Environment(\.openURL) private var openURL
    @State private var viewModel = GitHubViewModel()

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .loading:
                    ProgressView("Checking GitHub connection…")
                case .disconnected:
                    disconnectedContent
                case let .authorizing(authorization):
                    authorizingContent(authorization)
                case let .connected(account):
                    connectedContent(account)
                case let .needsAttention(message):
                    needsAttentionContent(message)
                }
            }
            .navigationTitle("GitHub")
        }
        .task {
            await viewModel.restore()
        }
    }

    private var disconnectedContent: some View {
        ContentUnavailableView {
            Label("Connect GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
        } description: {
            Text("Authorize Buddy to read your public GitHub identity. Your access token stays in this device's Keychain.")
        } actions: {
            Button("Connect GitHub") {
                viewModel.connect(openURL: openURL)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func authorizingContent(_ authorization: GitHubDeviceAuthorization) -> some View {
        VStack(spacing: BuddyTheme.Spacing.medium) {
            Image(systemName: "person.badge.key.fill")
                .font(.largeTitle)
                .foregroundStyle(BuddyTheme.accent)

            Text("Enter this code on GitHub")
                .font(.headline)

            Text(authorization.userCode)
                .font(.system(.title, design: .monospaced, weight: .bold))
                .textSelection(.enabled)
                .accessibilityLabel("GitHub device code \(authorization.userCode)")

            Text("Buddy opened GitHub in your browser and will finish connecting after you approve access.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Open GitHub Again") {
                openURL(authorization.verificationURI)
            }
            .buttonStyle(.borderedProminent)

            Button("Cancel", role: .cancel) {
                viewModel.cancel()
            }
        }
        .padding(BuddyTheme.Spacing.medium)
    }

    private func connectedContent(_ account: GitHubAccount) -> some View {
        Form {
            Section("Connected account") {
                LabeledContent("Username", value: "@\(account.login)")

                if let name = account.name, !name.isEmpty {
                    LabeledContent("Name", value: name)
                }
            }

            Section {
                Button("Disconnect GitHub", role: .destructive) {
                    Task { await viewModel.disconnect() }
                }
            } footer: {
                Text("Disconnecting removes Buddy's GitHub access token from this device.")
            }
        }
    }

    private func needsAttentionContent(_ message: String) -> some View {
        ContentUnavailableView {
            Label("GitHub Needs Attention", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                viewModel.retry(openURL: openURL)
            }
            .buttonStyle(.borderedProminent)

            Button("Disconnect", role: .destructive) {
                Task { await viewModel.disconnect() }
            }
        }
    }
}

@MainActor
@Observable
final class GitHubViewModel {
    private(set) var state: GitHubViewState = .loading

    private let integration: GitHubIntegration
    private var connectionTask: Task<Void, Never>?
    private var retryAction = RetryAction.restore

    init(integration: GitHubIntegration = IntegrationCatalog.github) {
        self.integration = integration
    }

    func restore() async {
        connectionTask?.cancel()
        state = .loading

        do {
            if let account = try await integration.restoreAccount() {
                state = .connected(account)
            } else {
                state = .disconnected
            }
        } catch is CancellationError {
            return
        } catch {
            retryAction = (error as? GitHubConnectionError) == .invalidToken ? .connect : .restore
            state = .needsAttention(error.localizedDescription)
        }
    }

    func connect(openURL: OpenURLAction) {
        connectionTask?.cancel()
        retryAction = .connect
        connectionTask = Task {
            do {
                let authorization = try await integration.beginAuthorization()
                try Task.checkCancellation()
                state = .authorizing(authorization)
                openURL(authorization.verificationURI)

                let account = try await integration.completeAuthorization(authorization)
                try Task.checkCancellation()
                state = .connected(account)
            } catch is CancellationError {
                state = .disconnected
            } catch {
                state = .needsAttention(error.localizedDescription)
            }
        }
    }

    func retry(openURL: OpenURLAction) {
        switch retryAction {
        case .connect:
            connect(openURL: openURL)
        case .restore:
            Task { await restore() }
        }
    }

    func cancel() {
        connectionTask?.cancel()
        connectionTask = nil
        state = .disconnected
        Task {
            do {
                try await integration.cancelAuthorization()
            } catch {
                retryAction = .restore
                state = .needsAttention(error.localizedDescription)
            }
        }
    }

    func disconnect() async {
        connectionTask?.cancel()
        connectionTask = nil

        do {
            try await integration.disconnect()
            state = .disconnected
        } catch {
            retryAction = .restore
            state = .needsAttention(error.localizedDescription)
        }
    }

    private enum RetryAction {
        case connect
        case restore
    }
}

enum GitHubViewState: Equatable {
    case loading
    case disconnected
    case authorizing(GitHubDeviceAuthorization)
    case connected(GitHubAccount)
    case needsAttention(String)
}

#Preview {
    GitHubView()
}
