import AppKit
import Foundation
import FrameScriptCore
import SwiftUI
import XCTest

@testable import FrameScript

/// Shared isolated setup for the Wave 3 A/B/F fix regressions. Every store uses
/// a `TestDefaults` suite under the process temporary directory.
@MainActor
enum W3FixABFSupport {
    static func makeDefaults() -> TestDefaults {
        TestDefaults.make()
    }

    static func makeAppState(
        project: FrameProject,
        defaults: UserDefaults,
        language: AppLanguage = .spanish,
        provider: (any LLMProviderProtocol)? = nil,
        confirmationHandler: AppState.ConfirmationHandler? = nil
    ) -> AppState {
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        var settings = AppSettings.defaults
        settings.generalPreferences.language = language
        settings.aiPreferences.provider = .openAICompatible
        let llm = provider ?? OpenAICompatibleLLMProvider()
        return AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            dependencies: AppDependencies(
                rewriteService: RewriteService(provider: llm),
                analysisService: AnalysisService(provider: llm),
                exportService: ExportService(),
                llmProvider: llm,
                providerCredentials: ProviderCredentialSession(reader: { _ in "test-key" })
            ),
            recording: RecordingController(
                preferences: OBSPreferencesStore(defaults: defaults, secretStore: W3FixABFEmptySecretStore()),
                defaults: defaults
            ),
            subscriptionRuntime: SubscriptionAIRuntime(
                store: SubscriptionAISettingsStore(userDefaults: defaults)
            ),
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults),
            confirmationHandler: confirmationHandler,
            templates: SampleData.templates,
            customTemplates: []
        )
    }

    static func makeProject(sceneText: String = "Uno dos tres.") -> FrameProject {
        let scene = Scene(
            order: 0,
            sectionType: .hook,
            title: "Gancho",
            scriptText: sceneText
        )
        return FrameProject(title: "Proyecto de prueba", scenes: [scene], primaryLanguage: "es")
    }
}

private struct W3FixABFEmptySecretStore: OBSSecretStoring {
    func readPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
}

/// Keeps an offscreen host window alive while a test drives AppKit views.
@MainActor
final class W3FixABFOffscreenHost {
    let window: NSWindow
    let hosting: NSHostingView<AnyView>

    init<Content: View>(_ root: Content, size: CGSize) {
        hosting = NSHostingView(rootView: AnyView(root))
        hosting.frame = NSRect(origin: .zero, size: size)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    func pump(_ seconds: TimeInterval = 0.08) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    func subviews<T: NSView>(of type: T.Type) -> [T] {
        Self.collect(hosting).compactMap { $0 as? T }
    }

    private static func collect(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(collect)
    }
}
