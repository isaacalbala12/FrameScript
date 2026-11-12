import Foundation
import Testing
@testable import FrameScriptCore

private let planeWorkspaceSlug = "acme"
private let planeProjectID = "project-uuid-1"
private let planeAPIKey = "test-api-key"
private let planeWorkItemsPath = "/api/v1/workspaces/acme/projects/project-uuid-1/work-items/"
private let planeIssuesPath = "/api/v1/workspaces/acme/projects/project-uuid-1/issues/"

private func planeStub(
    _ json: String,
    status: Int = 200,
    headers: [String: String] = [:]
) -> PlaneURLProtocolStub.Stub {
    PlaneURLProtocolStub.Stub(statusCode: status, headers: headers, body: Data(json.utf8))
}

private func makePlaneClient(
    baseURL: String = "https://plane.example.test",
    workItemRoute: PlaneWorkItemRoute = .automatic
) throws -> PlaneClient {
    let url = try #require(URL(string: baseURL))
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [PlaneURLProtocolStub.self]
    let session = URLSession(configuration: sessionConfiguration)
    let configuration = PlaneClient.Configuration(
        baseURL: url,
        workspaceSlug: planeWorkspaceSlug,
        projectID: planeProjectID,
        apiKey: planeAPIKey,
        workItemRoute: workItemRoute
    )
    return try PlaneClient(
        configuration: configuration,
        transport: URLSessionPlaneHTTPTransport(session: session)
    )
}

@Suite("Plane client", .serialized)
struct PlaneClientTests {
    // MARK: - Reads

    @Test func listProjectsBuildsDocumentedRequest() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(
                """
                {"results":[
                  {"id":"project-1","name":"Demo project","identifier":"DEMO"},
                  {"id":"project-2","name":"Second project","identifier":"SEC"}
                ],"next_cursor":"","next_page_results":false}
                """
            )
        }

        let client = try makePlaneClient()
        let projects = try await client.listProjects()

        #expect(projects.map(\.id) == ["project-1", "project-2"])
        #expect(projects.first?.name == "Demo project")
        #expect(projects.first?.identifier == "DEMO")

        let request = try #require(PlaneURLProtocolStub.requests.first)
        #expect(request.method == "GET")
        let url = try #require(request.url)
        #expect(url.scheme == "https")
        #expect(url.host == "plane.example.test")
        #expect(url.planePath == "/api/v1/workspaces/acme/projects/")
        #expect(url.absoluteString == "https://plane.example.test/api/v1/workspaces/acme/projects/?per_page=100")
        #expect(url.queryValue("per_page") == "100")
        #expect(url.queryValue("cursor") == nil)
        #expect(request.header("X-API-Key") == planeAPIKey)
        #expect(request.header("Accept") == "application/json")
        #expect(request.header("Content-Type") == nil)
    }

    @Test func listStatesAndLabelsUseProjectEndpoints() async throws {
        PlaneURLProtocolStub.install { request in
            switch request.url?.planePath ?? "" {
            case "/api/v1/workspaces/acme/projects/project-uuid-1/states/":
                return planeStub(
                    """
                    {"results":[{"id":"state-1","name":"Todo","group":"unstarted","color":"#6b7280","sequence":1}],
                     "next_cursor":"","next_page_results":false}
                    """
                )
            case "/api/v1/workspaces/acme/projects/project-uuid-1/labels/":
                return planeStub(
                    """
                    {"results":[{"id":"label-1","name":"B-roll","color":"#f59e0b"}],
                     "next_cursor":"","next_page_results":false}
                    """
                )
            default:
                throw URLError(.badURL)
            }
        }

        let client = try makePlaneClient()
        let states = try await client.listStates()
        let labels = try await client.listLabels()

        #expect(states == [PlaneState(id: "state-1", name: "Todo", group: "unstarted", color: "#6b7280", sequence: 1)])
        #expect(labels == [PlaneLabel(id: "label-1", name: "B-roll", color: "#f59e0b")])

        let requests = PlaneURLProtocolStub.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.planePath == "/api/v1/workspaces/acme/projects/project-uuid-1/states/")
        #expect(requests[1].url?.planePath == "/api/v1/workspaces/acme/projects/project-uuid-1/labels/")
        #expect(requests.allSatisfy { $0.header("X-API-Key") == planeAPIKey })
    }

    @Test func paginationFollowsNextCursor() async throws {
        PlaneURLProtocolStub.install { request in
            if request.url?.queryValue("cursor") == nil {
                return planeStub(
                    """
                    {"results":[{"id":"project-1","name":"First","identifier":"ONE"}],
                     "next_cursor":"100:1:0","next_page_results":true,"total_results":2}
                    """
                )
            }
            return planeStub(
                """
                {"results":[{"id":"project-2","name":"Second","identifier":"TWO"}],
                 "next_cursor":"","next_page_results":false,"total_results":2}
                """
            )
        }

        let client = try makePlaneClient()
        let projects = try await client.listProjects()

        #expect(projects.map(\.id) == ["project-1", "project-2"])

        let requests = PlaneURLProtocolStub.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.queryValue("cursor") == nil)
        #expect(requests[1].url?.queryValue("cursor") == "100:1:0")
        #expect(requests[1].url?.queryValue("per_page") == "100")
    }

    @Test func paginationStopsWhenCursorRepeats() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(
                """
                {"results":[{"id":"project-1","name":"First","identifier":"ONE"}],
                 "next_cursor":"100:1:0","next_page_results":true}
                """
            )
        }

        let client = try makePlaneClient()
        let projects = try await client.listProjects()

        #expect(projects.map(\.id) == ["project-1"])
        #expect(PlaneURLProtocolStub.requests.count == 2)
    }

    // MARK: - Writes

    @Test func createWorkItemSendsDocumentedBody() async throws {
        PlaneURLProtocolStub.install { request in
            #expect(request.method == "POST")
            return planeStub(
                """
                {"id":"wi-1","name":"Grabar intro","sequence_id":42,
                 "external_id":"framescript:project-uuid-1:task-1","external_source":"framescript",
                 "target_date":"2026-11-20"}
                """,
                status: 201,
                headers: ["Content-Type": "application/json"]
            )
        }

        let client = try makePlaneClient()
        let targetDate = try #require(PlaneDate(iso8601: "2026-11-20"))
        let draft = PlaneWorkItemDraft(
            name: "Grabar intro",
            descriptionHTML: "<p>Grabar</p>",
            priority: .high,
            stateID: "state-uuid",
            labelIDs: ["label-1", "label-2"],
            targetDate: targetDate,
            externalID: "framescript:project-uuid-1:task-1",
            externalSource: "framescript"
        )

        let created = try await client.createWorkItem(draft)

        #expect(created.id == "wi-1")
        #expect(created.sequenceID == 42)
        #expect(created.externalID == "framescript:project-uuid-1:task-1")
        #expect(created.externalSource == "framescript")
        #expect(created.targetDate == targetDate)

        let request = try #require(PlaneURLProtocolStub.requests.first)
        #expect(request.url?.planePath == planeWorkItemsPath)
        #expect(request.url?.absoluteString.hasSuffix("/work-items/") == true)
        #expect(request.header("Content-Type") == "application/json")
        #expect(request.header("X-API-Key") == planeAPIKey)

        let body = try request.jsonObject()
        #expect(
            Set(body.keys) == Set([
                "name", "description_html", "priority", "state", "labels",
                "target_date", "external_id", "external_source"
            ])
        )
        #expect(body["name"] as? String == "Grabar intro")
        #expect(body["description_html"] as? String == "<p>Grabar</p>")
        #expect(body["priority"] as? String == "high")
        #expect(body["state"] as? String == "state-uuid")
        #expect(body["labels"] as? [String] == ["label-1", "label-2"])
        #expect(body["target_date"] as? String == "2026-11-20")
        #expect(body["external_id"] as? String == "framescript:project-uuid-1:task-1")
        #expect(body["external_source"] as? String == "framescript")
    }

    @Test func createWorkItemOmitsUnsetOptionalFields() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(
                """
                {"id":"wi-1","name":"Investigar referencia","sequence_id":1}
                """,
                status: 201
            )
        }

        let client = try makePlaneClient()
        let draft = PlaneWorkItemDraft(
            name: "Investigar referencia",
            descriptionHTML: "<p>Investigar</p>",
            externalID: "framescript:project-uuid-1:task-2",
            externalSource: "framescript"
        )

        _ = try await client.createWorkItem(draft)

        let request = try #require(PlaneURLProtocolStub.requests.first)
        let body = try request.jsonObject()
        #expect(
            Set(body.keys) == Set([
                "name", "description_html", "priority", "external_id", "external_source"
            ])
        )
        #expect(body["state"] == nil)
        #expect(body["labels"] == nil)
        #expect(body["target_date"] == nil)
    }

    // MARK: - Idempotency

    @Test func findWorkItemFiltersByExternalIDAndPaginates() async throws {
        PlaneURLProtocolStub.install { request in
            if request.url?.queryValue("cursor") == nil {
                return planeStub(
                    """
                    {"results":[{"id":"wi-other","name":"Other","external_id":"framescript:other:task",
                     "external_source":"framescript"}],
                     "next_cursor":"100:1:0","next_page_results":true}
                    """
                )
            }
            return planeStub(
                """
                {"results":[{"id":"wi-2","name":"Grabar intro",
                 "external_id":"framescript:project-uuid-1:task-1","external_source":"framescript"}],
                 "next_cursor":"","next_page_results":false}
                """
            )
        }

        let client = try makePlaneClient()
        let match = try await client.findWorkItem(byExternalId: "framescript:project-uuid-1:task-1")

        #expect(match?.id == "wi-2")

        let requests = PlaneURLProtocolStub.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.queryValue("external_id") == "framescript:project-uuid-1:task-1")
        #expect(requests[0].url?.queryValue("external_source") == "framescript")
        #expect(requests[0].url?.queryValue("per_page") == "100")
        #expect(requests[1].url?.queryValue("cursor") == "100:1:0")
    }

    @Test func findWorkItemReturnsNilWhenNoMatchExists() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(
                """
                {"results":[{"id":"wi-other","name":"Other","external_id":"framescript:other:task",
                 "external_source":"framescript"}],
                 "next_cursor":"","next_page_results":false}
                """
            )
        }

        let client = try makePlaneClient()
        let match = try await client.findWorkItem(byExternalId: "framescript:project-uuid-1:task-9")

        #expect(match == nil)
        #expect(PlaneURLProtocolStub.requests.count == 1)
    }

    // MARK: - Legacy route fallback

    @Test func automaticRouteFallsBackToLegacyIssuesAndCachesTheChoice() async throws {
        PlaneURLProtocolStub.install { request in
            switch request.url?.planePath ?? "" {
            case planeWorkItemsPath:
                return planeStub(#"{"error":"Not found"}"#, status: 404)
            case planeIssuesPath:
                return planeStub(
                    """
                    {"results":[{"id":"wi-legacy","name":"Grabar intro",
                     "external_id":"framescript:project-uuid-1:task-1","external_source":"framescript"}],
                     "next_cursor":"","next_page_results":false}
                    """
                )
            default:
                throw URLError(.badURL)
            }
        }

        let client = try makePlaneClient(workItemRoute: .automatic)
        let first = try await client.findWorkItem(byExternalId: "framescript:project-uuid-1:task-1")
        let second = try await client.findWorkItem(byExternalId: "framescript:project-uuid-1:task-1")

        #expect(first?.id == "wi-legacy")
        #expect(second?.id == "wi-legacy")

        let paths = PlaneURLProtocolStub.requests.compactMap { $0.url?.planePath }
        #expect(paths == [planeWorkItemsPath, planeIssuesPath, planeIssuesPath])
    }

    @Test func createWorkItemFallsBackToLegacyIssues() async throws {
        PlaneURLProtocolStub.install { request in
            switch request.url?.planePath ?? "" {
            case planeWorkItemsPath:
                return planeStub(#"{"error":"Not found"}"#, status: 404)
            case planeIssuesPath:
                return planeStub(
                    #"{"id":"wi-legacy","name":"Grabar intro","sequence_id":7}"#,
                    status: 201
                )
            default:
                throw URLError(.badURL)
            }
        }

        let client = try makePlaneClient(workItemRoute: .automatic)
        let draft = PlaneWorkItemDraft(
            name: "Grabar intro",
            descriptionHTML: "<p>Grabar</p>",
            externalID: "framescript:project-uuid-1:task-1",
            externalSource: "framescript"
        )

        let created = try await client.createWorkItem(draft)

        #expect(created.id == "wi-legacy")
        let requests = PlaneURLProtocolStub.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.method == "POST" })
        #expect(requests[0].url?.planePath == planeWorkItemsPath)
        #expect(requests[1].url?.planePath == planeIssuesPath)
    }

    @Test func explicitWorkItemsRouteDoesNotFallBack() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(#"{"error":"Not found"}"#, status: 404)
        }

        let client = try makePlaneClient(workItemRoute: .workItems)

        do {
            _ = try await client.findWorkItem(byExternalId: "framescript:project-uuid-1:task-1")
            Issue.record("Expected notFound")
        } catch let error as PlaneError {
            #expect(error == .notFound(message: "Not found"))
        }

        #expect(PlaneURLProtocolStub.requests.count == 1)
        #expect(PlaneURLProtocolStub.requests.first?.url?.planePath == planeWorkItemsPath)
    }

    @Test func automaticRoutePropagatesNotFoundWhenBothRoutesAreMissing() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(#"{"error":"Not found"}"#, status: 404)
        }

        let client = try makePlaneClient(workItemRoute: .automatic)

        do {
            _ = try await client.createWorkItem(
                PlaneWorkItemDraft(
                    name: "Grabar",
                    descriptionHTML: "<p>Grabar</p>",
                    externalID: "framescript:project-uuid-1:task-1",
                    externalSource: "framescript"
                )
            )
            Issue.record("Expected notFound")
        } catch let error as PlaneError {
            #expect(error == .notFound(message: "Not found"))
        }

        let paths = PlaneURLProtocolStub.requests.compactMap { $0.url?.planePath }
        #expect(paths == [planeWorkItemsPath, planeIssuesPath])
    }

    // MARK: - Errors

    @Test func mapsUnauthorized() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(#"{"error":"Invalid API key"}"#, status: 401)
        }

        let client = try makePlaneClient()
        do {
            _ = try await client.listProjects()
            Issue.record("Expected unauthorized")
        } catch let error as PlaneError {
            #expect(error == .unauthorized(message: "Invalid API key"))
        }
    }

    @Test func mapsForbidden() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(#"{"detail":"Forbidden for this token"}"#, status: 403)
        }

        let client = try makePlaneClient()
        do {
            _ = try await client.listProjects()
            Issue.record("Expected forbidden")
        } catch let error as PlaneError {
            #expect(error == .forbidden(message: "Forbidden for this token"))
        }
    }

    @Test func mapsNotFound() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(#"{"detail":"Project not found"}"#, status: 404)
        }

        let client = try makePlaneClient()
        do {
            _ = try await client.listProjects()
            Issue.record("Expected notFound")
        } catch let error as PlaneError {
            #expect(error == .notFound(message: "Project not found"))
        }
    }

    @Test func mapsRateLimitedWithRetryAfter() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(
                #"{"detail":"Rate limit exceeded"}"#,
                status: 429,
                headers: ["Retry-After": "17"]
            )
        }

        let client = try makePlaneClient()
        do {
            _ = try await client.listProjects()
            Issue.record("Expected rateLimited")
        } catch let error as PlaneError {
            #expect(error == .rateLimited(retryAfter: 17))
        }
    }

    @Test func mapsServerError() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(#"{"error":"Internal error"}"#, status: 500)
        }

        let client = try makePlaneClient()
        do {
            _ = try await client.listProjects()
            Issue.record("Expected server error")
        } catch let error as PlaneError {
            #expect(error == .server(statusCode: 500, message: "Internal error"))
        }
    }

    @Test func mapsDecodingFailure() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub("not json")
        }

        let client = try makePlaneClient()
        do {
            _ = try await client.listProjects()
            Issue.record("Expected decoding failure")
        } catch let error as PlaneError {
            guard case .decoding = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test func mapsNetworkFailure() async throws {
        PlaneURLProtocolStub.install { _ in
            throw URLError(.notConnectedToInternet)
        }

        let client = try makePlaneClient()
        do {
            _ = try await client.listProjects()
            Issue.record("Expected network failure")
        } catch let error as PlaneError {
            guard case let .network(code, message) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(code == NSURLErrorNotConnectedToInternet)
            #expect(!message.isEmpty)
        }
    }

    // MARK: - Rate limits and configuration

    @Test func recordsRateLimitHeaders() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(
                #"{"results":[],"next_cursor":"","next_page_results":false}"#,
                headers: [
                    "X-RateLimit-Remaining": "45",
                    "X-RateLimit-Reset": "1700327957"
                ]
            )
        }

        let client = try makePlaneClient()
        _ = try await client.listProjects()

        let limit = await client.lastRateLimit
        #expect(limit?.remaining == 45)
        #expect(limit?.resetAt == Date(timeIntervalSince1970: 1_700_327_957))
    }

    @Test func normalizesBaseURLWithAPIAndSubpath() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(#"{"results":[],"next_cursor":"","next_page_results":false}"#)
        }

        let client = try makePlaneClient(baseURL: "https://plane.example.test/plane/api/v1/")
        _ = try await client.listProjects()

        let request = try #require(PlaneURLProtocolStub.requests.first)
        #expect(request.url?.planePath == "/plane/api/v1/workspaces/acme/projects/")
    }

    @Test func rejectsInvalidConfiguration() throws {
        let badScheme = try #require(URL(string: "ftp://plane.example.test"))
        #expect(throws: PlaneError.self) {
            _ = try PlaneClient(
                configuration: .init(
                    baseURL: badScheme,
                    workspaceSlug: planeWorkspaceSlug,
                    projectID: planeProjectID,
                    apiKey: planeAPIKey
                )
            )
        }

        let validURL = try #require(URL(string: "https://plane.example.test"))
        #expect(throws: PlaneError.self) {
            _ = try PlaneClient(
                configuration: .init(
                    baseURL: validURL,
                    workspaceSlug: "  ",
                    projectID: planeProjectID,
                    apiKey: planeAPIKey
                )
            )
        }
        #expect(throws: PlaneError.self) {
            _ = try PlaneClient(
                configuration: .init(
                    baseURL: validURL,
                    workspaceSlug: planeWorkspaceSlug,
                    projectID: planeProjectID,
                    apiKey: "  "
                )
            )
        }
    }
}
