import Foundation
import FrameScriptCore
import Observation
import OSLog

// MARK: - Library folders

/// A user-chosen library folder persisted with a security-scoped bookmark.
struct BoardLibraryFolder: Identifiable, Codable, Hashable {
    var id: UUID
    var bookmarkData: Data
    var displayName: String
    var lastKnownPath: String

    init(
        id: UUID = UUID(),
        bookmarkData: Data,
        displayName: String,
        lastKnownPath: String
    ) {
        self.id = id
        self.bookmarkData = bookmarkData
        self.displayName = displayName
        self.lastKnownPath = lastKnownPath
    }
}

enum BoardLayout: String, CaseIterable, Identifiable {
    case kanban
    case list

    var id: String { rawValue }
}

/// Result of a classification write started from the board.
enum BoardWriteOutcome: Equatable {
    case saved(BoardProjectSummary)
    /// The file changed since the board indexed it; the board reloaded it and
    /// deliberately left the external version untouched.
    case conflict(BoardProjectSummary?)
    case failed(String)
}

// MARK: - Board store

/// Owns the scanned project index, the user's library folders and the board's
/// view state. Every file-system dependency is injectable so app tests never
/// touch the user's real library, recents or preferences.
@MainActor
@Observable
final class BoardStore {
    typealias BookmarkCreator = @MainActor @Sendable (URL) throws -> Data
    typealias BookmarkResolver = @MainActor @Sendable (Data, inout Bool) throws -> URL

    static let foldersKey = "FrameScript.board.folders.v1"
    static let shared = BoardStore()

    private(set) var folders: [BoardLibraryFolder] = []
    private(set) var index = BoardLibraryIndex()
    private(set) var lastScanStats: BoardScanStats = .empty
    private(set) var lastScanDate: Date?
    private(set) var isScanning = false
    private(set) var scanFailure: String?
    private(set) var folderFailure: String?

    var filter = BoardFilter()
    var grouping: BoardGrouping = .status
    var sort = BoardSort()
    var layout: BoardLayout = .kanban
    var selectedProjectID: String?
    var showsWarnings = false

    private let userDefaults: UserDefaults
    private let foldersStorageKey: String
    private let bookmarkCreator: BookmarkCreator
    private let bookmarkResolver: BookmarkResolver
    private let securityScope: SecurityScopedResourceAccess
    private let scanner: BoardLibraryScanner
    private let now: @MainActor () -> Date
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "FrameScript",
        category: "Board"
    )
    private var didLoadFolders = false

    init(
        userDefaults: UserDefaults = .standard,
        foldersStorageKey: String = BoardStore.foldersKey,
        bookmarkCreator: @escaping BookmarkCreator = { url in
            try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        },
        bookmarkResolver: @escaping BookmarkResolver = { data, isStale in
            try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        },
        securityScope: SecurityScopedResourceAccess = .live,
        scanner: BoardLibraryScanner = BoardLibraryScanner(),
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.foldersStorageKey = foldersStorageKey
        self.bookmarkCreator = bookmarkCreator
        self.bookmarkResolver = bookmarkResolver
        self.securityScope = securityScope
        self.scanner = scanner
        self.now = now
    }

    // MARK: Folders

    func loadFolders() {
        guard !didLoadFolders else { return }
        didLoadFolders = true
        guard let data = userDefaults.data(forKey: foldersStorageKey) else { return }
        do {
            folders = try JSONDecoder().decode([BoardLibraryFolder].self, from: data)
        } catch {
            // Keep the undecodable blob instead of overwriting it; the user can
            // still re-add folders and the next save replaces it deliberately.
            folderFailure = "board.error.folders"
            logger.error("Board folders could not be decoded: \(error.localizedDescription, privacy: .private)")
        }
    }

    @discardableResult
    func addFolder(at url: URL) throws -> Bool {
        let standardized = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path) else {
            throw BoardFolderError.missingFolder
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw BoardFolderError.notAFolder
        }
        if resolvedFolders().contains(where: { $0.url?.standardizedFileURL.path == standardized.path }) {
            return false
        }
        if folders.contains(where: { $0.lastKnownPath == standardized.path }) {
            return false
        }

        let data = try bookmarkCreator(standardized)
        folders.append(
            BoardLibraryFolder(
                bookmarkData: data,
                displayName: displayName(for: standardized),
                lastKnownPath: standardized.path
            )
        )
        persistFolders()
        folderFailure = nil
        return true
    }

    func removeFolder(id: UUID) {
        folders.removeAll { $0.id == id }
        persistFolders()
    }

    func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    struct ResolvedFolder {
        let folder: BoardLibraryFolder
        let url: URL?
    }

    func resolvedFolders() -> [ResolvedFolder] {
        folders.map { folder in
            var stale = false
            do {
                let url = try bookmarkResolver(folder.bookmarkData, &stale).standardizedFileURL
                return ResolvedFolder(folder: folder, url: url)
            } catch {
                // Fall back to the last known path. Non-sandboxed builds can
                // still read it; sandboxed builds will report the folder as
                // missing and the user can re-add it.
                return ResolvedFolder(
                    folder: folder,
                    url: URL(fileURLWithPath: folder.lastKnownPath)
                )
            }
        }
    }

    /// Recreates stale bookmarks once per scan instead of mutating state while
    /// a view is rendering the folder list.
    private func refreshFolderBookmarksIfNeeded() {
        var changed = false
        for index in folders.indices {
            var stale = false
            do {
                let url = try bookmarkResolver(folders[index].bookmarkData, &stale)
                guard stale, let data = try? bookmarkCreator(url) else { continue }
                folders[index].bookmarkData = data
                folders[index].lastKnownPath = url.path
                changed = true
            } catch {
                continue
            }
        }
        if changed { persistFolders() }
    }

    private func persistFolders() {
        do {
            let data = try JSONEncoder().encode(folders)
            userDefaults.set(data, forKey: foldersStorageKey)
        } catch {
            folderFailure = "board.error.folders"
            logger.error("Board folders could not be saved: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: Scanning

    /// Scans folders and recent files off the main actor. Recents may live
    /// outside every chosen folder and are scanned read-only.
    func refresh(appState: AppState) async {
        refreshFolderBookmarksIfNeeded()
        let folderURLs = resolvedFolders().compactMap(\.url)
        let recentURLs = appState.recentProjectStore.entries.compactMap { entry in
            try? appState.recentProjectStore.validatedURL(for: entry)
        }
        await refresh(
            folderURLs: folderURLs,
            extraFileURLs: recentURLs,
            securityScope: appState.securityScope
        )
    }

    func refresh(
        folderURLs: [URL],
        extraFileURLs: [URL],
        securityScope: SecurityScopedResourceAccess? = nil
    ) async {
        loadFolders()
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let scope = securityScope ?? self.securityScope
        var started: [URL] = []
        for url in folderURLs + extraFileURLs where scope.start(url) {
            started.append(url)
        }
        defer { for url in started { scope.stop(url) } }

        let request = BoardScanRequest(
            folderURLs: folderURLs,
            extraFileURLs: extraFileURLs,
            previous: index
        )
        let scanner = self.scanner
        let result = await Task.detached(priority: .userInitiated) {
            scanner.scan(request)
        }.value

        index = displayingTopics(in: result.index)
        lastScanStats = result.stats
        lastScanDate = now()
        scanFailure = nil
        folderFailure = nil
        if let selectedProjectID, index.summaries.allSatisfy({ $0.id != selectedProjectID }) {
            self.selectedProjectID = nil
        }
    }

    /// Re-reads a single file after a write or an external-change conflict.
    func reloadFile(at url: URL) {
        let scanned = securityScope.withAccess(to: url) {
            scanner.scan(
                BoardScanRequest(folderURLs: [], extraFileURLs: [url], previous: BoardLibraryIndex())
            )
        }
        let result = (index: displayingTopics(in: scanned.index), stats: scanned.stats)
        if let summary = result.index.summary(forFileAt: url) {
            index = index.replacing(summary)
        } else {
            index = index.removingFile(at: url)
        }
        let path = url.standardizedFileURL.path
        let remaining = index.warnings.filter { $0.url.standardizedFileURL.path != path }
        index = BoardLibraryIndex(
            summaries: index.summaries,
            warnings: remaining + result.index.warnings
        )
    }

    // MARK: Query

    var summaries: [BoardProjectSummary] {
        index.summaries
    }

    var warnings: [BoardScanWarning] {
        index.warnings
    }

    func summary(id: String?) -> BoardProjectSummary? {
        guard let id else { return nil }
        return index.summaries.first { $0.id == id }
    }

    var selectedSummary: BoardProjectSummary? {
        summary(id: selectedProjectID)
    }

    var groups: [BoardGroup] {
        BoardQuery.groups(
            summaries: index.summaries,
            filter: filter,
            grouping: layout == .kanban ? .status : grouping,
            sort: sort
        )
    }

    func toggle(status: FrameScriptDocument.ProductionStatus) {
        if filter.statuses.contains(status) {
            filter.statuses.remove(status)
        } else {
            filter.statuses.insert(status)
        }
    }

    func toggle(topic: String) {
        if filter.topics.contains(where: { BoardCatalog.matches($0, topic) }) {
            filter.topics = filter.topics.filter { !BoardCatalog.matches($0, topic) }
        } else {
            filter.topics.insert(topic)
        }
    }

    func toggle(videoType: String) {
        if filter.videoTypes.contains(where: { BoardCatalog.matches($0, videoType) }) {
            filter.videoTypes = filter.videoTypes.filter { !BoardCatalog.matches($0, videoType) }
        } else {
            filter.videoTypes.insert(videoType)
        }
    }

    func clearFilters() {
        filter = BoardFilter()
    }

    /// Replaces the raw `topic` (which may contain escaleta notes) with the
    /// value the board should show.
    private func displayingTopics(in index: BoardLibraryIndex) -> BoardLibraryIndex {
        BoardLibraryIndex(
            summaries: index.summaries.map { summary in
                let display = BoardProjectTopic.display(from: summary.topic)
                guard display != summary.topic else { return summary }
                return summary.applying(
                    BoardProjectEdit(topic: display),
                    fingerprint: summary.fingerprint
                )
            },
            warnings: index.warnings
        )
    }

    // MARK: Writes

    /// Applies a classification edit using the app's safe write path.
    ///
    /// - When the file is the project currently open in FrameScript, the edit
    ///   goes through `AppState.saveProject()`, so the existing external-change
    ///   prompt, backups and file tracking all apply.
    /// - Otherwise the document is decoded, the indexed content hash is checked
    ///   against disk, a backup is written, and the Core codec performs the same
    ///   atomic replace the app uses. A mismatch is reported as `.conflict`
    ///   instead of overwriting another app's version.
    func apply(
        _ edit: BoardProjectEdit,
        to summary: BoardProjectSummary,
        appState: AppState
    ) async -> BoardWriteOutcome {
        guard !edit.isEmpty else { return .saved(summary) }
        let url = summary.fileURL.standardizedFileURL
        let openURL = appState.projectStore.currentFileURL?.standardizedFileURL

        if openURL == url,
           appState.projectStore.project.id == summary.projectID {
            return applyToOpenProject(edit, summary: summary, appState: appState)
        }

        return applyToFile(edit, summary: summary, appState: appState)
    }

    private func applyToOpenProject(
        _ edit: BoardProjectEdit,
        summary: BoardProjectSummary,
        appState: AppState
    ) -> BoardWriteOutcome {
        let project = appState.project
        if let topic = edit.topic {
            project.topic = BoardProjectTopic.merging(topic, into: project.topic)
        }
        if let videoType = edit.videoType {
            project.videoType = videoType.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let status = edit.productionStatus {
            project.productionStatus = AppProductionStatus(rawValue: status.rawValue) ?? .idea
        }
        if edit.clearsTargetDate {
            project.targetDate = nil
        } else if let targetDate = edit.targetDate {
            project.targetDate = targetDate
        }
        if edit.clearsPublishDate {
            project.publishDate = nil
        } else if let publishDate = edit.publishDate {
            project.publishDate = publishDate
        }
        appState.projectStore.markProjectDirty()
        guard appState.saveProject() else {
            reloadFile(at: summary.fileURL)
            return .failed("board.error.write")
        }
        reloadFile(at: summary.fileURL)
        if let refreshed = index.summary(forFileAt: summary.fileURL) {
            selectedProjectID = refreshed.id
            return edit.isSatisfied(by: refreshed) ? .saved(refreshed) : .conflict(refreshed)
        }
        return .failed("board.error.write")
    }

    private func applyToFile(
        _ edit: BoardProjectEdit,
        summary: BoardProjectSummary,
        appState: AppState
    ) -> BoardWriteOutcome {
        let url = summary.fileURL
        do {
            try appState.securityScope.withAccess(to: url) {
                let data = try Data(contentsOf: url)
                let diskHash = BoardFileFingerprint.hash(of: data)
                guard diskHash == summary.fingerprint.contentHash else {
                    throw BoardWriteError.changedExternally
                }
                var document = try FrameScriptDocumentCodec.decode(data)
                // Map the untouched document first so the pre-overwrite backup
                // matches the Backups feature exactly.
                let currentProject = try document.makeProject()
                var documentEdit = edit
                if let topic = edit.topic {
                    documentEdit.topic = BoardProjectTopic.merging(topic, into: document.project.topic)
                }
                BoardDocumentEditor.apply(documentEdit, to: &document)
                BackupsCenter.backUpBeforeOverwrite(project: currentProject, fileURL: url)
                try FrameScriptDocumentCodec.write(document, to: url)
            }
            reloadFile(at: url)
            if let refreshed = index.summary(forFileAt: url) {
                selectedProjectID = refreshed.id
                return edit.isSatisfied(by: refreshed) ? .saved(refreshed) : .conflict(refreshed)
            }
            return .failed("board.error.write")
        } catch BoardWriteError.changedExternally {
            reloadFile(at: url)
            return .conflict(index.summary(forFileAt: url))
        } catch {
            logger.error("Board write failed: \(error.localizedDescription, privacy: .private)")
            reloadFile(at: url)
            return .failed("board.error.write")
        }
    }

    // MARK: Plane plan

    func planePlan(
        for summary: BoardProjectSummary,
        appState: AppState
    ) -> PlaneExportPlan {
        let labels = pendingLabels(appState: appState)
        let tasks: [BoardPendingTask]
        if appState.projectStore.currentFileURL?.standardizedFileURL == summary.fileURL.standardizedFileURL,
           appState.projectStore.project.id == summary.projectID {
            let document = FrameScriptDocument(project: appState.project)
            tasks = BoardPendingTaskDeriver().pendingTasks(for: document.project, labels: labels)
        } else if let document = try? FrameScriptDocumentCodec.read(from: summary.fileURL) {
            tasks = BoardPendingTaskDeriver().pendingTasks(for: document.project, labels: labels)
        } else {
            tasks = summary.pendingTasks
        }
        let dueDate = BoardPlaneDate.make(from: summary.targetDate)
        return PlaneExportPlan(
            tasks: tasks.map {
                $0.planeTask(
                    projectID: summary.projectID.uuidString,
                    projectTitle: summary.title,
                    dueDate: dueDate
                )
            },
            labels: PlaneExportLabels(
                scene: appState.localized("board.plane.scene"),
                project: appState.localized("board.plane.project"),
                kindNames: [
                    .grabar: appState.localized("board.kind.grabar"),
                    .conseguirBroll: appState.localized("board.kind.conseguirBroll"),
                    .editar: appState.localized("board.kind.editar"),
                    .investigar: appState.localized("board.kind.investigar"),
                    .manual: appState.localized("board.kind.manual")
                ]
            )
        )
    }

    func planeExportLabels(appState: AppState) -> PlaneExportLabels {
        PlaneExportLabels(
            scene: appState.localized("board.plane.scene"),
            project: appState.localized("board.plane.project"),
            kindNames: [
                .grabar: appState.localized("board.kind.grabar"),
                .conseguirBroll: appState.localized("board.kind.conseguirBroll"),
                .editar: appState.localized("board.kind.editar"),
                .investigar: appState.localized("board.kind.investigar"),
                .manual: appState.localized("board.kind.manual")
            ]
        )
    }

    func pendingLabels(appState: AppState) -> BoardPendingLabels {
        BoardPendingLabels(
            record: appState.localized("board.kind.grabar"),
            bRoll: appState.localized("board.kind.conseguirBroll"),
            edit: appState.localized("board.kind.editar"),
            research: appState.localized("board.kind.investigar"),
            manual: appState.localized("board.kind.manual")
        )
    }
}

enum BoardFolderError: Error, Equatable {
    case missingFolder
    case notAFolder
}

private enum BoardWriteError: Error {
    case changedExternally
}

// MARK: - Catalog

/// Editable game/topic and video-type vocabulary, persisted as an app
/// preference (never in project files).
@MainActor
@Observable
final class BoardCatalogStore {
    static let storageKey = "FrameScript.board.catalog.v1"
    static let shared = BoardCatalogStore()

    var catalog: BoardCatalog {
        didSet { save() }
    }

    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = BoardCatalogStore.storageKey
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(BoardCatalog.self, from: data) {
            self.catalog = decoded
        } else {
            self.catalog = .seeded
        }
    }

    func resetToSeeds() {
        catalog = .seeded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        userDefaults.set(data, forKey: storageKey)
    }
}

// MARK: - Plane settings

struct PlaneSettings: Codable, Equatable {
    var baseURL: String = ""
    var workspaceSlug: String = ""
    var projectID: String = ""

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !workspaceSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func configuration(apiKey: String) throws -> PlaneClient.Configuration {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw PlaneError.invalidConfiguration("The base URL is not a valid URL.")
        }
        return PlaneClient.Configuration(
            baseURL: url,
            workspaceSlug: workspaceSlug.trimmingCharacters(in: .whitespacesAndNewlines),
            projectID: projectID.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

/// Plane connection settings. The base URL, workspace slug and project id are
/// always supplied by the user; no URL or project id ships in the app. The API
/// token lives only in the Keychain.
@MainActor
@Observable
final class PlaneSettingsStore {
    typealias TokenReader = @MainActor () throws -> String?
    typealias TokenWriter = @MainActor (String) throws -> Void
    typealias TokenDeleter = @MainActor () throws -> Void

    static let storageKey = "FrameScript.plane.settings.v1"
    static let tokenAccount = "plane.apiKey"
    static let shared = PlaneSettingsStore()

    var settings: PlaneSettings {
        didSet { save() }
    }

    private(set) var hasStoredToken = false
    private(set) var tokenError: String?

    private let userDefaults: UserDefaults
    private let storageKey: String
    private let readToken: TokenReader
    private let writeToken: TokenWriter
    private let deleteToken: TokenDeleter

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = PlaneSettingsStore.storageKey,
        readToken: @escaping TokenReader = {
            try KeychainStore.readAPIKey(account: PlaneSettingsStore.tokenAccount)
        },
        writeToken: @escaping TokenWriter = { token in
            try KeychainStore.saveAPIKey(token, account: PlaneSettingsStore.tokenAccount)
        },
        deleteToken: @escaping TokenDeleter = {
            try KeychainStore.deleteAPIKey(account: PlaneSettingsStore.tokenAccount)
        }
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.readToken = readToken
        self.writeToken = writeToken
        self.deleteToken = deleteToken
        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(PlaneSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = PlaneSettings()
        }
        refreshTokenStatus()
    }

    func refreshTokenStatus() {
        do {
            hasStoredToken = (try readToken())?.isEmpty == false
            tokenError = nil
        } catch {
            hasStoredToken = false
            tokenError = "board.settings.plane.tokenError"
        }
    }

    func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try writeToken(trimmed)
        refreshTokenStatus()
    }

    func deleteStoredToken() throws {
        try deleteToken()
        refreshTokenStatus()
    }

    func tokenForExport() throws -> String {
        guard let token = try readToken()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw PlaneError.invalidConfiguration("The Plane token is missing.")
        }
        return token
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        userDefaults.set(data, forKey: storageKey)
    }
}

/// Per-project Plane ledger so re-exporting verifies existing work items
/// instead of creating duplicates. Stored as an app preference; never in the
/// `.fscr` file and never in the Keychain.
struct BoardPlaneLedgerStore {
    static let storageKey = "FrameScript.plane.ledger.v1"
    private let userDefaults: UserDefaults
    private let storageKey: String

    init(userDefaults: UserDefaults = .standard, storageKey: String = BoardPlaneLedgerStore.storageKey) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    func ledger(for projectID: UUID) -> PlaneExportLedger {
        guard let data = userDefaults.data(forKey: key(for: projectID)),
              let ledger = try? JSONDecoder().decode(PlaneExportLedger.self, from: data) else {
            return PlaneExportLedger()
        }
        return ledger
    }

    func save(_ ledger: PlaneExportLedger, for projectID: UUID) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        userDefaults.set(data, forKey: key(for: projectID))
    }

    private func key(for projectID: UUID) -> String {
        "\(storageKey).\(projectID.uuidString)"
    }
}

/// Runs one explicit Plane export. The transport factory is injectable so tests
/// can prove the flow without any network access.
struct BoardPlaneExporter {
    var transportFactory: @Sendable () -> any PlaneHTTPTransport = {
        URLSessionPlaneHTTPTransport()
    }

    func export(
        plan: PlaneExportPlan,
        configuration: PlaneClient.Configuration,
        ledger: PlaneExportLedger
    ) async throws -> PlaneExportReport {
        let client = try PlaneClient(
            configuration: configuration,
            transport: transportFactory()
        )
        return try await client.export(plan: plan, ledger: ledger)
    }
}
