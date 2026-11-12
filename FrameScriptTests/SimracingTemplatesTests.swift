import Foundation
@testable import FrameScript
import XCTest

final class SimracingTemplatesTests: XCTestCase {
    func testFiveBuiltInSimracingTemplatesAreCompleteBlueprints() {
        let definitions = SimracingTemplates.all
        XCTAssertEqual(definitions.count, 5)
        XCTAssertEqual(Set(definitions.map(\.kind)).count, 5)

        let expectedCounts: [SimracingTemplates.Kind: Int] = [
            .updateAnalysis: 10,
            .modReview: 9,
            .comparison: 8,
            .news: 7,
            .raceChronicle: 7
        ]

        for definition in definitions {
            let template = definition.frameTemplate
            XCTAssertTrue(template.builtIn)
            XCTAssertEqual(template.category, .script)
            XCTAssertEqual(template.structureDefinition, definition.scenes.map(\.canonicalTitle))
            XCTAssertEqual(definition.scenes.count, expectedCounts[definition.kind] ?? -1)

            XCTAssertEqual(definition.scenes.first?.sectionType, .hook)
            XCTAssertLessThanOrEqual(definition.scenes.first?.targetDuration ?? .infinity, 15)
            XCTAssertGreaterThan(definition.targetDuration, 0)

            XCTAssertTrue(definition.scenes.contains { $0.reHook != nil })
            for scene in definition.scenes {
                XCTAssertGreaterThan(scene.targetDuration, 0)
                XCTAssertFalse(scene.prompt.text(for: .spanish).isEmpty)
                XCTAssertFalse(scene.prompt.text(for: .english).isEmpty)
                XCTAssertFalse(scene.editingNote.text(for: .spanish).isEmpty)
                XCTAssertFalse(scene.captures.isEmpty)
                XCTAssertTrue(scene.captures.allSatisfy { !$0.description.text(for: .spanish).isEmpty })
            }

            let sources = Set(definition.scenes.flatMap { $0.captures.map(\.source) })
            XCTAssertEqual(sources, Set(SimracingTemplates.CaptureSource.allCases))
            XCTAssertTrue(definition.scenes.flatMap { $0.captures }.contains { $0.source == .cam })
            XCTAssertTrue(definition.scenes.flatMap { $0.captures }.contains { $0.source == .obsGameplay })
            XCTAssertTrue(definition.scenes.flatMap { $0.captures }.contains { $0.source == .screenshot })
            XCTAssertTrue(definition.scenes.flatMap { $0.captures }.contains { $0.source == .web })

            for scene in definition.scenes where scene.canonicalTitle != "CTA" {
                XCTAssertNotEqual(scene.localizedTitle(.spanish), scene.localizedTitle(.english))
            }
        }

        let updated = definitions.first { $0.kind == .updateAnalysis }
        XCTAssertGreaterThanOrEqual(updated?.scenes.compactMap(\.reHook).count ?? 0, 2)
    }

    func testNamesAndDescriptionsAreLocalized() {
        for definition in SimracingTemplates.all {
            for language in [AppLanguage.english, .spanish, .russian] {
                let name = definition.localizedName(language)
                XCTAssertFalse(name.isEmpty)
                XCTAssertNotEqual(name, "template.\(definition.name)")
                let description = definition.localizedDescription(language)
                XCTAssertFalse(description.isEmpty)
                XCTAssertNotEqual(description, "template.\(definition.name).description")
            }
            XCTAssertNotEqual(definition.localizedName(.spanish), definition.localizedName(.english))
            XCTAssertNotEqual(definition.localizedDescription(.spanish), definition.localizedDescription(.english))
        }
    }

    func testEachTemplateInstantiatesIntoProjectWithExpectedSpanishScenes() throws {
        for definition in SimracingTemplates.all {
            let project = SampleData.project(
                named: "Prueba",
                template: definition.frameTemplate,
                language: .spanish
            )
            let scenes = project.scenes.sortedByOrder

            XCTAssertEqual(project.templateID, definition.id)
            XCTAssertEqual(scenes.count, definition.scenes.count)
            XCTAssertEqual(scenes.map(\.title), definition.scenes.map { $0.localizedTitle(.spanish) })
            XCTAssertEqual(scenes.map(\.sectionType), definition.scenes.map(\.sectionType))
            XCTAssertTrue(scenes.allSatisfy { $0.scriptText.isEmpty && !$0.textSegments.isEmpty })

            for (scene, blueprint) in zip(scenes, definition.scenes) {
                XCTAssertTrue(scene.notes.contains("Objetivo:"))
                XCTAssertTrue(scene.notes.contains("Captura:"))
                XCTAssertTrue(scene.notes.contains("Montaje:"))
                XCTAssertTrue(scene.notes.contains("Duración objetivo:"))
                XCTAssertTrue(scene.notes.contains(blueprint.prompt.text(for: .spanish)))
                XCTAssertEqual(scene.bRollItems.count, blueprint.captures.count)
                XCTAssertEqual(scene.bRollItems.map(\.sourceType), blueprint.captures.map { $0.source.brollSource })
                XCTAssertTrue(scene.bRollItems.allSatisfy { $0.textAnchor == nil && $0.status == .idea })
                XCTAssertEqual(scene.editingItems.count, 1)
                XCTAssertEqual(scene.editingItems.first?.textAnchor, nil)
                XCTAssertEqual(scene.editingItems.first?.cutStyle, "Nota de plantilla")
                XCTAssertEqual(scene.editingItems.first?.notes, blueprint.editingNote.text(for: .spanish))
            }
        }
    }

    func testEachTemplateInstantiatesWithEnglishTitlesAndGuidance() throws {
        for definition in SimracingTemplates.all {
            let project = SampleData.project(
                named: "Test",
                template: definition.frameTemplate,
                language: .english
            )
            let scenes = project.scenes.sortedByOrder

            XCTAssertEqual(scenes.map(\.title), definition.scenes.map { $0.localizedTitle(.english) })
            XCTAssertEqual(scenes.first?.title, definition.scenes.first?.localizedTitle(.english))
            XCTAssertTrue(scenes.allSatisfy { $0.notes.contains("Goal:") && $0.notes.contains("Target duration:") })
            XCTAssertTrue(scenes.allSatisfy { $0.editingItems.first?.cutStyle == "Template note" })
        }
    }

    func testSimracingTemplatesAreAppendedWithoutChangingCoreTemplates() throws {
        let all = SampleData.templates
        XCTAssertEqual(all.count, 12)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertEqual(all.prefix(7).map(\.name), [
            "Blank", "Standard YouTube", "Educational", "Storytelling",
            "Product Review", "Commentary / Essay", "Tutorial"
        ])
        XCTAssertEqual(SimracingTemplates.frameTemplates.count, 5)
        XCTAssertEqual(Set(all.suffix(5).map(\.id)), Set(SimracingTemplates.frameTemplates.map(\.id)))

        let blank = try XCTUnwrap(all.first)
        let project = SampleData.project(named: "Blank", template: blank, language: .spanish)
        XCTAssertEqual(project.scenes.count, 1)
        XCTAssertEqual(project.scenes.first?.scriptText, "")
    }

    func testProjectFromTemplateKeepsCoreTemplateBehaviour() throws {
        let tutorial = try XCTUnwrap(SampleData.templates.first { $0.name == "Tutorial" })
        let project = SampleData.project(named: "Tutorial", template: tutorial, language: .spanish)
        XCTAssertEqual(project.scenes.map(\.title), tutorial.structureDefinition)
        XCTAssertTrue(project.scenes.allSatisfy { $0.bRollItems.isEmpty && $0.editingItems.isEmpty })
    }

    func testCustomizedCopyUsesItsEditedStructureInsteadOfTheBlueprint() throws {
        let definition = try XCTUnwrap(SimracingTemplates.all.first { $0.kind == .updateAnalysis })
        var customized = definition.frameTemplate
        customized.builtIn = false
        customized.builtInSourceName = definition.name
        customized.name = "Mi análisis"
        customized.structureDefinition = ["Mi gancho", "Mi veredicto"]

        let project = SampleData.project(named: "Custom", template: customized, language: .spanish)

        XCTAssertEqual(project.templateID, customized.id)
        XCTAssertEqual(project.scenes.map(\.title), ["Mi gancho", "Mi veredicto"])
        XCTAssertTrue(project.scenes.allSatisfy { $0.notes.isEmpty && $0.bRollItems.isEmpty && $0.editingItems.isEmpty })
    }

    @MainActor
    func testAppStateCreatesSpanishSimracingProjectFromTemplate() throws {
        let definition = try XCTUnwrap(SimracingTemplates.all.first { $0.kind == .updateAnalysis })
        let suite = UserDefaults(suiteName: "SimracingTemplatesTests-\(UUID().uuidString)")!
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        let store = ProjectStore()
        let appState = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: settings, userDefaults: suite, key: "settings")
        )

        appState.createNewProject(named: "Análisis", template: definition.frameTemplate)

        XCTAssertEqual(appState.displayName(definition.frameTemplate), definition.localizedName(.spanish))
        XCTAssertEqual(appState.localizedTemplateSceneName("What changes I"), "Qué cambia I")
        XCTAssertEqual(appState.localizedTemplateSceneName("Hook / result"), "Gancho / resultado")
        XCTAssertEqual(store.project.templateID, definition.id)
        XCTAssertEqual(store.project.scenes.count, definition.scenes.count)
        XCTAssertEqual(store.project.scenes.sortedByOrder.map(\.title), definition.scenes.map { $0.localizedTitle(.spanish) })
    }
}
