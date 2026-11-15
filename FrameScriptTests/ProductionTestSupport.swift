import Foundation
import FrameScriptCore
import XCTest
@testable import FrameScript

/// Shared fixture and isolation rules for production tests.
///
/// Every test gets its own `UserDefaults` suite; tear-down removes the domain
/// and the on-disk plist so no `FrameScriptTests.*` leftovers remain.
@MainActor
class ProductionTestCase: XCTestCase {
    private(set) var suiteName = ""
    private(set) var suite: UserDefaults!
    weak var lastAppState: AppState?

    override func setUp() {
        super.setUp()
        ProductionTestBundleCleanup.register()
        suiteName = "FrameScriptTests.Production.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
        ProductionPresentation.shared.resetForTesting()
        ProductionChecklistCenter.shared.clear()
    }

    override func tearDown() {
        ProductionPresentation.shared.resetForTesting()
        ProductionChecklistCenter.shared.clear()
        XCTAssertNil(lastAppState, "AppState was retained after the test")
        if !suiteName.isEmpty {
            let name = suiteName
            suite?.removePersistentDomain(forName: name)
            suite?.synchronize()
            CFPreferencesAppSynchronize(name as CFString)
            let plist = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(name).plist")
            try? FileManager.default.removeItem(at: plist)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            try? FileManager.default.removeItem(at: plist)
        }
        suite = nil
        suiteName = ""
        super.tearDown()
    }

    func makeAppState(project: FrameProject) -> AppState {
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: true)

        let appState = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: .defaults, userDefaults: suite, key: "settings"),
            recording: RecordingController(
                preferences: OBSPreferencesStore(
                    defaults: suite,
                    secretStore: EmptyOBSSecretStore()
                ),
                defaults: suite
            ),
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: suite)
        )
        appState.settings.generalPreferences.language = AppLanguage.spanish
        appState.editorState.selectedSceneID = project.scenes.sortedByOrder.first?.id
        appState.refreshProductionChecklist()
        lastAppState = appState
        return appState
    }

    /// Synthetic Spanish project used by the logic and snapshot tests.
    func makeSpanishFixtureProject() -> FrameProject {
        let sceneText = "Hoy vamos a probar el nuevo simulador en la recta."
        let secondText = "El coche gira mejor cuando frenamos antes de la curva."

        let anchor = TextAnchor(
            startUTF16: 0,
            lengthUTF16: 3,
            selectedText: "Hoy"
        )
        let bRoll = BRollItem(
            textAnchor: anchor,
            templateType: "",
            sourceType: .stockFootage,
            descriptionText: "Plano del coche en la recta",
            status: .idea
        )
        let editing = EditingItem(
            textAnchor: anchor,
            templateType: "",
            cutStyle: "Corte seco al volante",
            transition: "",
            subtitleStyle: ""
        )
        let firstScene = Scene(
            order: 0,
            sectionType: .hook,
            title: "Gancho",
            scriptText: sceneText,
            bRollItems: [bRoll],
            editingItems: [editing]
        )

        let doneBRoll = BRollItem(
            templateType: "",
            sourceType: .screenRecording,
            descriptionText: "Telemetría en pantalla",
            status: .done
        )
        let doneEditing = EditingItem(
            templateType: "",
            cutStyle: "Fundido a la telemetría",
            transition: "",
            subtitleStyle: "",
            status: .done
        )
        let goodTake = Take(
            number: 1,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 18,
            rating: .good,
            sceneTextHash: FrameScriptDocument.TextHash.hash(secondText)
        )
        let secondScene = Scene(
            order: 1,
            sectionType: .explanation,
            title: "Explicación",
            scriptText: secondText,
            bRollItems: [doneBRoll],
            editingItems: [doneEditing],
            takes: [goodTake]
        )

        let asset = ProjectAsset(
            path: "/tmp/telemetria.mov",
            linkedBRollItemIDs: [doneBRoll.id]
        )
        let claim = ProjectClaim(
            text: "El neumático nuevo mejora el agarre",
            status: .probable,
            sceneIDs: [firstScene.id]
        )
        let pack = PublishingPack(
            chosenTitle: "",
            description: "Descripción del vídeo",
            tags: [],
            thumbnailVariants: []
        )
        let pendingTask = ChecklistTask(
            text: "Grabar la intro",
            kind: .record,
            sceneID: firstScene.id
        )
        let doneTask = ChecklistTask(
            text: "Revisar fuentes",
            kind: .research,
            isDone: true
        )

        return FrameProject(
            title: "Vídeo de prueba",
            scenes: [firstScene, secondScene],
            primaryLanguage: "es",
            assets: [asset],
            publishingPacks: ["es": pack],
            checklistTasks: [pendingTask, doneTask],
            claims: [claim]
        )
    }
}

/// Last-chance sweep after the whole test bundle. cfprefsd can flush an empty
/// domain after an individual tearDown, so the bundle observer removes any
/// production suites that survived until the end of the run.
final class ProductionTestBundleCleanup: NSObject, XCTestObservation, @unchecked Sendable {
    private static let shared = ProductionTestBundleCleanup()
    nonisolated(unsafe) private static var didRegister = false
    private static let prefix = "FrameScriptTests.Production."

    static func register() {
        guard !didRegister else { return }
        didRegister = true
        XCTestObservationCenter.shared.addTestObserver(shared)
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let fileManager = FileManager.default
        let preferences = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: preferences,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files
        where file.lastPathComponent.hasPrefix(Self.prefix) && file.pathExtension == "plist" {
            let name = file.deletingPathExtension().lastPathComponent
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            CFPreferencesAppSynchronize(name as CFString)
            try? fileManager.removeItem(at: file)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        for file in (try? fileManager.contentsOfDirectory(at: preferences, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasPrefix(Self.prefix) && file.pathExtension == "plist" {
            try? fileManager.removeItem(at: file)
        }

        // cfprefsd can flush an empty domain after the test host exits, which
        // recreates a 42-byte plist. A detached one-shot cleanup runs after
        // the host is gone and removes only this feature's suites.
        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: "/bin/sh")
        cleanup.arguments = [
            "-c",
            "sleep 2; rm -f \"$HOME\"/Library/Preferences/FrameScriptTests.Production.*.plist"
        ]
        cleanup.standardOutput = FileHandle.nullDevice
        cleanup.standardError = FileHandle.nullDevice
        try? cleanup.run()
    }
}

/// Stateless fake so no test can read or write the real OBS Keychain item.
struct EmptyOBSSecretStore: OBSSecretStoring {
    func readPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
}

@MainActor
final class RecordingProductionNavigator: ProductionNavigator {
    var targets: [ProductionTarget] = []
    var accepts = true

    func navigate(to target: ProductionTarget) -> Bool {
        targets.append(target)
        return accepts
    }
}
