import Foundation
import Testing
@testable import FrameScriptCore

private let wp1BaseDate = Date(timeIntervalSince1970: 1_700_000_000)
private let wp1ProjectID = "22222222-2222-2222-2222-222222222222"

private final class WP1Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// WP1 regression tests for backup safety: symlinked project files, in-memory
/// safety copies, and retention that must not evict automatic backups.
@Suite("WP1 backup safety")
struct WP1BackupSafetyTests {
    @Test("A symlinked project file gets a backup of its target")
    func symlinkedProjectFileGetsABackup() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Real.fscr")
        let link = root.appendingPathComponent("Linked.fscr")
        try Data("project bytes".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let store = BackupStore(rootDirectory: root.appendingPathComponent("Backups"), now: { wp1BaseDate })
        let outcome = store.backUpIfNeeded(fileURL: link, projectID: wp1ProjectID)

        guard case let .created(entry, warning) = outcome else {
            Issue.record("A symlinked project file must produce a backup, got \(outcome)")
            return
        }
        #expect(warning == nil)
        #expect(try Data(contentsOf: entry.url) == Data("project bytes".utf8))
        #expect(entry.originalPath == target.resolvingSymlinksInPath().path)
        #expect(entry.isSafetyCopy == false)
        // The link itself is untouched.
        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    @Test("In-memory bytes can be backed up as a safety copy")
    func inMemoryDataIsBackedUp() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackupStore(rootDirectory: root, now: { wp1BaseDate })

        let outcome = store.backUpData(
            Data("local edit".utf8),
            originalFileName: "My Project.fscr",
            originalPath: "/tmp/My Project.fscr",
            projectID: wp1ProjectID
        )

        guard case let .created(entry, _) = outcome else {
            Issue.record("Expected a created backup, got \(outcome)")
            return
        }
        #expect(try Data(contentsOf: entry.url) == Data("local edit".utf8))
        #expect(entry.originalFileName == "My Project.fscr")
        #expect(entry.isSafetyCopy)
        // The flag survives the metadata round trip the listing uses.
        let listed = try #require(store.listBackups(projectID: wp1ProjectID).first)
        #expect(listed.isSafetyCopy)
    }

    @Test("Forced safeguard copies do not evict the newest automatic backups")
    func safetyCopiesDoNotEvictAutomaticBackups() {
        let now = wp1BaseDate
        let policy = BackupPolicy(
            minimumInterval: 0,
            maximumCount: 2,
            dailyRetentionDays: 0
        )
        let automaticOld = BackupEntry(
            url: URL(fileURLWithPath: "/backups/old.fscr"),
            createdAt: now.addingTimeInterval(-300),
            byteSize: 1,
            originalFileName: "Project.fscr"
        )
        let automaticNewer = BackupEntry(
            url: URL(fileURLWithPath: "/backups/newer.fscr"),
            createdAt: now.addingTimeInterval(-200),
            byteSize: 1,
            originalFileName: "Project.fscr"
        )
        let safety = BackupEntry(
            url: URL(fileURLWithPath: "/backups/safety.fscr"),
            createdAt: now.addingTimeInterval(-100),
            byteSize: 1,
            originalFileName: "Project.fscr",
            isSafetyCopy: true
        )
        let newestAutomatic = BackupEntry(
            url: URL(fileURLWithPath: "/backups/newest.fscr"),
            createdAt: now,
            byteSize: 1,
            originalFileName: "Project.fscr"
        )

        let deletions = policy.backupsToDelete(
            from: [automaticOld, automaticNewer, safety, newestAutomatic],
            now: now
        )

        // Newest two automatic entries plus the safety copy stay; only the
        // oldest automatic entry is removed.
        #expect(Set(deletions.map(\.url)) == [automaticOld.url])
        #expect(!deletions.contains { $0.isSafetyCopy })
    }

    @Test("Safety copies are bounded so a restore loop cannot fill the disk")
    func safetyCopiesAreBounded() {
        let now = wp1BaseDate
        let policy = BackupPolicy(minimumInterval: 0, maximumCount: 5, dailyRetentionDays: 0)
        var entries: [BackupEntry] = (0..<25).map { index in
            BackupEntry(
                url: URL(fileURLWithPath: "/backups/safety-\(index).fscr"),
                createdAt: now.addingTimeInterval(TimeInterval(-index)),
                byteSize: 1,
                originalFileName: "Project.fscr",
                isSafetyCopy: true
            )
        }
        entries.append(BackupEntry(
            url: URL(fileURLWithPath: "/backups/auto.fscr"),
            createdAt: now.addingTimeInterval(-100),
            byteSize: 1,
            originalFileName: "Project.fscr"
        ))

        let deletions = policy.backupsToDelete(from: entries, now: now)

        #expect(deletions.count == 5)
        #expect(deletions.allSatisfy { $0.isSafetyCopy })
        #expect(!deletions.contains { $0.url.lastPathComponent == "auto.fscr" })
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameScriptWP1Backups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
