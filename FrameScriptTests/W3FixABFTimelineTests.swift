import AppKit
import Foundation
import FrameScriptCore
import SwiftUI
import XCTest

@testable import FrameScript

/// B-1, B-2, N-2, A-3/A-5 and the mode-switcher label/spacing fix.
@MainActor
final class W3FixABFTimelineTests: XCTestCase {
    private var isolatedDefaults: TestDefaults?
    private var appState: AppState?

    override func setUp() async throws {
        try await super.setUp()
        TestBundleCleanup.register()
    }

    override func tearDown() async throws {
        appState = nil
        isolatedDefaults?.cleanup()
        isolatedDefaults = nil
        try await super.tearDown()
    }

    // MARK: - B-1

    func testW3FixABFUnanchoredTimelineItemOpensItsWorkspace() {
        let scene = makeScene(text: "Uno dos tres")
        scene.bRollItems[0].textAnchor = nil
        let applicationState = makeAppState(scene: scene)

        applicationState.openTimelineProductionItem(
            scene.bRollItems[0].id,
            sceneID: scene.id,
            mode: .bRoll
        )

        XCTAssertEqual(applicationState.selectedMode, .bRoll)
        XCTAssertEqual(applicationState.selectedScene?.id, scene.id)
        XCTAssertTrue(applicationState.editorState.selectedProductionItemIDs.isEmpty)
    }

    func testW3FixABFStaleAnchorTimelineItemOpensItsWorkspace() {
        let scene = makeScene(text: "Uno dos tres")
        scene.editingItems[0].textAnchor = TextAnchor(
            startUTF16: 99_999,
            lengthUTF16: 4,
            selectedText: "Antiguo",
            prefixContext: "zzz",
            suffixContext: "yyy"
        )
        let applicationState = makeAppState(scene: scene)

        applicationState.openTimelineProductionItem(
            scene.editingItems[0].id,
            sceneID: scene.id,
            mode: .editing
        )

        XCTAssertEqual(applicationState.selectedMode, .editing)
        XCTAssertEqual(applicationState.selectedScene?.id, scene.id)
        XCTAssertTrue(applicationState.editorState.selectedProductionItemIDs.isEmpty)
    }

    func testW3FixABFAnchoredTimelineItemStillSelectsIt() {
        let scene = makeScene(text: "Uno dos tres")
        let item = scene.bRollItems[0]
        let applicationState = makeAppState(scene: scene)

        applicationState.openTimelineProductionItem(item.id, sceneID: scene.id, mode: .bRoll)

        XCTAssertEqual(applicationState.selectedMode, .bRoll)
        XCTAssertTrue(applicationState.editorState.selectedProductionItemIDs.contains(item.id))
    }

    // MARK: - B-2

    func testW3FixABFZoomShortcutResolvesEqualsAndPlus() {
        XCTAssertEqual(
            ShortcutRegistry.command(for: .init("=", modifiers: [.command])),
            .timelineZoomIn
        )
        XCTAssertEqual(
            ShortcutRegistry.command(for: .init("+", modifiers: [.command])),
            .timelineZoomIn
        )
        XCTAssertEqual(
            ShortcutRegistry.command(for: .init("+", modifiers: [.command, .shift])),
            .timelineZoomIn
        )
        XCTAssertEqual(
            ShortcutRegistry.command(for: .init("=", modifiers: [.command, .shift])),
            .timelineZoomIn
        )
        XCTAssertNil(ShortcutRegistry.command(for: .init("+", modifiers: [])))
        XCTAssertEqual(
            ShortcutRegistry.binding(for: .timelineZoomOut, overrides: [:]),
            .init("-", modifiers: [.command])
        )
    }

    func testW3FixABFPlusZoomWorksThroughTheRealPhysicalRouter() throws {
        let settings = AppSettings.defaults
        let menu = NSMenu()
        var performed: ShortcutCommand?

        // Spanish ISO: the "+" key is keyCode 30 with characters "+".
        let plus = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "+",
                charactersIgnoringModifiers: "+",
                isARepeat: false,
                keyCode: 30
            )
        )
        XCTAssertTrue(
            PhysicalShortcutMenuDispatcher.dispatch(plus, settings: settings, menu: menu) { command in
                performed = command
                return true
            }
        )
        XCTAssertEqual(performed, .timelineZoomIn)

        // US: ⇧⌘= still reaches the same command through the ANSI key code.
        performed = nil
        let shiftEquals = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "=",
                charactersIgnoringModifiers: "=",
                isARepeat: false,
                keyCode: 24
            )
        )
        XCTAssertTrue(
            PhysicalShortcutMenuDispatcher.dispatch(shiftEquals, settings: settings, menu: menu) { command in
                performed = command
                return true
            }
        )
        XCTAssertEqual(performed, .timelineZoomIn)
    }

    // MARK: - N-2

    func testW3FixABFTimelineUsesLocalizedSourceName() {
        let scene = makeScene(text: "Uno dos tres")
        scene.bRollItems[0].descriptionText = ""
        scene.bRollItems[0].sourceType = .custom
        scene.bRollItems[0].textAnchor = nil
        let project = FrameProject(title: "Sintético", scenes: [scene], primaryLanguage: "es")

        let spanish = TimelineInputBuilder.input(
            project: project,
            configuration: DurationConfiguration(wordsPerMinute: 150),
            selectedTakeIDs: [:],
            warningsByScene: [:],
            projectWarnings: [],
            interfaceLanguage: .spanish
        )
        let english = TimelineInputBuilder.input(
            project: project,
            configuration: DurationConfiguration(wordsPerMinute: 150),
            selectedTakeIDs: [:],
            warningsByScene: [:],
            projectWarnings: [],
            interfaceLanguage: .english
        )

        XCTAssertEqual(spanish.scenes[0].bRoll[0].label, "Personalizado")
        XCTAssertEqual(english.scenes[0].bRoll[0].label, "Custom")
    }

    // MARK: - A-3 / A-5

    func testW3FixABFPluralCountsUseOneSceneAndOneWarning() {
        XCTAssertEqual(
            TimelineSubtitle.text(sceneCount: 1, totalDuration: 0, language: .spanish),
            "1 escena · 0:00"
        )
        XCTAssertEqual(
            TimelineSubtitle.text(sceneCount: 1, totalDuration: 12, language: .russian),
            "1 сцена · 0:12"
        )
        XCTAssertEqual(
            L10n.plural("timeline.sceneCount", count: 2, language: .russian),
            "2 сцены"
        )
        XCTAssertEqual(
            L10n.plural("timeline.sceneCount", count: 5, language: .russian),
            "5 сцен"
        )
        XCTAssertEqual(
            L10n.plural("timeline.warningsCount", count: 1, language: .spanish),
            "1 aviso de ritmo"
        )
        XCTAssertEqual(
            L10n.plural("timeline.blockCount", count: 1, language: .spanish),
            "1 bloque"
        )
    }

    func testW3FixABFUnanchoredEditingAndVisualLabelsShareTheTerm() {
        let sceneID = UUID()
        let editing = TimelineBlock(
            id: "editing",
            sceneID: sceneID,
            track: .editing,
            start: 0,
            end: 0,
            label: "Corte suave",
            isAnchored: false
        )
        let visual = TimelineBlock(
            id: "broll",
            sceneID: sceneID,
            track: .bRoll,
            start: 0,
            end: 1,
            label: "Plano de apoyo",
            isAnchored: false
        )

        XCTAssertEqual(
            TimelineBlockLabel.label(for: editing, layout: .empty, language: .spanish),
            "Corte suave · Sin anclar"
        )
        XCTAssertEqual(
            TimelineBlockLabel.label(for: visual, layout: .empty, language: .spanish),
            "Plano de apoyo · Sin anclar"
        )
        XCTAssertEqual(
            L10n.tr("avScript.unanchored", language: .spanish),
            L10n.tr("timeline.unanchored", language: .spanish)
        )
    }

    // MARK: - VW2

    func testW3FixABFModeSwitcherUsesTimelineLabelAndEvenSpacing() {
        XCTAssertEqual(L10n.tr("mode.timeline", language: .spanish), "Timeline")
        let applicationState = makeAppState(scene: makeScene(text: "Uno dos"))
        let theme = FrameTheme(colorScheme: .light, accent: .sage)
        let root = ModeSwitcher(selection: .constant(.timeline))
            .environment(applicationState)
            .environment(\.frameTheme, theme)

        let hosting = NSHostingView(rootView: root.frame(width: 342, height: 40))
        XCTAssertLessThanOrEqual(hosting.fittingSize.width, 343)

        let snapshot = SnapshotRenderer.render(
            root,
            name: "mode-switcher-timeline-980",
            suite: "w3-fix-abf",
            size: CGSize(width: 342, height: 40),
            appearance: .light,
            language: .spanish,
            appState: applicationState
        )
        XCTAssertGreaterThan(snapshot.pixelSize.width, 0)
        XCTAssertGreaterThan(snapshot.distinctColorCount, 4)
        XCTAssertTrue(
            snapshot.textFragments.contains { $0.contains("Timeline") },
            "the mode switcher must show the Timeline label: \(snapshot.textFragments)"
        )
    }

    // MARK: - Fixtures

    private func makeScene(text: String) -> FrameScript.Scene {
        let bRollAnchor = TextAnchorRepair.anchor(
            in: text,
            range: (text as NSString).range(of: "dos").location == NSNotFound
                ? NSRange(location: 0, length: 3)
                : (text as NSString).range(of: "dos")
        )
        let editingAnchor = TextAnchorRepair.anchor(
            in: text,
            range: NSRange(location: 0, length: min(3, (text as NSString).length))
        )
        return FrameScript.Scene(
            order: 0,
            sectionType: .hook,
            title: "Gancho",
            scriptText: text,
            bRollItems: [
                BRollItem(
                    textAnchor: bRollAnchor,
                    templateType: "",
                    sourceType: .stockFootage,
                    descriptionText: "Plano de apoyo"
                )
            ],
            editingItems: [
                EditingItem(
                    textAnchor: editingAnchor,
                    templateType: "",
                    cutStyle: "Corte suave",
                    transition: "",
                    subtitleStyle: ""
                )
            ]
        )
    }

    private func makeAppState(scene: FrameScript.Scene) -> AppState {
        isolatedDefaults?.cleanup()
        let isolatedDefaults = W3FixABFSupport.makeDefaults()
        self.isolatedDefaults = isolatedDefaults
        let project = FrameProject(title: "Sintético", scenes: [scene], primaryLanguage: "es")
        let applicationState = W3FixABFSupport.makeAppState(
            project: project,
            defaults: isolatedDefaults.defaults
        )
        applicationState.editorState.selectedSceneID = scene.id
        appState = applicationState
        return applicationState
    }
}
