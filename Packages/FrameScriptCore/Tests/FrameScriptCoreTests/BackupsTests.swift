import Foundation
import Testing
@testable import FrameScriptCore

private let baseDate = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
private let sampleProjectID = "11111111-1111-1111-1111-111111111111"

private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "UTC") ?? .current
    return calendar
}

private func makeTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FrameScriptBackups-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func utcDate(year: Int, month: Int, day: Int, hour: Int = 9, minute: Int = 0) -> Date {
    var components = DateComponents()
    components.calendar = utcCalendar
    components.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "UTC")
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return components.date ?? Date(timeIntervalSince1970: 0)
}

private func backupURL(_ name: String, in root: URL) -> URL {
    root.appendingPathComponent(name)
}

private func write(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url, options: .atomic)
}

private func read(_ url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

// MARK: - Interval throttling

@Test func automaticBackupsAreThrottledByMinimumInterval() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let clock = TestClock(baseDate)
    let store = BackupStore(rootDirectory: root, calendar: utcCalendar, now: { clock.now })
    let source = backupURL("Project.fscr", in: root)
    try write("version one", to: source)

    guard case let .created(first, warning) = store.backUpIfNeeded(fileURL: source, projectID: sampleProjectID) else {
        Issue.record("The first backup should have been created")
        return
    }
    #expect(warning == nil)
    #expect(try read(first.url) == "version one")
    #expect(store.listBackups(projectID: sampleProjectID).count == 1)

    try write("version two", to: source)
    clock.now = baseDate.addingTimeInterval(9 * 60)
    #expect(store.backUpIfNeeded(fileURL: source, projectID: sampleProjectID) == .skipped(.intervalNotElapsed))
    #expect(store.listBackups(projectID: sampleProjectID).count == 1)

    clock.now = baseDate.addingTimeInterval(10 * 60)
    guard case let .created(second, _) = store.backUpIfNeeded(fileURL: source, projectID: sampleProjectID) else {
        Issue.record("A backup at the ten-minute mark should have been created")
        return
    }
    #expect(second.url != first.url)
    #expect(try read(first.url) == "version one")
    #expect(try read(second.url) == "version two")
    #expect(store.listBackups(projectID: sampleProjectID).count == 2)
}

@Test func forcedBackupsIgnoreTheMinimumInterval() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let clock = TestClock(baseDate)
    let store = BackupStore(rootDirectory: root, calendar: utcCalendar, now: { clock.now })
    let source = backupURL("Project.fscr", in: root)
    try write("one", to: source)

    guard case .created = store.backUpIfNeeded(fileURL: source, projectID: sampleProjectID) else {
        Issue.record("The first backup should have been created")
        return
    }

    clock.now = baseDate.addingTimeInterval(1)
    #expect(store.backUpIfNeeded(fileURL: source, projectID: sampleProjectID) == .skipped(.intervalNotElapsed))

    clock.now = baseDate.addingTimeInterval(2)
    guard case .created = store.backUpIfNeeded(fileURL: source, projectID: sampleProjectID, force: true) else {
        Issue.record("A forced backup should ignore the interval")
        return
    }
    #expect(store.listBackups(projectID: sampleProjectID).count == 2)
}

// MARK: - Rotation

@Test func rotationKeepsNewestTwentyAndOnePerDayForFourteenDays() {
    let now = utcDate(year: 2026, month: 11, day: 12, hour: 12)

    var entries: [BackupEntry] = []
    // 25 backups today: only the newest 20 should survive from this group.
    for index in 0..<25 {
        let date = utcDate(year: 2026, month: 11, day: 12, hour: 10, minute: index)
        entries.append(BackupEntry(
            url: URL(fileURLWithPath: "/backups/today-\(index).fscr"),
            createdAt: date,
            byteSize: 10,
            originalFileName: "Project.fscr"
        ))
    }
    // One backup per day for the previous 20 days.
    for offset in 1...20 {
        let date = utcCalendar.date(byAdding: .day, value: -offset, to: utcDate(year: 2026, month: 11, day: 12)) ?? now
        entries.append(BackupEntry(
            url: URL(fileURLWithPath: "/backups/day-\(offset).fscr"),
            createdAt: date,
            byteSize: 10,
            originalFileName: "Project.fscr"
        ))
    }

    let policy = BackupPolicy()
    let deleted = policy.backupsToDelete(from: entries, now: now, calendar: utcCalendar)
    let deletedPaths = Set(deleted.map(\.url.path))

    // The five oldest backups from today fall outside the newest twenty.
    for index in 0..<5 {
        #expect(deletedPaths.contains("/backups/today-\(index).fscr"))
    }
    for index in 5..<25 {
        #expect(!deletedPaths.contains("/backups/today-\(index).fscr"))
    }
    // Days 1...13 are inside the fourteen-day window and get their daily copy.
    for offset in 1...13 {
        #expect(!deletedPaths.contains("/backups/day-\(offset).fscr"))
    }
    // Days 14...20 fall outside both rules.
    for offset in 14...20 {
        #expect(deletedPaths.contains("/backups/day-\(offset).fscr"))
    }
    #expect(deleted.count == 12)
    #expect(!deletedPaths.contains("/backups/today-24.fscr"))
}

@Test func dailyRetentionKeepsTheNewestBackupOfEachDay() {
    let now = utcDate(year: 2026, month: 11, day: 12, hour: 12)
    let today = BackupEntry(
        url: URL(fileURLWithPath: "/backups/today.fscr"),
        createdAt: utcDate(year: 2026, month: 11, day: 12, hour: 10),
        byteSize: 1,
        originalFileName: "Project.fscr"
    )
    let yesterdayMorning = BackupEntry(
        url: URL(fileURLWithPath: "/backups/yesterday-morning.fscr"),
        createdAt: utcDate(year: 2026, month: 11, day: 11, hour: 8),
        byteSize: 1,
        originalFileName: "Project.fscr"
    )
    let yesterdayEvening = BackupEntry(
        url: URL(fileURLWithPath: "/backups/yesterday-evening.fscr"),
        createdAt: utcDate(year: 2026, month: 11, day: 11, hour: 18),
        byteSize: 1,
        originalFileName: "Project.fscr"
    )

    let policy = BackupPolicy(minimumInterval: 0, maximumCount: 1, dailyRetentionDays: 14)
    let deleted = policy.backupsToDelete(
        from: [yesterdayMorning, today, yesterdayEvening],
        now: now,
        calendar: utcCalendar
    )
    #expect(deleted.map(\.url) == [yesterdayMorning.url])
}

@Test func clockRollbackAndFutureTimestampsDoNotBlockBackups() {
    let policy = BackupPolicy()
    let newest = BackupEntry(
        url: URL(fileURLWithPath: "/backups/new.fscr"),
        createdAt: baseDate,
        byteSize: 1,
        originalFileName: "Project.fscr"
    )
    // Wall clock moved backwards: the next save must still back up.
    #expect(policy.allowsBackup(existing: [newest], now: baseDate.addingTimeInterval(-86_400)))
    #expect(policy.allowsBackup(existing: [newest], now: baseDate.addingTimeInterval(-1)))
    // A mis-set future stamp must be treated as stale, not block until that date.
    let future = BackupEntry(
        url: URL(fileURLWithPath: "/backups/future.fscr"),
        createdAt: baseDate.addingTimeInterval(365 * 86_400),
        byteSize: 1,
        originalFileName: "Project.fscr"
    )
    #expect(policy.allowsBackup(existing: [future], now: baseDate))
    // A future stamp must not force a backup on every save: the recent past
    // entry still throttles normally.
    let recent = BackupEntry(
        url: URL(fileURLWithPath: "/backups/recent.fscr"),
        createdAt: baseDate.addingTimeInterval(-60),
        byteSize: 1,
        originalFileName: "Project.fscr"
    )
    #expect(policy.allowsBackup(existing: [recent, future], now: baseDate) == false)
    #expect(policy.allowsBackup(existing: [newest], now: baseDate.addingTimeInterval(9 * 60)) == false)
    #expect(policy.allowsBackup(existing: [newest], now: baseDate.addingTimeInterval(10 * 60)))
}

@Test func subSecondBackupsArePrunedInTheRightOrder() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let clock = TestClock(baseDate)
    let store = BackupStore(
        rootDirectory: root,
        policy: BackupPolicy(minimumInterval: 0, maximumCount: 2, dailyRetentionDays: 0),
        calendar: utcCalendar,
        now: { clock.now }
    )
    let source = backupURL("Project.fscr", in: root)

    for index in 0..<3 {
        try write("content-\(index)", to: source)
        clock.now = baseDate.addingTimeInterval(0.1 + Double(index) / 10)
        guard case .created = store.backUpIfNeeded(fileURL: source, projectID: sampleProjectID) else {
            Issue.record("Backup \(index) should have been created")
            return
        }
    }

    let entries = store.listBackups(projectID: sampleProjectID)
    #expect(entries.count == 2)
    #expect(try Set(entries.map { try read($0.url) }) == ["content-1", "content-2"])
}

@Test func degeneratePolicyStillKeepsTheNewestBackup() {
    let older = BackupEntry(
        url: URL(fileURLWithPath: "/backups/old.fscr"),
        createdAt: baseDate,
        byteSize: 1,
        originalFileName: "Project.fscr"
    )
    let newer = BackupEntry(
        url: URL(fileURLWithPath: "/backups/new.fscr"),
        createdAt: baseDate.addingTimeInterval(60),
        byteSize: 1,
        originalFileName: "Project.fscr"
    )
    var rawPolicy = BackupPolicy()
    rawPolicy.maximumCount = 0
    rawPolicy.dailyRetentionDays = 0

    let deleted = rawPolicy.backupsToDelete(
        from: [older, newer],
        now: baseDate.addingTimeInterval(120),
        calendar: utcCalendar
    )
    #expect(deleted.map(\.url) == [older.url])
}

@Test func pruningRunsAfterEachNewBackup() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let clock = TestClock(baseDate)
    let store = BackupStore(
        rootDirectory: root,
        policy: BackupPolicy(minimumInterval: 0, maximumCount: 3, dailyRetentionDays: 0),
        calendar: utcCalendar,
        now: { clock.now }
    )
    let source = backupURL("Project.fscr", in: root)

    for index in 0..<5 {
        try write("version \(index)", to: source)
        clock.now = baseDate.addingTimeInterval(TimeInterval(index))
        guard case .created = store.backUpIfNeeded(fileURL: source, projectID: sampleProjectID) else {
            Issue.record("Backup \(index) should have been created")
            return
        }
    }

    let entries = store.listBackups(projectID: sampleProjectID)
    #expect(entries.count == 3)
    #expect(try entries.map { try read($0.url) }.sorted() == ["version 2", "version 3", "version 4"])
    #expect(entries.map(\.createdAt) == entries.map(\.createdAt).sorted(by: >))
}

// MARK: - Restore

@Test func restoreBacksUpTheDestinationBeforeOverwritingIt() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let clock = TestClock(baseDate)
    let store = BackupStore(rootDirectory: root, calendar: utcCalendar, now: { clock.now })
    let destination = backupURL("Project.fscr", in: root)
    try write("original version", to: destination)

    guard case let .created(entry, _) = store.backUpIfNeeded(fileURL: destination, projectID: sampleProjectID) else {
        Issue.record("The source backup should have been created")
        return
    }

    try write("current version", to: destination)
    // No interval elapses: the safeguard backup must still be forced.
    switch store.restore(entry, over: destination, projectID: sampleProjectID) {
    case let .restored(safeguard):
        guard let safeguard else {
            Issue.record("Restore should have created a safeguard backup")
            return
        }
        #expect(try read(safeguard.url) == "current version")
    case let .failed(failure):
        Issue.record("Restore failed: \(failure.reason)")
        return
    }

    #expect(try read(destination) == "original version")
    let entries = store.listBackups(projectID: sampleProjectID)
    #expect(entries.count == 2)
    #expect(try Set(entries.map { try read($0.url) }) == ["current version", "original version"])
}

@Test func restoreReadsTheSelectedBackupBeforeTheSafeguardCanPruneIt() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let clock = TestClock(baseDate.addingTimeInterval(-30 * 86_400))
    let store = BackupStore(rootDirectory: root, calendar: utcCalendar, now: { clock.now })
    let source = backupURL("Project.fscr", in: root)

    for index in 0..<20 {
        try write("old-\(index)", to: source)
        clock.now = baseDate.addingTimeInterval(-30 * 86_400 + TimeInterval(index))
        guard case .created = store.backUpIfNeeded(fileURL: source, projectID: sampleProjectID, force: true) else {
            Issue.record("Historical backup \(index) should have been created")
            return
        }
    }
    let entries = store.listBackups(projectID: sampleProjectID)
    #expect(entries.count == 20)
    guard let oldest = entries.last else {
        Issue.record("Expected an oldest backup")
        return
    }

    try write("current version", to: source)
    clock.now = baseDate
    // The safeguard is #21, so a prune-before-read would delete the selected
    // oldest entry and the restore would fail.
    switch store.restore(oldest, over: source, projectID: sampleProjectID) {
    case .restored:
        #expect(try read(source) == "old-0")
    case let .failed(failure):
        Issue.record("Restore of the oldest backup failed: \(failure.reason)")
    }
}

@Test func restoreFromDataSurvivesTheSourceBackupBeingPruned() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = BackupStore(rootDirectory: root, calendar: utcCalendar, now: { baseDate })
    let source = backupURL("Source.fscr", in: root)
    try write("payload to restore", to: source)
    guard case let .created(entry, _) = store.backUpIfNeeded(fileURL: source, projectID: sampleProjectID) else {
        Issue.record("The source backup should have been created")
        return
    }
    let payload = try Data(contentsOf: entry.url)

    // Simulate a save hook running retention after the app read the payload.
    try FileManager.default.removeItem(at: entry.url)

    let destination = backupURL("Project.fscr", in: root)
    try write("current content", to: destination)

    switch store.restore(data: payload, over: destination, projectID: sampleProjectID) {
    case .restored:
        #expect(try read(destination) == "payload to restore")
    case let .failed(failure):
        Issue.record("Restore from data failed: \(failure.reason)")
    }
}

@Test func restoreIsRefusedWhenTheSafeguardCannotBeWritten() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = BackupStore(
        rootDirectory: root,
        fileManager: FailingDirectoryFileManager(),
        calendar: utcCalendar,
        now: { baseDate }
    )
    let projectDirectory = store.projectDirectory(forProjectID: sampleProjectID)
    try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)

    let existingBackup = projectDirectory.appendingPathComponent("2023-11-14T22-13-20.000Z__Project.fscr")
    try write("backup content", to: existingBackup)
    let entry = BackupEntry(
        url: existingBackup,
        createdAt: baseDate,
        byteSize: 14,
        originalFileName: "Project.fscr",
        originalPath: nil
    )
    let destination = backupURL("Project.fscr", in: root)
    try write("current content", to: destination)

    switch store.restore(entry, over: destination, projectID: sampleProjectID) {
    case .restored:
        Issue.record("Restore should have failed when the safeguard backup could not be written")
    case let .failed(failure):
        #expect(failure.operation == .createDirectory)
    }
    #expect(try read(destination) == "current content")
}

// MARK: - Missing and unicode files

@Test func missingSourceFileIsSkippedWithoutCreatingAnything() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = BackupStore(rootDirectory: root, calendar: utcCalendar, now: { baseDate })
    let missing = backupURL("Not There.fscr", in: root)

    #expect(store.backUpIfNeeded(fileURL: missing, projectID: sampleProjectID) == .skipped(.sourceMissing))
    #expect(store.listBackups(projectID: sampleProjectID).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: store.projectDirectory(forProjectID: sampleProjectID).path))
}

@Test func unicodeFileNamesRoundTripThroughBackupAndRestore() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let clock = TestClock(baseDate)
    let store = BackupStore(rootDirectory: root, calendar: utcCalendar, now: { clock.now })
    let name = "Escaleta ñandú 日本語 🎬.fscr"
    let source = backupURL(name, in: root)
    try write("texto original", to: source)

    guard case let .created(entry, warning) = store.backUpIfNeeded(fileURL: source, projectID: sampleProjectID) else {
        Issue.record("The unicode-named file should have been backed up")
        return
    }
    #expect(warning == nil)
    #expect(entry.originalFileName == name)
    #expect(entry.url.lastPathComponent.contains("日本語"))
    #expect(entry.url.lastPathComponent.hasSuffix(".fscr"))
    #expect(entry.originalPath == source.path)

    let listed = store.listBackups(projectID: sampleProjectID)
    #expect(listed.count == 1)
    #expect(listed.first?.originalFileName == name)

    try write("texto cambiado", to: source)
    switch store.restore(entry, over: source, projectID: sampleProjectID) {
    case .restored:
        #expect(try read(source) == "texto original")
    case let .failed(failure):
        Issue.record("Unicode restore failed: \(failure.reason)")
    }
}

@Test func veryLongEmojiNamesProduceAValidBackupFileName() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = BackupStore(rootDirectory: root, calendar: utcCalendar, now: { baseDate })
    // 113 emoji are 231 UTF-16 units, which is a legal APFS file name, but the
    // ISO stamp pushes the backup name past the 255-unit limit.
    let name = String(repeating: "🎬", count: 113) + ".fscr"
    let source = backupURL(name, in: root)
    try write("long name", to: source)

    guard case let .created(entry, _) = store.backUpIfNeeded(fileURL: source, projectID: sampleProjectID) else {
        Issue.record("A long unicode name should still be backed up")
        return
    }
    #expect(entry.url.lastPathComponent.utf16.count <= 255)
    #expect(entry.url.lastPathComponent.utf8.count <= 255)
    #expect(entry.originalFileName == name)
    #expect(try read(entry.url) == "long name")
}

@Test func restoreRejectsInvalidBackupBeforeTouchingTheDestination() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = BackupStore(rootDirectory: root, calendar: utcCalendar, now: { baseDate })
    let invalidSource = backupURL("Invalid.fscr", in: root)
    try write("not a project", to: invalidSource)
    guard case let .created(entry, _) = store.backUpIfNeeded(fileURL: invalidSource, projectID: sampleProjectID) else {
        Issue.record("The invalid source should still have a byte-for-byte backup")
        return
    }

    let destination = backupURL("Project.fscr", in: root)
    try write("current content", to: destination)

    let outcome = store.restore(entry, over: destination, projectID: sampleProjectID) { data in
        guard String(decoding: data, as: UTF8.self) == "a valid project" else {
            throw ValidationFailure()
        }
    }

    guard case let .failed(failure) = outcome else {
        Issue.record("A backup rejected by the validator must not be restored")
        return
    }
    #expect(failure.operation == .validateBackup)
    #expect(try read(destination) == "current content")
    // Validation runs before the safeguard, so no backup of the destination is made.
    #expect(store.listBackups(projectID: sampleProjectID).count == 1)
}

@Test func restoreWritesThroughASymlinkedDestination() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = BackupStore(rootDirectory: root, calendar: utcCalendar, now: { baseDate })
    let source = backupURL("Source.fscr", in: root)
    try write("restored content", to: source)
    guard case let .created(entry, _) = store.backUpIfNeeded(fileURL: source, projectID: sampleProjectID) else {
        Issue.record("The source backup should have been created")
        return
    }

    let target = backupURL("Real Project.fscr", in: root)
    try write("current content", to: target)
    let link = backupURL("Linked Project.fscr", in: root)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    switch store.restore(entry, over: link, projectID: sampleProjectID) {
    case .restored:
        #expect(try read(target) == "restored content")
        #expect(try read(link) == "restored content")
    case let .failed(failure):
        Issue.record("Restore through a symlink failed: \(failure.reason)")
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
    #expect((attributes[.type] as? FileAttributeType) == .typeSymbolicLink)
}

@Test func legacyWholeSecondMetadataStillLists() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = BackupStore(rootDirectory: root, calendar: utcCalendar, now: { baseDate })
    let directory = store.projectDirectory(forProjectID: sampleProjectID)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let backup = directory.appendingPathComponent("2023-11-14T22-13-20Z__Project.fscr")
    try write("legacy", to: backup)
    let sidecar = backup.appendingPathExtension("json")
    let json = """
    {"originalPath":"/old/Project.fscr","originalFileName":"Project.fscr","createdAt":"2023-11-14T22:13:20Z","byteSize":6}
    """
    try write(json, to: sidecar)

    let entries = store.listBackups(projectID: sampleProjectID)
    #expect(entries.count == 1)
    #expect(entries.first?.createdAt == baseDate)
    #expect(entries.first?.originalPath == "/old/Project.fscr")
    #expect(entries.first?.originalFileName == "Project.fscr")
}

@Test func sharedWritePathHelperUsesProjectIdentity() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = BackupStore(rootDirectory: root, calendar: utcCalendar, now: { baseDate })
    let uuid = UUID()
    let withUUID = backupURL("With UUID.fscr", in: root)
    try write("uuid content", to: withUUID)

    guard case .created = store.backUpBeforeOverwrite(projectUUID: uuid, fileURL: withUUID) else {
        Issue.record("The shared helper should back up a UUID project")
        return
    }
    #expect(store.listBackups(projectID: uuid.uuidString.lowercased()).count == 1)

    let withoutUUID = backupURL("Path Only.fscr", in: root)
    try write("path content", to: withoutUUID)
    guard case .created = store.backUpBeforeOverwrite(projectUUID: nil, fileURL: withoutUUID) else {
        Issue.record("The shared helper should fall back to the path hash")
        return
    }
    let pathID = BackupProjectIdentity.identifier(projectUUID: nil, fileURL: withoutUUID)
    #expect(store.listBackups(projectID: pathID).count == 1)
}

// MARK: - Reporting, identity and codable policy

@Test func directoryFailureIsReportedInsteadOfThrown() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = BackupStore(
        rootDirectory: root,
        fileManager: FailingDirectoryFileManager(),
        calendar: utcCalendar,
        now: { baseDate }
    )
    let source = backupURL("Project.fscr", in: root)
    try write("content", to: source)

    switch store.backUpIfNeeded(fileURL: source, projectID: sampleProjectID) {
    case let .failed(failure):
        #expect(failure.operation == .createDirectory)
        #expect(failure.path.contains("Backups") || failure.path.contains(sampleProjectID))
    default:
        Issue.record("A failing directory creation should be reported as a failure")
    }
}

@Test func policyRoundTripsThroughCodable() throws {
    let policy = BackupPolicy(minimumInterval: 42, maximumCount: 7, dailyRetentionDays: 3)
    let data = try JSONEncoder().encode(policy)
    let decoded = try JSONDecoder().decode(BackupPolicy.self, from: data)
    #expect(decoded == policy)
}

@Test func projectIdentityPrefersUUIDAndFallsBackToStablePathHash() {
    let uuid = UUID()
    #expect(BackupProjectIdentity.identifier(projectUUID: uuid, fileURL: URL(fileURLWithPath: "/a.fscr")) == uuid.uuidString.lowercased())
    #expect(BackupProjectIdentity.identifier(projectUUID: nil, fileURL: nil) == "unfiled")

    let first = BackupProjectIdentity.identifier(projectUUID: nil, fileURL: URL(fileURLWithPath: "/tmp/One.fscr"))
    let second = BackupProjectIdentity.identifier(projectUUID: nil, fileURL: URL(fileURLWithPath: "/tmp/One.fscr"))
    let other = BackupProjectIdentity.identifier(projectUUID: nil, fileURL: URL(fileURLWithPath: "/tmp/Two.fscr"))
    #expect(first == second)
    #expect(first.hasPrefix("path-"))
    #expect(first != other)
    #expect(first.count == "path-".count + 16)
}

// MARK: - Helpers

private struct ValidationFailure: Error {}

private struct FailingDirectoryFileManager: BackupFileManaging {
    private let base = SystemBackupFileManager()

    func fileExists(atPath path: String) -> Bool {
        base.fileExists(atPath: path)
    }

    func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]?
    ) throws {
        throw CocoaError(.fileWriteNoPermission)
    }

    func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL] {
        try base.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }

    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        try base.attributesOfItem(atPath: path)
    }

    func read(from url: URL) throws -> Data {
        try base.read(from: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try base.write(data, to: url)
    }

    func removeItem(at url: URL) throws {
        try base.removeItem(at: url)
    }
}
