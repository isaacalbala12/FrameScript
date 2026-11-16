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
    /// Snapshot tests set this to false so opening the view never starts a scan
    /// that races the deterministic fixture (NEW-4/VW8).
    var scansOnAppear = true

    let userDefaults: UserDefaults
    private let foldersStorageKey: String
    private let bookmarkCreator: BookmarkCreator
    private let bookmarkResolver: BookmarkResolver
    private let securityScope: SecurityScopedResourceAccess
    private let scanner: BoardLibraryScanner
    private let backupStore: BackupStore
    private let now: @MainActor () -> Date
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "FrameScript",
        category: "Board"
    )
    private var didLoadFolders = false
    /// Labels used by the last scan. Kept so a single-file reload keeps the
    /// same localized pending-task titles as the full index.
    private var scanLabels: BoardPendingLabels = .english
    nonisolated(unsafe) private var projectFileStateObserver: NSObjectProtocol?
    private var fileStateReloadTask: Task<Void, Never>?
    private var pendingFileStateURLs: [URL] = []

    init(
        userDefaults: UserDefaults = AppEnvironment.defaults,
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
        backupStore: BackupStore = BackupsCenter.store,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.userDefaults = AppEnvironment.isolatedDefaults(userDefaults)
        self.foldersStorageKey = foldersStorageKey
        self.bookmarkCreator = bookmarkCreator
        self.bookmarkResolver = bookmarkResolver
        self.securityScope = securityScope
        self.scanner = scanner
        self.backupStore = backupStore
        self.now = now
        projectFileStateObserver = NotificationCenter.default.addObserver(
            forName: .frameScriptProjectFileStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = notification.object as? URL else { return }
            MainActor.assumeIsolated {
                self?.scheduleFileStateReload(at: url)
            }
        }
    }

    deinit {
        if let projectFileStateObserver {
            NotificationCenter.default.removeObserver(projectFileStateObserver)
        }
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
        scanLabels = pendingLabels(appState: appState)
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
            previous: index,
            labels: scanLabels
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
    func reloadFile(at url: URL) async {
        let scope = securityScope
        let didAccess = scope.start(url)
        defer { if didAccess { scope.stop(url) } }

        let scanner = self.scanner
        let labels = scanLabels
        let scanned = await Task.detached(priority: .userInitiated) {
            scanner.scan(
                BoardScanRequest(
                    folderURLs: [],
                    extraFileURLs: [url],
                    previous: BoardLibraryIndex(),
                    labels: labels
                )
            )
        }.value
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

    /// Re-reads one indexed file after the open project's disk state changed
    /// (saved, reloaded, closed or discarded). Unknown URLs are ignored so a
    /// board window never adopts a file it did not scan.
    func reloadFileIfIndexed(at url: URL) async {
        guard index.summary(forFileAt: url) != nil else { return }
        await reloadFile(at: url)
    }

    private func scheduleFileStateReload(at url: URL) {
        let standardized = url.standardizedFileURL
        if !pendingFileStateURLs.contains(standardized) {
            pendingFileStateURLs.append(standardized)
        }
        guard fileStateReloadTask == nil else { return }
        // One serial task drains every queued URL. Saves and autosaves can post
        // many notifications; this keeps the work bounded and ordered.
        fileStateReloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.pendingFileStateURLs.isEmpty {
                let next = self.pendingFileStateURLs.removeFirst()
                await self.reloadFileIfIndexed(at: next)
            }
            self.fileStateReloadTask = nil
        }
    }

    /// Test seam: waits for the reloads started by
    /// `.frameScriptProjectFileStateDidChange` notifications.
    func waitForPendingFileStateReloads() async {
        // The notification queue can deliver the block one runloop turn after
        // `post`, so wait briefly for the serial task to appear.
        for _ in 0..<50 {
            if let task = fileStateReloadTask {
                await task.value
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
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

        return await applyToFile(edit, summary: summary, appState: appState)
    }

    /// Applies a board edit to the project that is already open in the editor.
    /// It only marks the project dirty: the app's normal save or autosave keeps
    /// the write path in one place, and unrelated unsaved edits are never
    /// written because the user dragged a card (NEW-2).
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

        // The file is intentionally not written yet, so refresh the indexed row
        // from the edit instead of re-reading the old bytes from disk.
        var displayEdit = edit
        if edit.topic != nil {
            displayEdit.topic = BoardProjectTopic.display(from: project.topic)
        }
        let updated = summary.applying(displayEdit, fingerprint: summary.fingerprint)
        let pending = ProductionBoardPendingTaskProvider().pendingTasks(
            for: FrameScriptDocument.Project(project: project),
            labels: pendingLabels(appState: appState)
        )
        let refreshed = updated.replacingPendingTasks(pending)
        // The file was not written. Keep the row visible for this session but
        // mark it impossible to reuse: the next scan (and the explicit reload
        // posted on save/close/discard) must decode the file again (must-fix 1).
        index = index.replacing(refreshed.markingIndexStale())
        selectedProjectID = refreshed.id
        return edit.isSatisfied(by: refreshed) ? .saved(refreshed) : .conflict(refreshed)
    }

    private func applyToFile(
        _ edit: BoardProjectEdit,
        summary: BoardProjectSummary,
        appState: AppState
    ) async -> BoardWriteOutcome {
        let url = summary.fileURL
        let expectedHash = summary.fingerprint.contentHash
        let scope = appState.securityScope
        let backupStore = self.backupStore
        let backupProjectID = BackupProjectIdentity.identifier(
            projectUUID: summary.projectID,
            fileURL: url
        )
        let attemptsBackup = BackupsCenter.shouldAttemptBackup(projectID: backupProjectID)
        let didAccess = scope.start(url)
        defer { if didAccess { scope.stop(url) } }

        let result: FileApplyOutcome = await Task.detached(priority: .userInitiated) {
            do {
                let data = try Data(contentsOf: url)
                let diskHash = BoardFileFingerprint.hash(of: data)
                guard diskHash == expectedHash else {
                    return .changedExternally
                }
                var document = try FrameScriptDocumentCodec.decode(data)
                var documentEdit = edit
                if let topic = edit.topic {
                    documentEdit.topic = BoardProjectTopic.merging(topic, into: document.project.topic)
                }
                BoardDocumentEditor.apply(documentEdit, to: &document)
                let backupOutcome = attemptsBackup
                    ? backupStore.backUpIfNeeded(fileURL: url, projectID: backupProjectID)
                    : BackupOutcome.skipped(.intervalNotElapsed)
                try FrameScriptDocumentCodec.write(document, to: url)
                return .written(backup: backupOutcome, projectID: backupProjectID)
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value

        switch result {
        case .written(let backupOutcome, let projectID):
            // The backup copy runs off-main; its result still has to reach the
            // same logging and BackupHealth path as the editor's writes
            // (must-fix 3).
            BackupsCenter.record(backupOutcome, projectID: projectID)
            await reloadFile(at: url)
            if let refreshed = index.summary(forFileAt: url) {
                selectedProjectID = refreshed.id
                return edit.isSatisfied(by: refreshed) ? .saved(refreshed) : .conflict(refreshed)
            }
            return .failed("board.error.write")
        case .changedExternally:
            await reloadFile(at: url)
            return .conflict(index.summary(forFileAt: url))
        case .failed(let message):
            logger.error("Board write failed: \(message, privacy: .private)")
            await reloadFile(at: url)
            return .failed("board.error.write")
        }
    }

    // MARK: Plane plan

    func planePlan(
        for summary: BoardProjectSummary,
        appState: AppState
    ) async -> PlaneExportPlan {
        let labels = pendingLabels(appState: appState)
        let exportLabels = planeExportLabels(appState: appState)
        let provider = ProductionBoardPendingTaskProvider()
        let dueDate = BoardPlaneDate.make(from: summary.targetDate)
        let tasks: [BoardPendingTask]

        if appState.projectStore.currentFileURL?.standardizedFileURL == summary.fileURL.standardizedFileURL,
           appState.projectStore.project.id == summary.projectID {
            let document = FrameScriptDocument(project: appState.project)
            tasks = provider.pendingTasks(for: document.project, labels: labels)
        } else {
            let url = summary.fileURL
            let scope = appState.securityScope
            let didAccess = scope.start(url)
            defer { if didAccess { scope.stop(url) } }
            let document: FrameScriptDocument? = await Task.detached(priority: .userInitiated) {
                try? FrameScriptDocumentCodec.read(from: url)
            }.value
            tasks = document.map { provider.pendingTasks(for: $0.project, labels: labels) }
                ?? summary.pendingTasks
        }

        return PlaneExportPlan(
            tasks: tasks.map {
                $0.planeTask(
                    projectID: summary.projectID.uuidString,
                    projectTitle: summary.title,
                    dueDate: dueDate
                )
            },
            labels: exportLabels
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
                .publicar: appState.localized("board.kind.publicar"),
                .manual: appState.localized("board.kind.manual")
            ]
        )
    }

    func pendingLabels(appState: AppState) -> BoardPendingLabels {
        var titles: [String: String] = [:]
        for item in PublishingChecklistItem.allCases {
            titles[item.rawValue] = appState.localized(item.titleKey)
        }
        return BoardPendingLabels(
            record: appState.localized("board.kind.grabar"),
            bRoll: appState.localized("board.kind.conseguirBroll"),
            edit: appState.localized("board.kind.editar"),
            research: appState.localized("board.kind.investigar"),
            manual: appState.localized("board.kind.manual"),
            publish: appState.localized("board.kind.publicar"),
            publishingChecklistTitles: titles
        )
    }
}

enum BoardFolderError: Error, Equatable {
    case missingFolder
    case notAFolder
}

private enum FileApplyOutcome: Sendable {
    case written(backup: BackupOutcome, projectID: String)
    case changedExternally
    case failed(String)
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

    let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = AppEnvironment.defaults,
        storageKey: String = BoardCatalogStore.storageKey
    ) {
        self.userDefaults = AppEnvironment.isolatedDefaults(userDefaults)
        self.storageKey = storageKey
        if let data = self.userDefaults.data(forKey: storageKey),
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

    /// True when the configured URL would send the `X-API-Key` header over
    /// cleartext HTTP to a host other than the local machine. Self-hosted LAN
    /// setups stay allowed; the settings UI only warns (NEW-3).
    var isInsecureTransport: Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return false
        }
        return host != "localhost" && host != "127.0.0.1" && host != "::1"
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

    let userDefaults: UserDefaults
    private let storageKey: String
    private let readToken: TokenReader
    private let writeToken: TokenWriter
    private let deleteToken: TokenDeleter

    init(
        userDefaults: UserDefaults = AppEnvironment.defaults,
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
        self.userDefaults = AppEnvironment.isolatedDefaults(userDefaults)
        self.storageKey = storageKey
        self.readToken = readToken
        self.writeToken = writeToken
        self.deleteToken = deleteToken
        if let data = self.userDefaults.data(forKey: storageKey),
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
    let userDefaults: UserDefaults
    private let storageKey: String

    init(userDefaults: UserDefaults = AppEnvironment.defaults, storageKey: String = BoardPlaneLedgerStore.storageKey) {
        self.userDefaults = AppEnvironment.isolatedDefaults(userDefaults)
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
