import AppKit
import FrameScriptCore
import SwiftUI
import XCTest
@testable import FrameScript

/// WP2 visual coverage for the AI review panel, whose analyze action changed
/// from a plain text button to a bordered control and gained accessibility
/// labels. The subscription settings and hook sheet screens are covered by
/// `MainWindowSnapshotTests`.
@MainActor
final class WP2SnapshotTests: FrameScriptTestCase {
    func testAIReviewPanelSnapshots() {
        let project = SampleData.demoProject(language: .spanish)
        let appState = makeSnapshotAppState(project: project)
        appState.settings.editorPreferences.showAIReviewPanel = true
        renderAll("ai-review-panel-empty", appState: appState) {
            panel()
        }
    }

    func testAIReviewPanelWithCommentsSnapshots() {
        let project = SampleData.demoProject(language: .spanish)
        let scene = project.scenes.sortedByOrder[0]
        scene.aiComments = [
            AIComment(
                sceneID: scene.id,
                type: "Gancho",
                severity: .important,
                message: "El gancho explica el contexto antes de la promesa.",
                suggestion: "Empieza por el dato del retraso."
            ),
            AIComment(
                sceneID: scene.id,
                type: "Ritmo",
                severity: .suggestion,
                message: "La segunda frase tiene 31 palabras.",
                suggestion: "Pártela en dos."
            )
        ]
        let appState = makeSnapshotAppState(project: project)
        appState.editorState.selectedSceneID = scene.id
        appState.settings.editorPreferences.showAIReviewPanel = true
        renderAll("ai-review-panel-comments", appState: appState) {
            panel()
        }
    }

    func testSubscriptionSettingsRecoveryNoticeSnapshots() {
        let appState = makeSnapshotAppState(project: SampleData.demoProject(language: .spanish))
        let defaults = makeDefaults()
        defaults.set(Data("not the subscription settings".utf8), forKey: SubscriptionAISettingsStore.storageKey)
        let store = SubscriptionAISettingsStore(userDefaults: defaults)
        XCTAssertTrue(store.didRecoverFromUnreadableSettings)

        renderAll("ai-provider-settings-recovered", appState: appState) {
            ScrollView {
                SubscriptionAISettingsView(
                    store: store,
                    runtime: SubscriptionAIRuntime(store: store)
                )
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: Helpers

    private func panel() -> some View {
        HStack(spacing: 0) {
            AIReviewPanel()
                .frame(width: 320)
            Spacer(minLength: 0)
        }
    }

    private func renderAll<Content: View>(
        _ screen: String,
        appState: AppState,
        file: StaticString = #filePath,
        line: UInt = #line,
        @ViewBuilder content: () -> Content
    ) {
        for size in SnapshotSize.allCases {
            for appearance in SnapshotAppearance.allCases {
                let name = "\(screen)-\(size.label)-\(appearance.rawValue)"
                let result = SnapshotRenderer.render(
                    content(),
                    name: name,
                    suite: "WP2SnapshotTests",
                    size: size.size,
                    appearance: appearance,
                    language: .spanish,
                    appState: appState,
                    file: file,
                    line: line
                )
                XCTAssertGreaterThan(result.pixelSize.width, 0, "\(name) produced no pixels", file: file, line: line)
                XCTAssertGreaterThan(result.pixelSize.height, 0, "\(name) produced no pixels", file: file, line: line)
            }
        }
    }

    private func makeSnapshotAppState(project: FrameProject) -> AppState {
        let defaults = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        settings.generalPreferences.autosaveEnabled = false
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        let appState = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults)
        )
        appState.editorState.selectedSceneID = project.scenes.sortedByOrder.first?.id
        return appState
    }
}
