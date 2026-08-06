import Foundation
import SwiftUI

protocol CredentialStoring: Sendable {
    func set(_ data: Data, for account: String) async throws
    func setIfMissing(_ data: Data, for account: String) async throws -> Bool
    func data(for account: String) async throws -> Data?
    func removeData(for account: String) async throws
    func removeData(for account: String, ifMatches expectedData: Data) async throws -> Bool
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
}

extension KeychainStore: CredentialStoring {}

actor GitHubIntegration: IntegrationProviding {
    private struct AccountAuthorizationSession: Sendable {
        let targetID: ConnectedAccountID?
        let targetGeneration: Int?
    }

    private struct LegacyMigrationResult: Sendable {
        let record: ConnectedAccountRecord
        let requiresScopedValidation: Bool
    }

    private static let credentialAccount = "github.oauth-token"

    static func credentialAccount(for id: ConnectedAccountID) -> String {
        "github.account.\(id.subject).oauth-token"
    }

    nonisolated var summary: IntegrationSummary { summaryStorage.value }
    nonisolated let isAuthorizationConfigured: Bool

    private let clientID: String?
    private let api: any GitHubAPIProviding
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
    private var activeDeviceCode: String?
    private var accountAuthorizations: [String: AccountAuthorizationSession] = [:]
    private var accountGenerations: [ConnectedAccountID: Int] = [:]

    init(
        clientID: String? = AppConfiguration.current.githubClientID,
        api: (any GitHubAPIProviding)? = nil,
        credentials: any CredentialStoring = KeychainStore(),
        accountStore: (any ConnectedAccountStoring)? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.clientID = clientID
        isAuthorizationConfigured = clientID != nil
        self.api = api ?? GitHubAPI()
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
        if let migrated {
            if migrated.requiresScopedValidation {
                if let connection = await restoreRegisteredAccount(migrated.record) {
                    connections.append(connection)
                }
            } else {
                connections.append(
                    GitHubAccountConnection(
                        account: GitHubAccount(record: migrated.record),
                        state: .connected
                    )
                )
            }
        }
        for record in records.sorted(by: { $0.id < $1.id }) {
            if let connection = await restoreRegisteredAccount(record) {
                connections.append(connection)
            }
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
    ) async throws -> GitHubDeviceAuthorization {
        guard let clientID else { throw GitHubConnectionError.missingClientID }
        let targetGeneration = id.map { id in
            accountGenerations[id, default: 0] &+= 1
            return accountGenerations[id, default: 0]
        }
        do {
            let authorization = try await api.requestDeviceAuthorization(clientID: clientID)
            if let id,
               accountGenerations[id, default: 0] != targetGeneration {
                throw CancellationError()
            }
            accountAuthorizations[authorization.deviceCode] = AccountAuthorizationSession(
                targetID: id,
                targetGeneration: targetGeneration
            )
            return authorization
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw map(error)
        }
    }

    func completeAccountAuthorization(
        _ authorization: GitHubDeviceAuthorization
    ) async throws -> GitHubAccountConnection {
        guard let clientID else { throw GitHubConnectionError.missingClientID }
        guard let session = accountAuthorizations[authorization.deviceCode] else {
            throw CancellationError()
        }
        let targetID = session.targetID
        let targetGeneration = session.targetGeneration
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(authorization.expiresIn)
        var interval = authorization.interval

        do {
            while clock.now < deadline {
                try Task.checkCancellation()
                try await sleep(min(.seconds(interval), clock.now.duration(to: deadline)))
                guard accountAuthorizations.keys.contains(authorization.deviceCode) else {
                    throw CancellationError()
                }
                guard clock.now < deadline else { throw GitHubConnectionError.requestExpired }

                switch try await api.pollForAccessToken(
                    clientID: clientID,
                    deviceCode: authorization.deviceCode
                ) {
                case .pending:
                    continue
                case let .slowDown(serverInterval):
                    interval = max(interval + 5, serverInterval ?? 0)
                case let .authorized(token):
                    let account = try await api.authenticatedUser(token: token)
                    let accountID = account.connectedAccountID
                    if let targetID, targetID != accountID {
                        throw GitHubConnectionError.accountMismatch
                    }
                    if let targetID,
                       accountGenerations[targetID, default: 0] != targetGeneration {
                        throw CancellationError()
                    }
                    guard accountAuthorizations.keys.contains(authorization.deviceCode) else {
                        throw CancellationError()
                    }

                    accountGenerations[accountID, default: 0] &+= 1
                    let accountGeneration = accountGenerations[accountID, default: 0]
                    let credentialAccount = Self.credentialAccount(for: accountID)
                    let previousToken: Data?
                    let previousRecord: ConnectedAccountRecord?
                    do {
                        previousToken = try await credentials.data(for: credentialAccount)
                        previousRecord = try await accountStore.accounts(for: .github)
                            .first { $0.id == accountID }
                    } catch {
                        throw GitHubConnectionError.credentialStorage
                    }
                    guard !Task.isCancelled,
                          accountAuthorizations.keys.contains(authorization.deviceCode),
                          accountGenerations[accountID, default: 0] == accountGeneration
                    else {
                        throw CancellationError()
                    }

                    do {
                        try await credentials.set(Data(token.utf8), for: credentialAccount)
                        guard !Task.isCancelled,
                              accountAuthorizations.keys.contains(authorization.deviceCode),
                              accountGenerations[accountID, default: 0] == accountGeneration
                        else {
                            if accountGenerations[accountID, default: 0] == accountGeneration {
                                await rollbackAccountWrite(
                                    id: accountID,
                                    previousToken: previousToken,
                                    previousRecord: previousRecord
                                )
                            }
                            throw CancellationError()
                        }
                        try await accountStore.upsert(account.connectedAccountRecord)
                    } catch {
                        if error is CancellationError { throw error }
                        if accountGenerations[accountID, default: 0] == accountGeneration {
                            await rollbackAccountWrite(
                                id: accountID,
                                previousToken: previousToken,
                                previousRecord: previousRecord
                            )
                        }
                        throw GitHubConnectionError.credentialStorage
                    }

                    guard !Task.isCancelled,
                          accountAuthorizations.keys.contains(authorization.deviceCode),
                          accountGenerations[accountID, default: 0] == accountGeneration
                    else {
                        if accountGenerations[accountID, default: 0] == accountGeneration {
                            await rollbackAccountWrite(
                                id: accountID,
                                previousToken: previousToken,
                                previousRecord: previousRecord
                            )
                        }
                        throw CancellationError()
                    }
                    accountAuthorizations.removeValue(forKey: authorization.deviceCode)
                    return GitHubAccountConnection(account: account, state: .connected)
                }
            }
            throw GitHubConnectionError.requestExpired
        } catch is CancellationError {
            accountAuthorizations.removeValue(forKey: authorization.deviceCode)
            throw CancellationError()
        } catch {
            accountAuthorizations.removeValue(forKey: authorization.deviceCode)
            throw map(error)
        }
    }

    func cancelAccountAuthorization(_ authorization: GitHubDeviceAuthorization) {
        accountAuthorizations.removeValue(forKey: authorization.deviceCode)
    }

    func disconnect(accountID: ConnectedAccountID) async throws {
        accountGenerations[accountID, default: 0] &+= 1
        let generation = accountGenerations[accountID, default: 0]
        accountAuthorizations = accountAuthorizations.filter { $0.value.targetID != accountID }
        var previousRecord: ConnectedAccountRecord?
        var tokenData: Data?
        let credentialAccount = Self.credentialAccount(for: accountID)
        do {
            // Singleton credentials are pre-migration state and are never authoritative
            // once account-scoped records are presented. Clear the legacy item locally
            // so disconnect remains durable while offline.
            try await credentials.removeData(for: Self.credentialAccount)
            guard generation == accountGenerations[accountID, default: 0] else {
                throw CancellationError()
            }

            previousRecord = try await accountStore.accounts(for: .github)
                .first { $0.id == accountID }
            tokenData = try await credentials.data(for: credentialAccount)
            guard generation == accountGenerations[accountID, default: 0] else {
                throw CancellationError()
            }

            // Remove metadata before the scoped token. If a reconnect supersedes this
            // operation, rollback only fills values that its newer write did not replace.
            try await accountStore.remove(accountID)
            guard generation == accountGenerations[accountID, default: 0] else {
                await restoreDisconnectedAccount(
                    record: previousRecord,
                    tokenData: tokenData,
                    credentialAccount: credentialAccount
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
                        record: previousRecord,
                        tokenData: tokenData,
                        credentialAccount: credentialAccount
                    )
                    if generation != accountGenerations[accountID, default: 0] {
                        throw CancellationError()
                    }
                    throw GitHubConnectionError.credentialStorage
                }
            }
            guard generation == accountGenerations[accountID, default: 0] else {
                await restoreDisconnectedAccount(
                    record: previousRecord,
                    tokenData: tokenData,
                    credentialAccount: credentialAccount
                )
                throw CancellationError()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await restoreDisconnectedAccount(
                record: previousRecord,
                tokenData: tokenData,
                credentialAccount: credentialAccount
            )
            throw GitHubConnectionError.credentialStorage
        }
    }

    private func restoreDisconnectedAccount(
        record: ConnectedAccountRecord?,
        tokenData: Data?,
        credentialAccount: String
    ) async {
        if let record {
            _ = try? await accountStore.upsertIfMissing(record)
        }
        if let tokenData {
            _ = try? await credentials.setIfMissing(tokenData, for: credentialAccount)
        }
    }

    private func rollbackAccountWrite(
        id: ConnectedAccountID,
        previousToken: Data?,
        previousRecord: ConnectedAccountRecord?
    ) async {
        let credentialAccount = Self.credentialAccount(for: id)
        if let previousToken {
            try? await credentials.set(previousToken, for: credentialAccount)
        } else {
            try? await credentials.removeData(for: credentialAccount)
        }

        if let previousRecord {
            try? await accountStore.upsert(previousRecord)
        } else {
            try? await accountStore.remove(id)
        }
    }

    private func migrateLegacyCredential() async throws -> LegacyMigrationResult? {
        let legacyData: Data?
        do {
            legacyData = try await credentials.data(for: Self.credentialAccount)
        } catch {
            throw GitHubConnectionError.credentialStorage
        }
        guard let legacyData else { return nil }
        guard let token = String(data: legacyData, encoding: .utf8), !token.isEmpty else {
            do {
                try await credentials.removeData(for: Self.credentialAccount)
            } catch {
                throw GitHubConnectionError.credentialStorage
            }
            return nil
        }

        let account: GitHubAccount
        do {
            account = try await api.authenticatedUser(token: token)
        } catch GitHubAPIError.unauthorized {
            do {
                try await credentials.removeData(for: Self.credentialAccount)
            } catch {
                throw GitHubConnectionError.credentialStorage
            }
            return nil
        } catch {
            throw map(error)
        }

        let scopedCredentialAccount = Self.credentialAccount(for: account.connectedAccountID)
        let existingRecord: ConnectedAccountRecord?
        let existingScopedCredential: Data?
        do {
            existingRecord = try await accountStore.accounts(for: .github)
                .first { $0.id == account.connectedAccountID }
            existingScopedCredential = try await credentials.data(for: scopedCredentialAccount)
        } catch {
            throw GitHubConnectionError.credentialStorage
        }

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
            }
            try? await credentials.removeData(for: Self.credentialAccount)
            return LegacyMigrationResult(record: record, requiresScopedValidation: true)
        }

        do {
            try await credentials.set(
                legacyData,
                for: scopedCredentialAccount
            )
            try await accountStore.upsert(account.connectedAccountRecord)
            try? await credentials.removeData(for: Self.credentialAccount)
        } catch {
            throw GitHubConnectionError.credentialStorage
        }
        return LegacyMigrationResult(
            record: account.connectedAccountRecord,
            requiresScopedValidation: false
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
                let removed = try? await credentials.removeData(
                    for: credentialAccount,
                    ifMatches: tokenData
                )
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
            try? await accountStore.upsert(refreshed.connectedAccountRecord)
            guard generation == accountGenerations[record.id, default: 0] else { return nil }
            return GitHubAccountConnection(account: refreshed, state: .connected)
        } catch GitHubAPIError.unauthorized {
            guard generation == accountGenerations[record.id, default: 0] else { return nil }
            let removed = try? await credentials.removeData(
                for: credentialAccount,
                ifMatches: tokenData
            )
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
            let pullRequests = try await api.authoredPullRequests(login: account.login, token: token)
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

    func beginAuthorization() async throws -> GitHubDeviceAuthorization {
        guard let clientID else {
            updateSummary(detail: "Client ID is not configured", state: .needsAttention)
            throw GitHubConnectionError.missingClientID
        }

        authorizationGeneration &+= 1
        let generation = authorizationGeneration
        activeDeviceCode = nil

        do {
            let authorization = try await api.requestDeviceAuthorization(clientID: clientID)
            guard generation == authorizationGeneration else {
                throw CancellationError()
            }
            activeDeviceCode = authorization.deviceCode
            updateSummary(detail: "Waiting for authorization", state: .disconnected)
            return authorization
        } catch {
            if Task.isCancelled || generation != authorizationGeneration {
                if generation == authorizationGeneration {
                    activeDeviceCode = nil
                    updateSummary(detail: "Ready to connect", state: .disconnected)
                }
                throw CancellationError()
            }
            updateSummary(detail: "Unable to start authorization", state: .needsAttention)
            throw map(error)
        }
    }

    func completeAuthorization(_ authorization: GitHubDeviceAuthorization) async throws -> GitHubAccount {
        guard let clientID else {
            updateSummary(detail: "Client ID is not configured", state: .needsAttention)
            throw GitHubConnectionError.missingClientID
        }

        guard activeDeviceCode == authorization.deviceCode else {
            throw CancellationError()
        }

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(authorization.expiresIn)
        let generation = authorizationGeneration
        var interval = authorization.interval

        do {
            while clock.now < deadline {
                try Task.checkCancellation()
                let remainingLifetime = clock.now.duration(to: deadline)
                try await sleep(min(.seconds(interval), remainingLifetime))

                guard generation == authorizationGeneration,
                      activeDeviceCode == authorization.deviceCode
                else {
                    throw CancellationError()
                }

                guard clock.now < deadline else {
                    throw GitHubConnectionError.requestExpired
                }

                switch try await api.pollForAccessToken(
                    clientID: clientID,
                    deviceCode: authorization.deviceCode
                ) {
                case .pending:
                    continue
                case let .slowDown(serverInterval):
                    interval = max(interval + 5, serverInterval ?? 0)
                case let .authorized(token):
                    let account = try await api.authenticatedUser(token: token)
                    guard generation == authorizationGeneration,
                          activeDeviceCode == authorization.deviceCode
                    else {
                        throw CancellationError()
                    }

                    do {
                        try await credentials.set(Data(token.utf8), for: Self.credentialAccount)
                    } catch {
                        guard !Task.isCancelled,
                              generation == authorizationGeneration,
                              activeDeviceCode == authorization.deviceCode
                        else {
                            throw CancellationError()
                        }
                        throw GitHubConnectionError.credentialStorage
                    }

                    if Task.isCancelled ||
                        generation != authorizationGeneration ||
                        activeDeviceCode != authorization.deviceCode {
                        do {
                            try await credentials.removeData(for: Self.credentialAccount)
                        } catch {
                            throw GitHubConnectionError.credentialStorage
                        }
                        throw CancellationError()
                    }

                    activeDeviceCode = nil
                    updateSummary(detail: "@\(account.login)", state: .connected)
                    return account
                }
            }

            guard generation == authorizationGeneration,
                  activeDeviceCode == authorization.deviceCode
            else {
                throw CancellationError()
            }
            updateSummary(detail: "Authorization request expired", state: .needsAttention)
            throw GitHubConnectionError.requestExpired
        } catch is CancellationError {
            if generation == authorizationGeneration {
                activeDeviceCode = nil
                updateSummary(detail: "Ready to connect", state: .disconnected)
            }
            throw CancellationError()
        } catch {
            if let error = error as? GitHubConnectionError, error == .credentialStorage {
                if activeDeviceCode == authorization.deviceCode {
                    activeDeviceCode = nil
                }
                updateSummary(detail: error.summaryDetail, state: .needsAttention)
                throw error
            }
            if Task.isCancelled {
                if generation == authorizationGeneration {
                    activeDeviceCode = nil
                    updateSummary(detail: "Ready to connect", state: .disconnected)
                }
                throw CancellationError()
            }
            guard generation == authorizationGeneration else {
                throw CancellationError()
            }
            let connectionError = map(error)
            activeDeviceCode = nil
            updateSummary(detail: connectionError.summaryDetail, state: .needsAttention)
            throw connectionError
        }
    }

    func cancelAuthorization() async throws {
        authorizationGeneration &+= 1
        let generation = authorizationGeneration
        activeDeviceCode = nil

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

    func disconnect() async throws {
        authorizationGeneration &+= 1
        let generation = authorizationGeneration
        activeDeviceCode = nil

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
            case .deviceFlowDisabled:
                return .deviceFlowDisabled
            case .incorrectClientCredentials:
                return .invalidConfiguration
            case .rateLimited:
                return .rateLimited
            case .incompleteResults:
                return .incompleteResults
            case let .server(statusCode):
                return .server(statusCode)
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
    case invalidConfiguration
    case deviceFlowDisabled
    case accessDenied
    case requestExpired
    case invalidToken
    case networkUnavailable
    case malformedResponse
    case rateLimited
    case incompleteResults
    case server(Int)
    case credentialStorage
    case accountStorage
    case accountMismatch

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            "Buddy was built without a GitHub client ID. Set BUDDY_GITHUB_CLIENT_ID in the build configuration and rebuild the app."
        case .invalidConfiguration:
            "GitHub rejected this app's client ID. Check the local configuration and try again."
        case .deviceFlowDisabled:
            "Device Flow is not enabled for this GitHub OAuth app. Enable it in the app's GitHub settings."
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
        case let .server(statusCode):
            "GitHub returned an error (\(statusCode)). Try again later."
        case .credentialStorage:
            "Buddy couldn't update the credential in Keychain. Try again."
        case .accountStorage:
            "Buddy couldn't load the connected account list. Try again."
        case .accountMismatch:
            "GitHub authorized a different account. Sign in with the account being reconnected."
        }
    }

    fileprivate var summaryDetail: String {
        switch self {
        case .missingClientID: "Client ID is not configured"
        case .invalidConfiguration: "GitHub configuration is invalid"
        case .deviceFlowDisabled: "Device Flow is not enabled"
        case .accessDenied: "Authorization was denied"
        case .requestExpired: "Authorization request expired"
        case .invalidToken: "Authorization expired"
        case .networkUnavailable: "Unable to reach GitHub"
        case .malformedResponse: "Unexpected response from GitHub"
        case .rateLimited: "GitHub request limit reached"
        case .incompleteResults: "GitHub returned partial results"
        case .server: "GitHub is unavailable"
        case .credentialStorage: "Keychain update failed"
        case .accountStorage: "Account list unavailable"
        case .accountMismatch: "Different GitHub account authorized"
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
