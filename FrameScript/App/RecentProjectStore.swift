import Foundation
import Observation
import OSLog

struct RecentProjectEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var bookmarkData: Data
    var displayName: String
    var lastKnownPath: String
    var lastOpenedAt: Date
}

struct ResolvedRecentProject {
    let url: URL
    let refreshedBookmarkData: Data?
    let displayName: String
    let lastKnownPath: String
}

struct RecentValidationResult: Equatable {
    var removedMissingCount = 0
    var removedInvalidCount = 0
    var refreshedCount = 0
}

struct SecurityScopedResourceAccess: Sendable {
    let start: @MainActor @Sendable (URL) -> Bool
    let stop: @MainActor @Sendable (URL) -> Void

    static let live = SecurityScopedResourceAccess(
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )

    @MainActor
    func withAccess<T>(to url: URL, _ operation: () throws -> T) rethrows -> T {
        let didAccess = start(url)
        defer { if didAccess { stop(url) } }
        return try operation()
    }
}

enum RecentProjectStoreError: LocalizedError, Equatable {
    case missingFile(URL)
    case unreadableFile(URL)
    case invalidBookmark
    case corruptedStorage
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .missingFile(let url): "The project file no longer exists at \(url.path)."
        case .unreadableFile(let url): "The project file is not a readable regular file at \(url.path)."
        case .invalidBookmark: "The recent project bookmark could not be resolved."
        case .corruptedStorage: "Recent Projects data could not be read. The stored data was preserved."
        case .persistenceFailed: "Recent Projects could not be saved."
        }
    }
}

@MainActor
@Observable
final class RecentProjectStore {
    typealias BookmarkCreator = @MainActor @Sendable (URL) throws -> Data
    typealias BookmarkResolver = @MainActor @Sendable (Data, inout Bool) throws -> URL
    typealias EntriesEncoder = @MainActor @Sendable ([RecentProjectEntry]) throws -> Data

    private(set) var entries: [RecentProjectEntry] = []
    private(set) var storeError: RecentProjectStoreError?
    private(set) var availableEntryIDs: Set<UUID> = []

    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let storageKey: String
    private let legacyPathsKey: String
    private let limit: Int
    private let bookmarkCreator: BookmarkCreator
    private let bookmarkResolver: BookmarkResolver
    private let entriesEncoder: EntriesEncoder
    private let securityScope: SecurityScopedResourceAccess
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FrameScript", category: "RecentProjects")
    private var didLoad = false
    private var hasUndecodableStoredData = false
#if DEBUG
    private var hasUITestEntries = false
    private var skipsNextUITestValidation = false
#endif

    init(
        userDefaults: UserDefaults = AppEnvironment.defaults,
        fileManager: FileManager = .default,
        storageKey: String = "FrameScript.recentProjects.v1",
        legacyPathsKey: String = "FrameScript.recentProjectPaths",
        limit: Int = 12,
        bookmarkCreator: @escaping BookmarkCreator = RecentProjectStore.defaultBookmarkCreator,
        bookmarkResolver: @escaping BookmarkResolver = RecentProjectStore.defaultBookmarkResolver,
        entriesEncoder: @escaping EntriesEncoder = { try JSONEncoder().encode($0) },
        securityScope: SecurityScopedResourceAccess = .live
    ) {
        self.userDefaults = AppEnvironment.isolatedDefaults(userDefaults)
        self.fileManager = fileManager
        self.storageKey = storageKey
        self.legacyPathsKey = legacyPathsKey
        self.limit = limit
        self.bookmarkCreator = bookmarkCreator
        self.bookmarkResolver = bookmarkResolver
        self.entriesEncoder = entriesEncoder
        self.securityScope = securityScope
    }

    func load() {
        guard !didLoad else { return }
        didLoad = true
        if let data = userDefaults.data(forKey: storageKey) {
            do {
                entries = try JSONDecoder().decode([RecentProjectEntry].self, from: data)
            } catch {
                hasUndecodableStoredData = true
                storeError = .corruptedStorage
                logger.error("Failed to decode Recent Projects; stored data was preserved. Error: \(error.localizedDescription, privacy: .private)")
                return
            }
        }
        migrateLegacyPathsIfNeeded()
    }

    @discardableResult
    func validateEntries() async -> RecentValidationResult { validateEntriesNow() }

    @discardableResult
    func validateEntriesNow() -> RecentValidationResult {
        guard !hasUndecodableStoredData else { return RecentValidationResult() }
        let previousEntries = entries
        let snapshot = entries.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
        var validated: [RecentProjectEntry] = []
        var available: Set<UUID> = []
        var seen: Set<String> = []
        var result = RecentValidationResult()
        for entry in snapshot {
            do {
                let resolved = try resolveEntry(entry)
#if DEBUG
                if isUITestEntry(entry), skipsNextUITestValidation {
                    validated.append(entry)
                    available.insert(entry.id)
                    continue
                }
#endif
                let status = securityScope.withAccess(to: resolved.url) {
                    (exists: fileManager.fileExists(atPath: resolved.url.path), readable: isReadableRegularFile(resolved.url))
                }
                guard status.exists else {
                    result.removedMissingCount += 1
                    logger.notice("Discarding missing Recent entry \(entry.id.uuidString, privacy: .public).")
                    continue
                }
                guard status.readable else {
                    result.removedInvalidCount += 1
                    logger.notice("Discarding unreadable Recent entry \(entry.id.uuidString, privacy: .public).")
                    continue
                }
                guard seen.insert(canonicalKey(for: resolved.url)).inserted else {
                    result.removedInvalidCount += 1
                    continue
                }
                validated.append(updated(entry, with: resolved))
                available.insert(entry.id)
                if resolved.refreshedBookmarkData != nil { result.refreshedCount += 1 }
            } catch {
                result.removedInvalidCount += 1
                logger.notice("Discarding invalid Recent entry \(entry.id.uuidString, privacy: .public). Error: \(error.localizedDescription, privacy: .private)")
            }
        }
        entries = Array(validated.prefix(limit))
        availableEntryIDs = available.intersection(Set(entries.map(\.id)))
#if DEBUG
        skipsNextUITestValidation = false
#endif
        if entries != previousEntries {
            persist()
        }
        return result
    }

    func add(url: URL) throws {
        let url = url.standardizedFileURL
        let entry = try securityScope.withAccess(to: url) { () throws -> RecentProjectEntry in
            guard isReadableRegularFile(url) else {
                throw fileManager.fileExists(atPath: url.path) ? RecentProjectStoreError.unreadableFile(url) : RecentProjectStoreError.missingFile(url)
            }
            return RecentProjectEntry(id: UUID(), bookmarkData: try bookmarkCreator(url), displayName: displayName(for: url), lastKnownPath: url.path, lastOpenedAt: Date())
        }
        let key = canonicalKey(for: url)
        var remaining: [RecentProjectEntry] = []
        for old in entries where old.lastKnownPath != url.path {
            do {
                if canonicalKey(for: try resolveEntry(old).url) != key {
                    remaining.append(old)
                }
            } catch {
                logger.notice("Discarding Recent entry with an invalid bookmark while adding a project. Entry: \(old.id.uuidString, privacy: .public)")
            }
        }
        entries = Array(([entry] + remaining).prefix(limit))
        availableEntryIDs = Set(entries.map(\.id))
        persist()
    }

#if DEBUG
    func addUITestEntry(url: URL) throws {
        let url = url.standardizedFileURL
        let data = Data("framescript-ui-test:\(url.path)".utf8)
        hasUITestEntries = true
        skipsNextUITestValidation = true
        entries = [RecentProjectEntry(id: UUID(), bookmarkData: data, displayName: displayName(for: url), lastKnownPath: url.path, lastOpenedAt: Date())]
        availableEntryIDs = Set(entries.map(\.id))
    }
#endif

    func remove(id: UUID) {
        entries = entries.filter { $0.id != id }
        availableEntryIDs.remove(id)
        persist()
    }

    func remove(url: URL) {
        let url = url.standardizedFileURL
        let key = canonicalKey(for: url)
        var remaining: [RecentProjectEntry] = []
        for entry in entries where entry.lastKnownPath != url.path {
            do {
                if canonicalKey(for: try resolveEntry(entry).url) != key {
                    remaining.append(entry)
                }
            } catch {
                logger.notice("Discarding Recent entry with an invalid bookmark while removing a project. Entry: \(entry.id.uuidString, privacy: .public)")
            }
        }
        entries = remaining
        availableEntryIDs.formIntersection(Set(entries.map(\.id)))
        persist()
    }

    func removeAll() {
        entries = []
        availableEntryIDs = []
        hasUndecodableStoredData = false
        storeError = nil
        userDefaults.removeObject(forKey: storageKey)
        userDefaults.removeObject(forKey: legacyPathsKey)
    }

    func resolve(_ entry: RecentProjectEntry) throws -> URL { try resolveEntry(entry).url }

#if DEBUG
    func isUITestEntry(_ entry: RecentProjectEntry) -> Bool {
        String(data: entry.bookmarkData, encoding: .utf8)?.hasPrefix("framescript-ui-test:") == true
    }
#endif

    func validatedURL(for entry: RecentProjectEntry) throws -> URL {
        guard let storedEntry = entries.first(where: { $0.id == entry.id }) else {
            let url = URL(fileURLWithPath: entry.lastKnownPath)
            throw fileManager.fileExists(atPath: url.path) ? RecentProjectStoreError.unreadableFile(url) : RecentProjectStoreError.missingFile(url)
        }
        let url: URL
        do {
            url = try resolveEntry(storedEntry).url
        } catch {
            throw RecentProjectStoreError.invalidBookmark
        }
        let status = securityScope.withAccess(to: url) {
            (exists: fileManager.fileExists(atPath: url.path), readable: isReadableRegularFile(url))
        }
        guard status.exists else { throw RecentProjectStoreError.missingFile(url) }
        guard status.readable else { throw RecentProjectStoreError.unreadableFile(url) }
        return url
    }

    func availability(for entry: RecentProjectEntry) -> Bool {
        availableEntryIDs.contains(entry.id)
    }

    func compactParentFolder(for entry: RecentProjectEntry) -> String {
        let url = URL(fileURLWithPath: entry.lastKnownPath)
        let parent = url.deletingLastPathComponent()
        let home = fileManager.homeDirectoryForCurrentUser.path
        if parent.path == home { return "~" }
        if parent.path.hasPrefix(home + "/") { return "~/" + parent.path.dropFirst(home.count + 1) }
        return parent.path
    }

    private func migrateLegacyPathsIfNeeded() {
        guard let paths = userDefaults.stringArray(forKey: legacyPathsKey) else { return }
        var migrated = entries
        for path in paths.reversed() {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard fileManager.fileExists(atPath: url.path) else { logger.info("Skipping missing legacy Recent path."); continue }
            do {
                let entry = try securityScope.withAccess(to: url) { () throws -> RecentProjectEntry in
                    guard isReadableRegularFile(url) else { throw RecentProjectStoreError.unreadableFile(url) }
                    return RecentProjectEntry(id: UUID(), bookmarkData: try bookmarkCreator(url), displayName: displayName(for: url), lastKnownPath: url.path, lastOpenedAt: Date())
                }
                migrated.removeAll { $0.lastKnownPath == url.path }
                migrated.insert(entry, at: 0)
            } catch {
                logger.error("Failed to migrate legacy Recent path. Error: \(error.localizedDescription, privacy: .private)")
            }
        }
        entries = Array(migrated.prefix(limit))
        availableEntryIDs = Set(entries.map(\.id))
        guard persist() else { return }
        userDefaults.removeObject(forKey: legacyPathsKey)
    }

    private func resolveEntry(_ entry: RecentProjectEntry) throws -> ResolvedRecentProject {
#if DEBUG
        if let encoded = String(data: entry.bookmarkData, encoding: .utf8),
           encoded.hasPrefix("framescript-ui-test:") {
            let path = String(encoded.dropFirst("framescript-ui-test:".count))
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return ResolvedRecentProject(url: url, refreshedBookmarkData: nil, displayName: displayName(for: url), lastKnownPath: url.path)
        }
#endif
        var stale = false
        let url = try bookmarkResolver(entry.bookmarkData, &stale).standardizedFileURL
        let refreshed = stale ? try securityScope.withAccess(to: url) { try bookmarkCreator(url) } : nil
        return ResolvedRecentProject(url: url, refreshedBookmarkData: refreshed, displayName: displayName(for: url), lastKnownPath: url.path)
    }

    private func updated(_ entry: RecentProjectEntry, with resolved: ResolvedRecentProject) -> RecentProjectEntry {
        var result = entry
        if let data = resolved.refreshedBookmarkData { result.bookmarkData = data }
        result.displayName = resolved.displayName
        result.lastKnownPath = resolved.lastKnownPath
        return result
    }

    private func isReadableRegularFile(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue && fileManager.isReadableFile(atPath: url.path)
    }

    private func canonicalKey(for url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
    private func displayName(for url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    @discardableResult
    private func persist() -> Bool {
#if DEBUG
        guard !hasUITestEntries else { return true }
#endif
        guard !hasUndecodableStoredData else {
            storeError = .corruptedStorage
            return false
        }
        do {
            let data = try entriesEncoder(entries)
            userDefaults.set(data, forKey: storageKey)
            guard userDefaults.data(forKey: storageKey) == data else {
                throw RecentProjectStoreError.persistenceFailed
            }
            storeError = nil
            return true
        } catch {
            storeError = .persistenceFailed
            logger.error("Failed to persist Recents. Error: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    func acknowledgeStoreError() {
        storeError = nil
    }

    private static func defaultBookmarkCreator(url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func defaultBookmarkResolver(data: Data, isStale: inout Bool) throws -> URL {
        try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
    }
}
