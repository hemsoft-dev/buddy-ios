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

    func testAuthoredPullRequestsUsesVersionedEncodedBoundedSearchAndSortsResults() async throws {
        let httpClient = MockHTTPClient(responses: [
            .success(
                #"{"total_count":72,"items":[{"id":1,"number":7,"title":"Older","draft":false,"updated_at":"2026-07-31T12:00:00Z","html_url":"https://github.com/HemSoft/Buddy/pull/7","repository_url":"https://api.github.com/repos/HemSoft/Buddy"},{"id":2,"number":9,"title":"Newer","draft":true,"updated_at":"2026-08-01T12:00:00Z","html_url":"https://github.com/HemSoft/Other/pull/9","repository_url":"https://api.github.com/repos/HemSoft/Other"}]}"#,
                statusCode: 200
            ),
        ])
        let api = GitHubAPI(httpClient: httpClient)

        let collection = try await api.authoredPullRequests(login: "franz-test", token: "secret-token")
        let pullRequests = collection.pullRequests

        XCTAssertEqual(collection.totalCount, 72)
        XCTAssertEqual(pullRequests.map(\.id), [2, 1])
        XCTAssertEqual(pullRequests.first?.repository, "HemSoft/Other")
        XCTAssertEqual(pullRequests.first?.number, 9)
        XCTAssertEqual(pullRequests.first?.isDraft, true)

        let capturedRequest = await httpClient.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "api.github.com")
        XCTAssertEqual(components.path, "/search/issues")
        XCTAssertEqual(query["q"]!, "is:pr is:open author:franz-test")
        XCTAssertEqual(query["sort"]!, "updated")
        XCTAssertEqual(query["order"]!, "desc")
        XCTAssertEqual(query["per_page"]!, "50")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
    }

    func testAuthoredPullRequestsSupportsEmptyResults() async throws {
        let httpClient = MockHTTPClient(responses: [.success(#"{"total_count":0,"items":[]}"#, statusCode: 200)])

        let collection = try await GitHubAPI(httpClient: httpClient)
            .authoredPullRequests(login: "octocat", token: "token")

        XCTAssertEqual(collection, GitHubPullRequestCollection(pullRequests: [], totalCount: 0))
    }

    func testAuthoredPullRequestsRejectsUnsafeLoginAndMalformedItems() async throws {
        let unusedClient = MockHTTPClient(responses: [])
        do {
            _ = try await GitHubAPI(httpClient: unusedClient)
                .authoredPullRequests(login: "octocat is:closed", token: "token")
            XCTFail("Expected unsafe login to be rejected")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .malformedResponse)
        }

        let malformedClient = MockHTTPClient(responses: [
            .success(
                #"{"total_count":1,"items":[{"id":1,"number":1,"title":"PR","updated_at":"2026-08-01T12:00:00Z","html_url":"http://example.com/pr/1","repository_url":"https://api.github.com/repos/HemSoft/Buddy"}]}"#,
                statusCode: 200
            ),
        ])
        do {
            _ = try await GitHubAPI(httpClient: malformedClient)
                .authoredPullRequests(login: "octocat", token: "token")
            XCTFail("Expected malformed URL to be rejected")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .malformedResponse)
        }
    }

    func testAuthoredPullRequestsMapsRateLimitServerAndNetworkFailures() async throws {
        let cases: [(MockHTTPClient.Response, ErrorExpectation)] = [
            (.rateLimited, .api(.rateLimited)),
            (.success("{}", statusCode: 429), .api(.rateLimited)),
            (.success("{}", statusCode: 403), .api(.server(403))),
            (.success("{}", statusCode: 503), .api(.server(503))),
            (.networkFailure, .network),
        ]

        for (response, expectation) in cases {
            do {
                _ = try await GitHubAPI(httpClient: MockHTTPClient(responses: [response]))
                    .authoredPullRequests(login: "octocat", token: "token")
                XCTFail("Expected request to fail")
            } catch let error as GitHubAPIError {
                guard case let .api(expected) = expectation else {
                    return XCTFail("Expected network error")
                }
                XCTAssertEqual(error, expected)
            } catch let error as URLError {
                XCTAssertEqual(expectation, .network)
                XCTAssertEqual(error.code, .notConnectedToInternet)
            }
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

private enum ErrorExpectation: Equatable {
    case api(GitHubAPIError)
    case network
}

private actor MockHTTPClient: HTTPClient {
    enum Response: Sendable {
        case success(String, statusCode: Int)
        case networkFailure
        case rateLimited
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
        case .rateLimited:
            throw HTTPClientError.rateLimited
        }
    }

    func lastRequest() -> URLRequest? {
        capturedRequests.last
    }
}
