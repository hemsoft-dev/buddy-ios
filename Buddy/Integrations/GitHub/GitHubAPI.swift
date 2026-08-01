import Foundation

struct GitHubDeviceAuthorization: Equatable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let expiresIn: Int
    let interval: Int
}

struct GitHubAccount: Equatable, Sendable {
    let id: Int
    let login: String
    let name: String?
    let avatarURL: URL?
}

enum GitHubTokenPollResult: Equatable, Sendable {
    case pending
    case slowDown(interval: Int?)
    case authorized(token: String)
}

protocol GitHubAPIProviding: Sendable {
    func requestDeviceAuthorization(clientID: String) async throws -> GitHubDeviceAuthorization
    func pollForAccessToken(clientID: String, deviceCode: String) async throws -> GitHubTokenPollResult
    func authenticatedUser(token: String) async throws -> GitHubAccount
}

struct GitHubAPI: GitHubAPIProviding {
    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func requestDeviceAuthorization(clientID: String) async throws -> GitHubDeviceAuthorization {
        let request = try formRequest(
            url: "https://github.com/login/device/code",
            fields: ["client_id": clientID]
        )
        let data = try await perform(request)

        if let errorResponse = try? JSONDecoder().decode(TokenResponse.self, from: data),
           let error = errorResponse.error {
            throw mapOAuthError(error)
        }

        let response: DeviceAuthorizationResponse
        do {
            response = try JSONDecoder().decode(DeviceAuthorizationResponse.self, from: data)
        } catch {
            throw GitHubAPIError.malformedResponse
        }

        guard !response.deviceCode.isEmpty,
              !response.userCode.isEmpty,
              response.expiresIn > 0,
              response.interval > 0,
              let verificationURI = URL(string: response.verificationURI),
              verificationURI.scheme == "https",
              verificationURI.host == "github.com"
        else {
            throw GitHubAPIError.malformedResponse
        }

        return GitHubDeviceAuthorization(
            deviceCode: response.deviceCode,
            userCode: response.userCode,
            verificationURI: verificationURI,
            expiresIn: response.expiresIn,
            interval: response.interval
        )
    }

    func pollForAccessToken(clientID: String, deviceCode: String) async throws -> GitHubTokenPollResult {
        let request = try formRequest(
            url: "https://github.com/login/oauth/access_token",
            fields: [
                "client_id": clientID,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ]
        )
        let data = try await perform(request)

        let response: TokenResponse
        do {
            response = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw GitHubAPIError.malformedResponse
        }

        if let token = response.accessToken, !token.isEmpty {
            return .authorized(token: token)
        }

        switch response.error {
        case "authorization_pending":
            return .pending
        case "slow_down":
            return .slowDown(interval: response.interval)
        case "expired_token", "token_expired":
            throw GitHubAPIError.expiredRequest
        case "access_denied":
            throw GitHubAPIError.accessDenied
        case "device_flow_disabled":
            throw GitHubAPIError.deviceFlowDisabled
        case "incorrect_client_credentials", "incorrect_device_code":
            throw GitHubAPIError.incorrectClientCredentials
        default:
            throw GitHubAPIError.malformedResponse
        }
    }

    func authenticatedUser(token: String) async throws -> GitHubAccount {
        guard let url = URL(string: "https://api.github.com/user") else {
            throw GitHubAPIError.malformedResponse
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let data = try await perform(request)
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

    private func formRequest(url urlString: String, fields: [String: String]) throws -> URLRequest {
        guard let url = URL(string: urlString) else {
            throw GitHubAPIError.malformedResponse
        }

        var components = URLComponents()
        components.queryItems = fields
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let body = components.percentEncodedQuery?.data(using: .utf8) else {
            throw GitHubAPIError.malformedResponse
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
        } catch HTTPClientError.unacceptableStatus(401) {
            throw GitHubAPIError.unauthorized
        } catch HTTPClientError.unacceptableStatus(let statusCode) {
            throw GitHubAPIError.server(statusCode)
        } catch HTTPClientError.invalidResponse {
            throw GitHubAPIError.malformedResponse
        }
    }

    private func mapOAuthError(_ error: String) -> GitHubAPIError {
        switch error {
        case "expired_token", "token_expired": .expiredRequest
        case "access_denied": .accessDenied
        case "device_flow_disabled": .deviceFlowDisabled
        case "incorrect_client_credentials", "incorrect_device_code": .incorrectClientCredentials
        default: .malformedResponse
        }
    }
}

enum GitHubAPIError: Error, Equatable, Sendable {
    case accessDenied
    case expiredRequest
    case unauthorized
    case malformedResponse
    case deviceFlowDisabled
    case incorrectClientCredentials
    case server(Int)
}

private struct DeviceAuthorizationResponse: Decodable {
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
