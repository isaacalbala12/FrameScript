import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

/// Plane export tests use a fake HTTP transport. Nothing here can reach a real
/// server, and the Keychain is replaced by the harness fake.
@MainActor
final class BoardPlaneExportTests: XCTestCase {
    private var harness: BoardTestHarness!

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try BoardTestHarness()
        let harness = harness!
        addTeardownBlock { harness.tearDown() }
    }

    func testExportOnlyRunsAfterTheExplicitCallAndStoresTheLedger() async throws {
        try await harness.prepareSampleBoard()
        let summary = try XCTUnwrap(
            harness.board.summaries.first { $0.title.contains("Análisis de la actualización") }
        )
        let plan = await harness.board.planePlan(for: summary, appState: harness.appState)
        XCTAssertFalse(plan.entries.isEmpty)

        let transport = BoardFakePlaneTransport { request in
            if request.httpMethod == "GET" {
                return PlaneHTTPResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    data: Data(#"{"results":[]}"#.utf8)
                )
            }
            if request.httpMethod == "POST" {
                return PlaneHTTPResponse(
                    statusCode: 201,
                    headers: ["Content-Type": "application/json"],
                    data: Data(#"{"id":"plane-123","name":"Creado"}"#.utf8)
                )
            }
            return PlaneHTTPResponse(statusCode: 500, headers: [:], data: Data())
        }
        let exporter = BoardPlaneExporter(transportFactory: { transport })
        let configuration = PlaneClient.Configuration(
            baseURL: URL(string: "https://plane.example.test")!,
            workspaceSlug: "mi-workspace",
            projectID: "project-id",
            apiKey: "token-sintetico"
        )

        XCTAssertEqual(transport.requestCount, 0, "Previewing must never touch the network")

        let report = try await exporter.export(
            plan: plan,
            configuration: configuration,
            ledger: harness.ledger.ledger(for: summary.projectID)
        )

        XCTAssertEqual(transport.requestCount, plan.entries.count * 2)
        XCTAssertEqual(
            report.outcomes.filter {
                if case .created = $0 { true } else { false }
            }.count,
            plan.entries.count
        )
        XCTAssertTrue(report.outcomes.allSatisfy { $0.workItemID == "plane-123" })

        harness.ledger.save(report.ledger, for: summary.projectID)
        XCTAssertEqual(
            harness.ledger.ledger(for: summary.projectID).workItemIDsByTaskExternalID.count,
            plan.entries.count
        )
    }

    func testMissingTokenIsReportedBeforeCreatingARequest() async throws {
        try await harness.prepareSampleBoard()
        let summary = try XCTUnwrap(
            harness.board.summaries.first { $0.title.contains("Análisis de la actualización") }
        )
        let plan = await harness.board.planePlan(for: summary, appState: harness.appState)

        let transport = BoardFakePlaneTransport { _ in
            PlaneHTTPResponse(statusCode: 500, headers: [:], data: Data())
        }
        let exporter = BoardPlaneExporter(transportFactory: { transport })

        do {
            _ = try harness.plane.tokenForExport()
            XCTFail("Expected a missing-token error")
        } catch {
            XCTAssertEqual(transport.requestCount, 0)
        }

        XCTAssertFalse(plan.entries.isEmpty)
        XCTAssertEqual(transport.requestCount, 0)
        _ = exporter
    }
}

/// Records every request and answers through a synchronous handler. The handler
/// never reaches the network.
final class BoardFakePlaneTransport: PlaneHTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> PlaneHTTPResponse

    private let lock = NSLock()
    private let handler: Handler
    private var requests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    var recordedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func perform(_ request: URLRequest) async throws -> PlaneHTTPResponse {
        append(request)
        return try handler(request)
    }

    private func append(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
}
