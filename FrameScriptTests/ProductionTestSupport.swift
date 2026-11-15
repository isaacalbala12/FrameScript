import Foundation
import FrameScriptCore
import XCTest
@testable import FrameScript

/// Shared fixture and isolation rules for production tests.
///
/// The suite comes from `TestDefaults.make()`, an absolute path inside the
/// per-process temporary directory, so CFPreferences writes the plist next to
/// the fixture instead of `~/Library/Preferences`. `cleanup()` removes the
/// domain, the plist and the directory in `tearDown`.
@MainActor
class ProductionTestCase: XCTestCase {
    private var testDefaults: TestDefaults?
    private(set) var suite: UserDefaults!
    weak var lastAppState: AppState?

    override func setUp() {
        super.setUp()
        TestBundleCleanup.register()
        let made = TestDefaults.make()
        testDefaults = made
        suite = made.defaults
        ProductionPresentation.shared.resetForTesting()
        ProductionChecklistCenter.shared.clear()
    }

    override func tearDown() {
        ProductionPresentation.shared.resetForTesting()
        ProductionChecklistCenter.shared.clear()
        XCTAssertNil(lastAppState, "AppState was retained after the test")
        testDefaults?.cleanup()
        testDefaults = nil
        suite = nil
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
