import Foundation
@testable import FrameScript
import XCTest

final class RecentProjectStoreTests: FrameScriptTestCase {
    private var temporaryDirectory: URL!
    private var bookmarkCodec: TestBookmarkCodec!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameScriptRecentProjectStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        bookmarkCodec = TestBookmarkCodec()
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        bookmarkCodec = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testManualRemovalDoesNotDeleteProjectFile() throws {
        let fileURL = try makeProjectFile(named: "ManualRemove.fscr")
        let store = makeStore()

        try store.add(url: fileURL)
        XCTAssertEqual(store.entries.count, 1)

        store.remove(id: try XCTUnwrap(store.entries.first?.id))

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func testLegacyPathMigrationSkipsMissingFilesAndRemovesLegacyStorage() throws {
        let existingURL = try makeProjectFile(named: "Existing.fscr")
        let missingURL = temporaryDirectory.appendingPathComponent("Missing.fscr")
        makeDefaults().set([missingURL.path, existingURL.path], forKey: "legacy-recents")

        let store = makeStore(legacyPathsKey: "legacy-recents")
        store.load()

        XCTAssertEqual(store.entries.map(\.displayName), ["Existing"])
        XCTAssertNil(makeDefaults().stringArray(forKey: "legacy-recents"))
    }

    @MainActor
    func testDeletedFilesDisappearDuringValidation() throws {
        let fileURL = try makeProjectFile(named: "Deleted.fscr")
        let store = makeStore()

        try store.add(url: fileURL)
        try FileManager.default.removeItem(at: fileURL)
        let result = store.validateEntriesNow()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(result.removedMissingCount, 1)
    }

    @MainActor
    func testDuplicateURLsMoveToTopAndThirteenthEntryRemovesOldest() throws {
        let store = makeStore()
        var fileURLs: [URL] = []

        for index in 0..<13 {
            let url = try makeProjectFile(named: "Project-\(index).fscr")
            fileURLs.append(url)
            try store.add(url: url)
        }

        XCTAssertEqual(store.entries.count, 12)
        XCTAssertEqual(store.entries.first?.displayName, "Project-12")
        XCTAssertFalse(store.entries.contains { $0.displayName == "Project-0" })

        try store.add(url: fileURLs[3])

        XCTAssertEqual(store.entries.count, 12)
        XCTAssertEqual(store.entries.first?.displayName, "Project-3")
        XCTAssertEqual(store.entries.filter { $0.displayName == "Project-3" }.count, 1)
    }

    @MainActor
    func testInvalidBookmarksAreRemovedDuringValidation() throws {
        let invalidEntry = RecentProjectEntry(
            id: UUID(),
            bookmarkData: Data("not-a-bookmark".utf8),
            displayName: "Invalid",
            lastKnownPath: "/tmp/Invalid.fscr",
            lastOpenedAt: Date()
        )
        let data = try JSONEncoder().encode([invalidEntry])
        makeDefaults().set(data, forKey: "recents")
        let store = makeStore(storageKey: "recents")

        store.load()
        store.validateEntriesNow()

        XCTAssertTrue(store.entries.isEmpty)
    }

    @MainActor
    func testStaleBookmarkRefreshesBookmarkData() throws {
        let fileURL = try makeProjectFile(named: "Stale.fscr")
        let store = makeStore()

        try store.add(url: fileURL)
        let originalData = try XCTUnwrap(store.entries.first?.bookmarkData)
        bookmarkCodec.stalePaths.insert(fileURL.path)

        store.validateEntriesNow()

        let refreshedData = try XCTUnwrap(store.entries.first?.bookmarkData)
        XCTAssertNotEqual(refreshedData, originalData)
        XCTAssertGreaterThan(bookmarkCodec.createCount, 1)
    }

    @MainActor
    func testMovedBookmarkRefreshesPathAndDisplayName() throws {
        let original = try makeProjectFile(named: "Original.fscr")
        let moved = temporaryDirectory.appendingPathComponent("Moved.fscr")
        let store = makeStore()
        try store.add(url: original)
        try FileManager.default.moveItem(at: original, to: moved)
        bookmarkCodec.redirects[original.path] = moved.path
        bookmarkCodec.stalePaths.insert(original.path)

        store.validateEntriesNow()

        XCTAssertEqual(store.entries.first?.lastKnownPath, moved.path)
        XCTAssertEqual(store.entries.first?.displayName, "Moved")
    }

    @MainActor
    func testClearRecentsLeavesEveryProjectFileIntact() throws {
        let first = try makeProjectFile(named: "First.fscr")
        let second = try makeProjectFile(named: "Second.fscr")
        let store = makeStore()
        try store.add(url: first)
        try store.add(url: second)
        makeDefaults().set([first.path, second.path], forKey: "legacy-recents")

        store.removeAll()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertNil(makeDefaults().data(forKey: "recents"))
        XCTAssertNil(makeDefaults().stringArray(forKey: "legacy-recents"))
    }

    @MainActor
    func testLegacyMigrationPreservesLegacyStorageWhenPersistenceFails() throws {
        let file = try makeProjectFile(named: "RecoverableLegacy.fscr")
        makeDefaults().set([file.path], forKey: "legacy-recents")
        let store = makeStore(entriesEncoder: { _ in throw RecentProjectStoreError.persistenceFailed })

        store.load()

        XCTAssertEqual(store.entries.map(\.displayName), ["RecoverableLegacy"])
        XCTAssertEqual(makeDefaults().stringArray(forKey: "legacy-recents"), [file.path])
        XCTAssertEqual(store.storeError, .persistenceFailed)
    }

    @MainActor
    func testCorruptedStoredJSONIsNotOverwritten() throws {
        let corrupted = Data("{broken-json".utf8)
        makeDefaults().set(corrupted, forKey: "recents")
        let store = makeStore()

        store.load()
        store.validateEntriesNow()

        XCTAssertEqual(makeDefaults().data(forKey: "recents"), corrupted)
        XCTAssertNotNil(store.storeError)
    }

    @MainActor
    func testFailedPersistenceExposesStoreErrorAndKeepsInMemoryEntry() throws {
        let file = try makeProjectFile(named: "PersistenceFailure.fscr")
        let store = makeStore(entriesEncoder: { _ in throw RecentProjectStoreError.persistenceFailed })

        try store.add(url: file)

        XCTAssertEqual(store.entries.map(\.displayName), ["PersistenceFailure"])
        XCTAssertEqual(store.storeError, .persistenceFailed)
        XCTAssertNil(makeDefaults().data(forKey: "recents"))
    }

    @MainActor
    func testResolutionDoesNotMutateEntries() throws {
        let file = try makeProjectFile(named: "PureResolution.fscr")
        let store = makeStore()
        try store.add(url: file)
        let snapshot = store.entries
        bookmarkCodec.stalePaths.insert(file.path)

        _ = try store.resolve(try XCTUnwrap(snapshot.first))

        XCTAssertEqual(store.entries, snapshot)
    }

    @MainActor
    func testCompactParentFolderDoesNotResolveBookmark() throws {
        let file = try makeProjectFile(named: "DisplayOnly.fscr")
        let store = makeStore()
        try store.add(url: file)
        let entry = try XCTUnwrap(store.entries.first)
        let resolutionsBeforeDisplay = bookmarkCodec.resolveCount

        XCTAssertEqual(store.compactParentFolder(for: entry), temporaryDirectory.path)
        XCTAssertEqual(bookmarkCodec.resolveCount, resolutionsBeforeDisplay)
    }

    @MainActor
    func testValidationBalancesSecurityScopedAccess() throws {
        let file = try makeProjectFile(named: "Scoped.fscr")
        let access = TestSecurityScope()
        let store = makeStore(securityScope: access.value)
        try store.add(url: file)
        access.reset()

        store.validateEntriesNow()

        XCTAssertEqual(access.started, [file.path])
        XCTAssertEqual(access.stopped, [file.path])
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertTrue(store.availability(for: entry))
        XCTAssertEqual(access.started, [file.path], "Cached availability must not reopen the bookmark during rendering.")
        XCTAssertEqual(access.stopped, [file.path])
    }

    @MainActor
    func testLegacyExportFolderMigratesToBookmarkWithBalancedScopedAccess() throws {
        let access = TestSecurityScope()
        let appState = makeAppState(securityScope: access.value)
        appState.settings.exportPreferences.defaultExportFolder = temporaryDirectory.path
        appState.settings.exportPreferences.defaultExportFolderBookmarkData = nil

        XCTAssertEqual(appState.resolvedDefaultExportFolder(), temporaryDirectory)
        XCTAssertNotNil(appState.settings.exportPreferences.defaultExportFolderBookmarkData)
        XCTAssertEqual(access.started, [temporaryDirectory.path])
        XCTAssertEqual(access.stopped, [temporaryDirectory.path])
    }

    @MainActor
    func testStaleExportFolderBookmarkIsRefreshed() throws {
        let originalBookmark = try bookmarkCodec.createBookmark(for: temporaryDirectory)
        bookmarkCodec.stalePaths.insert(temporaryDirectory.path)
        let appState = makeAppState()
        appState.settings.exportPreferences.defaultExportFolder = temporaryDirectory.path
        appState.settings.exportPreferences.defaultExportFolderBookmarkData = originalBookmark

        XCTAssertEqual(appState.resolvedDefaultExportFolder(), temporaryDirectory)
        XCTAssertNotEqual(appState.settings.exportPreferences.defaultExportFolderBookmarkData, originalBookmark)
    }

    @MainActor
    func testFailedLegacyExportFolderMigrationClearsUnusableState() {
        let appState = AppState(
            exportFolderBookmarkCreator: { _ in throw RecentProjectStoreError.invalidBookmark },
            exportFolderBookmarkResolver: bookmarkCodec.resolveBookmark(data:isStale:)
        )
        appState.settings.exportPreferences.defaultExportFolder = temporaryDirectory.path
        appState.settings.exportPreferences.defaultExportFolderBookmarkData = nil

        XCTAssertNil(appState.resolvedDefaultExportFolder())
        XCTAssertTrue(appState.settings.exportPreferences.defaultExportFolder.isEmpty)
        XCTAssertNil(appState.settings.exportPreferences.defaultExportFolderBookmarkData)
    }

    @MainActor
    func testClearExportFolderClearsPathAndBookmark() throws {
        let appState = makeAppState()
        appState.settings.exportPreferences.defaultExportFolder = temporaryDirectory.path
        appState.settings.exportPreferences.defaultExportFolderBookmarkData = try bookmarkCodec.createBookmark(for: temporaryDirectory)

        appState.clearDefaultExportFolder()

        XCTAssertTrue(appState.settings.exportPreferences.defaultExportFolder.isEmpty)
        XCTAssertNil(appState.settings.exportPreferences.defaultExportFolderBookmarkData)
    }

    @MainActor
    private func makeStore(
        storageKey: String = "recents",
        legacyPathsKey: String = "legacy-recents",
        entriesEncoder: @escaping RecentProjectStore.EntriesEncoder = { try JSONEncoder().encode($0) },
        securityScope: SecurityScopedResourceAccess = SecurityScopedResourceAccess(start: { _ in false }, stop: { _ in })
    ) -> RecentProjectStore {
        RecentProjectStore(
            userDefaults: makeDefaults(),
            storageKey: storageKey,
            legacyPathsKey: legacyPathsKey,
            bookmarkCreator: bookmarkCodec.createBookmark(for:),
            bookmarkResolver: bookmarkCodec.resolveBookmark(data:isStale:),
            entriesEncoder: entriesEncoder,
            securityScope: securityScope
        )
    }

    @MainActor
    private func makeAppState(
        securityScope: SecurityScopedResourceAccess = SecurityScopedResourceAccess(start: { _ in false }, stop: { _ in })
    ) -> AppState {
        AppState(
            recentProjectStore: RecentProjectStore(userDefaults: makeDefaults()),
            settingsStore: SettingsStore(settings: .defaults, userDefaults: makeDefaults(), key: "settings"),
            securityScope: securityScope,
            exportFolderBookmarkCreator: bookmarkCodec.createBookmark(for:),
            exportFolderBookmarkResolver: bookmarkCodec.resolveBookmark(data:isStale:)
        )
    }

    private func makeProjectFile(named name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try "FrameScript test file".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private final class TestBookmarkCodec: @unchecked Sendable {
    var createCount = 0
    var resolveCount = 0
    var stalePaths: Set<String> = []
    var redirects: [String: String] = [:]

    func createBookmark(for url: URL) throws -> Data {
        createCount += 1
        return "\(url.path)|\(createCount)".data(using: .utf8) ?? Data()
    }

    func resolveBookmark(data: Data, isStale: inout Bool) throws -> URL {
        resolveCount += 1
        guard let encoded = String(data: data, encoding: .utf8),
              let path = encoded.split(separator: "|").first.map(String.init),
              encoded.contains("|") else {
            throw RecentProjectStoreError.invalidBookmark
        }
        if stalePaths.remove(path) != nil {
            isStale = true
        }
        return URL(fileURLWithPath: redirects[path] ?? path)
    }
}

@MainActor
private final class TestSecurityScope {
    var started: [String] = []
    var stopped: [String] = []

    var value: SecurityScopedResourceAccess {
        SecurityScopedResourceAccess(
            start: { [weak self] url in self?.started.append(url.path); return true },
            stop: { [weak self] url in self?.stopped.append(url.path) }
        )
    }

    func reset() {
        started = []
        stopped = []
    }
}
