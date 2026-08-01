import Foundation
import SwiftUI

protocol CredentialStoring: Sendable {
    func set(_ data: Data, for account: String) async throws
    func data(for account: String) async throws -> Data?
    func removeData(for account: String) async throws
}

extension KeychainStore: CredentialStoring {}

actor GitHubIntegration: IntegrationProviding {
    private static let credentialAccount = "github.oauth-token"

    nonisolated var summary: IntegrationSummary { summaryStorage.value }

    private let clientID: String?
    private let api: any GitHubAPIProviding
    private let credentials: any CredentialStoring
    private let sleep: @Sendable (Duration) async throws -> Void
    private let summaryStorage: LockedGitHubSummary
    private var authorizationGeneration = 0
    private var activeDeviceCode: String?

    init(
        clientID: String? = AppConfiguration.current.githubClientID,
        api: (any GitHubAPIProviding)? = nil,
        credentials: any CredentialStoring = KeychainStore(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.clientID = clientID
        self.api = api ?? GitHubAPI()
        self.credentials = credentials
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
        _ = try await restoreAccount()
        return summary
    }

    func restoreAccount() async throws -> GitHubAccount? {
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
            try? await credentials.removeData(for: Self.credentialAccount)
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
            try? await credentials.removeData(for: Self.credentialAccount)
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
                try await sleep(.seconds(interval))

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
            try await credentials.removeData(for: Self.credentialAccount)
            guard generation == authorizationGeneration else { return }
            updateSummary(detail: "Ready to connect", state: .disconnected)
        } catch {
            guard generation == authorizationGeneration else { return }
            updateSummary(detail: "Unable to remove authorization", state: .needsAttention)
            throw GitHubConnectionError.credentialStorage
        }
    }

    func disconnect() async throws {
        authorizationGeneration &+= 1
        let generation = authorizationGeneration
        activeDeviceCode = nil

        do {
            try await credentials.removeData(for: Self.credentialAccount)
            guard generation == authorizationGeneration else { return }
            updateSummary(detail: "Ready to connect", state: .disconnected)
        } catch {
            guard generation == authorizationGeneration else { return }
            updateSummary(detail: "Unable to remove authorization", state: .needsAttention)
            throw GitHubConnectionError.credentialStorage
        }
    }

    private func updateSummary(detail: String, state: IntegrationConnectionState) {
        summaryStorage.update(detail: detail, state: state)
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
    case server(Int)
    case credentialStorage

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            "GitHub connection is not configured. Add BUDDY_GITHUB_CLIENT_ID to Config/Local.xcconfig."
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
        case let .server(statusCode):
            "GitHub returned an error (\(statusCode)). Try again later."
        case .credentialStorage:
            "Buddy couldn't update the credential in Keychain. Try again."
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
        case .server: "GitHub is unavailable"
        case .credentialStorage: "Keychain update failed"
        }
    }
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
