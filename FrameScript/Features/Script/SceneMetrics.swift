import Foundation
import FrameScriptCore
import Observation

/// Cached spoken word count and duration for a scene.
///
/// The editor header reads this cache instead of parsing the script in
/// `body`; `SceneMetricsDebouncer` fills it once typing pauses, from a single
/// `ScriptMarkup.estimate` parse per settled edit.
@MainActor
@Observable
final class SceneMetricsCache {
    struct Entry: Equatable, Sendable {
        let wordCount: Int
        let duration: TimeInterval
    }

    static let shared = SceneMetricsCache()

    private(set) var entries: [UUID: Entry] = [:]

    init() {}

    func entry(for sceneID: UUID) -> Entry? {
        entries[sceneID]
    }

    func store(_ estimate: MarkupEstimate, for sceneID: UUID) {
        entries[sceneID] = Entry(
            wordCount: estimate.spokenWordCount,
            duration: estimate.duration
        )
    }

    func remove(sceneID: UUID) {
        entries.removeValue(forKey: sceneID)
    }

    func removeAll() {
        entries.removeAll()
    }
}

/// Project/session-scoped cache resets used by `ProjectStore` when the open
/// document changes. Kept in one place so no cache outlives its scenes.
@MainActor
enum EditorMarkupSessionCaches {
    static func reset() {
        RhythmReviewCenter.shared.clear()
        SceneMetricsCache.shared.removeAll()
        SceneMetricsDebouncer.shared.cancelAll()
    }

    static func removeScene(_ sceneID: UUID) {
        RhythmReviewCenter.shared.removeScene(sceneID)
        SceneMetricsCache.shared.remove(sceneID: sceneID)
        SceneMetricsDebouncer.shared.cancel(sceneID: sceneID)
    }
}

/// Debounces scene metrics so typing never pays for a full-script parse.
///
/// A keystroke only replaces the pending task for that scene. After the delay,
/// the single parse runs off the main actor and the result is stored in
/// `SceneMetricsCache` plus applied to `Scene.estimatedDuration`.
@MainActor
final class SceneMetricsDebouncer {
    static let shared = SceneMetricsDebouncer()

    private var tasks: [UUID: Task<Void, Never>] = [:]

    init() {}

    func schedule(
        sceneID: UUID,
        text: String,
        configuration: DurationConfiguration,
        delay: Duration = .milliseconds(350),
        onEstimate: @escaping @MainActor (MarkupEstimate) -> Void
    ) {
        tasks[sceneID]?.cancel()
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let wordsPerMinute = configuration.wordsPerMinute
            let pauseDefaults = configuration.pauseDefaults
            let estimate = await Task.detached(priority: .userInitiated) {
                ScriptMarkup.estimate(
                    text,
                    wordsPerMinute: wordsPerMinute,
                    defaults: pauseDefaults
                )
            }.value
            guard !Task.isCancelled else { return }
            SceneMetricsCache.shared.store(estimate, for: sceneID)
            onEstimate(estimate)
            self.tasks[sceneID] = nil
        }
        tasks[sceneID] = task
    }

    func cancel(sceneID: UUID) {
        tasks[sceneID]?.cancel()
        tasks[sceneID] = nil
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }
}
