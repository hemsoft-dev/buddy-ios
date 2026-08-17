import XCTest
@testable import Buddy

final class GitHubStatusServiceTests: XCTestCase {
    func testParsesAndQualifiesUnresolvedDegradationFixture() async throws {
        let client = GitHubStatusHTTPClient(response: .data(Self.incidentsFixture))
        let incidents = try await GitHubStatusService(httpClient: client).fetchActiveIncidents()

        XCTAssertEqual(incidents.count, 1)
        let incident = try XCTUnwrap(incidents.first)
        XCTAssertEqual(incident.id, "incident-1")
        XCTAssertEqual(incident.updateID, "update-2")
        XCTAssertEqual(incident.title, "Degraded Git Operations")
        XCTAssertEqual(incident.status, "identified")
        XCTAssertEqual(incident.impact, "major")
        XCTAssertEqual(incident.affectedComponents, ["Git Operations"])
        XCTAssertEqual(incident.detailsURL.absoluteString, "https://www.githubstatus.com/incidents/incident-1")
        XCTAssertTrue(incident.summary.contains("Affected: Git Operations"))

        let capturedRequest = await client.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url, GitHubStatusService.unresolvedIncidentsURL)
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testIgnoresResolvedNoneImpactAndScheduledMaintenanceIncidents() async throws {
        let client = GitHubStatusHTTPClient(response: .data(Self.nonQualifyingFixture))
        let incidents = try await GitHubStatusService(httpClient: client).fetchActiveIncidents()

        XCTAssertTrue(incidents.isEmpty)
    }

    func testMalformedFixtureAndNetworkFailureThrowWithoutInventingIncidents() async {
        for response in [GitHubStatusHTTPClient.Response.data(Data("{".utf8)), .failure] {
            do {
                _ = try await GitHubStatusService(
                    httpClient: GitHubStatusHTTPClient(response: response)
                ).fetchActiveIncidents()
                XCTFail("Expected the status fetch to fail")
            } catch {
                // Expected: callers degrade silently and retain their last confirmed state.
            }
        }
    }

    private static let incidentsFixture = Data(#"""
    {
      "incidents": [
        {
          "id": "incident-1",
          "name": "Degraded Git Operations",
          "status": "investigating",
          "impact": "major",
          "updated_at": "2026-08-17T16:11:12.345Z",
          "incident_updates": [
            {"id":"update-1","status":"investigating","updated_at":"2026-08-17T16:00:00Z"},
            {"id":"update-2","status":"identified","updated_at":"2026-08-17T16:11:12.345Z"}
          ],
          "components": [
            {"name":"Git Operations","status":"degraded_performance"},
            {"name":"API Requests","status":"operational"}
          ]
        },
        {
          "id": "resolved-1",
          "name": "Resolved incident",
          "status": "resolved",
          "impact": "critical",
          "updated_at": "2026-08-17T15:00:00Z",
          "incident_updates": [],
          "components": []
        }
      ]
    }
    """#.utf8)

    private static let nonQualifyingFixture = Data(#"""
    {
      "incidents": [
        {"id":"one","name":"Resolved","status":"resolved","impact":"major","updated_at":"2026-08-17T15:00:00Z","incident_updates":[],"components":[]},
        {"id":"two","name":"Informational","status":"investigating","impact":"none","updated_at":"2026-08-17T15:00:00Z","incident_updates":[],"components":[]},
        {"id":"three","name":"Maintenance","status":"scheduled","impact":"minor","updated_at":"2026-08-17T15:00:00Z","incident_updates":[],"components":[]}
      ]
    }
    """#.utf8)
}

@MainActor
final class GitHubStatusMonitorTests: XCTestCase {
    func testPersistsOptInAndPresentationStyleAcrossPreferenceInstances() throws {
        let defaults = try makeDefaults()
        let preferences = GitHubStatusPreferences(defaults: defaults)
        XCTAssertFalse(preferences.monitoringEnabled)
        XCTAssertEqual(preferences.presentationStyle, .alert)

        preferences.monitoringEnabled = true
        preferences.presentationStyle = .banner

        let restored = GitHubStatusPreferences(defaults: defaults)
        XCTAssertTrue(restored.monitoringEnabled)
        XCTAssertEqual(restored.presentationStyle, .banner)
    }

    func testAlertDeduplicatesUnchangedIncidentAndPresentsMaterialUpdate() async throws {
        let defaults = try makeDefaults()
        let first = makeIncident(updateID: "update-1", status: "investigating")
        let updated = makeIncident(updateID: "update-2", status: "identified")
        let service = GitHubStatusSequenceService(responses: [
            .incidents([first]),
            .incidents([first]),
            .incidents([updated]),
        ])
        let monitor = GitHubStatusMonitor(service: service, defaults: defaults)

        await monitor.refresh(isEnabled: true, style: .alert)
        XCTAssertEqual(monitor.pendingAlert, first)
        monitor.dismissAlert()

        await monitor.refresh(isEnabled: true, style: .alert)
        XCTAssertNil(monitor.pendingAlert)

        await monitor.refresh(isEnabled: true, style: .alert)
        XCTAssertEqual(monitor.pendingAlert, updated)
        XCTAssertEqual(monitor.currentIncident, updated)
    }

    func testBannerUpdatesClearsAfterResolutionAndDoesNotQueueAlert() async throws {
        let first = makeIncident(updateID: "update-1", status: "investigating")
        let updated = makeIncident(updateID: "update-2", status: "monitoring")
        let service = GitHubStatusSequenceService(responses: [
            .incidents([first]),
            .incidents([updated]),
            .incidents([]),
        ])
        let monitor = GitHubStatusMonitor(service: service, defaults: try makeDefaults())

        await monitor.refresh(isEnabled: true, style: .banner)
        XCTAssertEqual(monitor.currentIncident, first)
        XCTAssertNil(monitor.pendingAlert)

        await monitor.refresh(isEnabled: true, style: .banner)
        XCTAssertEqual(monitor.currentIncident, updated)

        await monitor.refresh(isEnabled: true, style: .banner)
        XCTAssertNil(monitor.currentIncident)
        XCTAssertNil(monitor.pendingAlert)
    }

    func testNetworkFailureRetainsConfirmedIncidentAndRecoveryClearsIt() async throws {
        let incident = makeIncident(updateID: "update-1", status: "investigating")
        let service = GitHubStatusSequenceService(responses: [
            .incidents([incident]),
            .failure,
            .incidents([]),
        ])
        let monitor = GitHubStatusMonitor(service: service, defaults: try makeDefaults())

        await monitor.refresh(isEnabled: true, style: .banner)
        await monitor.refresh(isEnabled: true, style: .banner)
        XCTAssertEqual(monitor.currentIncident, incident)

        await monitor.refresh(isEnabled: true, style: .banner)
        XCTAssertNil(monitor.currentIncident)
    }

    func testDisablingMonitoringImmediatelyClearsPresentations() async throws {
        let incident = makeIncident(updateID: "update-1", status: "investigating")
        let monitor = GitHubStatusMonitor(
            service: GitHubStatusSequenceService(responses: [.incidents([incident])]),
            defaults: try makeDefaults()
        )
        await monitor.refresh(isEnabled: true, style: .alert)

        await monitor.refresh(isEnabled: false, style: .alert)

        XCTAssertNil(monitor.currentIncident)
        XCTAssertNil(monitor.pendingAlert)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "GitHubStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeIncident(updateID: String, status: String) -> GitHubStatusIncident {
        GitHubStatusIncident(
            id: "incident-1",
            updateID: updateID,
            title: "Git operations degraded",
            status: status,
            impact: "major",
            affectedComponents: ["Git Operations"],
            updatedAt: Date(timeIntervalSince1970: updateID == "update-1" ? 1 : 2),
            detailsURL: URL(string: "https://www.githubstatus.com/incidents/incident-1")!
        )
    }
}

private actor GitHubStatusHTTPClient: HTTPClient {
    enum Response: Sendable {
        case data(Data)
        case failure
    }

    private let response: Response
    private var capturedRequest: URLRequest?

    init(response: Response) {
        self.response = response
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        capturedRequest = request
        switch response {
        case let .data(data):
            return (
                data,
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        case .failure:
            throw URLError(.timedOut)
        }
    }

    func lastRequest() -> URLRequest? { capturedRequest }
}

private actor GitHubStatusSequenceService: GitHubStatusFetching {
    enum Response: Sendable {
        case incidents([GitHubStatusIncident])
        case failure
    }

    private var responses: [Response]

    init(responses: [Response]) {
        self.responses = responses
    }

    func fetchActiveIncidents() async throws -> [GitHubStatusIncident] {
        switch responses.removeFirst() {
        case let .incidents(incidents): incidents
        case .failure: throw URLError(.notConnectedToInternet)
        }
    }
}
