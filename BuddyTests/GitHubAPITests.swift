import XCTest
@testable import Buddy

final class GitHubAPITests: XCTestCase {
    func testBrowserAuthorizationURLUsesPKCEStateExactLoopbackRedirectAndAccountPicker() throws {
        let redirectURI = "http://127.0.0.1:49152/callback"
        let url = GitHubWebOAuthService.authorizationURL(
            clientID: "buddy-client",
            redirectURI: redirectURI,
            state: "random-state",
            codeChallenge: "challenge"
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/login/oauth/authorize")
        XCTAssertEqual(query["response_type"]!, "code")
        XCTAssertEqual(query["client_id"]!, "buddy-client")
        XCTAssertEqual(query["redirect_uri"]!, redirectURI)
        XCTAssertEqual(query["state"]!, "random-state")
        XCTAssertEqual(query["code_challenge"]!, "challenge")
        XCTAssertEqual(query["code_challenge_method"]!, "S256")
        XCTAssertEqual(query["scope"]!, "repo read:org")
        XCTAssertEqual(query["prompt"]!, "select_account")
    }

    func testPKCEUsesIndependentSecureMaterialAndReportsRandomnessFailure() async throws {
        let pair = try GitHubWebOAuthService.makePKCEPair { count in
            Data(repeating: 7, count: count)
        }
        XCTAssertGreaterThanOrEqual(pair.verifier.count, 43)
        XCTAssertNotEqual(pair.verifier, pair.challenge)

        let service = GitHubWebOAuthService(randomBytes: { _ in throw TestOAuthError.unavailable })
        do {
            _ = try await service.beginAuthorization(
                configuration: GitHubOAuthConfiguration(clientID: "client", clientSecret: "public-secret")
            )
            XCTFail("Expected secure randomness failure")
        } catch let error as GitHubOAuthError {
            XCTAssertEqual(error, .secureRandomUnavailable)
        }
    }

    func testTokenExchangeBodyReusesRedirectAndVerifier() throws {
        let request = GitHubWebOAuthService.tokenRequest(
            configuration: GitHubOAuthConfiguration(clientID: "client id", clientSecret: "public/secret"),
            code: "code+value",
            redirectURI: "http://127.0.0.1:49152/callback",
            codeVerifier: "verifier_value"
        )
        XCTAssertEqual(request.url, GitHubWebOAuthService.tokenEndpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(body.contains("client_id=client%20id"))
        XCTAssertTrue(body.contains("client_secret=public%2Fsecret"))
        XCTAssertTrue(body.contains("code=code%2Bvalue"))
        XCTAssertTrue(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2Fcallback"))
        XCTAssertTrue(body.contains("code_verifier=verifier_value"))
    }

    func testCallbackParserHandlesFragmentedMalformedOversizedStateAndCode() throws {
        let parser = GitHubOAuthCallbackRequestParser(
            expectedState: "expected",
            callbackPath: "/callback",
            port: 49152,
            maximumRequestLength: 128
        )
        let firstFragment = Data("GET /callback?code=abc&state=expected HTTP/1.1\r\nHost:".utf8)
        XCTAssertEqual(parser.parse(firstFragment), .incomplete)
        var complete = firstFragment
        complete.append(Data(" 127.0.0.1\r\n\r\n".utf8))
        guard case let .success(url) = parser.parse(complete) else {
            return XCTFail("Expected a valid fragmented request")
        }
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.path, "/callback")

        XCTAssertEqual(parser.parse(Data("POST /callback HTTP/1.1\r\n\r\n".utf8)), .failure(.malformedCallback))
        XCTAssertEqual(
            parser.parse(Data("GET /wrong?code=abc&state=expected HTTP/1.1\r\n\r\n".utf8)),
            .failure(.malformedCallback)
        )
        XCTAssertEqual(
            parser.parse(Data("GET /callback?code=abc&state=wrong HTTP/1.1\r\n\r\n".utf8)),
            .failure(.stateMismatch)
        )
        XCTAssertEqual(
            parser.parse(Data("GET /callback?state=expected HTTP/1.1\r\n\r\n".utf8)),
            .failure(.missingAuthorizationCode)
        )
        XCTAssertEqual(
            parser.parse(Data("GET /callback?error=access_denied&state=expected HTTP/1.1\r\n\r\n".utf8)),
            .failure(.accessDenied)
        )
        XCTAssertEqual(
            parser.parse(Data("GET /callback?error=server_error&state=expected HTTP/1.1\r\n\r\n".utf8)),
            .failure(.authorizationFailed)
        )
        XCTAssertEqual(parser.parse(Data(repeating: 65, count: 129)), .failure(.callbackTooLarge))
    }

    func testBrowserAuthorizationCompletesLoopbackCallbackAndExchangesCode() async throws {
        let httpClient = MockHTTPClient(responses: [
            .success(#"{"access_token":"browser-token"}"#, statusCode: 200),
        ])
        let service = GitHubWebOAuthService(
            httpClient: httpClient,
            callbackTimeout: .seconds(15),
            randomBytes: { count in Data(repeating: UInt8(count), count: count) }
        )
        let authorization = try await service.beginAuthorization(
            configuration: GitHubOAuthConfiguration(
                clientID: "buddy-client",
                clientSecret: "public-secret"
            )
        )
        let authorizationComponents = try XCTUnwrap(
            URLComponents(url: authorization.authorizationURL, resolvingAgainstBaseURL: false)
        )
        let authorizationQuery = Dictionary(
            uniqueKeysWithValues: (authorizationComponents.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        let redirectURI = try XCTUnwrap(authorizationQuery["redirect_uri"])
        let state = try XCTUnwrap(authorizationQuery["state"])
        var callbackComponents = try XCTUnwrap(URLComponents(string: redirectURI))
        callbackComponents.queryItems = [
            URLQueryItem(name: "code", value: "one-time-code"),
            URLQueryItem(name: "state", value: state),
        ]
        let callbackURL = try XCTUnwrap(callbackComponents.url)

        let completion = Task { try await service.completeAuthorization(authorization) }
        var unrelatedComponents = callbackComponents
        unrelatedComponents.path = "/unrelated"
        let unrelatedURL = try XCTUnwrap(unrelatedComponents.url)
        let (_, unrelatedResponse) = try await URLSession.shared.data(from: unrelatedURL)
        XCTAssertEqual((unrelatedResponse as? HTTPURLResponse)?.statusCode, 400)
        let (_, callbackResponse) = try await URLSession.shared.data(from: callbackURL)
        XCTAssertEqual((callbackResponse as? HTTPURLResponse)?.statusCode, 200)
        let token = try await completion.value

        XCTAssertEqual(token, "browser-token")
        let capturedTokenRequest = await httpClient.lastRequest()
        let tokenRequest = try XCTUnwrap(capturedTokenRequest)
        let body = try XCTUnwrap(tokenRequest.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        var bodyComponents = URLComponents()
        bodyComponents.query = body
        let tokenQuery = Dictionary(
            uniqueKeysWithValues: (bodyComponents.queryItems ?? []).compactMap { item in
                item.value?.removingPercentEncoding.map { (item.name, $0) }
            }
        )
        XCTAssertEqual(tokenQuery["code"], "one-time-code")
        XCTAssertEqual(tokenQuery["redirect_uri"], redirectURI)
        XCTAssertEqual(tokenQuery["client_id"], "buddy-client")
        XCTAssertEqual(tokenQuery["client_secret"], "public-secret")
        XCTAssertFalse(try XCTUnwrap(tokenQuery["code_verifier"]).isEmpty)
    }

    func testBrowserAuthorizationTimesOut() async throws {
        let configuration = GitHubOAuthConfiguration(clientID: "client", clientSecret: "public-secret")
        let timeoutService = GitHubWebOAuthService(
            callbackTimeout: .milliseconds(10),
            randomBytes: { count in Data(repeating: UInt8(count), count: count) }
        )
        let timedAuthorization = try await timeoutService.beginAuthorization(configuration: configuration)
        do {
            _ = try await timeoutService.completeAuthorization(timedAuthorization)
            XCTFail("Expected callback timeout")
        } catch let error as GitHubOAuthError {
            XCTAssertEqual(error, .callbackTimedOut)
        }
    }

    func testBrowserAuthorizationCancellationStopsPendingCallback() async throws {
        let configuration = GitHubOAuthConfiguration(clientID: "client", clientSecret: "public-secret")
        let cancellationService = GitHubWebOAuthService(
            callbackTimeout: .seconds(2),
            randomBytes: { count in Data(repeating: UInt8(count), count: count) }
        )
        let canceledAuthorization = try await cancellationService.beginAuthorization(configuration: configuration)
        let completion = Task { try await cancellationService.completeAuthorization(canceledAuthorization) }
        await Task.yield()
        completion.cancel()
        do {
            _ = try await completion.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testBrowserAuthorizationReportsTerminalOAuthErrorCallbacks() async throws {
        for (callbackError, expectedError) in [
            ("access_denied", GitHubOAuthError.accessDenied),
            ("server_error", GitHubOAuthError.authorizationFailed),
        ] {
            let service = GitHubWebOAuthService(
                callbackTimeout: .seconds(15),
                randomBytes: { count in Data(repeating: UInt8(count), count: count) }
            )
            let authorization = try await service.beginAuthorization(
                configuration: GitHubOAuthConfiguration(clientID: "client", clientSecret: "public-secret")
            )
            let authorizationComponents = try XCTUnwrap(
                URLComponents(url: authorization.authorizationURL, resolvingAgainstBaseURL: false)
            )
            let query = Dictionary(
                uniqueKeysWithValues: (authorizationComponents.queryItems ?? []).compactMap { item in
                    item.value.map { (item.name, $0) }
                }
            )
            var callbackComponents = try XCTUnwrap(
                URLComponents(string: try XCTUnwrap(query["redirect_uri"]))
            )
            callbackComponents.queryItems = [
                URLQueryItem(name: "error", value: callbackError),
                URLQueryItem(name: "state", value: try XCTUnwrap(query["state"])),
            ]

            let completion = Task { try await service.completeAuthorization(authorization) }
            let (_, callbackResponse) = try await URLSession.shared.data(
                from: try XCTUnwrap(callbackComponents.url)
            )
            XCTAssertEqual((callbackResponse as? HTTPURLResponse)?.statusCode, 400)
            do {
                _ = try await completion.value
                XCTFail("Expected terminal OAuth callback error")
            } catch let error as GitHubOAuthError {
                XCTAssertEqual(error, expectedError)
            }
        }
    }

    func testBrowserAuthorizationReportsMissingCodeAsTerminalCallbackError() async throws {
        let service = GitHubWebOAuthService(
            callbackTimeout: .seconds(15),
            randomBytes: { count in Data(repeating: UInt8(count), count: count) }
        )
        let authorization = try await service.beginAuthorization(
            configuration: GitHubOAuthConfiguration(clientID: "client", clientSecret: "public-secret")
        )
        let authorizationComponents = try XCTUnwrap(
            URLComponents(url: authorization.authorizationURL, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (authorizationComponents.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        var callbackComponents = try XCTUnwrap(
            URLComponents(string: try XCTUnwrap(query["redirect_uri"]))
        )
        callbackComponents.queryItems = [
            URLQueryItem(name: "state", value: try XCTUnwrap(query["state"])),
        ]

        let completion = Task { try await service.completeAuthorization(authorization) }
        let (_, callbackResponse) = try await URLSession.shared.data(
            from: try XCTUnwrap(callbackComponents.url)
        )
        XCTAssertEqual((callbackResponse as? HTTPURLResponse)?.statusCode, 400)
        do {
            _ = try await completion.value
            XCTFail("Expected a missing authorization code failure")
        } catch let error as GitHubOAuthError {
            XCTAssertEqual(error, .missingAuthorizationCode)
        }
    }

    func testTokenExchangeTreatsBadVerificationCodeAsRetryableAuthorizationFailure() async throws {
        let httpClient = MockHTTPClient(responses: [
            .success(#"{"error":"bad_verification_code"}"#, statusCode: 200),
        ])
        let service = GitHubWebOAuthService(
            httpClient: httpClient,
            callbackTimeout: .seconds(15),
            randomBytes: { count in Data(repeating: UInt8(count), count: count) }
        )
        let authorization = try await service.beginAuthorization(
            configuration: GitHubOAuthConfiguration(clientID: "client", clientSecret: "public-secret")
        )
        let authorizationComponents = try XCTUnwrap(
            URLComponents(url: authorization.authorizationURL, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (authorizationComponents.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        var callbackComponents = try XCTUnwrap(
            URLComponents(string: try XCTUnwrap(query["redirect_uri"]))
        )
        callbackComponents.queryItems = [
            URLQueryItem(name: "code", value: "expired-code"),
            URLQueryItem(name: "state", value: try XCTUnwrap(query["state"])),
        ]

        let completion = Task { try await service.completeAuthorization(authorization) }
        let (_, callbackResponse) = try await URLSession.shared.data(
            from: try XCTUnwrap(callbackComponents.url)
        )
        XCTAssertEqual((callbackResponse as? HTTPURLResponse)?.statusCode, 200)
        do {
            _ = try await completion.value
            XCTFail("Expected a rejected authorization code")
        } catch let error as GitHubOAuthError {
            XCTAssertEqual(error, .authorizationFailed)
        }
    }

    func testAuthorizationRevocationDeletesOnlyTheSuppliedApplicationToken() async throws {
        let httpClient = MockHTTPClient(responses: [.success("", statusCode: 204)])
        let service = GitHubWebOAuthService(httpClient: httpClient)
        let configuration = GitHubOAuthConfiguration(
            clientID: "shared-client",
            clientSecret: "public-secret"
        )

        try await service.revokeAuthorization(token: "buddy-token", configuration: configuration)

        let capturedRequest = await httpClient.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/applications/shared-client/token")
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Basic " + Data("shared-client:public-secret".utf8).base64EncodedString()
        )
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, ["access_token": "buddy-token"])
    }

    func testAuthenticatedUserUsesBearerTokenAndMapsUnauthorized() async throws {
        let validClient = MockHTTPClient(responses: [
            .successWithScopes(
                #"{"id":42,"login":"octocat","name":"The Octocat","avatar_url":"https://avatars.githubusercontent.com/u/42"}"#,
                statusCode: 200,
                scopes: "user, repo"
            ),
        ])
        let api = GitHubAPI(httpClient: validClient)

        let account = try await api.authenticatedUser(token: "sensitive-token")

        XCTAssertEqual(account.id, 42)
        XCTAssertEqual(account.login, "octocat")
        let capturedRequest = await validClient.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sensitive-token")

        let unauthorizedClient = MockHTTPClient(responses: [.success("{}", statusCode: 401)])
        do {
            _ = try await GitHubAPI(httpClient: unauthorizedClient).authenticatedUser(token: "revoked")
            XCTFail("Expected unauthorized")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testAuthenticatedUserRejectsTokensWithoutPrivateRepositoryScope() async throws {
        let client = MockHTTPClient(responses: [
            .successWithScopes(
                #"{"id":42,"login":"octocat"}"#,
                statusCode: 200,
                scopes: "read:user"
            ),
        ])

        do {
            _ = try await GitHubAPI(httpClient: client).authenticatedUser(token: "public-only-token")
            XCTFail("Expected missing repository scope")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .insufficientOAuthScope)
        }
    }

    func testCredentialMigrationCanIdentifyPublicOnlyTokenOwner() async throws {
        let client = MockHTTPClient(responses: [
            .successWithScopes(
                #"{"id":42,"login":"octocat"}"#,
                statusCode: 200,
                scopes: "read:user"
            ),
        ])

        let account = try await GitHubAPI(httpClient: client)
            .authenticatedUserForCredentialMigration(token: "public-only-token")

        XCTAssertEqual(account.id, 42)
        XCTAssertEqual(account.login, "octocat")
    }

    func testAuthoredPullRequestsUsesVersionedEncodedBoundedSearchAndSortsResults() async throws {
        let httpClient = MockHTTPClient(responses: [
            .success(
                #"{"total_count":72,"incomplete_results":false,"items":[{"id":1,"number":7,"title":"Older","draft":false,"updated_at":"2026-07-31T12:00:00Z","html_url":"https://github.com/HemSoft/Buddy/pull/7","repository_url":"https://api.github.com/repos/HemSoft/Buddy"},{"id":2,"number":9,"title":"Newer","draft":true,"updated_at":"2026-08-01T12:00:00Z","html_url":"https://github.com/HemSoft/Other/pull/9","repository_url":"https://api.github.com/repos/HemSoft/Other"}]}"#,
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
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(query["q"]!, "is:pr is:open author:franz-test")
        XCTAssertEqual(query["sort"]!, "updated")
        XCTAssertEqual(query["order"]!, "desc")
        XCTAssertEqual(query["per_page"]!, "50")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
    }

    func testAssignedPullRequestsUsesReviewRequestedQualifierAndAccountCredential() async throws {
        let httpClient = MockHTTPClient(responses: [
            .success(
                #"{"total_count":1,"incomplete_results":false,"items":[{"id":9,"number":20,"title":"Assigned review","draft":false,"updated_at":"2026-08-06T12:00:00Z","html_url":"https://github.com/HemSoft/Buddy/pull/20","repository_url":"https://api.github.com/repos/HemSoft/Buddy"}]}"#,
                statusCode: 200
            ),
        ])

        let collection = try await GitHubAPI(httpClient: httpClient)
            .assignedPullRequests(login: "franz-test", token: "account-token")

        XCTAssertEqual(collection.pullRequests.map(\.id), [9])
        let capturedRequest = await httpClient.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(query["q"]!, "is:pr is:open review-requested:franz-test")
        XCTAssertEqual(query["sort"]!, "updated")
        XCTAssertEqual(query["order"]!, "desc")
        XCTAssertEqual(query["per_page"]!, "50")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
    }

    func testPullRequestSearchesRejectTokensWithoutPrivateRepositoryScope() async throws {
        let emptyResponse = #"{"total_count":0,"incomplete_results":false,"items":[]}"#

        for assigned in [false, true] {
            let client = MockHTTPClient(responses: [
                .successWithScopes(emptyResponse, statusCode: 200, scopes: "read:user"),
            ])
            let api = GitHubAPI(httpClient: client)

            do {
                if assigned {
                    _ = try await api.assignedPullRequests(login: "octocat", token: "public-only-token")
                } else {
                    _ = try await api.authoredPullRequests(login: "octocat", token: "public-only-token")
                }
                XCTFail("Expected missing repository scope")
            } catch let error as GitHubAPIError {
                XCTAssertEqual(error, .insufficientOAuthScope)
            }
        }
    }

    func testAuthoredPullRequestsSupportsEmptyResults() async throws {
        let httpClient = MockHTTPClient(responses: [.success(#"{"total_count":0,"incomplete_results":false,"items":[]}"#, statusCode: 200)])

        let collection = try await GitHubAPI(httpClient: httpClient)
            .authoredPullRequests(login: "octocat", token: "token")

        XCTAssertEqual(collection, GitHubPullRequestCollection(pullRequests: [], totalCount: 0))
    }

    func testAuthoredPullRequestsRejectsIncompleteSearchResults() async throws {
        let httpClient = MockHTTPClient(responses: [
            .success(#"{"total_count":1,"incomplete_results":true,"items":[]}"#, statusCode: 200),
        ])

        do {
            _ = try await GitHubAPI(httpClient: httpClient)
                .authoredPullRequests(login: "octocat", token: "token")
            XCTFail("Expected incomplete search results to be rejected")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .incompleteResults)
        }
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
                #"{"total_count":1,"incomplete_results":false,"items":[{"id":1,"number":1,"title":"PR","updated_at":"2026-08-01T12:00:00Z","html_url":"http://example.com/pr/1","repository_url":"https://api.github.com/repos/HemSoft/Buddy"}]}"#,
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

    func testPullRequestDetailsUsesOneAccountScopedGraphQLRequestAndReducesReviewers() async throws {
        let response = #"""
        {
          "data": {
            "repository": {
              "pullRequest": {
                "databaseId": 300,
                "number": 30,
                "title": "Private detail",
                "state": "OPEN",
                "isDraft": false,
                "updatedAt": "2026-08-08T18:00:00Z",
                "url": "https://github.com/Relias/private-repo/pull/30",
                "body": "## Summary\n\n[Read more](https://example.com)",
                "changedFiles": 8,
                "additions": 162,
                "deletions": 52,
                "author": {"login":"octocat","name":"The Octocat","avatarUrl":"https://avatars.githubusercontent.com/u/1"},
                "closingIssuesReferences": {"nodes":[{"number":29,"title":"Detail issue","url":"https://github.com/Relias/private-repo/issues/29"}]},
                "reviewRequests": {"nodes":[
                  {"requestedReviewer":{"__typename":"User","login":"bob","name":"Bob","avatarUrl":null}},
                  {"requestedReviewer":{"__typename":"Team","name":"Core Team","slug":"core","avatarUrl":null,"organization":{"login":"Relias"}}}
                ]},
                "reviews": {"nodes":[
                  {"state":"COMMENTED","submittedAt":"2026-08-08T12:00:00Z","author":{"login":"alice","name":"Alice","avatarUrl":null}},
                  {"state":"APPROVED","submittedAt":"2026-08-08T13:00:00Z","author":{"login":"alice","name":"Alice","avatarUrl":null}},
                  {"state":"COMMENTED","submittedAt":"2026-08-08T13:30:00Z","author":{"login":"alice","name":"Alice","avatarUrl":null}},
                  {"state":"CHANGES_REQUESTED","submittedAt":"2026-08-08T14:00:00Z","author":{"login":"bob","name":"Bob","avatarUrl":null}}
                ]}
              }
            }
          }
        }
        """#
        let client = MockHTTPClient(responses: [.success(response, statusCode: 200)])

        let details = try await GitHubAPI(httpClient: client).pullRequestDetails(
            repository: "Relias/private-repo",
            number: 30,
            token: "private-account-token"
        )

        XCTAssertEqual(details.repository, "Relias/private-repo")
        XCTAssertEqual(details.number, 30)
        XCTAssertEqual(details.changedFiles, 8)
        XCTAssertEqual(details.changedLines, 214)
        XCTAssertEqual(details.author?.login, "octocat")
        XCTAssertEqual(details.linkedIssues.map(\.number), [29])
        XCTAssertEqual(details.reviewers.map(\.reviewer.login), ["alice", "bob", "Relias/core"])
        XCTAssertEqual(details.reviewers.map(\.status), [.approved, .requested, .requested])

        let capturedRequest = await client.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/graphql")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer private-account-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let variables = try XCTUnwrap(object["variables"] as? [String: Any])
        XCTAssertEqual(variables["owner"] as? String, "Relias")
        XCTAssertEqual(variables["name"] as? String, "private-repo")
        XCTAssertEqual(variables["number"] as? Int, 30)
        let query = try XCTUnwrap(object["query"] as? String)
        XCTAssertTrue(query.contains("closingIssuesReferences(first: 50)"))
        XCTAssertTrue(query.contains("reviewRequests(first: 50)"))
        XCTAssertTrue(query.contains("reviews(last: 100)"))
    }

    func testPullRequestDetailsSupportsPartialAndEmptyMetadata() async throws {
        let response = #"""
        {"data":{"repository":{"pullRequest":{
          "databaseId":31,"number":31,"title":"Sparse detail","state":"CLOSED","isDraft":false,
          "updatedAt":"2026-08-08T18:00:00Z","url":"https://github.com/HemSoft/buddy-ios/pull/31",
          "body":"","changedFiles":0,"additions":0,"deletions":0,"author":null,
          "closingIssuesReferences":{"nodes":[null]},"reviewRequests":{"nodes":[]},"reviews":{"nodes":[null]}
        }}}}
        """#

        let details = try await GitHubAPI(httpClient: MockHTTPClient(responses: [.success(response, statusCode: 200)]))
            .pullRequestDetails(repository: "HemSoft/buddy-ios", number: 31, token: "token")

        XCTAssertEqual(details.state, .closed)
        XCTAssertNil(details.author)
        XCTAssertTrue(details.body.isEmpty)
        XCTAssertTrue(details.linkedIssues.isEmpty)
        XCTAssertTrue(details.reviewers.isEmpty)
    }

    func testPullRequestDetailsRejectsGraphQLErrorsMissingNodesAndMalformedIdentity() async throws {
        let responses = [
            #"{"errors":[{"message":"denied"}],"data":{"repository":null}}"#,
            #"{"data":{"repository":{"pullRequest":null}}}"#,
        ]

        for response in responses {
            do {
                _ = try await GitHubAPI(httpClient: MockHTTPClient(responses: [.success(response, statusCode: 200)]))
                    .pullRequestDetails(repository: "HemSoft/buddy-ios", number: 30, token: "token")
                XCTFail("Expected malformed GraphQL response")
            } catch let error as GitHubAPIError {
                XCTAssertEqual(error, .malformedResponse)
            }
        }

        do {
            _ = try await GitHubAPI(httpClient: MockHTTPClient(responses: []))
                .pullRequestDetails(repository: "not-a-repository", number: 30, token: "token")
            XCTFail("Expected malformed repository identity")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .malformedResponse)
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

private enum TestOAuthError: Error {
    case unavailable
}

private enum ErrorExpectation: Equatable {
    case api(GitHubAPIError)
    case network
}

private actor MockHTTPClient: HTTPClient {
    enum Response: Sendable {
        case success(String, statusCode: Int)
        case successWithScopes(String, statusCode: Int, scopes: String)
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
                headerFields: ["X-OAuth-Scopes": "repo"]
            )!
            guard 200..<300 ~= statusCode else {
                throw HTTPClientError.unacceptableStatus(statusCode)
            }
            return (Data(body.utf8), httpResponse)
        case let .successWithScopes(body, statusCode, scopes):
            let httpResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["X-OAuth-Scopes": scopes]
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
