import Observation
import SwiftUI

struct GitHubView: View {
    @Environment(\.openURL) private var openURL
    @State private var addedAccountID: ConnectedAccountID?
    let viewModel: GitHubViewModel
    let accountID: ConnectedAccountID?

    init(
        viewModel: GitHubViewModel,
        accountID: ConnectedAccountID? = nil,
        addedAccountID: ConnectedAccountID? = nil
    ) {
        self.viewModel = viewModel
        self.accountID = accountID
        _addedAccountID = State(initialValue: addedAccountID)
    }

    var body: some View {
        Group {
            switch presentationState {
            case .loading:
                ProgressView("Checking GitHub connection…")
            case .disconnected:
                disconnectedContent
            case let .configurationRequired(message):
                configurationRequiredContent(message)
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

    var presentationState: GitHubViewState {
        if case let .authorizing(authorization) = viewModel.state,
           viewModel.activeAccountAuthorizationTarget == presentedAccountID {
            return .authorizing(authorization)
        }
        if let presentedAccountID,
           let connection = viewModel.accounts.first(where: { $0.id == presentedAccountID }) {
            if connection.state == .needsAttention {
                return .needsAttention(connection.message ?? GitHubConnectionError.invalidToken.localizedDescription)
            }
            return .connected(connection.account)
        }
        if case let .needsAttention(message) = viewModel.state {
            return .needsAttention(message)
        }
        if presentedAccountID != nil {
            return .disconnected
        }
        if viewModel.accounts.isEmpty, viewModel.state == .loading {
            return .loading
        }
        if !viewModel.integrationIsAuthorizationConfigured {
            return .configurationRequired(GitHubConnectionError.missingClientID.localizedDescription)
        }
        return .disconnected
    }

    private func configurationRequiredContent(_ message: String) -> some View {
        ContentUnavailableView {
            Label("GitHub Isn't Configured", systemImage: "wrench.and.screwdriver.fill")
        } description: {
            Text(message)
        }
    }

    private var disconnectedContent: some View {
        ContentUnavailableView {
            Label("Connect GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
        } description: {
            Text("Authorize Buddy to read your public GitHub identity. Your access token stays in this device's Keychain.")
        } actions: {
            Button("Connect GitHub") {
                if let accountID {
                    viewModel.reconnect(accountID, openURL: openURL)
                } else {
                    viewModel.addAccount(openURL: openURL) { addedAccountID = $0 }
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var presentedAccountID: ConnectedAccountID? {
        accountID ?? addedAccountID
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
                viewModel.cancelAccountAuthorization()
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
                Button("Reconnect account") {
                    viewModel.reconnect(account.connectedAccountID, openURL: openURL)
                }

                Button("Disconnect GitHub", role: .destructive) {
                    Task { await viewModel.disconnect(account.connectedAccountID) }
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
                if let presentedAccountID {
                    viewModel.retry(presentedAccountID, openURL: openURL)
                } else {
                    viewModel.retryAccountSetup(openURL: openURL) { addedAccountID = $0 }
                }
            }
            .buttonStyle(.borderedProminent)

            Button("Disconnect", role: .destructive) {
                Task { await disconnectPresentedAccount() }
            }
        }
    }

    @MainActor
    func disconnectPresentedAccount() async {
        if let presentedAccountID {
            await viewModel.disconnect(presentedAccountID)
        } else {
            viewModel.cancelAccountAuthorization()
        }
    }
}

@MainActor
@Observable
final class GitHubViewModel {
    private(set) var state: GitHubViewState = .loading
    private(set) var accounts: [GitHubAccountConnection] = []
    private(set) var activeAccountAuthorizationTarget: ConnectedAccountID?

    private let integration: GitHubIntegration
    private var connectionTask: Task<Void, Never>?
    private var accountConnectionTask: Task<Void, Never>?
    private var activeAccountAuthorization: GitHubDeviceAuthorization?
    private var cancellationTask: Task<Void, Error>?
    private var retryAction = RetryAction.restore
    private var operationGeneration = 0
    private var accountOperationGenerations: [ConnectedAccountID: Int] = [:]

    init(integration: GitHubIntegration = IntegrationCatalog.github) {
        self.integration = integration
    }

    var integrationIsAuthorizationConfigured: Bool {
        integration.isAuthorizationConfigured
    }

    func restore() async {
        guard connectionTask == nil,
              accountConnectionTask == nil,
              cancellationTask == nil
        else {
            return
        }
        await performRestore()
    }

    private func performRestore() async {
        operationGeneration &+= 1
        let generation = operationGeneration
        connectionTask?.cancel()
        state = .loading

        do {
            let restoredAccounts = try await integration.restoreAccounts()
            guard generation == operationGeneration else { return }
            accounts = restoredAccounts
            if let account = restoredAccounts.first(where: { $0.state == .connected })?.account {
                guard generation == operationGeneration else { return }
                state = .connected(account)
            } else if let message = restoredAccounts.first?.message {
                state = .needsAttention(message)
            } else {
                guard generation == operationGeneration else { return }
                state = disconnectedState
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == operationGeneration else { return }
            retryAction = (error as? GitHubConnectionError) == .invalidToken ? .connect : .restore
            state = .needsAttention(error.localizedDescription)
        }
    }

    func addAccount(
        openURL: OpenURLAction,
        onConnected: ((ConnectedAccountID) -> Void)? = nil
    ) {
        retryAction = .connect
        authorizeAccount(reconnecting: nil, openURL: openURL, onConnected: onConnected)
    }

    func reconnect(_ id: ConnectedAccountID, openURL: OpenURLAction) {
        authorizeAccount(reconnecting: id, openURL: openURL)
    }

    func retry(_ id: ConnectedAccountID, openURL: OpenURLAction) {
        guard let connection = accounts.first(where: { $0.id == id }),
              connection.recoveryAction == .validate
        else {
            reconnect(id, openURL: openURL)
            return
        }
        Task { await restore() }
    }

    private func authorizeAccount(
        reconnecting id: ConnectedAccountID?,
        openURL: OpenURLAction,
        onConnected: ((ConnectedAccountID) -> Void)? = nil
    ) {
        if let id {
            accountOperationGenerations[id, default: 0] &+= 1
        }
        operationGeneration &+= 1
        let generation = operationGeneration
        accountConnectionTask?.cancel()
        activeAccountAuthorizationTarget = id
        accountConnectionTask = Task {
            var authorization: GitHubDeviceAuthorization?
            defer {
                if generation == operationGeneration {
                    accountConnectionTask = nil
                    activeAccountAuthorization = nil
                    activeAccountAuthorizationTarget = nil
                }
            }
            do {
                let startedAuthorization = try await integration.beginAccountAuthorization(reconnecting: id)
                authorization = startedAuthorization
                guard generation == operationGeneration else {
                    await integration.cancelAccountAuthorization(startedAuthorization)
                    return
                }
                activeAccountAuthorization = startedAuthorization
                try Task.checkCancellation()
                state = .authorizing(startedAuthorization)
                openURL(startedAuthorization.verificationURI)

                let connection = try await integration.completeAccountAuthorization(startedAuthorization)
                try Task.checkCancellation()
                guard generation == operationGeneration else { return }
                accounts.removeAll { $0.id == connection.id }
                accounts.append(connection)
                accounts.sort { $0.id < $1.id }
                state = .connected(connection.account)
                onConnected?(connection.id)
            } catch is CancellationError {
                if let authorization {
                    await integration.cancelAccountAuthorization(authorization)
                }
                guard generation == operationGeneration else { return }
                state = preferredRestingState
            } catch {
                guard generation == operationGeneration else { return }
                if let id,
                   let index = accounts.firstIndex(where: { $0.id == id }) {
                    if accounts[index].state == .connected {
                        state = .connected(accounts[index].account)
                        return
                    }
                    accounts[index].state = .needsAttention
                    accounts[index].message = error.localizedDescription
                    accounts[index].recoveryAction = .reconnect
                }
                state = .needsAttention(error.localizedDescription)
            }
        }
    }

    func cancelAccountAuthorization() {
        operationGeneration &+= 1
        accountConnectionTask?.cancel()
        accountConnectionTask = nil
        if let activeAccountAuthorization {
            Task { await integration.cancelAccountAuthorization(activeAccountAuthorization) }
        }
        activeAccountAuthorization = nil
        activeAccountAuthorizationTarget = nil
        state = preferredRestingState
    }

    func disconnect(_ id: ConnectedAccountID) async {
        if activeAccountAuthorizationTarget == id {
            cancelAccountAuthorization()
        }
        accountOperationGenerations[id, default: 0] &+= 1
        let generation = accountOperationGenerations[id, default: 0]
        do {
            try await integration.disconnect(accountID: id)
            guard generation == accountOperationGenerations[id, default: 0] else { return }
            accounts.removeAll { $0.id == id }
            state = preferredRestingState
        } catch is CancellationError {
            return
        } catch {
            guard generation == accountOperationGenerations[id, default: 0] else { return }
            if let index = accounts.firstIndex(where: { $0.id == id }) {
                accounts[index].state = .needsAttention
                accounts[index].message = error.localizedDescription
            }
            state = .needsAttention(error.localizedDescription)
        }
    }

    func reportDashboardAuthenticationFailure(for id: ConnectedAccountID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].state = .needsAttention
        accounts[index].message = GitHubConnectionError.invalidToken.localizedDescription
        accounts[index].recoveryAction = .reconnect
        state = preferredRestingState
    }

    private var preferredRestingState: GitHubViewState {
        if let account = accounts.first(where: { $0.state == .connected })?.account {
            return .connected(account)
        }
        if let message = accounts.first?.message {
            return .needsAttention(message)
        }
        return disconnectedState
    }

    func connect(openURL: OpenURLAction) {
        operationGeneration &+= 1
        let generation = operationGeneration
        connectionTask?.cancel()
        retryAction = .connect
        connectionTask = Task {
            defer {
                if generation == operationGeneration {
                    connectionTask = nil
                }
            }
            do {
                if let cancellationTask {
                    try await cancellationTask.value
                    try Task.checkCancellation()
                    guard generation == operationGeneration else { return }
                    self.cancellationTask = nil
                }

                let authorization = try await integration.beginAuthorization()
                try Task.checkCancellation()
                guard generation == operationGeneration else { return }
                state = .authorizing(authorization)
                openURL(authorization.verificationURI)

                let account = try await integration.completeAuthorization(authorization)
                try Task.checkCancellation()
                guard generation == operationGeneration else { return }
                state = .connected(account)
            } catch is CancellationError {
                guard generation == operationGeneration else { return }
                cancellationTask = nil
                state = disconnectedState
            } catch {
                guard generation == operationGeneration else { return }
                cancellationTask = nil
                if (error as? GitHubConnectionError) == .missingClientID {
                    state = disconnectedState
                } else {
                    state = .needsAttention(error.localizedDescription)
                }
            }
        }
    }

    func retry(openURL: OpenURLAction) {
        switch retryAction {
        case .connect:
            connect(openURL: openURL)
        case .restore:
            Task { await restore() }
        case .cancel:
            cancel()
        case .disconnect:
            Task { await disconnect() }
        }
    }

    func retryAccountSetup(
        openURL: OpenURLAction,
        onConnected: ((ConnectedAccountID) -> Void)? = nil
    ) {
        switch retryAction {
        case .restore:
            Task { await restore() }
        case .connect:
            addAccount(openURL: openURL, onConnected: onConnected)
        case .cancel:
            cancel()
        case .disconnect:
            Task { await disconnect() }
        }
    }

    func cancel() {
        operationGeneration &+= 1
        let generation = operationGeneration
        connectionTask?.cancel()
        connectionTask = nil
        state = .loading
        let cleanupTask = Task {
            try await integration.cancelAuthorization()
        }
        cancellationTask = cleanupTask
        Task {
            do {
                try await cleanupTask.value
                guard generation == operationGeneration else { return }
                cancellationTask = nil
                state = disconnectedState
            } catch {
                guard generation == operationGeneration else { return }
                cancellationTask = nil
                retryAction = .cancel
                state = .needsAttention(error.localizedDescription)
            }
        }
    }

    func disconnect() async {
        operationGeneration &+= 1
        let generation = operationGeneration
        connectionTask?.cancel()
        connectionTask = nil

        do {
            try await integration.disconnect()
            guard generation == operationGeneration else { return }
            state = disconnectedState
        } catch {
            guard generation == operationGeneration else { return }
            retryAction = .disconnect
            state = .needsAttention(error.localizedDescription)
        }
    }

    func reportDashboardAuthenticationFailure() {
        operationGeneration &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        retryAction = .connect
        state = .needsAttention(GitHubConnectionError.invalidToken.localizedDescription)
    }

    private enum RetryAction {
        case connect
        case restore
        case cancel
        case disconnect
    }

    private var disconnectedState: GitHubViewState {
        if integration.isAuthorizationConfigured {
            return .disconnected
        }
        return .configurationRequired(GitHubConnectionError.missingClientID.localizedDescription)
    }
}

enum GitHubViewState: Equatable {
    case loading
    case disconnected
    case configurationRequired(String)
    case authorizing(GitHubDeviceAuthorization)
    case connected(GitHubAccount)
    case needsAttention(String)
}

#Preview {
    NavigationStack {
        GitHubView(viewModel: GitHubViewModel())
    }
}
