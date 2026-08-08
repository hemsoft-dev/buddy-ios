import Foundation
#if DEBUG
import CryptoKit
import Network
import Security
#endif

struct GitHubBrowserAuthorization: Equatable, Identifiable, Sendable {
    let id: UUID
    let authorizationURL: URL
    let deviceCode: String?
    let userCode: String?
    let expiresIn: Int
    let interval: Int

    init(
        id: UUID,
        authorizationURL: URL,
        deviceCode: String? = nil,
        userCode: String? = nil,
        expiresIn: Int = 900,
        interval: Int = 5
    ) {
        self.id = id
        self.authorizationURL = authorizationURL
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.expiresIn = expiresIn
        self.interval = interval
    }
}

struct GitHubOAuthConfiguration: Equatable, Sendable {
    static let repositoryScope = "repo"

    let clientID: String
    let clientSecret: String
}

protocol GitHubOAuthAuthorizing: Sendable {
    func beginAuthorization(configuration: GitHubOAuthConfiguration) async throws -> GitHubBrowserAuthorization
    func completeAuthorization(_ authorization: GitHubBrowserAuthorization) async throws -> String
    func cancelAuthorization(_ authorization: GitHubBrowserAuthorization) async
    func revokeAuthorization(token: String, configuration: GitHubOAuthConfiguration) async throws
}

extension GitHubOAuthAuthorizing {
    func revokeAuthorization(token _: String, configuration _: GitHubOAuthConfiguration) async throws {}
}

struct GitHubAccount: Hashable, Sendable {
    let id: Int
    let login: String
    let name: String?
    let avatarURL: URL?

    init(id: Int, login: String, name: String?, avatarURL: URL?) {
        self.id = id
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
    }

    var connectedAccountID: ConnectedAccountID {
        ConnectedAccountID(provider: .github, subject: String(id))
    }

    var connectedAccountRecord: ConnectedAccountRecord {
        ConnectedAccountRecord(
            id: connectedAccountID,
            username: login,
            displayName: name,
            avatarURL: avatarURL
        )
    }

    init(record: ConnectedAccountRecord) {
        id = Int(record.id.subject) ?? 0
        login = record.username
        name = record.displayName
        avatarURL = record.avatarURL
    }
}

struct GitHubPullRequest: Identifiable, Equatable, Sendable {
    let id: Int
    let repository: String
    let number: Int
    let title: String
    let isDraft: Bool
    let updatedAt: Date
    let url: URL
}

struct GitHubPullRequestCollection: Equatable, Sendable {
    let pullRequests: [GitHubPullRequest]
    let totalCount: Int
}

protocol GitHubAPIProviding: Sendable {
    func authenticatedUser(token: String) async throws -> GitHubAccount
    func authenticatedUserForCredentialMigration(token: String) async throws -> GitHubAccount
    func authoredPullRequests(login: String, token: String) async throws -> GitHubPullRequestCollection
    func assignedPullRequests(login: String, token: String) async throws -> GitHubPullRequestCollection
    func hasAccessibleInstallation(token: String) async throws -> Bool
}

extension GitHubAPIProviding {
    func authenticatedUserForCredentialMigration(token: String) async throws -> GitHubAccount {
        try await authenticatedUser(token: token)
    }

    func authoredPullRequests(login _: String, token _: String) async throws -> GitHubPullRequestCollection {
        throw GitHubAPIError.malformedResponse
    }

    func assignedPullRequests(login _: String, token _: String) async throws -> GitHubPullRequestCollection {
        throw GitHubAPIError.malformedResponse
    }

    func hasAccessibleInstallation(token _: String) async throws -> Bool {
        true
    }
}

struct GitHubAPI: GitHubAPIProviding {
    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func authenticatedUser(token: String) async throws -> GitHubAccount {
        guard token.hasPrefix("ghu_") else {
            throw GitHubAPIError.legacyOAuthToken
        }
        return try await authenticatedUser(token: token, requiresRepositoryScope: true)
    }

    /// Identifies a legacy token owner so an upgrade never deletes another account's credential.
    /// The caller still treats a token without `repo` as disconnected and requires reauthorization.
    func authenticatedUserForCredentialMigration(token: String) async throws -> GitHubAccount {
        try await authenticatedUser(token: token, requiresRepositoryScope: false)
    }

    private func authenticatedUser(
        token: String,
        requiresRepositoryScope: Bool
    ) async throws -> GitHubAccount {
        guard let url = URL(string: "https://api.github.com/user") else {
            throw GitHubAPIError.malformedResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let data = try await perform(
            request,
            requiresRepositoryScope: requiresRepositoryScope
        )
        let response: UserResponse
        do {
            response = try JSONDecoder().decode(UserResponse.self, from: data)
        } catch {
            throw GitHubAPIError.malformedResponse
        }

        guard response.id > 0, !response.login.isEmpty else {
            throw GitHubAPIError.malformedResponse
        }

        return GitHubAccount(
            id: response.id,
            login: response.login,
            name: response.name,
            avatarURL: response.avatarURL.flatMap(URL.init(string:))
        )
    }

    /// Returns the 50 most recently active open pull requests authored by `login`.
    /// This intentionally bounded first page keeps the initial dashboard request predictable.
    func authoredPullRequests(login: String, token: String) async throws -> GitHubPullRequestCollection {
        try await pullRequests(
            login: login,
            token: token,
            qualifier: "author"
        )
    }

    /// Returns the 50 most recently active open pull requests awaiting review from `login`.
    /// Results are intentionally scoped to the credential and validated login supplied by the caller.
    func assignedPullRequests(login: String, token: String) async throws -> GitHubPullRequestCollection {
        try await pullRequests(
            login: login,
            token: token,
            qualifier: "review-requested"
        )
    }

    func hasAccessibleInstallation(token: String) async throws -> Bool {
        guard let url = URL(string: "https://api.github.com/user/installations?per_page=100") else {
            throw GitHubAPIError.malformedResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let data = try await perform(request, requiresRepositoryScope: false)
        do {
            let response = try JSONDecoder().decode(InstallationListResponse.self, from: data)
            return response.totalCount > 0 && response.installations.contains { installation in
                installation.permissions.pullRequests == "read" ||
                    installation.permissions.pullRequests == "write"
            }
        } catch {
            throw GitHubAPIError.malformedResponse
        }
    }

    private func pullRequests(
        login: String,
        token: String,
        qualifier: String
    ) async throws -> GitHubPullRequestCollection {
        guard isValidLogin(login),
              var components = URLComponents(string: "https://api.github.com/search/issues")
        else {
            throw GitHubAPIError.malformedResponse
        }

        components.queryItems = [
            URLQueryItem(name: "q", value: "is:pr is:open \(qualifier):\(login)"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: "50"),
        ]

        guard let url = components.url else {
            throw GitHubAPIError.malformedResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let data = try await perform(request)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let response: PullRequestSearchResponse
        do {
            response = try decoder.decode(PullRequestSearchResponse.self, from: data)
        } catch {
            throw GitHubAPIError.malformedResponse
        }

        guard !response.incompleteResults else {
            throw GitHubAPIError.incompleteResults
        }

        let pullRequests = try response.items.map { item in
            guard item.id > 0,
                  item.number > 0,
                  !item.title.isEmpty,
                  let repository = repositoryName(from: item.repositoryURL),
                  let url = canonicalGitHubURL(from: item.htmlURL)
            else {
                throw GitHubAPIError.malformedResponse
            }

            return GitHubPullRequest(
                id: item.id,
                repository: repository,
                number: item.number,
                title: item.title,
                isDraft: item.draft ?? false,
                updatedAt: item.updatedAt,
                url: url
            )
        }

        let boundedPullRequests = pullRequests
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(50)
            .map { $0 }
        guard response.totalCount >= boundedPullRequests.count else {
            throw GitHubAPIError.malformedResponse
        }
        return GitHubPullRequestCollection(
            pullRequests: boundedPullRequests,
            totalCount: response.totalCount
        )
    }

    private func perform(
        _ request: URLRequest,
        requiresRepositoryScope: Bool = true
    ) async throws -> Data {
        do {
            let (data, response) = try await httpClient.data(for: request)
            let usesGitHubAppUserToken = request.value(forHTTPHeaderField: "Authorization")?
                .hasPrefix("Bearer ghu_") == true
            guard !requiresRepositoryScope || usesGitHubAppUserToken ||
                    Self.oauthScopes(from: response).contains(GitHubOAuthConfiguration.repositoryScope)
            else {
                throw GitHubAPIError.insufficientOAuthScope
            }
            return data
        } catch HTTPClientError.unacceptableStatus(401) {
            throw GitHubAPIError.unauthorized
        } catch HTTPClientError.rateLimited,
                HTTPClientError.unacceptableStatus(429) {
            throw GitHubAPIError.rateLimited
        } catch HTTPClientError.unacceptableStatus(let statusCode) {
            throw GitHubAPIError.server(statusCode)
        } catch HTTPClientError.invalidResponse {
            throw GitHubAPIError.malformedResponse
        }
    }

    private static func oauthScopes(from response: HTTPURLResponse) -> Set<String> {
        Set(
            (response.value(forHTTPHeaderField: "X-OAuth-Scopes") ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private func isValidLogin(_ login: String) -> Bool {
        !login.isEmpty &&
            login.count <= 39 &&
            login.first != "-" &&
            login.last != "-" &&
            login.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber || character == "-")
            }
    }

    private func repositoryName(from repositoryURL: String) -> String? {
        guard let url = URL(string: repositoryURL),
              url.scheme == "https",
              url.host == "api.github.com"
        else {
            return nil
        }

        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 3,
              components[0] == "repos",
              !components[1].isEmpty,
              !components[2].isEmpty
        else {
            return nil
        }
        return "\(components[1])/\(components[2])"
    }

    private func canonicalGitHubURL(from urlString: String) -> URL? {
        guard let url = URL(string: urlString),
              url.scheme == "https",
              url.host == "github.com",
              url.pathComponents.count >= 5
        else {
            return nil
        }
        return url
    }

}

enum GitHubAPIError: Error, Equatable, Sendable {
    case accessDenied
    case expiredRequest
    case unauthorized
    case malformedResponse
    case incorrectClientCredentials
    case rateLimited
    case incompleteResults
    case insufficientOAuthScope
    case legacyOAuthToken
    case server(Int)
}

private struct InstallationListResponse: Decodable {
    let totalCount: Int
    let installations: [Installation]

    struct Installation: Decodable {
        let permissions: Permissions
    }

    struct Permissions: Decodable {
        let pullRequests: String?

        enum CodingKeys: String, CodingKey {
            case pullRequests = "pull_requests"
        }
    }

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case installations
    }
}

private struct UserResponse: Decodable {
    let id: Int
    let login: String
    let name: String?
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case login
        case name
        case avatarURL = "avatar_url"
    }
}

private struct PullRequestSearchResponse: Decodable {
    let totalCount: Int
    let incompleteResults: Bool
    let items: [PullRequestSearchItem]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case incompleteResults = "incomplete_results"
        case items
    }
}

private struct PullRequestSearchItem: Decodable {
    let id: Int
    let number: Int
    let title: String
    let draft: Bool?
    let updatedAt: Date
    let htmlURL: String
    let repositoryURL: String

    enum CodingKeys: String, CodingKey {
        case id
        case number
        case title
        case draft
        case updatedAt = "updated_at"
        case htmlURL = "html_url"
        case repositoryURL = "repository_url"
    }
}

enum GitHubOAuthError: Error, Equatable, LocalizedError, Sendable {
    case couldNotStartCallbackServer
    case missingConfiguration
    case secureRandomUnavailable
    case missingAuthorizationCode
    case stateMismatch
    case callbackTimedOut
    case malformedCallback
    case callbackTooLarge
    case accessDenied
    case authorizationFailed
    case invalidConfiguration
    case tokenExchangeFailed(Int)
    case invalidTokenResponse
    case authorizationRevocationFailed(Int)

    var errorDescription: String? {
        switch self {
        case .couldNotStartCallbackServer:
            "Buddy couldn't start the local GitHub sign-in callback."
        case .missingConfiguration:
            "GitHub browser sign-in is not configured in this build."
        case .secureRandomUnavailable:
            "Buddy couldn't create a secure GitHub sign-in request. Try again."
        case .missingAuthorizationCode:
            "GitHub sign-in did not return an authorization code."
        case .stateMismatch:
            "GitHub sign-in returned an unexpected security state. Start again."
        case .callbackTimedOut:
            "GitHub sign-in timed out. Start again and finish in the browser."
        case .malformedCallback:
            "GitHub returned an invalid sign-in callback."
        case .callbackTooLarge:
            "GitHub returned an oversized sign-in callback."
        case .accessDenied:
            "Authorization was denied. You can try again when you're ready."
        case .authorizationFailed:
            "GitHub couldn't complete sign-in. Try again."
        case .invalidConfiguration:
            "GitHub rejected Buddy's OAuth configuration."
        case let .tokenExchangeFailed(statusCode):
            "GitHub token exchange failed (HTTP \(statusCode))."
        case .invalidTokenResponse:
            "GitHub token exchange returned an invalid response."
        case let .authorizationRevocationFailed(statusCode):
            "GitHub authorization revocation failed (HTTP \(statusCode))."
        }
    }
}

typealias GitHubOAuthRandomByteGenerator = @Sendable (Int) throws -> Data

actor GitHubDeviceOAuthService: GitHubOAuthAuthorizing {
    private struct DeviceResponse: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let expiresIn: Int
        let interval: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case expiresIn = "expires_in"
            case interval
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let error: String?
        let interval: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case error
            case interval
        }
    }

    private let httpClient: any HTTPClient
    private let sleep: @Sendable (Duration) async throws -> Void
    private var activeAuthorizationIDs: Set<UUID> = []

    init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.httpClient = httpClient
        self.sleep = sleep
    }

    func beginAuthorization(
        configuration: GitHubOAuthConfiguration
    ) async throws -> GitHubBrowserAuthorization {
        guard !configuration.clientID.isEmpty else {
            throw GitHubOAuthError.missingConfiguration
        }
        let request = try formRequest(
            url: "https://github.com/login/device/code",
            fields: ["client_id": configuration.clientID]
        )
        let data = try await perform(request)
        let response: DeviceResponse
        do {
            response = try JSONDecoder().decode(DeviceResponse.self, from: data)
        } catch {
            throw GitHubOAuthError.invalidTokenResponse
        }
        guard !response.deviceCode.isEmpty,
              !response.userCode.isEmpty,
              response.expiresIn > 0,
              response.interval > 0,
              let verificationURI = URL(string: response.verificationURI),
              verificationURI.scheme == "https",
              verificationURI.host == "github.com"
        else {
            throw GitHubOAuthError.invalidTokenResponse
        }
        let authorization = GitHubBrowserAuthorization(
            id: UUID(),
            authorizationURL: verificationURI,
            deviceCode: response.deviceCode,
            userCode: response.userCode,
            expiresIn: response.expiresIn,
            interval: response.interval
        )
        activeAuthorizationIDs.insert(authorization.id)
        clientIDs[authorization.id] = configuration.clientID
        return authorization
    }

    func completeAuthorization(_ authorization: GitHubBrowserAuthorization) async throws -> String {
        guard let deviceCode = authorization.deviceCode,
              activeAuthorizationIDs.contains(authorization.id)
        else {
            throw CancellationError()
        }
        defer {
            activeAuthorizationIDs.remove(authorization.id)
            clientIDs.removeValue(forKey: authorization.id)
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(authorization.expiresIn)
        var interval = authorization.interval

        while clock.now < deadline {
            try Task.checkCancellation()
            try await sleep(.seconds(interval))
            guard activeAuthorizationIDs.contains(authorization.id) else {
                throw CancellationError()
            }
            let request = try formRequest(
                url: "https://github.com/login/oauth/access_token",
                fields: [
                    "client_id": "\(try configurationClientID(for: authorization))",
                    "device_code": deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ]
            )
            let data = try await perform(request)
            let response: TokenResponse
            do {
                response = try JSONDecoder().decode(TokenResponse.self, from: data)
            } catch {
                throw GitHubOAuthError.invalidTokenResponse
            }
            if let token = response.accessToken, token.hasPrefix("ghu_") {
                return token
            }
            switch response.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval = max(interval + 5, response.interval ?? 0)
            case "access_denied":
                throw GitHubOAuthError.accessDenied
            case "expired_token", "token_expired":
                throw GitHubOAuthError.callbackTimedOut
            case "incorrect_client_credentials", "incorrect_device_code", "device_flow_disabled":
                throw GitHubOAuthError.invalidConfiguration
            default:
                throw GitHubOAuthError.invalidTokenResponse
            }
        }
        throw GitHubOAuthError.callbackTimedOut
    }

    func cancelAuthorization(_ authorization: GitHubBrowserAuthorization) {
        activeAuthorizationIDs.remove(authorization.id)
        clientIDs.removeValue(forKey: authorization.id)
    }

    private var clientIDs: [UUID: String] = [:]

    private func configurationClientID(for authorization: GitHubBrowserAuthorization) throws -> String {
        guard let clientID = clientIDs[authorization.id] else {
            throw GitHubOAuthError.invalidConfiguration
        }
        return clientID
    }

    private func formRequest(url urlString: String, fields: [String: String]) throws -> URLRequest {
        guard let url = URL(string: urlString) else {
            throw GitHubOAuthError.invalidTokenResponse
        }
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else {
            throw GitHubOAuthError.invalidTokenResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data, _) = try await httpClient.data(for: request)
            return data
        } catch HTTPClientError.unacceptableStatus(let statusCode) {
            throw GitHubOAuthError.tokenExchangeFailed(statusCode)
        } catch HTTPClientError.invalidResponse {
            throw GitHubOAuthError.invalidTokenResponse
        }
    }
}

#if DEBUG
actor GitHubWebOAuthService: GitHubOAuthAuthorizing {
    struct PKCEPair: Equatable, Sendable {
        let verifier: String
        let challenge: String
    }

    static let authorizationEndpoint = URL(string: "https://github.com/login/oauth/authorize")!
    static let tokenEndpoint = URL(string: "https://github.com/login/oauth/access_token")!
    static let applicationEndpoint = URL(string: "https://api.github.com/applications")!
    static let callbackPath = "/callback"

    private struct Session: Sendable {
        let configuration: GitHubOAuthConfiguration
        let codeVerifier: String
        let redirectURI: String
        let callbackServer: GitHubOAuthCallbackServer
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case error
        }
    }

    private let httpClient: any HTTPClient
    private let callbackTimeout: Duration
    private let preferredCallbackPorts: [UInt16]
    private let randomBytes: GitHubOAuthRandomByteGenerator
    private var sessions: [UUID: Session] = [:]

    init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        callbackTimeout: Duration = .seconds(180),
        preferredCallbackPorts: [UInt16] = [0],
        randomBytes: GitHubOAuthRandomByteGenerator? = nil
    ) {
        self.httpClient = httpClient
        self.callbackTimeout = callbackTimeout
        self.preferredCallbackPorts = preferredCallbackPorts
        self.randomBytes = randomBytes ?? Self.systemRandomBytes
    }

    func beginAuthorization(
        configuration: GitHubOAuthConfiguration
    ) async throws -> GitHubBrowserAuthorization {
        let clientID = configuration.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = configuration.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            throw GitHubOAuthError.missingConfiguration
        }

        let state: String
        let pkce: PKCEPair
        do {
            state = try Self.base64URL(byteCount: 32, using: randomBytes)
            pkce = try Self.makePKCEPair(randomBytes: randomBytes)
        } catch {
            throw GitHubOAuthError.secureRandomUnavailable
        }

        let callbackServer = try await GitHubOAuthCallbackServer.start(
            preferredPorts: preferredCallbackPorts,
            expectedState: state,
            callbackPath: Self.callbackPath
        )
        let redirectURI = "http://127.0.0.1:\(callbackServer.port)\(Self.callbackPath)"
        let normalizedConfiguration = GitHubOAuthConfiguration(
            clientID: clientID,
            clientSecret: clientSecret
        )
        let id = UUID()
        let authorization = GitHubBrowserAuthorization(
            id: id,
            authorizationURL: Self.authorizationURL(
                clientID: clientID,
                redirectURI: redirectURI,
                state: state,
                codeChallenge: pkce.challenge
            )
        )
        sessions[id] = Session(
            configuration: normalizedConfiguration,
            codeVerifier: pkce.verifier,
            redirectURI: redirectURI,
            callbackServer: callbackServer
        )
        return authorization
    }

    func completeAuthorization(_ authorization: GitHubBrowserAuthorization) async throws -> String {
        guard let session = sessions[authorization.id] else {
            throw CancellationError()
        }
        defer {
            sessions.removeValue(forKey: authorization.id)?.callbackServer.cancel()
        }

        let callbackURL = try await session.callbackServer.waitForCallback(timeout: callbackTimeout)
        guard sessions[authorization.id] != nil else { throw CancellationError() }
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty
        else {
            throw GitHubOAuthError.missingAuthorizationCode
        }

        let request = Self.tokenRequest(
            configuration: session.configuration,
            code: code,
            redirectURI: session.redirectURI,
            codeVerifier: session.codeVerifier
        )
        let data: Data
        do {
            (data, _) = try await httpClient.data(for: request)
        } catch HTTPClientError.unacceptableStatus(let statusCode) {
            throw GitHubOAuthError.tokenExchangeFailed(statusCode)
        } catch HTTPClientError.rateLimited {
            throw GitHubOAuthError.tokenExchangeFailed(429)
        } catch HTTPClientError.invalidResponse {
            throw GitHubOAuthError.invalidTokenResponse
        }
        guard sessions[authorization.id] != nil else { throw CancellationError() }

        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw GitHubOAuthError.invalidTokenResponse
        }
        if let error = response.error {
            switch error {
            case "access_denied": throw GitHubOAuthError.accessDenied
            case "incorrect_client_credentials": throw GitHubOAuthError.invalidConfiguration
            case "bad_verification_code": throw GitHubOAuthError.authorizationFailed
            default: throw GitHubOAuthError.invalidTokenResponse
            }
        }
        guard let token = response.accessToken, !token.isEmpty else {
            throw GitHubOAuthError.invalidTokenResponse
        }
        return token
    }

    func cancelAuthorization(_ authorization: GitHubBrowserAuthorization) {
        sessions.removeValue(forKey: authorization.id)?.callbackServer.cancel()
    }

    func revokeAuthorization(
        token: String,
        configuration: GitHubOAuthConfiguration
    ) async throws {
        let request = try Self.revocationRequest(token: token, configuration: configuration)
        do {
            _ = try await httpClient.data(for: request)
        } catch HTTPClientError.unacceptableStatus(404) {
            // The token or grant is already gone, which satisfies disconnect.
        } catch HTTPClientError.unacceptableStatus(let statusCode) {
            throw GitHubOAuthError.authorizationRevocationFailed(statusCode)
        } catch HTTPClientError.rateLimited {
            throw GitHubOAuthError.authorizationRevocationFailed(429)
        } catch HTTPClientError.invalidResponse {
            throw GitHubOAuthError.authorizationRevocationFailed(0)
        }
    }

    static func revocationRequest(
        token: String,
        configuration: GitHubOAuthConfiguration
    ) throws -> URLRequest {
        let clientID = configuration.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = configuration.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientSecret.isEmpty, !token.isEmpty else {
            throw GitHubOAuthError.missingConfiguration
        }

        var request = URLRequest(url: applicationEndpoint
            .appendingPathComponent(clientID)
            .appendingPathComponent("grant"))
        request.httpMethod = "DELETE"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let basicCredential = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basicCredential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RevocationRequestBody(accessToken: token))
        return request
    }

    private struct RevocationRequestBody: Encodable {
        let accessToken: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }

    static func authorizationURL(
        clientID: String,
        redirectURI: String,
        state: String,
        codeChallenge: String
    ) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "scope", value: GitHubOAuthConfiguration.repositoryScope),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return components.url!
    }

    static func tokenRequest(
        configuration: GitHubOAuthConfiguration,
        code: String,
        redirectURI: String,
        codeVerifier: String
    ) -> URLRequest {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode([
            ("client_id", configuration.clientID),
            ("client_secret", configuration.clientSecret),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("code_verifier", codeVerifier),
        ])
        return request
    }

    static func makePKCEPair(randomBytes: GitHubOAuthRandomByteGenerator) throws -> PKCEPair {
        let verifier = try base64URL(byteCount: 64, using: randomBytes)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return PKCEPair(verifier: verifier, challenge: base64URL(Data(digest)))
    }

    private static func systemRandomBytes(byteCount: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw GitHubOAuthError.secureRandomUnavailable
        }
        return Data(bytes)
    }

    private static func base64URL(
        byteCount: Int,
        using generator: GitHubOAuthRandomByteGenerator
    ) throws -> String {
        let data = try generator(byteCount)
        guard data.count == byteCount else { throw GitHubOAuthError.secureRandomUnavailable }
        return base64URL(data)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = pairs.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}

enum GitHubOAuthCallbackParseResult: Equatable, Sendable {
    case incomplete
    case success(URL)
    case failure(GitHubOAuthError)
}

struct GitHubOAuthCallbackRequestParser: Sendable {
    let expectedState: String
    let callbackPath: String
    let port: UInt16
    let maximumRequestLength: Int

    func parse(_ data: Data) -> GitHubOAuthCallbackParseResult {
        guard data.count <= maximumRequestLength else { return .failure(.callbackTooLarge) }
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count == maximumRequestLength ? .failure(.callbackTooLarge) : .incomplete
        }
        guard let request = String(data: data[..<headerRange.upperBound], encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first
        else {
            return .failure(.malformedCallback)
        }
        let pieces = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard pieces.count == 3, pieces[0] == "GET", pieces[2].hasPrefix("HTTP/1.") else {
            return .failure(.malformedCallback)
        }
        let target = String(pieces[1])
        guard let url = URL(string: "http://127.0.0.1:\(port)\(target)"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path == callbackPath
        else {
            return .failure(.malformedCallback)
        }
        guard components.queryItems?.first(where: { $0.name == "state" })?.value == expectedState else {
            return .failure(.stateMismatch)
        }
        if let error = components.queryItems?.first(where: { $0.name == "error" })?.value {
            return error == "access_denied"
                ? .failure(.accessDenied)
                : .failure(.authorizationFailed)
        }
        guard components.queryItems?.first(where: { $0.name == "code" })?.value?.isEmpty == false else {
            return .failure(.missingAuthorizationCode)
        }
        return .success(url)
    }
}

final class GitHubOAuthCallbackServer: @unchecked Sendable {
    var port: UInt16 { lock.withLock { storedPort } }

    private let expectedState: String
    private let callbackPath: String
    private let maximumRequestLength: Int
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.hemsoft.Buddy.githubOAuthCallback")
    private let lock = NSLock()
    private var storedPort: UInt16
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallbackResult: Result<URL, Error>?
    private var callbackFinished = false

    private init(
        port: UInt16,
        expectedState: String,
        callbackPath: String,
        maximumRequestLength: Int
    ) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw GitHubOAuthError.couldNotStartCallbackServer
        }
        self.storedPort = port
        self.expectedState = expectedState
        self.callbackPath = callbackPath
        self.maximumRequestLength = maximumRequestLength
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.stateUpdateHandler = { [weak self] state in self?.handle(state) }
    }

    static func start(
        preferredPorts: [UInt16],
        expectedState: String,
        callbackPath: String,
        maximumRequestLength: Int = 8192
    ) async throws -> GitHubOAuthCallbackServer {
        var lastError: Error = GitHubOAuthError.couldNotStartCallbackServer
        for port in preferredPorts {
            do {
                let server = try GitHubOAuthCallbackServer(
                    port: port,
                    expectedState: expectedState,
                    callbackPath: callbackPath,
                    maximumRequestLength: maximumRequestLength
                )
                try await server.startListening()
                return server
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func waitForCallback(timeout: Duration) async throws -> URL {
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.finishCallback(.failure(GitHubOAuthError.callbackTimedOut))
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let pendingCallbackResult {
                    self.pendingCallbackResult = nil
                    lock.unlock()
                    continuation.resume(with: pendingCallbackResult)
                } else {
                    callbackContinuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.finishCallback(.failure(CancellationError()))
        }
    }

    func cancel() {
        listener.cancel()
        finishCallback(.failure(CancellationError()))
    }

    private func startListening() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            readyContinuation = continuation
            lock.unlock()
            listener.start(queue: queue)
        }
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let boundPort = listener.port?.rawValue {
                lock.withLock { storedPort = boundPort }
            }
            finishReady(.success(()))
        case .failed(let error):
            finishReady(.failure(error))
            finishCallback(.failure(error))
        case .cancelled:
            finishReady(.failure(GitHubOAuthError.couldNotStartCallbackServer))
        default:
            break
        }
    }

    private func finishReady(_ result: Result<Void, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { readyContinuation = nil }
            return readyContinuation
        }
        continuation?.resume(with: result)
    }

    private func finishCallback(_ result: Result<URL, Error>) {
        lock.lock()
        guard !callbackFinished else {
            lock.unlock()
            return
        }
        callbackFinished = true
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pendingCallbackResult = result
            lock.unlock()
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(from: connection, accumulated: Data())
    }

    private func receive(from connection: NWConnection, accumulated: Data) {
        let remaining = maximumRequestLength - accumulated.count
        guard remaining > 0 else {
            complete(connection, result: .failure(.callbackTooLarge))
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var requestData = accumulated
            if let data { requestData.append(data) }
            let parser = GitHubOAuthCallbackRequestParser(
                expectedState: expectedState,
                callbackPath: callbackPath,
                port: port,
                maximumRequestLength: maximumRequestLength
            )
            switch parser.parse(requestData) {
            case .incomplete where error == nil && !complete:
                receive(from: connection, accumulated: requestData)
            case .incomplete:
                self.complete(connection, result: .failure(.malformedCallback))
            case let .success(url):
                self.complete(connection, result: .success(url))
            case let .failure(error):
                self.complete(connection, result: .failure(error))
            }
        }
    }

    private func complete(_ connection: NWConnection, result: Result<URL, GitHubOAuthError>) {
        let success: Bool
        let status: String
        switch result {
        case .success:
            success = true
            status = "HTTP/1.1 200 OK"
        case .failure(.callbackTooLarge):
            success = false
            status = "HTTP/1.1 413 Payload Too Large"
        case .failure:
            success = false
            status = "HTTP/1.1 400 Bad Request"
        }
        let body = success
            ? """
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>body{font-family:-apple-system;padding:2rem;line-height:1.45}</style>
            <h1>GitHub returned to Buddy</h1>
            <p>Tap Done to return to Buddy and finish checking this account.</p>
            """
            : """
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>body{font-family:-apple-system;padding:2rem;line-height:1.45}</style>
            <h1>GitHub sign-in failed</h1>
            <p>Tap Done to return to Buddy, then try again.</p>
            """
        let response = "\(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(Data(body.utf8).count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        switch result {
        case let .success(url):
            finishCallback(.success(url))
        case let .failure(error) where error == .accessDenied
            || error == .authorizationFailed
            || error == .missingAuthorizationCode:
            finishCallback(.failure(error))
        case .failure:
            // A malformed or unrelated request must not consume the one valid
            // OAuth callback. Respond to that connection and keep listening.
            break
        }
    }
}
#endif
