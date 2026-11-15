import AppKit

/// Announces a transient notice to assistive technology (uiux 18).
///
/// Kept separate from the view so the payload is unit-testable: VoiceOver reads
/// `NSAccessibility.NotificationUserInfoKey.announcement` at high priority.
enum AccessibilityAnnouncement {
    static func userInfo(for message: String) -> [NSAccessibility.NotificationUserInfoKey: Any] {
        [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ]
    }

    /// Posts the announcement without touching focus or the window stack.
    @MainActor
    static func post(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: userInfo(for: trimmed)
        )
    }
}
