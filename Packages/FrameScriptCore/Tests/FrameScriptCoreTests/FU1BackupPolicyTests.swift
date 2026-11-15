import Foundation
import Testing
@testable import FrameScriptCore

private let fu1ReferenceDate = Date(timeIntervalSince1970: 1_700_000_000)

/// FU1 fix-up regressions for `BackupPolicy`: a forced safety copy must never
/// consume a daily-retention slot, otherwise it evicts that day's automatic
/// backup as soon as the automatic one falls outside the newest-N window.
@Suite("FU1 backup policy")
struct FU1BackupPolicyTests {
    /// Midday in the test machine's calendar, so a backup made "later that day"
    /// cannot accidentally land on the next calendar day.
    private func midday(_ calendar: Calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: fu1ReferenceDate)
        return calendar.date(byAdding: .hour, value: 12, to: startOfDay) ?? fu1ReferenceDate
    }

    @Test("A safety copy never takes a day's daily-retention slot")
    func safetyCopyDoesNotTakeADailySlot() {
        let calendar = Calendar(identifier: .gregorian)
        let now = midday(calendar)
        let policy = BackupPolicy(
            minimumInterval: 0,
            maximumCount: 1,
            dailyRetentionDays: 14
        )
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: now) ?? now

        let newestAutomatic = BackupEntry(
            url: URL(fileURLWithPath: "/backups/d0-auto.fscr"),
            createdAt: now,
            byteSize: 1,
            originalFileName: "Project.fscr"
        )
        // Same old day: an automatic backup first, a pre-restore safety copy
        // ten minutes later. The automatic one is outside the newest-1 window.
        let oldAutomatic = BackupEntry(
            url: URL(fileURLWithPath: "/backups/d3-auto.fscr"),
            createdAt: threeDaysAgo,
            byteSize: 1,
            originalFileName: "Project.fscr"
        )
        let oldSafety = BackupEntry(
            url: URL(fileURLWithPath: "/backups/d3-safety.fscr"),
            createdAt: threeDaysAgo.addingTimeInterval(600),
            byteSize: 1,
            originalFileName: "Project.fscr",
            isSafetyCopy: true
        )

        let deletions = policy.backupsToDelete(
            from: [oldAutomatic, oldSafety, newestAutomatic],
            now: now,
            calendar: calendar
        )

        #expect(
            Set(deletions.map(\.url)) == [],
            "The newest automatic entry and one automatic backup per retained day must stay"
        )
        #expect(
            !deletions.contains { $0.url == oldAutomatic.url },
            "The forced safety copy must not use up the day's retained slot"
        )
    }

    @Test("Only an automatic backup claims a retained day")
    func automaticBackupClaimsTheDay() {
        let calendar = Calendar(identifier: .gregorian)
        let now = midday(calendar)
        let policy = BackupPolicy(minimumInterval: 0, maximumCount: 1, dailyRetentionDays: 14)

        let newestAutomatic = BackupEntry(
            url: URL(fileURLWithPath: "/backups/now.fscr"),
            createdAt: now,
            byteSize: 1,
            originalFileName: "Project.fscr"
        )
        let olderAutomatic = BackupEntry(
            url: URL(fileURLWithPath: "/backups/six-days.fscr"),
            createdAt: calendar.date(byAdding: .day, value: -6, to: now) ?? now,
            byteSize: 1,
            originalFileName: "Project.fscr"
        )
        let unrelatedAutomatic = BackupEntry(
            url: URL(fileURLWithPath: "/backups/ten-days.fscr"),
            createdAt: calendar.date(byAdding: .day, value: -10, to: now) ?? now,
            byteSize: 1,
            originalFileName: "Project.fscr"
        )

        let deletions = policy.backupsToDelete(
            from: [olderAutomatic, unrelatedAutomatic, newestAutomatic],
            now: now,
            calendar: calendar
        )

        // Both old days are inside the 14-day window and both have their own
        // automatic backup, so nothing is obsolete.
        #expect(Set(deletions.map(\.url)) == [])
    }

    @Test("Outside the daily window only the newest automatic backups survive")
    func outsideTheDailyWindowDeletesOlderAutomatics() {
        let calendar = Calendar(identifier: .gregorian)
        let now = midday(calendar)
        let policy = BackupPolicy(minimumInterval: 0, maximumCount: 1, dailyRetentionDays: 2)

        let newestAutomatic = BackupEntry(
            url: URL(fileURLWithPath: "/backups/now.fscr"),
            createdAt: now,
            byteSize: 1,
            originalFileName: "Project.fscr"
        )
        let tooOld = BackupEntry(
            url: URL(fileURLWithPath: "/backups/ten-days.fscr"),
            createdAt: calendar.date(byAdding: .day, value: -10, to: now) ?? now,
            byteSize: 1,
            originalFileName: "Project.fscr"
        )

        let deletions = policy.backupsToDelete(
            from: [newestAutomatic, tooOld],
            now: now,
            calendar: calendar
        )

        #expect(Set(deletions.map(\.url)) == [tooOld.url])
    }
}
