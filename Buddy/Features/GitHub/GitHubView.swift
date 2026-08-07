import Observation
import SafariServices
import SwiftUI

struct GitHubView: View {
    @State private var addedAccountID: ConnectedAccountID?
    @State private var presentedAuthorizationURL: PresentedGitHubAuthorizationURL?
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
        .sheet(item: $presentedAuthorizationURL, onDismiss: authorizationSheetDismissed) { item in
            GitHubSafariView(url: item.url)
                .ignoresSafeArea()
        }
        .onChange(of: viewModel.state) { _, state in
            if case .authorizing = state { return }
            presentedAuthorizationURL = nil
        }
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
            switch viewModel.stateScope {
            case .global:
                return .needsAttention(message)
            case .accountSetup where presentedAccountID == nil:
                return .needsAttention(message)
            case let .account(id) where presentedAccountID == id:
                return .needsAttention(message)
            default:
                break
            }
        }
        if presentedAccountID != nil {
            return .disconnected
        }
        if viewModel.accounts.isEmpty, viewModel.state == .loading {
            return .loading
        }
        if !viewModel.integrationIsAuthorizationConfigured {
            return .configurationRequired(viewModel.authorizationConfigurationError.localizedDescription)
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
            Label("Choose a GitHub account", systemImage: "chevron.left.forwardslash.chevron.right")
        } description: {
            Text(
                "GitHub may ask you to sign in before showing its account picker. "
                    + "It identifies HemSoft as Buddy iOS's publisher, not as an account receiving access. "
                    + "Buddy requests repository access to show public and private pull requests. "
                    + "GitHub's OAuth permission includes write access, but Buddy only makes read-only API requests. "
                    + "The token stays in this device's Keychain."
            )
        } actions: {
            Button("Choose Account in GitHub") {
                connectPresentedAccount()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var presentedAccountID: ConnectedAccountID? {
        accountID ?? addedAccountID
    }

    @MainActor
    func connectPresentedAccount() {
        if let presentedAccountID {
            viewModel.reconnect(presentedAccountID, presentAuthorizationURL: presentAuthorizationURL)
        } else {
            viewModel.addAccount(presentAuthorizationURL: presentAuthorizationURL) { addedAccountID = $0 }
        }
    }

    @MainActor
    func connectPresentedAccount(openURL: OpenURLAction) {
        if let presentedAccountID {
            viewModel.reconnect(presentedAccountID, openURL: openURL)
        } else {
            viewModel.addAccount(openURL: openURL) { addedAccountID = $0 }
        }
    }

    private func authorizingContent(_ authorization: GitHubBrowserAuthorization) -> some View {
        VStack(spacing: BuddyTheme.Spacing.medium) {
            Image(systemName: "person.badge.key.fill")
                .font(.largeTitle)
                .foregroundStyle(BuddyTheme.accent)

            Text("Choose a GitHub account")
                .font(.headline)

            Text(
                "Sign in if needed, choose an account, then approve repository access. "
                    + "GitHub identifies Buddy iOS as the app and HemSoft as its publisher. "
                    + "Buddy uses the permission only to read public and private pull-request data. "
                    + "Buddy will finish connecting when GitHub returns to this device."
            )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Open GitHub Again") {
                presentAuthorizationURL(authorization.authorizationURL)
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
                    viewModel.reconnect(
                        account.connectedAccountID,
                        presentAuthorizationURL: presentAuthorizationURL
                    )
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
                    viewModel.retry(
                        presentedAccountID,
                        presentAuthorizationURL: presentAuthorizationURL
                    )
                } else {
                    viewModel.retryAccountSetup(
                        presentAuthorizationURL: presentAuthorizationURL
                    ) { addedAccountID = $0 }
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

    private func presentAuthorizationURL(_ url: URL) {
        presentedAuthorizationURL = PresentedGitHubAuthorizationURL(url: url)
    }

    func authorizationSheetDismissed() {
        // Dismissing Safari is not a reliable cancellation signal: GitHub may
        // already have delivered the callback while exchange and persistence
        // are still finishing. Keep the bounded authorization alive; the user
        // can reopen Safari or use the explicit Cancel action instead.
    }

}

private struct PresentedGitHubAuthorizationURL: Identifiable {
    let id = UUID()
    let url: URL
}

private struct GitHubSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

@MainActor
@Observable
final class GitHubViewModel {
    private(set) var state: GitHubViewState = .loading
    private(set) var stateScope: GitHubViewStateScope = .global
    private(set) var accounts: [GitHubAccountConnection] = []
    private(set) var activeAccountAuthorizationTarget: ConnectedAccountID?

    private let integration: GitHubIntegration
    private var connectionTask: Task<Void, Never>?
    private var accountConnectionTask: Task<Void, Never>?
    private var activeAccountAuthorization: GitHubBrowserAuthorization?
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

    var authorizationConfigurationError: GitHubConnectionError {
        integration.authorizationConfigurationError ?? .missingOAuthConfiguration
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
        stateScope = .global
        state = .loading

        do {
            let restoredAccounts = try await integration.restoreAccounts()
            guard generation == operationGeneration else { return }
            accounts = restoredAccounts
            if let account = restoredAccounts.first(where: { $0.state == .connected })?.account {
                guard generation == operationGeneration else { return }
                stateScope = .account(account.connectedAccountID)
                state = .connected(account)
            } else if let connection = restoredAccounts.first,
                      let message = connection.message {
                stateScope = .account(connection.id)
                state = .needsAttention(message)
            } else {
                guard generation == operationGeneration else { return }
                stateScope = .global
                state = disconnectedState
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == operationGeneration else { return }
            let connectionError = error as? GitHubConnectionError
            retryAction = connectionError == .invalidToken || connectionError == .privateRepositoryAccessRequired
                ? .connect
                : .restore
            stateScope = .global
            state = .needsAttention(error.localizedDescription)
        }
    }

    func addAccount(
        openURL: OpenURLAction,
        onConnected: ((ConnectedAccountID) -> Void)? = nil
    ) {
        addAccount(
            presentAuthorizationURL: { openURL($0) },
            onConnected: onConnected
        )
    }

    func addAccount(
        presentAuthorizationURL: @escaping (URL) -> Void,
        onConnected: ((ConnectedAccountID) -> Void)? = nil
    ) {
        retryAction = .connect
        authorizeAccount(
            reconnecting: nil,
            presentAuthorizationURL: presentAuthorizationURL,
            onConnected: onConnected
        )
    }

    func reconnect(_ id: ConnectedAccountID, openURL: OpenURLAction) {
        reconnect(id, presentAuthorizationURL: { openURL($0) })
    }

    func reconnect(_ id: ConnectedAccountID, presentAuthorizationURL: @escaping (URL) -> Void) {
        authorizeAccount(reconnecting: id, presentAuthorizationURL: presentAuthorizationURL)
    }

    func retry(_ id: ConnectedAccountID, openURL: OpenURLAction) {
        retry(id, presentAuthorizationURL: { openURL($0) })
    }

    func retry(_ id: ConnectedAccountID, presentAuthorizationURL: @escaping (URL) -> Void) {
        guard let connection = accounts.first(where: { $0.id == id }),
              connection.recoveryAction == .validate
        else {
            reconnect(id, presentAuthorizationURL: presentAuthorizationURL)
            return
        }
        Task { await restore() }
    }

    private func authorizeAccount(
        reconnecting id: ConnectedAccountID?,
        presentAuthorizationURL: @escaping (URL) -> Void,
        onConnected: ((ConnectedAccountID) -> Void)? = nil
    ) {
        if let previousTarget = activeAccountAuthorizationTarget,
           previousTarget != id {
            accountOperationGenerations[previousTarget, default: 0] &+= 1
        }
        if let id {
            accountOperationGenerations[id, default: 0] &+= 1
        }
        operationGeneration &+= 1
        let generation = operationGeneration
        accountConnectionTask?.cancel()
        activeAccountAuthorizationTarget = id
        stateScope = id.map(GitHubViewStateScope.account) ?? .accountSetup
        accountConnectionTask = Task {
            var authorization: GitHubBrowserAuthorization?
            defer {
                if generation == operationGeneration {
                    if let id {
                        accountOperationGenerations[id, default: 0] &+= 1
                    }
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
                presentAuthorizationURL(startedAuthorization.authorizationURL)

                let connection = try await integration.completeAccountAuthorization(startedAuthorization)
                try Task.checkCancellation()
                guard generation == operationGeneration else { return }
                if id == nil {
                    accountOperationGenerations[connection.id, default: 0] &+= 1
                }
                accounts.removeAll { $0.id == connection.id }
                accounts.append(connection)
                accounts.sort { $0.id < $1.id }
                stateScope = .account(connection.id)
                state = .connected(connection.account)
                onConnected?(connection.id)
            } catch is CancellationError {
                if let authorization {
                    await integration.cancelAccountAuthorization(authorization)
                }
                guard generation == operationGeneration else { return }
                stateScope = preferredRestingStateScope
                state = preferredRestingState
            } catch {
                guard generation == operationGeneration else { return }
                if let id,
                   let index = accounts.firstIndex(where: { $0.id == id }) {
                    if accounts[index].state == .connected {
                        stateScope = .account(id)
                        state = .connected(accounts[index].account)
                        return
                    }
                    accounts[index].state = .needsAttention
                    accounts[index].message = error.localizedDescription
                    accounts[index].recoveryAction = .reconnect
                }
                stateScope = id.map(GitHubViewStateScope.account) ?? .accountSetup
                state = .needsAttention(error.localizedDescription)
            }
        }
    }

    func cancelAccountAuthorization() {
        operationGeneration &+= 1
        accountConnectionTask?.cancel()
        accountConnectionTask = nil
        if let activeAccountAuthorizationTarget {
            accountOperationGenerations[activeAccountAuthorizationTarget, default: 0] &+= 1
        }
        if let activeAccountAuthorization {
            Task { await integration.cancelAccountAuthorization(activeAccountAuthorization) }
        }
        activeAccountAuthorization = nil
        activeAccountAuthorizationTarget = nil
        stateScope = preferredRestingStateScope
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
            if case .authorizing = state { return }
            stateScope = preferredRestingStateScope
            state = preferredRestingState
        } catch is CancellationError {
            return
        } catch {
            guard generation == accountOperationGenerations[id, default: 0] else { return }
            if let index = accounts.firstIndex(where: { $0.id == id }) {
                accounts[index].state = .needsAttention
                accounts[index].message = error.localizedDescription
            }
            if case .authorizing = state { return }
            stateScope = .account(id)
            state = .needsAttention(error.localizedDescription)
        }
    }

    func dashboardRefreshRevision(for id: ConnectedAccountID) -> Int {
        accountOperationGenerations[id, default: 0]
    }

    func reportDashboardAuthenticationFailure(for id: ConnectedAccountID) {
        reportDashboardAuthorizationFailure(for: id, error: .invalidToken)
    }

    func reportDashboardRepositoryAccessFailure(for id: ConnectedAccountID) {
        reportDashboardAuthorizationFailure(for: id, error: .privateRepositoryAccessRequired)
    }

    private func reportDashboardAuthorizationFailure(
        for id: ConnectedAccountID,
        error: GitHubConnectionError
    ) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].state = .needsAttention
        accounts[index].message = error.localizedDescription
        accounts[index].recoveryAction = .reconnect
        stateScope = preferredRestingStateScope
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

    private var preferredRestingStateScope: GitHubViewStateScope {
        if let connection = accounts.first(where: { $0.state == .connected }) {
            return .account(connection.id)
        }
        if let connection = accounts.first {
            return .account(connection.id)
        }
        return .global
    }

    func connect(openURL: OpenURLAction) {
        connect(presentAuthorizationURL: { openURL($0) })
    }

    func connect(presentAuthorizationURL: @escaping (URL) -> Void) {
        operationGeneration &+= 1
        let generation = operationGeneration
        connectionTask?.cancel()
        retryAction = .connect
        stateScope = .accountSetup
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
                stateScope = .accountSetup
                state = .authorizing(authorization)
                presentAuthorizationURL(authorization.authorizationURL)

                let account = try await integration.completeAuthorization(authorization)
                try Task.checkCancellation()
                guard generation == operationGeneration else { return }
                stateScope = .account(account.connectedAccountID)
                state = .connected(account)
            } catch is CancellationError {
                guard generation == operationGeneration else { return }
                cancellationTask = nil
                stateScope = .global
                state = disconnectedState
            } catch {
                guard generation == operationGeneration else { return }
                cancellationTask = nil
                if (error as? GitHubConnectionError) == .missingClientID {
                    stateScope = .global
                    state = disconnectedState
                } else {
                    stateScope = .accountSetup
                    state = .needsAttention(error.localizedDescription)
                }
            }
        }
    }

    func retry(openURL: OpenURLAction) {
        retry(presentAuthorizationURL: { openURL($0) })
    }

    func retry(presentAuthorizationURL: @escaping (URL) -> Void) {
        switch retryAction {
        case .connect:
            connect(presentAuthorizationURL: presentAuthorizationURL)
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
        retryAccountSetup(
            presentAuthorizationURL: { openURL($0) },
            onConnected: onConnected
        )
    }

    func retryAccountSetup(
        presentAuthorizationURL: @escaping (URL) -> Void,
        onConnected: ((ConnectedAccountID) -> Void)? = nil
    ) {
        switch retryAction {
        case .restore:
            Task { await restore() }
        case .connect:
            addAccount(
                presentAuthorizationURL: presentAuthorizationURL,
                onConnected: onConnected
            )
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
        stateScope = .accountSetup
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
                stateScope = .global
                state = disconnectedState
            } catch {
                guard generation == operationGeneration else { return }
                cancellationTask = nil
                retryAction = .cancel
                stateScope = .accountSetup
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
            stateScope = .global
            state = disconnectedState
        } catch {
            guard generation == operationGeneration else { return }
            retryAction = .disconnect
            stateScope = .global
            state = .needsAttention(error.localizedDescription)
        }
    }

    func reportDashboardAuthenticationFailure() {
        operationGeneration &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        retryAction = .connect
        stateScope = .global
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
        return .configurationRequired(authorizationConfigurationError.localizedDescription)
    }
}

enum GitHubViewStateScope: Equatable {
    case global
    case accountSetup
    case account(ConnectedAccountID)
}

enum GitHubViewState: Equatable {
    case loading
    case disconnected
    case configurationRequired(String)
    case authorizing(GitHubBrowserAuthorization)
    case connected(GitHubAccount)
    case needsAttention(String)
}

#Preview {
    NavigationStack {
        GitHubView(viewModel: GitHubViewModel())
    }
}
