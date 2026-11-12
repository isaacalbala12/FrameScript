import Foundation

/// Selects the work-item collection name used by the installed Plane version.
///
/// Plane's v1 docs now name the collection `work-items`, but older self-hosted
/// releases only expose `issues`. `automatic` tries `work-items` first and
/// falls back once on a `404`, then remembers the route that worked.
public enum PlaneWorkItemRoute: Sendable, Equatable {
    case workItems
    case issues
    case automatic
}

/// A small async client for the self-hosted Plane v1 REST API.
///
/// The caller supplies the base URL, workspace slug, project id and API key.
/// This type keeps them in memory for the lifetime of the client and never
/// writes them to disk; persistence belongs to the app (Keychain).
///
/// Every request uses the documented `X-API-Key` header and the
/// `/api/v1/workspaces/{slug}/projects/{project_id}/...` path layout.
public actor PlaneClient {
    public struct Configuration: Sendable, Equatable {
        /// Instance root, for example `https://plane.example.com`.
        /// A trailing `/api/v1` is accepted and normalized away.
        public var baseURL: URL
        public var workspaceSlug: String
        public var projectID: String
        public var apiKey: String
        public var workItemRoute: PlaneWorkItemRoute

        public init(
            baseURL: URL,
            workspaceSlug: String,
            projectID: String,
            apiKey: String,
            workItemRoute: PlaneWorkItemRoute = .automatic
        ) {
            self.baseURL = baseURL
            self.workspaceSlug = workspaceSlug
            self.projectID = projectID
            self.apiKey = apiKey
            self.workItemRoute = workItemRoute
        }
    }

    private static let pageSize = 100
    private static let maximumPages = 100

    private let baseURL: URL
    private let workspaceSlug: String
    private let projectID: String
    private let apiKey: String
    private let workItemRoute: PlaneWorkItemRoute
    private let transport: any PlaneHTTPTransport
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var resolvedWorkItemRoute: PlaneWorkItemRoute?

    /// Rate-limit information from the most recent response that reported it.
    /// Read it after a call to show remaining quota or a reset time in the UI.
    public private(set) var lastRateLimit: PlaneRateLimit?

    public init(
        configuration: Configuration,
        transport: any PlaneHTTPTransport = URLSessionPlaneHTTPTransport()
    ) throws {
        let normalizedBaseURL = try Self.normalizedBaseURL(configuration.baseURL)
        let slug = configuration.workspaceSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = configuration.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !slug.isEmpty else {
            throw PlaneError.invalidConfiguration("workspaceSlug must not be empty")
        }
        guard !project.isEmpty else {
            throw PlaneError.invalidConfiguration("projectID must not be empty")
        }
        guard !key.isEmpty else {
            throw PlaneError.invalidConfiguration("apiKey must not be empty")
        }

        self.baseURL = normalizedBaseURL
        self.workspaceSlug = slug
        self.projectID = project
        self.apiKey = key
        self.workItemRoute = configuration.workItemRoute
        self.transport = transport
    }

    // MARK: - Reads

    /// `GET /api/v1/workspaces/{workspace_slug}/projects/`
    public func listProjects() async throws -> [PlaneProject] {
        try await listAll(path: "workspaces/\(workspaceSlug)/projects/")
    }

    /// `GET /api/v1/workspaces/{workspace_slug}/projects/{project_id}/states/`
    public func listStates() async throws -> [PlaneState] {
        try await listAll(path: "\(projectPath)/states/")
    }

    /// `GET /api/v1/workspaces/{workspace_slug}/projects/{project_id}/labels/`
    public func listLabels() async throws -> [PlaneLabel] {
        try await listAll(path: "\(projectPath)/labels/")
    }

    /// Looks up an existing work item with ONE filtered list request.
    ///
    /// The documented v1 list row does not include `external_id`, and some
    /// self-hosted versions may ignore the filter. A match is accepted only
    /// when a row echoes the exact `external_id`, or when the response has
    /// exactly one result whose name equals `expectedName`. Anything else is
    /// reported as `.cannotVerify` so the caller does not create a duplicate.
    /// Pagination is never followed here.
    public func findWorkItem(
        byExternalId externalID: String,
        expectedName: String? = nil
    ) async throws -> PlaneWorkItemLookup {
        let identifier = externalID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return .notFound }

        return try await withWorkItemRoute { route in
            let queryItems = [
                URLQueryItem(name: "external_id", value: identifier),
                URLQueryItem(name: "external_source", value: PlaneExternalID.source),
                URLQueryItem(name: "per_page", value: String(Self.pageSize))
            ]
            let request = try self.makeRequest(
                method: "GET",
                path: self.workItemCollectionPath(route: route),
                queryItems: queryItems,
                cachePolicy: .reloadIgnoringLocalCacheData
            )
            let response = try await self.perform(request)
            let payload = try self.decodeList(PlaneWorkItem.self, from: response.data)
            return Self.lookup(
                in: payload.results,
                externalID: identifier,
                expectedName: expectedName,
                hasMorePages: payload.hasMore
            )
        }
    }

    /// `GET /api/v1/workspaces/{workspace_slug}/projects/{project_id}/work-items/{work_item_id}/`
    public func getWorkItem(id: String) async throws -> PlaneWorkItem {
        let identifier = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            throw PlaneError.invalidConfiguration("work item id must not be empty")
        }

        return try await withWorkItemRoute { route in
            let request = try self.makeRequest(
                method: "GET",
                path: self.workItemDetailPath(route: route, id: identifier),
                cachePolicy: .reloadIgnoringLocalCacheData
            )
            let response = try await self.perform(request)
            return try self.decode(PlaneWorkItem.self, from: response.data)
        }
    }

    // MARK: - Writes

    /// `POST /api/v1/workspaces/{workspace_slug}/projects/{project_id}/work-items/`
    ///
    /// Plane limits `name` to 255 characters. The name is grapheme-safely
    /// shortened before encoding if a caller supplies a longer draft.
    public func createWorkItem(_ draft: PlaneWorkItemDraft) async throws -> PlaneWorkItem {
        var sanitizedDraft = draft
        sanitizedDraft.name = PlaneWorkItemName.truncated(draft.name)
        let body = try encode(sanitizedDraft)

        return try await withWorkItemRoute { route in
            let request = try self.makeRequest(
                method: "POST",
                path: self.workItemCollectionPath(route: route),
                body: body
            )
            let response = try await self.perform(request)
            return try self.decode(PlaneWorkItem.self, from: response.data)
        }
    }

    // MARK: - Export

    /// Creates or verifies one Plane work item per plan entry.
    ///
    /// The ledger is caller-owned; this method returns an updated copy. A
    /// ledger id is verified with a fresh `GET`. When there is no ledger entry,
    /// exactly one filtered list page is checked before creating. A
    /// `cannotVerify` outcome never creates anything. Per-task failures are
    /// reported as `.failed`; cancellation aborts the whole export.
    public func export(
        plan: PlaneExportPlan,
        ledger: PlaneExportLedger = PlaneExportLedger(),
        policy: PlaneExportPolicy = PlaneExportPolicy()
    ) async throws -> PlaneExportReport {
        var updatedLedger = ledger
        var outcomes: [PlaneExportOutcome] = []

        for entry in plan.entries {
            if Task.isCancelled {
                throw PlaneError.cancelled
            }

            let externalID = entry.draft.externalID
            do {
                if let ledgerID = updatedLedger[externalID] {
                    do {
                        _ = try await getWorkItem(id: ledgerID)
                        outcomes.append(.verified(taskExternalID: externalID, workItemID: ledgerID))
                    } catch let error as PlaneError where error.isNotFound {
                        if policy.recreateDeletedWorkItems {
                            let created = try await createWorkItem(entry.draft)
                            updatedLedger.record(workItemID: created.id, forTaskExternalID: externalID)
                            outcomes.append(.recreated(taskExternalID: externalID, workItemID: created.id))
                        } else {
                            // Keep the stale id. Removing it would make the next
                            // export take the "never exported" path and create
                            // without the caller explicitly allowing recreation.
                            outcomes.append(.deleted(taskExternalID: externalID))
                        }
                    }
                } else {
                    let lookup = try await findWorkItem(
                        byExternalId: externalID,
                        expectedName: entry.draft.name
                    )
                    switch lookup {
                    case .found(let workItem):
                        updatedLedger.record(workItemID: workItem.id, forTaskExternalID: externalID)
                        outcomes.append(.verified(taskExternalID: externalID, workItemID: workItem.id))
                    case .notFound:
                        let created = try await createWorkItem(entry.draft)
                        updatedLedger.record(workItemID: created.id, forTaskExternalID: externalID)
                        outcomes.append(.created(taskExternalID: externalID, workItemID: created.id))
                    case .cannotVerify(let candidates):
                        outcomes.append(
                            .cannotVerify(taskExternalID: externalID, candidates: candidates)
                        )
                    }
                }
            } catch PlaneError.cancelled {
                throw PlaneError.cancelled
            } catch let error as PlaneError {
                outcomes.append(.failed(taskExternalID: externalID, error: error))
            }
        }

        let truncatedIDs = plan.entries
            .filter(\.wasNameTruncated)
            .map(\.draft.externalID)
        return PlaneExportReport(
            outcomes: outcomes,
            ledger: updatedLedger,
            truncatedNameTaskExternalIDs: truncatedIDs
        )
    }

    // MARK: - Requests

    private var projectPath: String {
        "workspaces/\(workspaceSlug)/projects/\(projectID)"
    }

    private func workItemCollectionPath(route: PlaneWorkItemRoute) -> String {
        let collection: String
        switch route {
        case .issues: collection = "issues"
        case .workItems, .automatic: collection = "work-items"
        }
        return "\(projectPath)/\(collection)/"
    }

    private func workItemDetailPath(route: PlaneWorkItemRoute, id: String) -> String {
        "\(workItemCollectionPath(route: route))\(id)/"
    }

    private func withWorkItemRoute<Value: Sendable>(
        _ operation: (PlaneWorkItemRoute) async throws -> Value
    ) async throws -> Value {
        switch workItemRoute {
        case .workItems:
            return try await operation(.workItems)
        case .issues:
            return try await operation(.issues)
        case .automatic:
            if let resolved = resolvedWorkItemRoute {
                return try await operation(resolved)
            }
            do {
                let value = try await operation(.workItems)
                resolvedWorkItemRoute = .workItems
                return value
            } catch let error as PlaneError where error.isNotFound {
                let value = try await operation(.issues)
                resolvedWorkItemRoute = .issues
                return value
            }
        }
    }

    private func listAll<Item: Decodable & Sendable>(path: String) async throws -> [Item] {
        var collected: [Item] = []
        var cursor: String?
        var pageIndex = 0

        while true {
            guard pageIndex < Self.maximumPages else {
                throw PlaneError.paginationLimitExceeded
            }

            var queryItems = [URLQueryItem(name: "per_page", value: String(Self.pageSize))]
            if let cursor {
                queryItems.append(URLQueryItem(name: "cursor", value: cursor))
            }

            let request = try makeRequest(method: "GET", path: path, queryItems: queryItems)
            let response = try await perform(request)
            let payload = try decodeList(Item.self, from: response.data)

            guard let next = payload.next else {
                collected.append(contentsOf: payload.results)
                return collected
            }
            guard next != cursor else {
                // A repeated cursor means the server ignored it. Stop rather
                // than appending a duplicate page or looping forever.
                return collected
            }

            collected.append(contentsOf: payload.results)
            cursor = next
            pageIndex += 1
        }
    }

    private func makeRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw PlaneError.invalidConfiguration("baseURL could not be decomposed")
        }

        var basePath = components.path
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        components.path = basePath + "/api/v1/" + path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw PlaneError.invalidConfiguration("Could not build a valid Plane request URL")
        }

        var request = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> PlaneHTTPResponse {
        let response: PlaneHTTPResponse
        do {
            response = try await transport.perform(request)
        } catch is CancellationError {
            throw PlaneError.cancelled
        } catch let error as PlaneError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled {
                throw PlaneError.cancelled
            }
            throw PlaneError.network(code: error.errorCode, message: error.localizedDescription)
        } catch {
            throw PlaneError.network(code: NSURLErrorUnknown, message: error.localizedDescription)
        }

        updateRateLimit(from: response)

        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(for: response)
        }
        return response
    }

    private func updateRateLimit(from response: PlaneHTTPResponse) {
        let remaining = response.header("X-RateLimit-Remaining").flatMap {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let resetAt = response.header("X-RateLimit-Reset").flatMap {
            TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }.map { Date(timeIntervalSince1970: $0) }

        if remaining != nil || resetAt != nil {
            lastRateLimit = PlaneRateLimit(remaining: remaining, resetAt: resetAt)
        }
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw PlaneError.encoding(String(describing: error))
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw PlaneError.decoding(String(describing: error))
        }
    }

    /// Accepts the documented `results` envelope and, defensively, a bare array.
    private func decodeList<Item: Decodable>(
        _ type: Item.Type,
        from data: Data
    ) throws -> PlaneListPayload<Item> {
        if let page = try? decoder.decode(PlanePage<Item>.self, from: data) {
            return PlaneListPayload(
                results: page.results,
                nextCursor: page.nextCursor,
                nextPageResults: page.nextPageResults
            )
        }

        do {
            let results = try decoder.decode([Item].self, from: data)
            return PlaneListPayload(results: results, nextCursor: nil, nextPageResults: false)
        } catch {
            throw PlaneError.decoding(String(describing: error))
        }
    }

    // MARK: - Helpers

    private static func lookup(
        in results: [PlaneWorkItem],
        externalID: String,
        expectedName: String?,
        hasMorePages: Bool
    ) -> PlaneWorkItemLookup {
        if let exact = results.first(where: { $0.externalID == externalID }) {
            return .found(exact)
        }

        if let expectedName {
            let expected = PlaneWorkItemName.truncated(
                expectedName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let nameMatches = results.filter {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == expected
            }
            if nameMatches.count == 1, let only = nameMatches.first {
                return .found(only)
            }
        }

        if results.isEmpty && !hasMorePages {
            return .notFound
        }
        return .cannotVerify(candidates: results)
    }

    private static func normalizedBaseURL(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty
        else {
            throw PlaneError.invalidConfiguration("baseURL must be an absolute http(s) URL")
        }

        components.scheme = scheme
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        var path = components.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/" {
            path = ""
        }
        for suffix in ["/api/v1"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
            break
        }
        components.path = path

        guard let normalized = components.url else {
            throw PlaneError.invalidConfiguration("baseURL is not a valid URL")
        }
        return normalized
    }

    private static func error(for response: PlaneHTTPResponse) -> PlaneError {
        let message = errorMessage(from: response.data)
        switch response.statusCode {
        case 401:
            return .unauthorized(message: message)
        case 403:
            return .forbidden(message: message)
        case 404:
            return .notFound(message: message)
        case 429:
            let retryAfter = PlaneRetryAfter.parse(response.header("Retry-After"))
                ?? PlaneRetryAfter.fromResetHeader(response.header("X-RateLimit-Reset"))
            return .rateLimited(retryAfter: retryAfter, message: message)
        case 400..<500:
            return .requestFailed(statusCode: response.statusCode, message: message)
        default:
            return .server(statusCode: response.statusCode, message: message)
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        if let envelope = try? JSONDecoder().decode(PlaneErrorEnvelope.self, from: data) {
            for candidate in [envelope.detail, envelope.error, envelope.message, envelope.code] {
                if let candidate, !candidate.isEmpty {
                    return candidate
                }
            }
        }

        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

private struct PlaneListPayload<Item> {
    let results: [Item]
    let nextCursor: String?
    let nextPageResults: Bool?

    var next: String? {
        guard let cursor = nextCursor?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cursor.isEmpty,
              nextPageResults != false
        else {
            return nil
        }
        return cursor
    }

    var hasMore: Bool {
        next != nil
    }
}

private struct PlanePage<Item: Decodable>: Decodable {
    let results: [Item]
    let nextCursor: String?
    let nextPageResults: Bool?

    private enum CodingKeys: String, CodingKey {
        case results
        case nextCursor = "next_cursor"
        case nextPageResults = "next_page_results"
    }
}

private struct PlaneErrorEnvelope: Decodable {
    let error: String?
    let detail: String?
    let message: String?
    let code: String?
}
