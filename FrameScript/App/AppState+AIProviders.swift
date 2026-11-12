import Foundation
import FrameScriptCore

// MARK: - F12 app wiring

/// Bridges the open FrameScript project to the subscription AI services.
/// The project keeps its own threads inside the `.fscr`, so switching projects
/// never reuses a T3 thread from another one.
@MainActor
extension AppState {
    var subscriptionAIContext: SubscriptionAIContext {
        guard hasOpenProject else { return .standalone() }
        let project = projectStore.project
        let settings = SubscriptionAISettingsStore.shared.settings
        let expectedProjectID = settings.t3ProjectIDForStorage
        let mapping = SubscriptionAIThreadMapping(
            read: { key in
                Self.threadID(
                    in: project.aiThreadMap,
                    storageKey: SubscriptionAIThreadKey.storageKey(key),
                    expectedProjectID: expectedProjectID
                )
            },
            write: { [weak self] threadID, key in
                guard let self, self.projectStore.project === project else { return }
                var map = project.aiThreadMap
                if !expectedProjectID.isEmpty {
                    map.t3ProjectID = expectedProjectID
                }
                let storageKey = SubscriptionAIThreadKey.storageKey(key)
                guard !storageKey.isEmpty else { return }
                map.threadIDsByProviderModel[storageKey] = threadID
                project.aiThreadMap = map
                self.touchProject()
            }
        )
        return SubscriptionAIContext(
            projectTitle: project.title,
            workingDirectory: projectStore.currentFileURL?.deletingLastPathComponent(),
            threadMapping: mapping
        )
    }

    func subscriptionAIThreadID(for selection: SubscriptionAISelection) -> String? {
        guard hasOpenProject,
              let key = SubscriptionAIThreadKey.storageKey(for: selection) else {
            return nil
        }
        let expectedProjectID = SubscriptionAISettingsStore.shared.settings.t3ProjectIDForStorage
        return Self.threadID(
            in: projectStore.project.aiThreadMap,
            storageKey: key,
            expectedProjectID: expectedProjectID
        )
    }

    /// "Nuevo hilo": forgets the thread for this provider+model pair. The entry
    /// for other pairs is kept, which is what D2 asks for.
    func subscriptionAIResetThread(for selection: SubscriptionAISelection) {
        guard hasOpenProject,
              let key = SubscriptionAIThreadKey.storageKey(for: selection) else {
            return
        }
        var map = projectStore.project.aiThreadMap
        map.threadIDsByProviderModel.removeValue(forKey: key)
        projectStore.project.aiThreadMap = map
        touchProject()
    }

    /// Selections that already have a thread, for the Settings summary.
    func subscriptionAIThreadEntries() -> [(task: SubscriptionAITask, selection: SubscriptionAISelection, threadID: String)] {
        guard hasOpenProject else { return [] }
        var seen = Set<String>()
        var entries: [(SubscriptionAITask, SubscriptionAISelection, String)] = []
        for (task, selection) in SubscriptionAISettingsStore.shared.settings.selectionsInUse() {
            guard let key = SubscriptionAIThreadKey.storageKey(for: selection),
                  !seen.contains(key),
                  let threadID = subscriptionAIThreadID(for: selection) else { continue }
            seen.insert(key)
            entries.append((task, selection, threadID))
        }
        return entries
    }

    private static func threadID(
        in map: AIThreadMap,
        storageKey: String,
        expectedProjectID: String
    ) -> String? {
        if !expectedProjectID.isEmpty,
           !map.t3ProjectID.isEmpty,
           map.t3ProjectID != expectedProjectID {
            return nil
        }
        guard let threadID = map.threadIDsByProviderModel[storageKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !threadID.isEmpty else {
            return nil
        }
        return threadID
    }
}
