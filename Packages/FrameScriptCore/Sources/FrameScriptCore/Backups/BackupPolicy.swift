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
    /// The comparison uses the newest existing entry, not the newest file on
    /// disk, so a backup created with a forced restore safeguard also resets
    /// the automatic interval.
    public func allowsBackup(existing: [BackupEntry], now: Date) -> Bool {
        guard let newest = existing.map(\.createdAt).max() else { return true }
        return now.timeIntervalSince(newest) >= max(0, minimumInterval)
    }

    /// Existing backups that may be removed under this policy.
    ///
    /// Keeps the newest `maximumCount` entries plus the newest entry of each
    /// calendar day inside the last `dailyRetentionDays` days (today included).
    /// At least the newest entry always survives, even if a decoded policy
    /// carries degenerate values.
    public func backupsToDelete(
        from existing: [BackupEntry],
        now: Date,
        calendar: Calendar = .current
    ) -> [BackupEntry] {
        guard !existing.isEmpty else { return [] }

        let sorted = existing.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.url.standardizedFileURL.path < rhs.url.standardizedFileURL.path
            }
            return lhs.createdAt > rhs.createdAt
        }

        var kept = Set<URL>()
        for entry in sorted.prefix(max(1, maximumCount)) {
            kept.insert(entry.url.standardizedFileURL)
        }

        let retentionDays = max(0, dailyRetentionDays)
        if retentionDays > 0 {
            let today = calendar.startOfDay(for: now)
            let oldestDay = calendar.date(byAdding: .day, value: -(retentionDays - 1), to: today) ?? today
            var seenDays = Set<Date>()
            for entry in sorted {
                let day = calendar.startOfDay(for: entry.createdAt)
                guard day >= oldestDay, day <= today else { continue }
                // `sorted` is newest first, so the first entry for a day is the
                // one worth keeping.
                if seenDays.insert(day).inserted {
                    kept.insert(entry.url.standardizedFileURL)
                }
            }
        }

        return sorted.filter { !kept.contains($0.url.standardizedFileURL) }
    }
}
