import Foundation
import Testing
@testable import FrameScriptCore

private let planeWorkspaceSlug = "acme"
private let planeProjectID = "project-uuid-1"
private let planeAPIKey = "test-api-key"
private let planeWorkItemsPath = "/api/v1/workspaces/acme/projects/project-uuid-1/work-items/"
private let planeIssuesPath = "/api/v1/workspaces/acme/projects/project-uuid-1/issues/"
private let planeWorkItemDetailPath = "/api/v1/workspaces/acme/projects/project-uuid-1/work-items/wi-1/"
private let planeTaskExternalID = "framescript:project-uuid-1:task-1"

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

private func makeExportPlan(title: String = "Grabar intro") -> PlaneExportPlan {
    PlaneExportPlan(
        tasks: [
            PlanePendingTask(
                id: "task-1",
                projectID: planeProjectID,
                title: title,
                kind: .grabar,
                sceneTitle: "Intro",
                projectTitle: "Demo project"
            )
        ]
    )
}

private func ledger(workItemID: String) -> PlaneExportLedger {
    PlaneExportLedger(workItemIDsByTaskExternalID: [planeTaskExternalID: workItemID])
}

private func createdWorkItemJSON(id: String) -> String {
    """
    {"id":"\(id)","name":"Grabar intro","sequence_id":7,
     "external_id":"\(planeTaskExternalID)","external_source":"framescript"}
    """
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

    @Test func listProjectsDecodesBareArray() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(#"[{"id":"project-1","name":"Demo project","identifier":"DEMO"}]"#)
        }

        let client = try makePlaneClient()
        let projects = try await client.listProjects()

        #expect(projects.map(\.id) == ["project-1"])
        #expect(PlaneURLProtocolStub.requests.count == 1)
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
                createdWorkItemJSON(id: "wi-1"),
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
            externalID: planeTaskExternalID,
            externalSource: "framescript"
        )

        let created = try await client.createWorkItem(draft)

        #expect(created.id == "wi-1")
        #expect(created.sequenceID == 7)
        #expect(created.externalID == planeTaskExternalID)
        #expect(created.externalSource == "framescript")

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
        #expect(body["external_id"] as? String == planeTaskExternalID)
        #expect(body["external_source"] as? String == "framescript")
    }

    @Test func createWorkItemOmitsUnsetOptionalFields() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(#"{"id":"wi-1","name":"Investigar referencia","sequence_id":1}"#, status: 201)
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

    @Test func createWorkItemTruncatesLongNameGraphemeSafely() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(#"{"id":"wi-1","name":"truncated"}"#, status: 201)
        }

        let client = try makePlaneClient()
        let longName = String(repeating: "e\u{301}", count: 300)
        let draft = PlaneWorkItemDraft(
            name: longName,
            descriptionHTML: "<p>Grabar</p>",
            externalID: planeTaskExternalID,
            externalSource: "framescript"
        )

        _ = try await client.createWorkItem(draft)

        let request = try #require(PlaneURLProtocolStub.requests.first)
        let body = try request.jsonObject()
        let sentName = try #require(body["name"] as? String)
        #expect(sentName.count == 255)
        #expect(sentName.unicodeScalars.count == 510)
        #expect(sentName == String(longName.prefix(255)))
    }

    // MARK: - Idempotent lookup

    @Test func findWorkItemAcceptsEchoedExternalIDAndUsesUncachedRequest() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(
                """
                {"results":[
                  {"id":"wi-other","name":"Other","external_id":"framescript:other:task",
                   "external_source":"framescript"},
                  {"id":"wi-1","name":"Grabar intro","external_id":"framescript:project-uuid-1:task-1",
                   "external_source":"framescript"}
                ],"next_cursor":"","next_page_results":false}
                """
            )
        }

        let client = try makePlaneClient()
        let lookup = try await client.findWorkItem(byExternalId: planeTaskExternalID)

        guard case .found(let item) = lookup else {
            Issue.record("Expected a found lookup, got \(lookup)")
            return
        }
        #expect(item.id == "wi-1")

        let request = try #require(PlaneURLProtocolStub.requests.first)
        #expect(request.method == "GET")
        #expect(request.url?.planePath == planeWorkItemsPath)
        #expect(request.url?.queryValue("external_id") == planeTaskExternalID)
        #expect(request.url?.queryValue("external_source") == "framescript")
        #expect(request.url?.queryValue("per_page") == "100")
        #expect(request.url?.queryValue("cursor") == nil)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(PlaneURLProtocolStub.requests.count == 1)
    }

    @Test func findWorkItemMakesOneRequestEvenWhenMorePagesExist() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(
                #"{"results":[],"next_cursor":"100:1:0","next_page_results":true}"#
            )
        }

        let client = try makePlaneClient()
        let lookup = try await client.findWorkItem(
            byExternalId: planeTaskExternalID,
            expectedName: "Grabar intro"
        )

        guard case .notFound = lookup else {
            Issue.record("Expected notFound, got \(lookup)")
            return
        }
        #expect(PlaneURLProtocolStub.requests.count == 1)
        #expect(PlaneURLProtocolStub.requests.first?.url?.queryValue("cursor") == nil)
    }

    @Test func findWorkItemReportsDocumentedNameMatchAsPossibleDuplicate() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(
                """
                {"results":[{"id":"wi-1","name":"Grabar intro","sequence_id":9}],
                 "next_page_results":false}
                """
            )
        }

        let client = try makePlaneClient()
        let lookup = try await client.findWorkItem(
            byExternalId: planeTaskExternalID,
            expectedName: "Grabar intro"
        )

        guard case .possibleDuplicate(let candidates) = lookup else {
            Issue.record("Expected possibleDuplicate, got \(lookup)")
            return
        }
        #expect(candidates.map(\.id) == ["wi-1"])
        #expect(candidates.first?.externalID == nil)
        #expect(lookup.workItem == nil)
    }

    @Test func findWorkItemReturnsNotFoundWhenDocumentedRowNameDiffers() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(
                """
                {"results":[{"id":"wi-1","name":"Otra cosa"}],
                 "next_page_results":false}
                """
            )
        }

        let client = try makePlaneClient()
        let lookup = try await client.findWorkItem(
            byExternalId: planeTaskExternalID,
            expectedName: "Grabar intro"
        )

        guard case .notFound = lookup else {
            Issue.record("Expected notFound, got \(lookup)")
            return
        }
    }

    @Test func findWorkItemReportsUniqueNameMatchAsPossibleDuplicate() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(
                """
                {"results":[
                  {"id":"wi-a","name":"Otra cosa"},
                  {"id":"wi-b","name":"Grabar intro"}
                ],"next_page_results":false}
                """
            )
        }

        let client = try makePlaneClient()
        let lookup = try await client.findWorkItem(
            byExternalId: planeTaskExternalID,
            expectedName: "Grabar intro"
        )

        guard case .possibleDuplicate(let candidates) = lookup else {
            Issue.record("Expected possibleDuplicate, got \(lookup)")
            return
        }
        #expect(candidates.map(\.id) == ["wi-b"])
    }

    @Test func findWorkItemReportsAmbiguousNameMatchesAsPossibleDuplicates() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(
                """
                {"results":[
                  {"id":"wi-a","name":"Grabar intro"},
                  {"id":"wi-b","name":"Grabar intro"}
                ],"next_page_results":false}
                """
            )
        }

        let client = try makePlaneClient()
        let lookup = try await client.findWorkItem(
            byExternalId: planeTaskExternalID,
            expectedName: "Grabar intro"
        )

        guard case .possibleDuplicate(let candidates) = lookup else {
            Issue.record("Expected possibleDuplicate, got \(lookup)")
            return
        }
        #expect(candidates.map(\.id) == ["wi-a", "wi-b"])
    }

    @Test func findWorkItemReturnsNotFoundOnFinalEmptyPage() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(#"{"results":[],"next_cursor":"","next_page_results":false}"#)
        }

        let client = try makePlaneClient()
        let lookup = try await client.findWorkItem(byExternalId: planeTaskExternalID)

        guard case .notFound = lookup else {
            Issue.record("Expected notFound, got \(lookup)")
            return
        }
    }

    @Test func findWorkItemDecodesBareArray() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(
                #"[{"id":"wi-1","name":"Grabar intro","external_id":"framescript:project-uuid-1:task-1"}]"#
            )
        }

        let client = try makePlaneClient()
        let lookup = try await client.findWorkItem(
            byExternalId: planeTaskExternalID,
            expectedName: "Grabar intro"
        )

        guard case .found(let item) = lookup else {
            Issue.record("Expected a found lookup, got \(lookup)")
            return
        }
        #expect(item.id == "wi-1")
    }

    @Test func getWorkItemFetchesByIDWithUncachedRequest() async throws {
        PlaneURLProtocolStub.install { request in
            #expect(request.url?.planePath == planeWorkItemDetailPath)
            return planeStub(#"{"id":"wi-1","name":"Grabar intro","sequence_id":3}"#)
        }

        let client = try makePlaneClient()
        let item = try await client.getWorkItem(id: "wi-1")

        #expect(item.id == "wi-1")
        let request = try #require(PlaneURLProtocolStub.requests.first)
        #expect(request.method == "GET")
        #expect(request.url?.planePath == planeWorkItemDetailPath)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.header("X-API-Key") == planeAPIKey)
    }

    // MARK: - Export and ledger

    @Test func exportUsesLedgerAndDoesNotList() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(#"{"id":"wi-1","name":"Grabar intro"}"#)
        }

        let client = try makePlaneClient(workItemRoute: .workItems)
        let report = try await client.export(
            plan: makeExportPlan(),
            ledger: ledger(workItemID: "wi-1")
        )

        #expect(
            report.outcomes == [
                .verified(taskExternalID: planeTaskExternalID, workItemID: "wi-1")
            ]
        )
        #expect(report.workItemIDsByTaskExternalID == [planeTaskExternalID: "wi-1"])
        #expect(report.ledger[planeTaskExternalID] == "wi-1")
        #expect(PlaneURLProtocolStub.requests.count == 1)
        #expect(PlaneURLProtocolStub.requests.first?.url?.planePath == planeWorkItemDetailPath)
        #expect(PlaneURLProtocolStub.requests.first?.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func exportCreatesAndReturnsWorkItemID() async throws {
        PlaneURLProtocolStub.install { request in
            switch (request.method ?? "", request.url?.planePath ?? "") {
            case ("GET", planeWorkItemsPath):
                return planeStub(#"{"results":[],"next_cursor":"","next_page_results":false}"#)
            case ("POST", planeWorkItemsPath):
                return planeStub(createdWorkItemJSON(id: "wi-new"), status: 201)
            default:
                throw URLError(.badURL)
            }
        }

        let client = try makePlaneClient(workItemRoute: .workItems)
        let report = try await client.export(plan: makeExportPlan())

        #expect(
            report.outcomes == [
                .created(taskExternalID: planeTaskExternalID, workItemID: "wi-new")
            ]
        )
        #expect(report.workItemIDsByTaskExternalID == [planeTaskExternalID: "wi-new"])
        #expect(report.ledger[planeTaskExternalID] == "wi-new")
        #expect(report.warnings.isEmpty)

        let requests = PlaneURLProtocolStub.requests
        #expect(requests.count == 2)
        #expect(requests[0].method == "GET")
        #expect(requests[0].cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(requests[0].url?.queryValue("external_id") == planeTaskExternalID)
        #expect(requests[0].url?.queryValue("cursor") == nil)
        #expect(requests[1].method == "POST")
    }

    @Test func exportCreatesAndWarnsWhenOnlyNameMatches() async throws {
        PlaneURLProtocolStub.install { request in
            switch (request.method ?? "", request.url?.planePath ?? "") {
            case ("GET", planeWorkItemsPath):
                return planeStub(
                    """
                    {"results":[{"id":"wi-existing","name":"Grabar intro"}],
                     "next_page_results":false}
                    """
                )
            case ("POST", planeWorkItemsPath):
                return planeStub(createdWorkItemJSON(id: "wi-new"), status: 201)
            default:
                throw URLError(.badURL)
            }
        }

        let client = try makePlaneClient(workItemRoute: .workItems)
        let report = try await client.export(plan: makeExportPlan())

        #expect(
            report.outcomes == [
                .created(taskExternalID: planeTaskExternalID, workItemID: "wi-new")
            ]
        )
        #expect(report.ledger[planeTaskExternalID] == "wi-new")
        #expect(report.warnings.count == 1)
        #expect(report.warnings.first?.kind == .possibleDuplicateByName)
        #expect(report.warnings.first?.candidates.map(\.id) == ["wi-existing"])
        #expect(PlaneURLProtocolStub.requests.count == 2)
    }

    @Test func exportReusesExactEchoedExternalIDWithoutCreating() async throws {
        PlaneURLProtocolStub.install { request in
            #expect(request.method == "GET")
            return planeStub(
                """
                {"results":[{"id":"wi-existing","name":"Grabar intro",
                 "external_id":"framescript:project-uuid-1:task-1",
                 "external_source":"framescript"}],
                 "next_page_results":false}
                """
            )
        }

        let client = try makePlaneClient(workItemRoute: .workItems)
        let report = try await client.export(plan: makeExportPlan())

        #expect(
            report.outcomes == [
                .verified(taskExternalID: planeTaskExternalID, workItemID: "wi-existing")
            ]
        )
        #expect(report.ledger[planeTaskExternalID] == "wi-existing")
        #expect(report.warnings.isEmpty)
        #expect(PlaneURLProtocolStub.requests.count == 1)
    }

    @Test func exportCreatesOnceWhenFilterIsIgnoredAndSecondRunUsesLedger() async throws {
        let createdDetailPath = "/api/v1/workspaces/acme/projects/project-uuid-1/work-items/wi-new/"
        PlaneURLProtocolStub.install { request in
            switch (request.method ?? "", request.url?.planePath ?? "") {
            case ("GET", planeWorkItemsPath):
                // The server ignored external_id and returned an unrelated page.
                return planeStub(
                    """
                    {"results":[
                      {"id":"wi-existing","name":"Grabar intro"},
                      {"id":"wi-other","name":"Otra cosa"}
                    ],"next_page_results":false}
                    """
                )
            case ("POST", planeWorkItemsPath):
                return planeStub(createdWorkItemJSON(id: "wi-new"), status: 201)
            case ("GET", createdDetailPath):
                return planeStub(#"{"id":"wi-new","name":"Grabar intro"}"#)
            default:
                throw URLError(.badURL)
            }
        }

        let client = try makePlaneClient(workItemRoute: .workItems)
        let plan = makeExportPlan()

        let first = try await client.export(plan: plan)
        #expect(
            first.outcomes == [
                .created(taskExternalID: planeTaskExternalID, workItemID: "wi-new")
            ]
        )
        #expect(first.ledger[planeTaskExternalID] == "wi-new")
        #expect(first.warnings.count == 1)
        #expect(first.warnings.first?.kind == .possibleDuplicateByName)
        #expect(first.warnings.first?.candidates.map(\.id) == ["wi-existing"])
        #expect(PlaneURLProtocolStub.requests.filter { $0.method == "POST" }.count == 1)

        let second = try await client.export(plan: plan, ledger: first.ledger)
        #expect(
            second.outcomes == [
                .verified(taskExternalID: planeTaskExternalID, workItemID: "wi-new")
            ]
        )
        #expect(second.warnings.isEmpty)

        let requests = PlaneURLProtocolStub.requests
        #expect(requests.map(\.method) == ["GET", "POST", "GET"])
        #expect(requests.filter { $0.method == "POST" }.count == 1)
        #expect(requests.filter { $0.url?.planePath == planeWorkItemsPath && $0.method == "GET" }.count == 1)
        #expect(requests.last?.url?.planePath == createdDetailPath)
    }

    @Test func exportKeepsDeletedLedgerEntryWithoutRecreate() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(#"{"detail":"Work item not found"}"#, status: 404)
        }

        let client = try makePlaneClient(workItemRoute: .workItems)
        let plan = makeExportPlan()
        let first = try await client.export(
            plan: plan,
            ledger: ledger(workItemID: "wi-gone")
        )

        #expect(first.outcomes == [.deleted(taskExternalID: planeTaskExternalID)])
        #expect(first.workItemIDsByTaskExternalID.isEmpty)
        #expect(first.ledger[planeTaskExternalID] == "wi-gone")
        #expect(PlaneURLProtocolStub.requests.count == 1)

        let second = try await client.export(plan: plan, ledger: first.ledger)
        #expect(second.outcomes == [.deleted(taskExternalID: planeTaskExternalID)])
        #expect(PlaneURLProtocolStub.requests.count == 2)
    }

    @Test func exportRecreatesDeletedLedgerEntryWhenAllowed() async throws {
        let deletedDetailPath = "/api/v1/workspaces/acme/projects/project-uuid-1/work-items/wi-gone/"
        PlaneURLProtocolStub.install { request in
            switch (request.method ?? "", request.url?.planePath ?? "") {
            case ("GET", deletedDetailPath):
                return planeStub(#"{"detail":"Work item not found"}"#, status: 404)
            case ("POST", planeWorkItemsPath):
                return planeStub(createdWorkItemJSON(id: "wi-new"), status: 201)
            default:
                throw URLError(.badURL)
            }
        }

        let client = try makePlaneClient(workItemRoute: .workItems)
        let report = try await client.export(
            plan: makeExportPlan(),
            ledger: ledger(workItemID: "wi-gone"),
            policy: PlaneExportPolicy(recreateDeletedWorkItems: true)
        )

        #expect(
            report.outcomes == [
                .recreated(taskExternalID: planeTaskExternalID, workItemID: "wi-new")
            ]
        )
        #expect(report.ledger[planeTaskExternalID] == "wi-new")
        #expect(PlaneURLProtocolStub.requests.count == 2)
    }

    @Test func exportReportsTruncatedNames() async throws {
        PlaneURLProtocolStub.install { _ in
            planeStub(#"{"id":"wi-1","name":"Grabar intro"}"#)
        }

        let client = try makePlaneClient(workItemRoute: .workItems)
        let report = try await client.export(
            plan: makeExportPlan(title: String(repeating: "a", count: 300)),
            ledger: ledger(workItemID: "wi-1")
        )

        #expect(report.truncatedNameTaskExternalIDs == [planeTaskExternalID])
    }

    @Test func exportPropagatesCancellationInsteadOfRecordingFailure() async throws {
        PlaneURLProtocolStub.install { _ in
            throw URLError(.cancelled)
        }

        let client = try makePlaneClient(workItemRoute: .workItems)
        do {
            _ = try await client.export(plan: makeExportPlan())
            Issue.record("Expected cancellation")
        } catch let error as PlaneError {
            #expect(error == .cancelled)
        }
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
        let first = try await client.findWorkItem(byExternalId: planeTaskExternalID)
        let second = try await client.findWorkItem(byExternalId: planeTaskExternalID)

        #expect(first.workItem?.id == "wi-legacy")
        #expect(second.workItem?.id == "wi-legacy")

        let paths = PlaneURLProtocolStub.requests.compactMap { $0.url?.planePath }
        #expect(paths == [planeWorkItemsPath, planeIssuesPath, planeIssuesPath])
    }

    @Test func createWorkItemFallsBackToLegacyIssues() async throws {
        PlaneURLProtocolStub.install { request in
            switch request.url?.planePath ?? "" {
            case planeWorkItemsPath:
                return planeStub(#"{"error":"Not found"}"#, status: 404)
            case planeIssuesPath:
                return planeStub(#"{"id":"wi-legacy","name":"Grabar intro","sequence_id":7}"#, status: 201)
            default:
                throw URLError(.badURL)
            }
        }

        let client = try makePlaneClient(workItemRoute: .automatic)
        let draft = PlaneWorkItemDraft(
            name: "Grabar intro",
            descriptionHTML: "<p>Grabar</p>",
            externalID: planeTaskExternalID,
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
            _ = try await client.findWorkItem(byExternalId: planeTaskExternalID)
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
                    externalID: planeTaskExternalID,
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

    @Test func mapsRateLimitedWithRetryAfterAndMessage() async throws {
        let reset = Int(Date().timeIntervalSince1970) + 300
        PlaneURLProtocolStub.install { _ in
            planeStub(
                #"{"detail":"Rate limit exceeded"}"#,
                status: 429,
                headers: [
                    "Retry-After": "17",
                    "X-RateLimit-Reset": "\(reset)"
                ]
            )
        }

        let client = try makePlaneClient()
        do {
            _ = try await client.listProjects()
            Issue.record("Expected rateLimited")
        } catch let error as PlaneError {
            #expect(error == .rateLimited(retryAfter: 17, message: "Rate limit exceeded"))
        }
    }

    @Test func mapsRateLimitedFromResetHeader() async throws {
        let reset = Int(Date().timeIntervalSince1970) + 600
        PlaneURLProtocolStub.install { _ in
            planeStub(
                #"{"detail":"Slow down"}"#,
                status: 429,
                headers: ["X-RateLimit-Reset": "\(reset)"]
            )
        }

        let client = try makePlaneClient()
        do {
            _ = try await client.listProjects()
            Issue.record("Expected rateLimited")
        } catch let error as PlaneError {
            guard case let .rateLimited(retryAfter, message) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            let delay = try #require(retryAfter)
            #expect(delay > 500)
            #expect(delay <= 601)
            #expect(message == "Slow down")
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

    @Test func mapsCancellation() async throws {
        PlaneURLProtocolStub.install { _ in
            throw URLError(.cancelled)
        }

        let client = try makePlaneClient()
        do {
            _ = try await client.listProjects()
            Issue.record("Expected cancellation")
        } catch let error as PlaneError {
            #expect(error == .cancelled)
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
