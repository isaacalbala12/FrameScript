import AppKit
import FrameScriptCore
import SwiftUI
import XCTest
@testable import FrameScript

/// Synthetic projects for the clarity pass (Producción, inspector, timeline).
@MainActor
enum ClarityFixtures {
    /// The user's case: four untouched «Escena nueva», one line of text.
    static func almostEmpty() -> FrameProject {
        let scenes = (0..<4).map { index in
            FrameScript.Scene(
                order: index,
                sectionType: index == 0 ? .hook : .custom,
                title: "Escena nueva",
                scriptText: index == 0 ? "Texto de prueba" : ""
            )
        }
        return FrameProject(title: "Guion sin título", scenes: scenes)
    }

    /// Nine scenes with text, takes on the first three, B-roll, editing notes,
    /// claims, one manual task and a publishing pack.
    static func realistic() -> FrameProject {
        let titles = [
            "Gancho", "Qué es y quién lo hace", "Versiones e instalación",
            "Cómo funciona I", "Cómo funciona II", "Cómo se conduce",
            "Comparativa", "Pegas y para quién es", "Veredicto y llamada a la acción"
        ]
        let scenes: [FrameScript.Scene] = titles.enumerated().map { index, title in
            let text = PerfFixture.sceneText(sceneIndex: index, words: 95)
            let scene = FrameScript.Scene(
                order: index,
                sectionType: index == 0 ? .hook : .custom,
                title: title,
                scriptText: text
            )
            let length = (text as NSString).length
            if (1...3).contains(index) {
                scene.bRollItems = [BRollItem(
                    textAnchor: TextAnchorRepair.anchor(in: text, range: NSRange(location: min(length - 10, 40), length: 8)),
                    templateType: "",
                    sourceType: .screenRecording,
                    descriptionText: "Vuelta de clasificación"
                )]
            }
            if index == 2 {
                scene.editingItems = [EditingItem(
                    textAnchor: TextAnchorRepair.anchor(in: text, range: NSRange(location: min(length - 10, 120), length: 6)),
                    templateType: "",
                    cutStyle: "Corte rápido",
                    transition: "",
                    subtitleStyle: ""
                )]
            }
            if index < 3 {
                scene.takes = [Take(
                    number: 1,
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                    duration: 40 + Double(index) * 3,
                    rating: .good,
                    readText: text,
                    sceneTextHash: FrameScriptDocument.TextHash.hash(text)
                )]
            }
            return scene
        }
        var claims: [ProjectClaim] = []
        for index in 0..<3 {
            claims.append(ProjectClaim(
                text: "Dato por comprobar \(index + 1)",
                status: .probable,
                sceneIDs: [scenes[index + 3].id],
                anchorSceneID: scenes[index + 3].id,
                needsVerification: true
            ))
        }
        var project = FrameProject(
            title: "Análisis de Apexia 3.0",
            scenes: scenes,
            primaryLanguage: "es",
            publishingPacks: ["es": PublishingPack(
                titleCandidates: ["Título A"],
                chosenTitle: "",
                description: "",
                tags: [],
                hashtags: [],
                chapterOverrides: []
            )],
            checklistTasks: [
                ChecklistTask(text: "Preparar la miniatura", kind: .edit, sceneID: scenes[4].id)
            ],
            claims: claims
        )
        project.targetDuration = 600
        return project
    }
}

@MainActor
final class ProductionClarityTests: FrameScriptTestCase {
    private func makeState(_ project: FrameProject) -> AppState {
        DesignReviewSnapshotTests.makeAppState(project: project, defaults: makeDefaults()).0
    }

    // MARK: Inspector / panel parity

    /// What the panel lists for a scene (it shows done tasks by default).
    private func panelItems(for sceneID: UUID) -> [ProductionItem] {
        ProductionFilter(sceneID: sceneID, showsDone: true)
            .apply(to: ProductionChecklistCenter.shared.snapshot.items)
    }

    func testInspectorCountEqualsPanelCountForEverySceneInBothFixtures() throws {
        for project in [ClarityFixtures.almostEmpty(), ClarityFixtures.realistic()] {
            let appState = makeState(project)
            appState.refreshProductionChecklist()
            let snapshot = ProductionChecklistCenter.shared.snapshot
            for scene in project.scenes {
                appState.selectScene(scene.id)
                let model = try XCTUnwrap(UXInspectorProductionModel(appState: appState))
                let scoped = panelItems(for: scene.id)
                let panelPending = ProductionSummary(items: scoped).totalPending
                XCTAssertEqual(model.openCount, panelPending, "\(project.title) / \(scene.title): inspector vs panel pending count")
                XCTAssertEqual(model.isEmpty, scoped.isEmpty, "\(scene.title): the inspector says empty exactly when the panel lists nothing")
                XCTAssertEqual(model.autoItems.count + model.tasks.count, scoped.count)
            }
            _ = snapshot
        }
    }

    func testUnrecordedSceneIsNeverReportedAsWithoutPendingItems() throws {
        let project = ClarityFixtures.almostEmpty()
        let appState = makeState(project)
        appState.refreshProductionChecklist()
        let first = try XCTUnwrap(project.scenes.sortedByOrder.first)
        appState.selectScene(first.id)
        let model = try XCTUnwrap(UXInspectorProductionModel(appState: appState))
        // The user's screenshot: the panel listed «falta grabar» while the
        // inspector said «Sin pendientes».
        XCTAssertEqual(model.openCount, 1)
        XCTAssertEqual(model.autoItems.map(\.reason), [.sceneNeedsTake])
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertFalse(model.isEmpty)
        // Scenes without text have nothing pending, in both surfaces.
        let second = project.scenes.sortedByOrder[1]
        appState.selectScene(second.id)
        let empty = try XCTUnwrap(UXInspectorProductionModel(appState: appState))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.openCount, 0)
        XCTAssertTrue(panelItems(for: second.id).isEmpty)
    }

    func testResearchMirrorStaysHiddenAndTheClaimAppearsOnce() throws {
        let project = ClarityFixtures.realistic()
        let appState = makeState(project)
        let scene = try XCTUnwrap(project.scenes.sortedByOrder.first)
        let claim = appState.addResearchClaim(
            text: "El circuito se reasfaltó en 2025",
            status: .probable,
            sceneIDs: [scene.id],
            needsVerification: true
        )
        XCTAssertTrue(appState.project.checklistTasks.contains { $0.kind == .research && $0.text == claim.text })
        appState.refreshProductionChecklist()
        appState.selectScene(scene.id)
        let model = try XCTUnwrap(UXInspectorProductionModel(appState: appState))
        let mentions = model.autoItems.filter { $0.sourceText == claim.text }.count
            + model.tasks.filter { $0.text == claim.text }.count
        XCTAssertEqual(mentions, 1, "E-2: the claim shows once, never as its research mirror copy")
        XCTAssertTrue(model.tasks.allSatisfy { $0.text != claim.text })
        XCTAssertEqual(model.openCount, ProductionSummary(items: panelItems(for: scene.id)).totalPending)
    }

    // MARK: Explanations

    func testEveryAutomaticReasonHasAnExplanationAndAnActionInAllLanguages() throws {
        let appState = makeState(ClarityFixtures.realistic())
        appState.refreshProductionChecklist()
        let items = ProductionChecklistCenter.shared.snapshot.items
        var seenReasons = Set<String>()
        for item in items {
            seenReasons.insert(item.reason.rawValue)
            for language in [AppLanguage.spanish, .english, .russian] {
                let text = ProductionExplanation.explanation(for: item, language: language, recordShortcut: "⌘R")
                XCTAssertFalse(text.isEmpty)
                XCTAssertFalse(text.hasPrefix("production.why"), "missing \(language) text for \(item.reason.rawValue)")
                if let key = ProductionExplanation.actionKey(for: item) {
                    XCTAssertNotEqual(L10n.tr(key, language: language), key)
                }
            }
            if ProductionExplanation.isAutomatic(item) {
                XCTAssertNotNil(ProductionExplanation.actionKey(for: item), "\(item.reason.rawValue) needs a one-click action")
            } else {
                XCTAssertNil(ProductionExplanation.actionKey(for: item))
            }
        }
        XCTAssertTrue(seenReasons.isSuperset(of: ["sceneNeedsTake", "bRollNeedsFootage", "editingNeedsWork", "claimNeedsVerification", "publishingChecklist", "manualTask"]),
                      "fixture covers \(seenReasons)")
    }

    func testRecordExplanationNamesTheShortcutAndFallsBackWithoutOne() throws {
        let appState = makeState(ClarityFixtures.almostEmpty())
        let item = try XCTUnwrap(ProductionChecklistCenter.shared.snapshot.items.first { $0.reason == .sceneNeedsTake })
        XCTAssertEqual(
            ProductionExplanation.explanation(for: item, language: .spanish, recordShortcut: "⌘R"),
            "Esta escena aún no tiene ninguna toma buena. Grábala con el botón «Grabar toma» (⌘R)."
        )
        XCTAssertEqual(
            ProductionExplanation.explanation(for: item, language: .spanish, recordShortcut: nil),
            "Esta escena aún no tiene ninguna toma buena. Grábala con el botón «Grabar toma»."
        )
        XCTAssertEqual(ProductionExplanation.actionKey(for: item), "production.action.record")
        // The real shortcut comes from the user's settings.
        XCTAssertNotNil(appState.settings.activeShortcut(for: .recordTake))
    }

    func testAutomaticAndManualTagsAreDistinct() {
        for language in [AppLanguage.spanish, .english, .russian] {
            let auto = L10n.tr("production.tag.auto", language: language)
            let manual = L10n.tr("production.tag.manual", language: language)
            XCTAssertNotEqual(auto, manual)
            XCTAssertNotEqual(auto, "production.tag.auto")
        }
        XCTAssertEqual(L10n.tr("production.tag.auto", language: .spanish), "automática")
    }

    func testEveryFilterChipHasATooltipInAllLanguages() {
        let kinds: [ProductionItemKind?] = [nil] + ProductionItemKind.allCases
        for kind in kinds {
            let key = ProductionExplanation.tooltipKey(for: kind)
            for language in [AppLanguage.spanish, .english, .russian] {
                let text = L10n.tr(key, language: language)
                XCTAssertNotEqual(text, key, "\(key) missing in \(language)")
                XCTAssertGreaterThan(text.count, 8)
            }
        }
        XCTAssertEqual(
            L10n.tr(ProductionExplanation.tooltipKey(for: .acquire), language: .spanish),
            "B-roll o material que falta conseguir o vincular a un archivo"
        )
    }

    // MARK: Explainer dismissal (isolated defaults)

    func testExplainerShowsFirstThenStaysDismissedInIsolatedDefaults() {
        let defaults = makeDefaults()
        let store = ProductionExplainerStore(defaults: defaults)
        XCTAssertFalse(store.isDismissed, "first time: the explainer shows")
        store.dismiss()
        XCTAssertTrue(store.isDismissed)
        XCTAssertTrue(ProductionExplainerStore(defaults: defaults).isDismissed, "survives a new panel")
        XCTAssertTrue(defaults.bool(forKey: ProductionExplainerStore.dismissedKey))
        store.reset()
        XCTAssertFalse(ProductionExplainerStore(defaults: defaults).isDismissed)
    }

    func testDefaultStoreUsesTheIsolatedAppEnvironmentSuite() {
        XCTAssertTrue(AppEnvironment.isRunningTests)
        let store = ProductionExplainerStore()
        XCTAssertTrue(store.defaults === AppEnvironment.defaults)
        XCTAssertFalse(store.defaults === UserDefaults.standard)
        store.dismiss()
        defer { store.reset() }
        XCTAssertTrue(ProductionExplainerStore().isDismissed)
        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: ProductionExplainerStore.dismissedKey),
            "the real preferences are never written from tests"
        )
    }

    func testNewKeysExistInSpanishEnglishAndRussian() {
        let keys = [
            "production.explainer.body", "production.explainer.dismiss", "production.explainer.help",
            "production.group.label", "production.group.help", "production.filter.showDone.help",
            "timeline.explainer", "timeline.fit", "timeline.fit.help", "timeline.scale.perDivision",
            "timeline.recordedSummary", "timeline.empty.friendly", "timeline.empty.goToScript",
            "timeline.legend.real", "timeline.legend.estimated"
        ] + TimelineTrack.allCases.map { "timeline.track.\($0.rawValue).help" }
        for key in keys {
            for language in [AppLanguage.spanish, .english, .russian] {
                XCTAssertNotEqual(L10n.tr(key, language: language), key, "\(key) missing in \(language)")
            }
        }
        XCTAssertEqual(
            L10n.tr("production.explainer.body", language: .spanish),
            "Aquí aparece lo que falta para terminar el vídeo. Algunas tareas salen solas: escenas sin grabar, B-roll sin archivo, datos sin verificar o la checklist de publicación. Otras las añades tú abajo."
        )
    }
}

@MainActor
final class TimelineClarityTests: FrameScriptTestCase {
    func testScaleReadoutIsATimeScaleNotAPercentage() {
        XCTAssertEqual(TimelineZoomText.scale(pointsPerSecond: 16, language: .spanish), "5 s por división")
        XCTAssertEqual(TimelineZoomText.scale(pointsPerSecond: 4, language: .spanish), "30 s por división")
        XCTAssertEqual(TimelineZoomText.scale(pointsPerSecond: 1.5, language: .spanish), "1 min por división")
        XCTAssertEqual(TimelineZoomText.scale(pointsPerSecond: 4, language: .english), "30 s per division")
    }

    func testFitToWidthShowsTheWholeVideoInsteadOfTheMaximumZoom() {
        let appState = DesignReviewSnapshotTests.makeAppState(
            project: ClarityFixtures.realistic(), defaults: makeDefaults()
        ).0
        let layout = TimelineLayoutBuilder.build(appState.timelineInput())
        XCTAssertGreaterThan(layout.totalDuration, TimelineEmptyState.minimumDuration)
        let state = TimelineViewState()
        let available = 760.0
        state.fitAndFollow(totalDuration: layout.totalDuration, availableWidth: available)
        XCTAssertLessThan(state.pointsPerSecond, TimelineZoom.maximumPointsPerSecond, "not the old 400%")
        XCTAssertEqual(
            TimelineViewport(pointsPerSecond: state.pointsPerSecond).contentWidth(totalDuration: layout.totalDuration),
            available,
            accuracy: 0.5,
            "the video spans exactly the available width"
        )
        XCTAssertTrue(TimelineZoom.isFitted(
            pointsPerSecond: state.pointsPerSecond, totalDuration: layout.totalDuration, availableWidth: available
        ))
        state.zoomIn()
        XCTAssertFalse(TimelineZoom.isFitted(
            pointsPerSecond: state.pointsPerSecond, totalDuration: layout.totalDuration, availableWidth: available
        ))
    }

    func testAlmostEmptyProjectShowsTheFriendlyEmptyStateAndTheRealOneDoesNot() {
        let empty = DesignReviewSnapshotTests.makeAppState(project: ClarityFixtures.almostEmpty(), defaults: makeDefaults()).0
        let emptyLayout = TimelineLayoutBuilder.build(empty.timelineInput())
        XCTAssertLessThan(emptyLayout.totalDuration, TimelineEmptyState.minimumDuration)
        XCTAssertTrue(TimelineEmptyState.shouldShow(for: emptyLayout))

        let real = DesignReviewSnapshotTests.makeAppState(project: ClarityFixtures.realistic(), defaults: makeDefaults()).0
        XCTAssertFalse(TimelineEmptyState.shouldShow(for: TimelineLayoutBuilder.build(real.timelineInput())))
    }

    func testSceneBlocksCarryTheirNumberAndTitle() {
        let appState = DesignReviewSnapshotTests.makeAppState(project: ClarityFixtures.realistic(), defaults: makeDefaults()).0
        let layout = TimelineLayoutBuilder.build(appState.timelineInput())
        let blocks = layout.blocks(on: .scenes)
        XCTAssertEqual(
            TimelineBlockLabel.label(for: blocks[0], layout: layout, language: .spanish),
            "01 · Gancho",
            "the block label has no « · Real» suffix so the title fits"
        )
        XCTAssertEqual(
            TimelineBlockLabel.sceneTooltip(for: blocks[0], layout: layout, language: .spanish),
            "01 · Gancho · Real"
        )
        XCTAssertEqual(
            TimelineBlockLabel.label(for: blocks[5], layout: layout, language: .spanish),
            "06 · Cómo se conduce"
        )
        XCTAssertEqual(TimelineBlockLabel.sceneNumber(for: blocks[8], layout: layout), "09")
    }

    func testRecordedSummaryReplacesTheBareBlockCount() {
        let appState = DesignReviewSnapshotTests.makeAppState(project: ClarityFixtures.realistic(), defaults: makeDefaults()).0
        let layout = TimelineLayoutBuilder.build(appState.timelineInput())
        XCTAssertEqual(TimelineZoomText.recordedSummary(layout: layout, language: .spanish), "Tomas reales: 3 de 9 escenas")
    }

    func testTrackTooltipsExplainEveryTrack() {
        XCTAssertEqual(
            L10n.tr("timeline.track.warnings.help", language: .spanish),
            "Frases demasiado largas o escenas lentas detectadas al analizar."
        )
        for track in TimelineTrack.allCases {
            XCTAssertGreaterThan(L10n.tr("timeline.track.\(track.rawValue).help", language: .spanish).count, 20)
        }
    }

    func testNarrationBlocksShowSpokenWordsNotMarkup() {
        let scene = TimelineSceneInput(
            id: UUID(), title: "Gancho",
            text: "[B-ROLL: vuelta de clasificación]\n\nHola a todos [pausa 1s] bienvenidos al canal [IMAGEN: logo]"
        )
        let layout = TimelineLayoutBuilder.build(TimelineProjectInput(
            scenes: [scene],
            configuration: TimelineConfiguration(wordsPerMinute: 150, pauseDefaults: PauseDefaults(short: 0.5, long: 1.2))
        ))
        let labels = layout.blocks(on: .narration).map(\.label)
        XCTAssertFalse(labels.isEmpty)
        for label in labels {
            XCTAssertFalse(label.contains("["), "markup leaked into the narration label: \(label)")
            XCTAssertFalse(label.contains("B-ROLL"))
        }
        XCTAssertTrue(labels.contains("Hola a todos bienvenidos al canal"), "\(labels)")
    }

    func testTakeBlocksAreCenteredWithANormalHeight() {
        let metrics = TimelineTrackMetrics.standard
        let one = metrics.takeLaneRect(lane: 0, lanesUsed: 1)
        XCTAssertEqual(one.height, TimelineTrackMetrics.takeBlockHeight)
        XCTAssertEqual(one.offset, (metrics.takeRowHeight - one.height) / 2, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(one.height, 22)
        for lanes in 2...TimelineLayoutBuilder.maximumTakeLanes {
            let first = metrics.takeLaneRect(lane: 0, lanesUsed: lanes)
            let last = metrics.takeLaneRect(lane: lanes - 1, lanesUsed: lanes)
            let topGap = first.offset
            let bottomGap = metrics.takeRowHeight - (last.offset + last.height)
            XCTAssertEqual(topGap, bottomGap, accuracy: 0.01, "\(lanes) lanes are centered")
            XCTAssertGreaterThanOrEqual(topGap, 3, "not glued to the row edge")
        }
    }

    func testNarrowSceneBlocksShowTheNumberOnlyAndKeepTheTitleInTheTooltip() {
        XCTAssertTrue(TimelineBlockLabel.fits("01 · Gancho", inWidth: 120))
        XCTAssertFalse(TimelineBlockLabel.fits("01 · Qué es y quién lo hace", inWidth: 60))
        let appState = DesignReviewSnapshotTests.makeAppState(project: ClarityFixtures.realistic(), defaults: makeDefaults()).0
        let layout = TimelineLayoutBuilder.build(appState.timelineInput())
        let block = layout.blocks(on: .scenes)[1]
        XCTAssertEqual(TimelineBlockLabel.sceneTooltip(for: block, layout: layout), "02 · Qué es y quién lo hace · Real")
    }

    func testNarrationLabelsAreCutAtWholeWordsWithAnEllipsis() {
        let text = "Llega y el segundo coche mientras la pista"
        XCTAssertEqual(TimelineBlockLabel.wholeWords(text, inWidth: 1_000), text)
        for width in stride(from: 10 as CGFloat, through: 260, by: 5) {
            let cut = TimelineBlockLabel.wholeWords(text, inWidth: width)
            if cut.isEmpty { continue }
            XCTAssertTrue(cut.hasSuffix("…"), "\(cut) at \(width)")
            let words = cut.dropLast().split(separator: " ")
            XCTAssertTrue(text.hasPrefix(words.joined(separator: " ")), "\(cut) is whole words")
            XCTAssertTrue(TimelineBlockLabel.fits(cut, inWidth: width), "\(cut) fits \(width)")
        }
        XCTAssertEqual(TimelineBlockLabel.wholeWords(text, inWidth: 8), "", "no word fits: draw nothing")
    }

    // MARK: Fit following (F6, F7)

    func testManualZoomStopsAutoFitAndAjustarResumesIt() {
        let state = TimelineViewState()
        let total = 360.0
        state.fitAndFollow(totalDuration: total, availableWidth: 900)
        let fitted = state.pointsPerSecond
        XCTAssertTrue(state.followsFit)
        // A resize refits while following.
        state.refitIfFollowing(totalDuration: total, availableWidth: 600)
        XCTAssertEqual(state.pointsPerSecond, 600 / total, accuracy: 0.0001)
        XCTAssertNotEqual(state.pointsPerSecond, fitted)
        // Manual zoom (the path ⌘=, ⌘- and + use) then a resize: no refit.
        state.zoomIn()
        let manual = state.pointsPerSecond
        state.refitIfFollowing(totalDuration: total, availableWidth: 900)
        XCTAssertFalse(state.followsFit)
        XCTAssertEqual(state.pointsPerSecond, manual)
        state.refitIfFollowing(totalDuration: total, availableWidth: 400)
        XCTAssertEqual(state.pointsPerSecond, manual, "stays manual on every later resize")
        // Slider path.
        let other = TimelineViewState()
        other.fitAndFollow(totalDuration: total, availableWidth: 900)
        other.zoomFraction = 0.9
        other.refitIfFollowing(totalDuration: total, availableWidth: 500)
        XCTAssertFalse(other.followsFit)
        // «Ajustar» resumes following.
        state.fitAndFollow(totalDuration: total, availableWidth: 900)
        XCTAssertTrue(state.followsFit)
        XCTAssertEqual(state.pointsPerSecond, 900 / total, accuracy: 0.0001)
        state.refitIfFollowing(totalDuration: total, availableWidth: 700)
        XCTAssertEqual(state.pointsPerSecond, 700 / total, accuracy: 0.0001)
    }

    func testSharedStateKeepsTheManualZoomAcrossVisits() {
        let shared = TimelineViewState.shared
        shared.fitAndFollow(totalDuration: 300, availableWidth: 900)
        shared.zoomOut()
        shared.refitIfFollowing(totalDuration: 300, availableWidth: 900)
        let manual = shared.pointsPerSecond
        XCTAssertFalse(shared.followsFit)
        // A new Timeline view reads the same object: nothing refits it.
        TimelineViewState.shared.refitIfFollowing(totalDuration: 300, availableWidth: 900)
        XCTAssertEqual(TimelineViewState.shared.pointsPerSecond, manual)
        shared.reset()
        shared.fitAndFollow(totalDuration: 300, availableWidth: 900)
    }
}

@MainActor
final class SidebarBadgeAlignmentTests: FrameScriptTestCase {
    func testRhythmAndResearchBadgesShareTheTitleTopEdge() throws {
        let sink = LayoutProbeSink()
        var project = ClarityFixtures.realistic()
        let scene = try XCTUnwrap(project.scenes.sortedByOrder.first)
        scene.scriptText = Array(repeating: "palabra", count: 90).joined(separator: " ") + "."
        let (appState, inspector) = DesignReviewSnapshotTests.makeAppState(project: project, defaults: makeDefaults())
        _ = appState.addResearchClaim(text: "Dato de prueba", status: .probable, sceneIDs: [scene.id], needsVerification: true)
        RhythmReviewCenter.shared.refreshNow(project: appState.project, settings: appState.settings)
        defer { RhythmReviewCenter.shared.clear() }
        // The analysis runs off the main thread; wait for it.
        for _ in 0..<100 where RhythmReviewCenter.shared.warningCount(for: scene.id) == 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThan(RhythmReviewCenter.shared.warningCount(for: scene.id), 0, "fixture needs a rhythm warning")
        project = appState.project
        SnapshotRenderer.render(
            AppShellView(inspectorState: inspector).environment(\.layoutProbeSink, sink),
            name: "sidebar-badges", suite: "SidebarBadgeAlignmentTests",
            size: CGSize(width: 1512, height: 949), appearance: .dark, language: .spanish, appState: appState
        )
        let rhythm = sink.frames("sidebar.badge.rhythm")
        let research = sink.frames("sidebar.badge.research")
        XCTAssertGreaterThanOrEqual(research.count, 1, "\(research)")
        // Every scene shares the long sentence, so pair each research badge
        // with the rhythm badge of its own row.
        for c in research {
            guard let r = rhythm.min(by: { abs($0.midY - c.midY) < abs($1.midY - c.midY) }) else {
                XCTFail("no rhythm badge for \(c)")
                continue
            }
            XCTAssertEqual(r.minY, c.minY, accuracy: 1, "badges share one top edge: \(r) vs \(c)")
            XCTAssertLessThan(r.maxX, c.minX, "rhythm sits left of research, not on top of it: \(r) vs \(c)")
        }
    }

    func testSidebarBadgesLightSnapshot() throws {
        let project = ClarityFixtures.realistic()
        let scene = try XCTUnwrap(project.scenes.sortedByOrder.first)
        scene.scriptText = Array(repeating: "palabra", count: 90).joined(separator: " ") + "."
        let (appState, inspector) = DesignReviewSnapshotTests.makeAppState(project: project, defaults: makeDefaults())
        _ = appState.addResearchClaim(text: "Dato de prueba", status: .probable, sceneIDs: [scene.id], needsVerification: true)
        RhythmReviewCenter.shared.refreshNow(project: appState.project, settings: appState.settings)
        defer { RhythmReviewCenter.shared.clear() }
        // The analysis runs off the main thread; wait for it.
        for _ in 0..<100 where RhythmReviewCenter.shared.warningCount(for: scene.id) == 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        SnapshotRenderer.render(
            AppShellView(inspectorState: inspector),
            name: "sidebar-badges-light", suite: "SidebarBadgeAlignmentTests",
            size: CGSize(width: 1512, height: 949), appearance: .light, language: .spanish, appState: appState
        )
    }
}
