import Foundation

/// Retention rules for automatic project backups.
///
/// The policy is pure and value-only so it can be shared by the app, the
/// `framescript` tool and the MCP server. Dates go in, decisions come out; the
/// clock and calendar are supplied by the caller.
public struct BackupPolicy: Codable, Hashable, Sendable {
    /// At most one automatic backup per project inside this window.
    public static let defaultMinimumInterval: TimeInterval = 10 * 60
    /// The newest backups that are always kept, whatever their age.
    public static let defaultMaximumCount = 20
    /// How many calendar days keep one daily backup in addition to the newest ones.
    public static let defaultDailyRetentionDays = 14
    /// Upper bound on retention-exempt safety copies. They do not count against
    /// `maximumCount`, so they need their own cap.
    public static let maximumSafetyCopyCount = 20

    /// Minimum number of seconds between two automatic backups of the same project.
    public var minimumInterval: TimeInterval
    /// Always keep this many of the newest backups.
    public var maximumCount: Int
    /// Keep one backup per calendar day for this many days, including today.
    public var dailyRetentionDays: Int

    public init(
        minimumInterval: TimeInterval = BackupPolicy.defaultMinimumInterval,
        maximumCount: Int = BackupPolicy.defaultMaximumCount,
        dailyRetentionDays: Int = BackupPolicy.defaultDailyRetentionDays
    ) {
        self.minimumInterval = max(0, minimumInterval)
        self.maximumCount = max(1, maximumCount)
        self.dailyRetentionDays = max(0, dailyRetentionDays)
    }

    /// Whether a new automatic backup is allowed now.
    ///
    /// The comparison uses the newest existing entry that is not in the
    /// future, not the newest file on disk, so a backup created with a forced
    /// restore safeguard also resets the automatic interval. A clock moved
    /// backwards, or a future stamp left by a mis-set clock, must not silently
    /// disable backups; future entries are simply ignored for the interval.
    public func allowsBackup(existing: [BackupEntry], now: Date) -> Bool {
        let newestPast = existing
            .map(\.createdAt)
            .filter { $0 <= now }
            .max()
        guard let newestPast else { return true }
        return now.timeIntervalSince(newestPast) >= max(0, minimumInterval)
    }

    /// Existing backups that may be removed under this policy.
    ///
    /// Keeps the newest `maximumCount` automatic entries plus the newest automatic
    /// entry of each calendar day inside the last `dailyRetentionDays` days (today
    /// included). Forced safety copies (pre-restore, pre-reload, pre-overwrite
    /// safeguards) never consume a slot in that newest-N window and never claim a
    /// day's retained slot either: a safeguard must not evict an older automatic
    /// backup the user may still need. At least the newest entry always survives,
    /// even if a decoded policy carries degenerate values.
    public func backupsToDelete(
        from existing: [BackupEntry],
        now: Date,
        calendar: Calendar = .current
    ) -> [BackupEntry] {
        guard !existing.isEmpty else { return [] }

        let sorted = existing.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                // The date is authoritative. When two entries share a stamp,
                // the later file name (timestamp + collision suffix) wins.
                return lhs.url.standardizedFileURL.path > rhs.url.standardizedFileURL.path
            }
            return lhs.createdAt > rhs.createdAt
        }

        var kept = Set<URL>()
        let automatic = sorted.filter { !$0.isSafetyCopy }
        for entry in automatic.prefix(max(1, maximumCount)) {
            kept.insert(entry.url.standardizedFileURL)
        }
        // Safety copies are retention-exempt, but they are still bounded so a
        // long restore session cannot fill the disk.
        for entry in sorted.filter(\.isSafetyCopy).prefix(BackupPolicy.maximumSafetyCopyCount) {
            kept.insert(entry.url.standardizedFileURL)
        }

        let retentionDays = max(0, dailyRetentionDays)
        if retentionDays > 0 {
            let today = calendar.startOfDay(for: now)
            let oldestDay = calendar.date(byAdding: .day, value: -(retentionDays - 1), to: today) ?? today
            var seenDays = Set<Date>()
            // Only automatic backups own a day. A safety copy made later on an
            // old day must not take that day's slot and evict its automatic
            // backup once the automatic one falls outside the newest-N window.
            for entry in automatic {
                let day = calendar.startOfDay(for: entry.createdAt)
                guard day >= oldestDay, day <= today else { continue }
                // `automatic` keeps the newest-first order, so the first entry
                // for a day is the one worth keeping.
                if seenDays.insert(day).inserted {
                    kept.insert(entry.url.standardizedFileURL)
                }
            }
        }

        return sorted.filter { !kept.contains($0.url.standardizedFileURL) }
    }
}
