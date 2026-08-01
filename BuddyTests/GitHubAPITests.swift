import XCTest
@testable import Buddy

final class GitHubAPITests: XCTestCase {
    func testRequestsDeviceAuthorizationWithoutSecretOrScopes() async throws {
        let httpClient = MockHTTPClient(responses: [
            .success(
                #"{"device_code":"device-secret","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#,
                statusCode: 200
            ),
        ])
        let api = GitHubAPI(httpClient: httpClient)

        let authorization = try await api.requestDeviceAuthorization(clientID: "client-id")

        XCTAssertEqual(authorization.userCode, "ABCD-EFGH")
        XCTAssertEqual(authorization.interval, 5)

        let capturedRequest = await httpClient.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://github.com/login/device/code")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(body, "client_id=client-id")
        XCTAssertFalse(body.contains("secret"))
        XCTAssertFalse(body.contains("scope"))
    }

    func testPollHandlesPendingSlowDownAndAuthorization() async throws {
        let httpClient = MockHTTPClient(responses: [
            .success(#"{"error":"authorization_pending"}"#, statusCode: 200),
            .success(#"{"error":"slow_down","interval":12}"#, statusCode: 200),
            .success(#"{"access_token":"token-value","token_type":"bearer"}"#, statusCode: 200),
        ])
        let api = GitHubAPI(httpClient: httpClient)

        let pending = try await api.pollForAccessToken(clientID: "client-id", deviceCode: "device-code")
        let slowDown = try await api.pollForAccessToken(clientID: "client-id", deviceCode: "device-code")
        let authorized = try await api.pollForAccessToken(clientID: "client-id", deviceCode: "device-code")

        XCTAssertEqual(pending, .pending)
        XCTAssertEqual(slowDown, .slowDown(interval: 12))
        XCTAssertEqual(authorized, .authorized(token: "token-value"))
    }

    func testPollReportsDeniedExpiredAndMalformedResponses() async throws {
        let cases: [(String, GitHubAPIError)] = [
            (#"{"error":"access_denied"}"#, .accessDenied),
            (#"{"error":"expired_token"}"#, .expiredRequest),
            (#"{"unexpected":true}"#, .malformedResponse),
        ]

        for (body, expectedError) in cases {
            let httpClient = MockHTTPClient(responses: [.success(body, statusCode: 200)])
            let api = GitHubAPI(httpClient: httpClient)

            do {
                _ = try await api.pollForAccessToken(clientID: "client-id", deviceCode: "device-code")
                XCTFail("Expected \(expectedError)")
            } catch let error as GitHubAPIError {
                XCTAssertEqual(error, expectedError)
            }
        }
    }

    func testDeviceFlowDisabledResponseIsReportedClearly() async throws {
        let httpClient = MockHTTPClient(responses: [
            .success(#"{"error":"device_flow_disabled"}"#, statusCode: 200),
        ])

        do {
            _ = try await GitHubAPI(httpClient: httpClient).requestDeviceAuthorization(clientID: "client-id")
            XCTFail("Expected disabled device flow")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .deviceFlowDisabled)
        }
    }

    func testAuthenticatedUserUsesBearerTokenAndMapsUnauthorized() async throws {
        let validClient = MockHTTPClient(responses: [
            .success(#"{"id":42,"login":"octocat","name":"The Octocat","avatar_url":"https://avatars.githubusercontent.com/u/42"}"#, statusCode: 200),
        ])
        let api = GitHubAPI(httpClient: validClient)

        let account = try await api.authenticatedUser(token: "sensitive-token")

        XCTAssertEqual(account.id, 42)
        XCTAssertEqual(account.login, "octocat")
        let capturedRequest = await validClient.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sensitive-token")

        let unauthorizedClient = MockHTTPClient(responses: [.success("{}", statusCode: 401)])
        do {
            _ = try await GitHubAPI(httpClient: unauthorizedClient).authenticatedUser(token: "revoked")
            XCTFail("Expected unauthorized")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testNetworkFailureRemainsRecoverable() async throws {
        let httpClient = MockHTTPClient(responses: [.networkFailure])

        do {
            _ = try await GitHubAPI(httpClient: httpClient).authenticatedUser(token: "token")
            XCTFail("Expected network failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
    }
}

private actor MockHTTPClient: HTTPClient {
    enum Response: Sendable {
        case success(String, statusCode: Int)
        case networkFailure
    }

    private var responses: [Response]
    private var capturedRequests: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        capturedRequests.append(request)
        let response = responses.removeFirst()

        switch response {
        case let .success(body, statusCode):
            let httpResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            guard 200..<300 ~= statusCode else {
                throw HTTPClientError.unacceptableStatus(statusCode)
            }
            return (Data(body.utf8), httpResponse)
        case .networkFailure:
            throw URLError(.notConnectedToInternet)
        }
    }

    func lastRequest() -> URLRequest? {
        capturedRequests.last
    }
}
