import Foundation
import SwiftUI

protocol CredentialStoring: Sendable {
    func set(_ data: Data, for account: String) async throws
    func setIfMissing(_ data: Data, for account: String) async throws -> Bool
    func data(for account: String) async throws -> Data?
    func removeData(for account: String) async throws
    func removeData(for account: String, ifMatches expectedData: Data) async throws -> Bool
    func replaceData(
        for account: String,
        ifMatches expectedData: Data,
        with replacementData: Data?
    ) async throws -> Bool
}

extension CredentialStoring {
    func setIfMissing(_ data: Data, for account: String) async throws -> Bool {
        guard try await self.data(for: account) == nil else { return false }
        try await set(data, for: account)
        return true
    }

    func removeData(for account: String, ifMatches expectedData: Data) async throws -> Bool {
        guard try await data(for: account) == expectedData else { return false }
        try await removeData(for: account)
        return true
    }

    func replaceData(
        for account: String,
        ifMatches expectedData: Data,
        with replacementData: Data?
    ) async throws -> Bool {
        guard try await data(for: account) == expectedData else { return false }
        if let replacementData {
            try await set(replacementData, for: account)
        } else {
            try await removeData(for: account)
        }
        return true
    }
}

actor GitHubIntegration: IntegrationProviding {
    private enum PullRequestQuery: Sendable {
        case authored
        case assigned
    }

    private enum AccountMutationIntent: Sendable {
        case reconnect
        case disconnect
    }
    private struct AccountAuthorizationSession: Sendable {
        let authorization: GitHubBrowserAuthorization
        let targetID: ConnectedAccountID?
        let targetGeneration: Int?
        let generationSnapshot: [ConnectedAccountID: Int]
    }

    private enum LegacyCredentialState: Sendable {
        case unknown(Data)
        case scopeUpgradeRequired(Data, ConnectedAccountID)
        case owned(Data, ConnectedAccountID)
    }

    private struct LegacyMigrationResult: Sendable {
        let record: ConnectedAccountRecord
        let requiresScopedValidation: Bool
        let requiresRepositoryScopeUpgrade: Bool
    }

    private static let credentialAccount = "github.oauth-token"

    static func credentialAccount(for id: ConnectedAccountID) -> String {
        "github.account.\(id.subject).oauth-token"
    }

    nonisolated var summary: IntegrationSummary { summaryStorage.value }
    nonisolated let isAuthorizationConfigured: Bool
    nonisolated let authorizationConfigurationError: GitHubConnectionError?

    private let clientID: String?
    private let clientSecret: String?
    private let api: any GitHubAPIProviding
    private let authorizer: any GitHubOAuthAuthorizing
    private let tokenRevoker: (any GitHubOAuthTokenRevoking)?
    private let credentials: any CredentialStoring
    private let accountStore: any ConnectedAccountStoring
    private let sleep: @Sendable (Duration) async throws -> Void
    private let summaryStorage: LockedGitHubSummary
    private var authorizationGeneration = 0
    private var restorationSequence = 0
    private var activeRestoration: (
        id: Int,
        authorizationGeneration: Int,
        task: Task<GitHubAccount?, Error>
    )?
    private var cleanupSequence = 0
    private var activeCredentialCleanup: (id: Int, task: Task<Void, Error>)?
    private var activeAuthorization: GitHubBrowserAuthorization?
    private var accountAuthorizations: [UUID: AccountAuthorizationSession] = [:]
    private var accountGenerations: [ConnectedAccountID: Int] = [:]
    private var accountMutationIntents: [ConnectedAccountID: AccountMutationIntent] = [:]
    private var legacyCredentialState: LegacyCredentialState?

    init(
        clientID: String? = AppConfiguration.current.githubClientID,
        clientSecret: String? = AppConfiguration.current.githubClientSecret,
        api: (any GitHubAPIProviding)? = nil,
        authorizer: (any GitHubOAuthAuthorizing)? = nil,
        tokenRevoker: (any GitHubOAuthTokenRevoking)? = nil,
        credentials: any CredentialStoring = KeychainStore(),
        accountStore: (any ConnectedAccountStoring)? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.clientID = clientID
        let resolvedAPI = api ?? GitHubAPI()
        let injectedAuthorizer = authorizer ?? (resolvedAPI as? any GitHubOAuthAuthorizing)
        let resolvedAuthorizer = injectedAuthorizer ?? GitHubWebOAuthService()
        self.clientSecret = clientSecret ?? (injectedAuthorizer == nil ? nil : "test-client-secret")
        if clientID == nil {
            authorizationConfigurationError = .missingClientID
        } else if self.clientSecret == nil {
            authorizationConfigurationError = .missingOAuthConfiguration
        } else {
            authorizationConfigurationError = nil
        }
        isAuthorizationConfigured = authorizationConfigurationError == nil
        self.api = resolvedAPI
        self.authorizer = resolvedAuthorizer
        if let tokenRevoker {
            self.tokenRevoker = tokenRevoker
        } else if let injectedTokenRevoker = injectedAuthorizer as? any GitHubOAuthTokenRevoking {
            self.tokenRevoker = injectedTokenRevoker
        } else if api == nil || resolvedAPI is GitHubAPI {
            self.tokenRevoker = resolvedAuthorizer as? any GitHubOAuthTokenRevoking
        } else {
            self.tokenRevoker = nil
        }
        self.credentials = credentials
        if let accountStore {
            self.accountStore = accountStore
        } else if credentials is KeychainStore {
            self.accountStore = UserDefaultsConnectedAccountStore()
        } else {
            self.accountStore = InMemoryConnectedAccountStore()
        }
        self.sleep = sleep
        summaryStorage = LockedGitHubSummary(
            IntegrationSummary(
                id: "github",
                title: "GitHub",
                detail: "Ready to connect",
                systemImage: "chevron.left.forwardslash.chevron.right",
                tint: .primary,
                connectionState: .disconnected
            )
        )
    }

    func refresh() async throws -> IntegrationSummary {
        _ = try await restoreAccounts()
        return summary
    }

    func restoreAccounts() async throws -> [GitHubAccountConnection] {
        var records: [ConnectedAccountRecord]
        do {
            records = try await accountStore.accounts(for: .github)
        } catch {
            throw GitHubConnectionError.accountStorage
        }

        let migrated: LegacyMigrationResult?
        do {
            migrated = try await migrateLegacyCredential()
        } catch {
            guard !records.isEmpty else { throw error }
            migrated = nil
        }
        if let migrated {
            records.removeAll { $0.id == migrated.record.id }
        }

        var connections: [GitHubAccountConnection] = []
        var connectionGenerations: [ConnectedAccountID: Int] = [:]
        if let migrated {
            if migrated.requiresRepositoryScopeUpgrade {
                let account = GitHubAccount(record: migrated.record)
                let connection = GitHubAccountConnection(
                    account: account,
                    state: .needsAttention,
                    message: GitHubConnectionError.privateRepositoryAccessRequired.localizedDescription,
                    recoveryAction: .reconnect
                )
                connections.append(connection)
                connectionGenerations[connection.id] = accountGenerations[connection.id, default: 0]
            } else if migrated.requiresScopedValidation {
                if let connection = await restoreRegisteredAccount(migrated.record) {
                    connections.append(connection)
                    connectionGenerations[connection.id] = accountGenerations[connection.id, default: 0]
                }
            } else {
                let connection = GitHubAccountConnection(
                    account: GitHubAccount(record: migrated.record),
                    state: .connected
                )
                connections.append(connection)
                connectionGenerations[connection.id] = accountGenerations[connection.id, default: 0]
            }
        }
        for record in records.sorted(by: { $0.id < $1.id }) {
            if let connection = await restoreRegisteredAccount(record) {
                connections.append(connection)
                connectionGenerations[connection.id] = accountGenerations[connection.id, default: 0]
            }
        }
        connections.removeAll { connection in
            connectionGenerations[connection.id] != accountGenerations[connection.id, default: 0]
        }
        connections.sort { $0.id < $1.id }

        if connections.isEmpty {
            updateSummary(detail: "Ready to connect", state: .disconnected)
        } else if let firstConnected = connections.first(where: { $0.state == .connected }) {
            updateSummary(detail: "@\(firstConnected.account.login)", state: .connected)
        } else {
            updateSummary(detail: "One or more accounts need attention", state: .needsAttention)
        }
        return connections
    }

    func beginAccountAuthorization(
        reconnecting id: ConnectedAccountID? = nil
    ) async throws -> GitHubBrowserAuthorization {
        let configuration = try oauthConfiguration()
        let authorizationGenerationSnapshot = authorizationGeneration
        let generationSnapshot = accountGenerations
        let targetGeneration = id.map { id in
            accountGenerations[id, default: 0] &+= 1
            accountMutationIntents[id] = .reconnect
            return accountGenerations[id, default: 0]
        }
        do {
            let authorization = try await authorizer.beginAuthorization(configuration: configuration)
            if Task.isCancelled || authorizationGeneration != authorizationGenerationSnapshot {
                await authorizer.cancelAuthorization(authorization)
                throw CancellationError()
            }
            if let id,
               accountGenerations[id, default: 0] != targetGeneration {
                await authorizer.cancelAuthorization(authorization)
                throw CancellationError()
            }
            accountAuthorizations[authorization.id] = AccountAuthorizationSession(
                authorization: authorization,
                targetID: id,
                targetGeneration: targetGeneration,
                generationSnapshot: generationSnapshot
            )
            return authorization
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw map(error)
        }
    }

    func completeAccountAuthorization(
        _ authorization: GitHubBrowserAuthorization
    ) async throws -> GitHubAccountConnection {
        _ = try oauthConfiguration()
        guard let session = accountAuthorizations[authorization.id] else {
            throw CancellationError()
        }
        let targetID = session.targetID
        let targetGeneration = session.targetGeneration

        do {
            try Task.checkCancellation()
            let token = try await authorizer.completeAuthorization(authorization)
            guard accountAuthorizations.keys.contains(authorization.id) else {
                throw CancellationError()
            }
            let account = try await api.authenticatedUser(token: token)
            let accountID = account.connectedAccountID
            if let targetID, targetID != accountID {
                throw GitHubConnectionError.accountMismatch
            }
            if let targetID,
               accountGenerations[targetID, default: 0] != targetGeneration {
                throw CancellationError()
            }
            if targetID == nil,
               accountGenerations[accountID, default: 0]
                != session.generationSnapshot[accountID, default: 0] {
                throw CancellationError()
            }
            guard accountAuthorizations.keys.contains(authorization.id) else {
                throw CancellationError()
            }

            let existingRecord: ConnectedAccountRecord?
            do {
                existingRecord = try await accountStore.accounts(for: .github)
                    .first { $0.id == accountID }
            } catch {
                throw GitHubConnectionError.accountStorage
            }
            guard accountAuthorizations.keys.contains(authorization.id) else {
                throw CancellationError()
            }
            if targetID == nil, existingRecord != nil {
                throw GitHubConnectionError.duplicateAccount
            }

            accountGenerations[accountID, default: 0] &+= 1
            accountMutationIntents[accountID] = .reconnect
            let accountGeneration = accountGenerations[accountID, default: 0]
            let credentialAccount = Self.credentialAccount(for: accountID)
            let previousToken: Data?
            let previousRecord: ConnectedAccountRecord?
            do {
                previousToken = try await credentials.data(for: credentialAccount)
                previousRecord = existingRecord
            } catch {
                throw GitHubConnectionError.credentialStorage
            }
            guard !Task.isCancelled,
                  accountAuthorizations.keys.contains(authorization.id),
                  accountGenerations[accountID, default: 0] == accountGeneration
            else {
                throw CancellationError()
            }

            let writtenToken = Data(token.utf8)
            var removedLegacyData: Data?
            do {
                try await credentials.set(writtenToken, for: credentialAccount)
                guard !Task.isCancelled,
                      accountAuthorizations.keys.contains(authorization.id),
                      accountGenerations[accountID, default: 0] == accountGeneration
                else {
                    if accountGenerations[accountID, default: 0] == accountGeneration {
                        let rolledBack = await rollbackAccountWrite(
                            id: accountID,
                            previousToken: previousToken,
                            previousRecord: previousRecord,
                            writtenToken: writtenToken,
                            writtenRecord: account.connectedAccountRecord,
                            generation: accountGeneration
                        )
                        guard rolledBack else { throw GitHubConnectionError.credentialStorage }
                    } else {
                        _ = try? await credentials.removeData(
                            for: credentialAccount,
                            ifMatches: writtenToken
                        )
                    }
                    throw CancellationError()
                }
                try await accountStore.upsert(account.connectedAccountRecord)
                removedLegacyData = try await removeLegacyCredentialReplacedByScopeUpgrade(
                    for: accountID
                )
            } catch {
                if error is CancellationError { throw error }
                if let connectionError = error as? GitHubConnectionError,
                   connectionError == .credentialStorage {
                    throw connectionError
                }
                if Task.isCancelled || !accountAuthorizations.keys.contains(authorization.id) {
                    if accountGenerations[accountID, default: 0] == accountGeneration {
                        let rolledBack = await rollbackAccountWrite(
                            id: accountID,
                            previousToken: previousToken,
                            previousRecord: previousRecord,
                            writtenToken: writtenToken,
                            writtenRecord: account.connectedAccountRecord,
                            generation: accountGeneration
                        )
                        var tokenWasNeverChanged = false
                        if !rolledBack {
                            tokenWasNeverChanged = (try? await credentials.data(for: credentialAccount))
                                == previousToken
                        }
                        guard rolledBack || tokenWasNeverChanged else {
                            throw GitHubConnectionError.credentialStorage
                        }
                    } else {
                        await discardSupersededAccountWrite(
                            id: accountID,
                            previousRecord: previousRecord,
                            writtenToken: writtenToken,
                            writtenRecord: account.connectedAccountRecord
                        )
                    }
                    throw CancellationError()
                }
                if accountGenerations[accountID, default: 0] == accountGeneration {
                    let rolledBack = await rollbackAccountWrite(
                        id: accountID,
                        previousToken: previousToken,
                        previousRecord: previousRecord,
                        writtenToken: writtenToken,
                        writtenRecord: account.connectedAccountRecord,
                        generation: accountGeneration
                    )
                    guard rolledBack else { throw GitHubConnectionError.credentialStorage }
                } else {
                    await discardSupersededAccountWrite(
                        id: accountID,
                        previousRecord: previousRecord,
                        writtenToken: writtenToken,
                        writtenRecord: account.connectedAccountRecord
                    )
                }
                throw GitHubConnectionError.credentialStorage
            }

            guard !Task.isCancelled,
                  accountAuthorizations.keys.contains(authorization.id),
                  accountGenerations[accountID, default: 0] == accountGeneration
            else {
                if accountGenerations[accountID, default: 0] == accountGeneration {
                    let rolledBack = await rollbackAccountWrite(
                        id: accountID,
                        previousToken: previousToken,
                        previousRecord: previousRecord,
                        writtenToken: writtenToken,
                        writtenRecord: account.connectedAccountRecord,
                        generation: accountGeneration
                    )
                    let restoredLegacy = await restoreLegacyCredentialAfterAuthorizationRollback(
                        removedLegacyData,
                        ownerID: accountID
                    )
                    guard rolledBack, restoredLegacy else {
                        throw GitHubConnectionError.credentialStorage
                    }
                } else {
                    await discardSupersededAccountWrite(
                        id: accountID,
                        previousRecord: previousRecord,
                        writtenToken: writtenToken,
                        writtenRecord: account.connectedAccountRecord
                    )
                    guard await restoreLegacyCredentialAfterAuthorizationRollback(
                        removedLegacyData,
                        ownerID: accountID
                    ) else {
                        throw GitHubConnectionError.credentialStorage
                    }
                }
                throw CancellationError()
            }
            if removedLegacyData != nil {
                legacyCredentialState = nil
            }
            accountAuthorizations.removeValue(forKey: authorization.id)
            return GitHubAccountConnection(account: account, state: .connected)
        } catch is CancellationError {
            accountAuthorizations.removeValue(forKey: authorization.id)
            await authorizer.cancelAuthorization(authorization)
            throw CancellationError()
        } catch {
            accountAuthorizations.removeValue(forKey: authorization.id)
            await authorizer.cancelAuthorization(authorization)
            throw map(error)
        }
    }

    func cancelAccountAuthorization(_ authorization: GitHubBrowserAuthorization) async {
        accountAuthorizations.removeValue(forKey: authorization.id)
        await authorizer.cancelAuthorization(authorization)
    }

    func disconnect(accountID: ConnectedAccountID) async throws {
        accountGenerations[accountID, default: 0] &+= 1
        accountMutationIntents[accountID] = .disconnect
        let generation = accountGenerations[accountID, default: 0]
        let canceledAuthorizations = accountAuthorizations.values
            .filter { $0.targetID == accountID }
            .map(\.authorization)
        accountAuthorizations = accountAuthorizations.filter { $0.value.targetID != accountID }
        for authorization in canceledAuthorizations {
            await authorizer.cancelAuthorization(authorization)
        }
        var previousRecord: ConnectedAccountRecord?
        var tokenData: Data?
        let credentialAccount = Self.credentialAccount(for: accountID)
        do {
            // Preserve a legacy item whose transient validation has not identified its
            // owner, or whose known owner is a different account.
            try await removeLegacyCredentialIfOwned(by: accountID)
            guard generation == accountGenerations[accountID, default: 0] else {
                throw CancellationError()
            }

            previousRecord = try await accountStore.accounts(for: .github)
                .first { $0.id == accountID }
            tokenData = try await credentials.data(for: credentialAccount)
            guard generation == accountGenerations[accountID, default: 0] else {
                throw CancellationError()
            }

            try await revokeAuthorizationIfPresent(tokenData)
            guard generation == accountGenerations[accountID, default: 0] else {
                throw CancellationError()
            }

            // Remove metadata before the scoped token. If a reconnect supersedes this
            // operation, rollback only fills values that its newer write did not replace.
            try await accountStore.remove(accountID)
            guard generation == accountGenerations[accountID, default: 0] else {
                await restoreDisconnectedAccount(
                    accountID: accountID,
                    record: previousRecord,
                    tokenData: tokenData,
                    credentialAccount: credentialAccount,
                    generation: generation
                )
                throw CancellationError()
            }

            if let tokenData {
                let removed = try await credentials.removeData(
                    for: credentialAccount,
                    ifMatches: tokenData
                )
                guard removed else {
                    await restoreDisconnectedAccount(
                        accountID: accountID,
                        record: previousRecord,
                        tokenData: tokenData,
                        credentialAccount: credentialAccount,
                        generation: generation
                    )
                    if generation != accountGenerations[accountID, default: 0] {
                        throw CancellationError()
                    }
                    throw GitHubConnectionError.credentialStorage
                }
            }
            guard generation == accountGenerations[accountID, default: 0] else {
                await restoreDisconnectedAccount(
                    accountID: accountID,
                    record: previousRecord,
                    tokenData: tokenData,
                    credentialAccount: credentialAccount,
                    generation: generation
                )
                throw CancellationError()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GitHubConnectionError {
            await restoreDisconnectedAccount(
                accountID: accountID,
                record: previousRecord,
                tokenData: tokenData,
                credentialAccount: credentialAccount,
                generation: generation
            )
            throw error
        } catch {
            await restoreDisconnectedAccount(
                accountID: accountID,
                record: previousRecord,
                tokenData: tokenData,
                credentialAccount: credentialAccount,
                generation: generation
            )
            throw GitHubConnectionError.credentialStorage
        }
    }

    private func restoreDisconnectedAccount(
        accountID: ConnectedAccountID,
        record: ConnectedAccountRecord?,
        tokenData: Data?,
        credentialAccount: String,
        generation: Int
    ) async {
        guard shouldRestoreDisconnectedAccount(accountID, generation: generation) else { return }
        if let record {
            _ = try? await accountStore.upsertIfMissing(record)
        }
        guard shouldRestoreDisconnectedAccount(accountID, generation: generation) else { return }
        if let tokenData {
            _ = try? await credentials.setIfMissing(tokenData, for: credentialAccount)
        }
    }

    private func shouldRestoreDisconnectedAccount(
        _ accountID: ConnectedAccountID,
        generation: Int
    ) -> Bool {
        generation == accountGenerations[accountID, default: 0]
            || accountMutationIntents[accountID] == .reconnect
    }

    private func rollbackAccountWrite(
        id: ConnectedAccountID,
        previousToken: Data?,
        previousRecord: ConnectedAccountRecord?,
        writtenToken: Data,
        writtenRecord: ConnectedAccountRecord,
        generation: Int
    ) async -> Bool {
        let credentialAccount = Self.credentialAccount(for: id)
        do {
            guard try await credentials.replaceData(
                for: credentialAccount,
                ifMatches: writtenToken,
                with: previousToken
            ) else {
                return false
            }
        } catch {
            return false
        }
        guard generation == accountGenerations[id, default: 0] else { return true }
        _ = try? await accountStore.replace(writtenRecord, with: previousRecord)
        return true
    }

    private func discardSupersededAccountWrite(
        id: ConnectedAccountID,
        previousRecord: ConnectedAccountRecord?,
        writtenToken: Data,
        writtenRecord: ConnectedAccountRecord
    ) async {
        let credentialAccount = Self.credentialAccount(for: id)
        let removedWrittenToken: Bool
        do {
            removedWrittenToken = try await credentials.removeData(
                for: credentialAccount,
                ifMatches: writtenToken
            )
        } catch {
            // If Keychain cleanup fails, preserve recoverable metadata rather than
            // leaving an invisible credential that the user cannot retry or remove.
            _ = try? await accountStore.upsertIfMissing(writtenRecord)
            return
        }
        if accountMutationIntents[id] == .disconnect {
            _ = try? await accountStore.replace(writtenRecord, with: nil)
            return
        }
        guard removedWrittenToken else { return }
        _ = try? await accountStore.replace(writtenRecord, with: previousRecord)
    }

    private func removeLegacyCredentialIfOwned(
        by accountID: ConnectedAccountID
    ) async throws {
        guard let legacyData = try await credentials.data(for: Self.credentialAccount) else {
            legacyCredentialState = nil
            return
        }
        switch legacyCredentialState {
        case let .unknown(pendingData) where pendingData == legacyData:
            return
        case let .scopeUpgradeRequired(pendingData, ownerID)
            where pendingData == legacyData && ownerID != accountID:
            return
        case let .owned(pendingData, ownerID)
            where pendingData == legacyData && ownerID != accountID:
            return
        default:
            break
        }
        if try await credentials.removeData(
            for: Self.credentialAccount,
            ifMatches: legacyData
        ) {
            legacyCredentialState = nil
        }
    }

    private func removeLegacyCredentialReplacedByScopeUpgrade(
        for accountID: ConnectedAccountID
    ) async throws -> Data? {
        guard case let .scopeUpgradeRequired(pendingData, ownerID) = legacyCredentialState,
              ownerID == accountID,
              try await credentials.data(for: Self.credentialAccount) == pendingData
        else {
            return nil
        }
        if try await credentials.removeData(
            for: Self.credentialAccount,
            ifMatches: pendingData
        ) {
            return pendingData
        }
        return nil
    }

    private func restoreLegacyCredentialAfterAuthorizationRollback(
        _ legacyData: Data?,
        ownerID: ConnectedAccountID
    ) async -> Bool {
        guard let legacyData else { return true }
        guard accountMutationIntents[ownerID] != .disconnect else {
            legacyCredentialState = nil
            return true
        }
        do {
            let currentData = try await credentials.data(for: Self.credentialAccount)
            if currentData == nil {
                try await credentials.set(legacyData, for: Self.credentialAccount)
                legacyCredentialState = .scopeUpgradeRequired(legacyData, ownerID)
            } else if currentData == legacyData {
                legacyCredentialState = .scopeUpgradeRequired(legacyData, ownerID)
            } else if let currentData {
                legacyCredentialState = .unknown(currentData)
            }
            return true
        } catch {
            return false
        }
    }

    private func removeLegacyCredential(ifMatches legacyData: Data) async throws {
        if try await credentials.removeData(
            for: Self.credentialAccount,
            ifMatches: legacyData
        ) {
            legacyCredentialState = nil
        }
    }

    private func migrateLegacyCredential() async throws -> LegacyMigrationResult? {
        let legacyData: Data?
        do {
            legacyData = try await credentials.data(for: Self.credentialAccount)
        } catch {
            throw GitHubConnectionError.credentialStorage
        }
        guard let legacyData else {
            legacyCredentialState = nil
            return nil
        }
        legacyCredentialState = .unknown(legacyData)
        guard let token = String(data: legacyData, encoding: .utf8), !token.isEmpty else {
            do {
                try await removeLegacyCredential(ifMatches: legacyData)
            } catch {
                throw GitHubConnectionError.credentialStorage
            }
            return nil
        }

        let generationSnapshot = accountGenerations
        let account: GitHubAccount
        let requiresRepositoryScopeUpgrade: Bool
        do {
            account = try await api.authenticatedUser(token: token)
            requiresRepositoryScopeUpgrade = false
        } catch GitHubAPIError.unauthorized {
            do {
                try await removeLegacyCredential(ifMatches: legacyData)
            } catch {
                throw GitHubConnectionError.credentialStorage
            }
            return nil
        } catch GitHubAPIError.insufficientOAuthScope {
            let migrationAccount: GitHubAccount
            do {
                migrationAccount = try await api.authenticatedUserForCredentialMigration(token: token)
            } catch GitHubAPIError.unauthorized {
                do {
                    try await removeLegacyCredential(ifMatches: legacyData)
                } catch {
                    throw GitHubConnectionError.credentialStorage
                }
                return nil
            } catch {
                throw map(error)
            }
            legacyCredentialState = .scopeUpgradeRequired(
                legacyData,
                migrationAccount.connectedAccountID
            )
            account = migrationAccount
            requiresRepositoryScopeUpgrade = true
        } catch {
            throw map(error)
        }

        let accountID = account.connectedAccountID
        if !requiresRepositoryScopeUpgrade {
            legacyCredentialState = .owned(legacyData, accountID)
        }
        let generation = generationSnapshot[accountID, default: 0]
        guard generation == accountGenerations[accountID, default: 0] else {
            if accountMutationIntents[accountID] == .disconnect {
                try? await removeLegacyCredential(ifMatches: legacyData)
            }
            return nil
        }
        let scopedCredentialAccount = Self.credentialAccount(for: accountID)
        let existingRecord: ConnectedAccountRecord?
        let existingScopedCredential: Data?
        do {
            existingRecord = try await accountStore.accounts(for: .github)
                .first { $0.id == account.connectedAccountID }
            existingScopedCredential = try await credentials.data(for: scopedCredentialAccount)
        } catch {
            throw GitHubConnectionError.credentialStorage
        }
        guard generation == accountGenerations[accountID, default: 0] else { return nil }

        // A legacy credential can linger when its earlier cleanup failed. Never let that
        // stale value overwrite a newer account-scoped reconnect credential.
        if existingRecord != nil || existingScopedCredential != nil {
            let record = existingRecord ?? account.connectedAccountRecord
            if existingRecord == nil {
                do {
                    try await accountStore.upsert(record)
                } catch {
                    throw GitHubConnectionError.accountStorage
                }
                guard generation == accountGenerations[accountID, default: 0] else {
                    if accountMutationIntents[accountID] == .disconnect {
                        _ = try? await accountStore.replace(record, with: nil)
                    }
                    return nil
                }
            }
            try? await removeLegacyCredential(ifMatches: legacyData)
            return LegacyMigrationResult(
                record: record,
                requiresScopedValidation: true,
                requiresRepositoryScopeUpgrade: false
            )
        }

        if requiresRepositoryScopeUpgrade {
            return LegacyMigrationResult(
                record: account.connectedAccountRecord,
                requiresScopedValidation: false,
                requiresRepositoryScopeUpgrade: true
            )
        }

        do {
            try await credentials.set(
                legacyData,
                for: scopedCredentialAccount
            )
            guard generation == accountGenerations[accountID, default: 0] else {
                if accountMutationIntents[accountID] == .disconnect {
                    _ = try? await credentials.removeData(
                        for: scopedCredentialAccount,
                        ifMatches: legacyData
                    )
                }
                return nil
            }
            try await accountStore.upsert(account.connectedAccountRecord)
            guard generation == accountGenerations[accountID, default: 0] else {
                if accountMutationIntents[accountID] == .disconnect {
                    _ = try? await credentials.removeData(
                        for: scopedCredentialAccount,
                        ifMatches: legacyData
                    )
                    _ = try? await accountStore.replace(
                        account.connectedAccountRecord,
                        with: nil
                    )
                }
                return nil
            }
            try? await removeLegacyCredential(ifMatches: legacyData)
        } catch {
            throw GitHubConnectionError.credentialStorage
        }
        return LegacyMigrationResult(
            record: account.connectedAccountRecord,
            requiresScopedValidation: false,
            requiresRepositoryScopeUpgrade: false
        )
    }

    private func restoreRegisteredAccount(
        _ record: ConnectedAccountRecord
    ) async -> GitHubAccountConnection? {
        let generation = accountGenerations[record.id, default: 0]
        let account = GitHubAccount(record: record)
        do {
            let isStillRegistered = try await accountStore.accounts(for: .github)
                .contains { $0.id == record.id }
            guard generation == accountGenerations[record.id, default: 0],
                  isStillRegistered
            else {
                return nil
            }
        } catch {
            guard generation == accountGenerations[record.id, default: 0] else { return nil }
            return GitHubAccountConnection(
                account: account,
                state: .needsAttention,
                message: GitHubConnectionError.accountStorage.localizedDescription,
                recoveryAction: .validate
            )
        }
        let credentialAccount = Self.credentialAccount(for: record.id)
        let tokenData: Data?
        do {
            tokenData = try await credentials.data(for: credentialAccount)
        } catch {
            guard generation == accountGenerations[record.id, default: 0] else { return nil }
            return GitHubAccountConnection(
                account: account,
                state: .needsAttention,
                message: GitHubConnectionError.credentialStorage.localizedDescription,
                recoveryAction: .validate
            )
        }
        guard generation == accountGenerations[record.id, default: 0] else { return nil }
        guard let tokenData,
              let token = String(data: tokenData, encoding: .utf8),
              !token.isEmpty
        else {
            if let tokenData {
                let removed: Bool
                do {
                    removed = try await credentials.removeData(
                        for: credentialAccount,
                        ifMatches: tokenData
                    )
                } catch {
                    guard generation == accountGenerations[record.id, default: 0] else { return nil }
                    return GitHubAccountConnection(
                        account: account,
                        state: .needsAttention,
                        message: GitHubConnectionError.credentialStorage.localizedDescription,
                        recoveryAction: .validate
                    )
                }
                guard removed == true else { return nil }
            }
            guard generation == accountGenerations[record.id, default: 0] else { return nil }
            return GitHubAccountConnection(
                account: account,
                state: .needsAttention,
                message: GitHubConnectionError.invalidToken.localizedDescription,
                recoveryAction: .reconnect
            )
        }

        do {
            let refreshed = try await api.authenticatedUser(token: token)
            guard generation == accountGenerations[record.id, default: 0] else { return nil }
            guard refreshed.connectedAccountID == record.id else {
                return GitHubAccountConnection(
                    account: account,
                    state: .needsAttention,
                    message: GitHubConnectionError.accountMismatch.localizedDescription,
                    recoveryAction: .reconnect
                )
            }
            let refreshedRecord = refreshed.connectedAccountRecord
            try? await accountStore.upsert(refreshedRecord)
            guard generation == accountGenerations[record.id, default: 0] else {
                if accountMutationIntents[record.id] == .disconnect {
                    _ = try? await accountStore.replace(refreshedRecord, with: nil)
                }
                return nil
            }
            return GitHubAccountConnection(account: refreshed, state: .connected)
        } catch GitHubAPIError.unauthorized {
            guard generation == accountGenerations[record.id, default: 0] else { return nil }
            let removed: Bool
            do {
                removed = try await credentials.removeData(
                    for: credentialAccount,
                    ifMatches: tokenData
                )
            } catch {
                guard generation == accountGenerations[record.id, default: 0] else { return nil }
                return GitHubAccountConnection(
                    account: account,
                    state: .needsAttention,
                    message: GitHubConnectionError.credentialStorage.localizedDescription,
                    recoveryAction: .validate
                )
            }
            guard removed == true,
                  generation == accountGenerations[record.id, default: 0]
            else {
                return nil
            }
            accountGenerations[record.id, default: 0] &+= 1
            return GitHubAccountConnection(
                account: account,
                state: .needsAttention,
                message: GitHubConnectionError.invalidToken.localizedDescription,
                recoveryAction: .reconnect
            )
        } catch GitHubAPIError.insufficientOAuthScope {
            guard generation == accountGenerations[record.id, default: 0] else { return nil }
            return GitHubAccountConnection(
                account: account,
                state: .needsAttention,
                message: GitHubConnectionError.privateRepositoryAccessRequired.localizedDescription,
                recoveryAction: .reconnect
            )
        } catch {
            guard generation == accountGenerations[record.id, default: 0] else { return nil }
            return GitHubAccountConnection(
                account: account,
                state: .needsAttention,
                message: map(error).localizedDescription,
                recoveryAction: .validate
            )
        }
    }

    func restoreAccount() async throws -> GitHubAccount? {
        if let activeCredentialCleanup {
            do {
                try await activeCredentialCleanup.task.value
            } catch {
                throw GitHubConnectionError.credentialStorage
            }
        }

        let authorizationGeneration = self.authorizationGeneration
        if let activeRestoration,
           activeRestoration.authorizationGeneration == authorizationGeneration {
            let account = try await activeRestoration.task.value
            guard authorizationGeneration == self.authorizationGeneration else {
                return nil
            }
            return account
        } else if let activeRestoration {
            activeRestoration.task.cancel()
            self.activeRestoration = nil
        }

        restorationSequence &+= 1
        let restorationID = restorationSequence
        let task = Task { try await self.performRestoreAccount() }
        activeRestoration = (restorationID, authorizationGeneration, task)

        do {
            let account = try await task.value
            guard authorizationGeneration == self.authorizationGeneration else {
                if activeRestoration?.id == restorationID {
                    activeRestoration = nil
                }
                return nil
            }
            if activeRestoration?.id == restorationID {
                activeRestoration = nil
            }
            return account
        } catch {
            if activeRestoration?.id == restorationID {
                activeRestoration = nil
            }
            throw error
        }
    }

    func authoredPullRequests(for account: GitHubAccount) async throws -> GitHubPullRequestCollection {
        try await pullRequests(for: account, query: .authored)
    }

    func assignedPullRequests(for account: GitHubAccount) async throws -> GitHubPullRequestCollection {
        try await pullRequests(for: account, query: .assigned)
    }

    func pullRequestDetails(
        for pullRequest: GitHubPullRequest,
        account: GitHubAccount
    ) async throws -> GitHubPullRequestDetails {
        if let activeCredentialCleanup {
            do {
                try await activeCredentialCleanup.task.value
            } catch {
                throw GitHubConnectionError.credentialStorage
            }
        }

        let generation = authorizationGeneration
        let accountID = account.connectedAccountID
        let accountGeneration = accountGenerations[accountID, default: 0]
        let tokenData: Data?
        let credentialAccount: String
        do {
            let registered = try await accountStore.accounts(for: .github)
                .contains { $0.id == accountID }
            if let scopedToken = try await credentials.data(for: Self.credentialAccount(for: accountID)) {
                tokenData = scopedToken
                credentialAccount = Self.credentialAccount(for: accountID)
            } else if !registered {
                tokenData = try await credentials.data(for: Self.credentialAccount)
                credentialAccount = Self.credentialAccount
            } else {
                tokenData = nil
                credentialAccount = Self.credentialAccount(for: accountID)
            }
        } catch {
            throw GitHubConnectionError.credentialStorage
        }

        guard generation == authorizationGeneration,
              accountGeneration == accountGenerations[accountID, default: 0]
        else {
            throw CancellationError()
        }
        guard let tokenData,
              let token = String(data: tokenData, encoding: .utf8),
              !token.isEmpty
        else {
            updateSummary(detail: "Authorization expired", state: .needsAttention)
            throw GitHubConnectionError.invalidToken
        }

        do {
            let details = try await api.pullRequestDetails(
                repository: pullRequest.repository,
                number: pullRequest.number,
                token: token
            )
            try Task.checkCancellation()
            guard generation == authorizationGeneration,
                  accountGeneration == accountGenerations[accountID, default: 0]
            else {
                throw CancellationError()
            }
            return details
        } catch GitHubAPIError.unauthorized {
            guard generation == authorizationGeneration,
                  accountGeneration == accountGenerations[accountID, default: 0]
            else {
                throw CancellationError()
            }
            let removed: Bool
            do {
                removed = try await credentials.removeData(
                    for: credentialAccount,
                    ifMatches: tokenData
                )
            } catch {
                throw GitHubConnectionError.credentialStorage
            }
            guard generation == authorizationGeneration,
                  accountGeneration == accountGenerations[accountID, default: 0],
                  removed
            else {
                throw CancellationError()
            }
            accountGenerations[accountID, default: 0] &+= 1
            updateSummary(detail: "Authorization expired", state: .needsAttention)
            throw GitHubConnectionError.invalidToken
        } catch GitHubAPIError.insufficientOAuthScope {
            guard generation == authorizationGeneration,
                  accountGeneration == accountGenerations[accountID, default: 0]
            else {
                throw CancellationError()
            }
            updateSummary(detail: "Private repository access required", state: .needsAttention)
            throw GitHubConnectionError.privateRepositoryAccessRequired
        } catch {
            if Task.isCancelled { throw CancellationError() }
            guard generation == authorizationGeneration,
                  accountGeneration == accountGenerations[accountID, default: 0]
            else {
                throw CancellationError()
            }
            throw map(error)
        }
    }

    private func pullRequests(
        for account: GitHubAccount,
        query: PullRequestQuery
    ) async throws -> GitHubPullRequestCollection {
        if let activeCredentialCleanup {
            do {
                try await activeCredentialCleanup.task.value
            } catch {
                throw GitHubConnectionError.credentialStorage
            }
        }

        let generation = authorizationGeneration
        let accountID = account.connectedAccountID
        let accountGeneration = accountGenerations[accountID, default: 0]
        let tokenData: Data?
        let credentialAccount: String
        do {
            let registered = try await accountStore.accounts(for: .github)
                .contains { $0.id == accountID }
            if let scopedToken = try await credentials.data(for: Self.credentialAccount(for: accountID)) {
                tokenData = scopedToken
                credentialAccount = Self.credentialAccount(for: accountID)
            } else if !registered {
                tokenData = try await credentials.data(for: Self.credentialAccount)
                credentialAccount = Self.credentialAccount
            } else {
                tokenData = nil
                credentialAccount = Self.credentialAccount(for: accountID)
            }
        } catch {
            throw GitHubConnectionError.credentialStorage
        }

        guard generation == authorizationGeneration,
              accountGeneration == accountGenerations[accountID, default: 0]
        else {
            throw CancellationError()
        }

        guard let tokenData,
              let token = String(data: tokenData, encoding: .utf8),
              !token.isEmpty
        else {
            updateSummary(detail: "Authorization expired", state: .needsAttention)
            throw GitHubConnectionError.invalidToken
        }

        do {
            let pullRequests = switch query {
            case .authored:
                try await api.authoredPullRequests(login: account.login, token: token)
            case .assigned:
                try await api.assignedPullRequests(login: account.login, token: token)
            }
            try Task.checkCancellation()
            guard generation == authorizationGeneration,
                  accountGeneration == accountGenerations[accountID, default: 0]
            else {
                throw CancellationError()
            }
            return pullRequests
        } catch GitHubAPIError.unauthorized {
            guard generation == authorizationGeneration,
                  accountGeneration == accountGenerations[accountID, default: 0]
            else {
                throw CancellationError()
            }
            let removed: Bool
            do {
                removed = try await credentials.removeData(
                    for: credentialAccount,
                    ifMatches: tokenData
                )
            } catch {
                throw GitHubConnectionError.credentialStorage
            }
            guard generation == authorizationGeneration,
                  accountGeneration == accountGenerations[accountID, default: 0],
                  removed
            else {
                throw CancellationError()
            }
            accountGenerations[accountID, default: 0] &+= 1
            updateSummary(detail: "Authorization expired", state: .needsAttention)
            throw GitHubConnectionError.invalidToken
        } catch GitHubAPIError.insufficientOAuthScope {
            guard generation == authorizationGeneration,
                  accountGeneration == accountGenerations[accountID, default: 0]
            else {
                throw CancellationError()
            }
            updateSummary(detail: "Private repository access required", state: .needsAttention)
            throw GitHubConnectionError.privateRepositoryAccessRequired
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            guard generation == authorizationGeneration,
                  accountGeneration == accountGenerations[accountID, default: 0]
            else {
                throw CancellationError()
            }
            throw map(error)
        }
    }

    private func performRestoreAccount() async throws -> GitHubAccount? {
        let generation = authorizationGeneration
        let storedTokenData: Data?
        do {
            storedTokenData = try await credentials.data(for: Self.credentialAccount)
        } catch {
            guard generation == authorizationGeneration else { return nil }
            updateSummary(detail: "Unable to read authorization", state: .needsAttention)
            throw GitHubConnectionError.credentialStorage
        }

        guard generation == authorizationGeneration else { return nil }

        guard let tokenData = storedTokenData else {
            updateSummary(detail: "Ready to connect", state: .disconnected)
            return nil
        }

        guard let token = String(data: tokenData, encoding: .utf8), !token.isEmpty else {
            guard try await removeInvalidCredential(generation: generation) else { return nil }
            updateSummary(detail: "Stored authorization is invalid", state: .needsAttention)
            throw GitHubConnectionError.invalidToken
        }

        do {
            let account = try await api.authenticatedUser(token: token)
            guard generation == authorizationGeneration else { return nil }
            updateSummary(detail: "@\(account.login)", state: .connected)
            return account
        } catch GitHubAPIError.unauthorized {
            guard generation == authorizationGeneration else { return nil }
            guard try await removeInvalidCredential(generation: generation) else { return nil }
            updateSummary(detail: "Authorization expired", state: .needsAttention)
            throw GitHubConnectionError.invalidToken
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            guard generation == authorizationGeneration else { return nil }
            updateSummary(detail: "Unable to validate account", state: .needsAttention)
            throw map(error)
        }
    }

    func beginAuthorization() async throws -> GitHubBrowserAuthorization {
        let configuration = try oauthConfiguration()
        authorizationGeneration &+= 1
        let generation = authorizationGeneration
        activeAuthorization = nil

        do {
            let authorization = try await authorizer.beginAuthorization(configuration: configuration)
            guard generation == authorizationGeneration else {
                await authorizer.cancelAuthorization(authorization)
                throw CancellationError()
            }
            activeAuthorization = authorization
            accountAuthorizations[authorization.id] = AccountAuthorizationSession(
                authorization: authorization,
                targetID: nil,
                targetGeneration: nil,
                generationSnapshot: accountGenerations
            )
            updateSummary(detail: "Waiting for authorization", state: .disconnected)
            return authorization
        } catch {
            if Task.isCancelled || generation != authorizationGeneration {
                if generation == authorizationGeneration {
                    activeAuthorization = nil
                    updateSummary(detail: "Ready to connect", state: .disconnected)
                }
                throw CancellationError()
            }
            updateSummary(detail: "Unable to start authorization", state: .needsAttention)
            throw map(error)
        }
    }

    func completeAuthorization(_ authorization: GitHubBrowserAuthorization) async throws -> GitHubAccount {
        guard activeAuthorization?.id == authorization.id else {
            throw CancellationError()
        }

        let generation = authorizationGeneration

        do {
            let connection = try await completeAccountAuthorization(authorization)
            guard generation == authorizationGeneration,
                  activeAuthorization?.id == authorization.id
            else {
                throw CancellationError()
            }
            activeAuthorization = nil
            updateSummary(detail: "@\(connection.account.login)", state: .connected)
            return connection.account
        } catch is CancellationError {
            if generation == authorizationGeneration {
                activeAuthorization = nil
                updateSummary(detail: "Ready to connect", state: .disconnected)
            }
            throw CancellationError()
        } catch {
            if let error = error as? GitHubConnectionError, error == .credentialStorage {
                if activeAuthorization?.id == authorization.id {
                    activeAuthorization = nil
                }
                updateSummary(detail: error.summaryDetail, state: .needsAttention)
                throw error
            }
            if Task.isCancelled {
                if generation == authorizationGeneration {
                    activeAuthorization = nil
                    updateSummary(detail: "Ready to connect", state: .disconnected)
                }
                throw CancellationError()
            }
            guard generation == authorizationGeneration else {
                throw CancellationError()
            }
            let connectionError = map(error)
            activeAuthorization = nil
            updateSummary(detail: connectionError.summaryDetail, state: .needsAttention)
            throw connectionError
        }
    }

    func cancelAuthorization() async throws {
        authorizationGeneration &+= 1
        let generation = authorizationGeneration
        await cancelAllAccountAuthorizations()

        do {
            let tokenData = try await credentials.data(for: Self.credentialAccount)
            try await revokeAuthorizationIfPresent(tokenData)
            try await performCredentialCleanup()
            guard generation == authorizationGeneration else { return }
            authorizationGeneration &+= 1
            updateSummary(detail: "Ready to connect", state: .disconnected)
        } catch {
            guard generation == authorizationGeneration else { return }
            authorizationGeneration &+= 1
            updateSummary(detail: "Unable to remove authorization", state: .needsAttention)
            throw GitHubConnectionError.credentialStorage
        }
    }

    func disconnect() async throws {
        authorizationGeneration &+= 1
        let generation = authorizationGeneration
        await cancelAllAccountAuthorizations()

        do {
            try await performCredentialCleanup()
            guard generation == authorizationGeneration else { return }
            authorizationGeneration &+= 1
            updateSummary(detail: "Ready to connect", state: .disconnected)
        } catch {
            guard generation == authorizationGeneration else { return }
            authorizationGeneration &+= 1
            updateSummary(detail: "Unable to remove authorization", state: .needsAttention)
            throw GitHubConnectionError.credentialStorage
        }
    }

    private func cancelAllAccountAuthorizations() async {
        let authorizations = accountAuthorizations.values.map(\.authorization)
        accountAuthorizations.removeAll()
        activeAuthorization = nil
        for authorization in authorizations {
            await authorizer.cancelAuthorization(authorization)
        }
    }

    private func updateSummary(detail: String, state: IntegrationConnectionState) {
        summaryStorage.update(detail: detail, state: state)
    }

    private func performCredentialCleanup() async throws {
        if let activeCredentialCleanup {
            try await activeCredentialCleanup.task.value
            return
        }

        cleanupSequence &+= 1
        let cleanupID = cleanupSequence
        let task = Task {
            try await credentials.removeData(for: Self.credentialAccount)
        }
        activeCredentialCleanup = (cleanupID, task)

        do {
            try await task.value
            if activeCredentialCleanup?.id == cleanupID {
                activeCredentialCleanup = nil
            }
        } catch {
            if activeCredentialCleanup?.id == cleanupID {
                activeCredentialCleanup = nil
            }
            throw error
        }
    }

    private func revokeAuthorizationIfPresent(_ tokenData: Data?) async throws {
        guard let tokenData else { return }
        guard let token = String(data: tokenData, encoding: .utf8), !token.isEmpty else {
            // A malformed local item cannot represent a usable GitHub token.
            // Continue with local cleanup so Disconnect remains recoverable.
            return
        }
        guard let clientID, let clientSecret else {
            // Local cleanup must remain possible for a build whose OAuth configuration
            // was removed after the credential was originally stored.
            return
        }
        guard let tokenRevoker else { return }

        do {
            try await tokenRevoker.revokeAuthorization(
                token: token,
                configuration: GitHubOAuthConfiguration(
                    clientID: clientID,
                    clientSecret: clientSecret
                )
            )
        } catch {
            throw map(error)
        }
    }

    private func removeInvalidCredential(generation: Int) async throws -> Bool {
        do {
            try await credentials.removeData(for: Self.credentialAccount)
        } catch {
            guard generation == authorizationGeneration else { return false }
            updateSummary(detail: "Unable to remove authorization", state: .needsAttention)
            throw GitHubConnectionError.credentialStorage
        }
        return generation == authorizationGeneration
    }

    private func oauthConfiguration() throws -> GitHubOAuthConfiguration {
        guard let clientID else {
            updateSummary(detail: "Client ID is not configured", state: .needsAttention)
            throw GitHubConnectionError.missingClientID
        }
        guard let clientSecret else {
            updateSummary(detail: "GitHub browser sign-in is not configured", state: .needsAttention)
            throw GitHubConnectionError.missingOAuthConfiguration
        }
        return GitHubOAuthConfiguration(clientID: clientID, clientSecret: clientSecret)
    }

    private func map(_ error: Error) -> GitHubConnectionError {
        if let error = error as? GitHubConnectionError {
            return error
        }

        if let error = error as? GitHubAPIError {
            switch error {
            case .accessDenied:
                return .accessDenied
            case .expiredRequest:
                return .requestExpired
            case .unauthorized:
                return .invalidToken
            case .malformedResponse:
                return .malformedResponse
            case .incorrectClientCredentials:
                return .invalidConfiguration
            case .rateLimited:
                return .rateLimited
            case .incompleteResults:
                return .incompleteResults
            case .insufficientOAuthScope:
                return .privateRepositoryAccessRequired
            case let .server(statusCode):
                return .server(statusCode)
            }
        }

        if let error = error as? GitHubOAuthError {
            switch error {
            case .missingConfiguration:
                return .missingOAuthConfiguration
            case .secureRandomUnavailable:
                return .secureRandomUnavailable
            case .couldNotStartCallbackServer:
                return .callbackUnavailable
            case .callbackTimedOut:
                return .requestExpired
            case .accessDenied:
                return .accessDenied
            case .authorizationFailed:
                return .malformedResponse
            case .invalidConfiguration:
                return .invalidConfiguration
            case .missingAuthorizationCode, .stateMismatch, .malformedCallback,
                 .callbackTooLarge, .invalidTokenResponse:
                return .malformedResponse
            case let .tokenExchangeFailed(statusCode):
                return .server(statusCode)
            case let .authorizationRevocationFailed(statusCode):
                return statusCode == 0 ? .malformedResponse : .server(statusCode)
            }
        }

        if error is URLError {
            return .networkUnavailable
        }

        return .networkUnavailable
    }
}

enum GitHubConnectionError: Error, Equatable, LocalizedError, Sendable {
    case missingClientID
    case missingOAuthConfiguration
    case invalidConfiguration
    case secureRandomUnavailable
    case callbackUnavailable
    case accessDenied
    case requestExpired
    case invalidToken
    case networkUnavailable
    case malformedResponse
    case rateLimited
    case incompleteResults
    case privateRepositoryAccessRequired
    case server(Int)
    case credentialStorage
    case accountStorage
    case accountMismatch
    case duplicateAccount

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            "Buddy was built without its bundled GitHub CLI-compatible client ID. Rebuild the app from a complete configuration."
        case .missingOAuthConfiguration:
            "Buddy was built without complete GitHub CLI-compatible browser configuration. Rebuild the app from a complete configuration."
        case .invalidConfiguration:
            "GitHub rejected the bundled GitHub CLI-compatible OAuth configuration. Rebuild Buddy or try again later."
        case .secureRandomUnavailable:
            "Buddy couldn't create a secure GitHub sign-in request. Try again."
        case .callbackUnavailable:
            "Buddy couldn't start the local GitHub sign-in callback. Try again."
        case .accessDenied:
            "Authorization was denied. You can try again when you're ready."
        case .requestExpired:
            "The authorization request expired. Start a new connection to try again."
        case .invalidToken:
            "GitHub authorization is no longer valid. Connect the account again."
        case .networkUnavailable:
            "Buddy couldn't reach GitHub. Check your connection and try again."
        case .malformedResponse:
            "GitHub returned an unexpected response. Try again in a moment."
        case .rateLimited:
            "GitHub's request limit was reached. Wait a little while, then refresh again."
        case .incompleteResults:
            "GitHub returned partial search results. Refresh to try again."
        case .privateRepositoryAccessRequired:
            "Buddy needs GitHub repository access to show private pull requests. Reconnect this account and approve repository access."
        case let .server(statusCode):
            "GitHub returned an error (\(statusCode)). Try again later."
        case .credentialStorage:
            "Buddy couldn't update the credential in Keychain. Try again."
        case .accountStorage:
            "Buddy couldn't load the connected account list. Try again."
        case .accountMismatch:
            "GitHub authorized a different account. Sign in with the account being reconnected."
        case .duplicateAccount:
            "This GitHub account is already connected. Use Reconnect account to replace its authorization."
        }
    }

    fileprivate var summaryDetail: String {
        switch self {
        case .missingClientID: "Client ID is not configured"
        case .missingOAuthConfiguration: "GitHub browser sign-in is not configured"
        case .invalidConfiguration: "GitHub configuration is invalid"
        case .secureRandomUnavailable: "Secure sign-in unavailable"
        case .callbackUnavailable: "Local sign-in callback unavailable"
        case .accessDenied: "Authorization was denied"
        case .requestExpired: "Authorization request expired"
        case .invalidToken: "Authorization expired"
        case .networkUnavailable: "Unable to reach GitHub"
        case .malformedResponse: "Unexpected response from GitHub"
        case .rateLimited: "GitHub request limit reached"
        case .incompleteResults: "GitHub returned partial results"
        case .privateRepositoryAccessRequired: "Private repository access required"
        case .server: "GitHub is unavailable"
        case .credentialStorage: "Keychain update failed"
        case .accountStorage: "Account list unavailable"
        case .accountMismatch: "Different GitHub account authorized"
        case .duplicateAccount: "GitHub account already connected"
        }
    }
}

struct GitHubAccountConnection: Identifiable, Equatable, Sendable {
    let account: GitHubAccount
    var state: IntegrationConnectionState
    var message: String?
    var recoveryAction: GitHubAccountRecoveryAction?

    var id: ConnectedAccountID { account.connectedAccountID }

    init(
        account: GitHubAccount,
        state: IntegrationConnectionState,
        message: String? = nil,
        recoveryAction: GitHubAccountRecoveryAction? = nil
    ) {
        self.account = account
        self.state = state
        self.message = message
        self.recoveryAction = recoveryAction
    }
}

enum GitHubAccountRecoveryAction: Equatable, Sendable {
    case validate
    case reconnect
}

private final class LockedGitHubSummary: @unchecked Sendable {
    private let lock = NSLock()
    private var summary: IntegrationSummary

    init(_ summary: IntegrationSummary) {
        self.summary = summary
    }

    var value: IntegrationSummary {
        lock.lock()
        defer { lock.unlock() }
        return summary
    }

    func update(detail: String, state: IntegrationConnectionState) {
        lock.lock()
        defer { lock.unlock() }
        summary.detail = detail
        summary.connectionState = state
    }
}
