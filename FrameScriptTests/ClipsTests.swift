import AppKit
import FrameScriptCore
import SwiftUI
import XCTest
@testable import FrameScript

@MainActor
final class ClipsTests: XCTestCase {
    /// Isolated suites live in the process temporary directory, so no test
    /// writes `~/Library/Preferences`.
    private var testDefaults: [TestDefaults] = []

    override func setUp() {
        super.setUp()
        TestBundleCleanup.register()
    }

    override func tearDown() {
        for defaults in testDefaults {
            defaults.cleanup()
        }
        testDefaults.removeAll()
        ClipLayoutRegistry.shared.reset()
        super.tearDown()
    }

    // MARK: - Creation and editing

    func testCreateClipFromSelectedSceneUsesWholeScene() {
        let appState = makeAppState()
        let scene = appState.project.scenes.sortedByOrder[0]
        appState.editorState.selectedSceneID = scene.id

        let clip = appState.createClipFromSelectedScene()

        XCTAssertNotNil(clip)
        XCTAssertEqual(clip?.sourceSceneIDs, [scene.id])
        XCTAssertEqual(clip?.adaptedText, scene.scriptText)
        XCTAssertEqual(clip?.status, .idea)
        XCTAssertEqual(clip?.targetSeconds, 30)
        XCTAssertEqual(appState.selectedMode, .clips)
        XCTAssertEqual(appState.windowState.selectedClipID, clip?.id)
        XCTAssertEqual(appState.project.clips.count, 1)
    }

    func testCreateClipFromAnchorUsesOnlyTheFragment() {
        let appState = makeAppState()
        let scene = appState.project.scenes.sortedByOrder[1]
        let range = (scene.scriptText as NSString).range(of: "segunda vuelta")
        let anchor = TextAnchorRepair.anchor(in: scene.scriptText, range: range)
        XCTAssertNotNil(anchor)

        let clip = appState.createClipFromAnchor(sceneID: scene.id, anchor: anchor!)

        XCTAssertEqual(clip?.anchor?.selectedText, "segunda vuelta")
        XCTAssertEqual(clip?.adaptedText, "segunda vuelta")
        XCTAssertEqual(clip?.anchorSceneID, scene.id)
        XCTAssertEqual(clip?.sceneSourceHashes.first?.sourceText, "segunda vuelta")
    }

    func testUpdateClipSanitizesTargetAndKeepsAnchorScene() {
        let appState = makeAppState()
        let scene = appState.project.scenes.sortedByOrder[0]
        var clip = appState.createClip(sceneIDs: [scene.id])!
        clip.targetSeconds = 1
        clip.sourceSceneIDs = []
        clip.anchor = TextAnchorRepair.anchor(
            in: scene.scriptText,
            range: (scene.scriptText as NSString).range(of: "mojado")
        )
        clip.anchorSceneID = scene.id

        appState.updateClip(clip)

        let updated = appState.clip(id: clip.id)
        XCTAssertEqual(updated?.targetSeconds, ClipLimits.minimumTarget)
        XCTAssertEqual(updated?.sourceSceneIDs, [scene.id])
    }

    func testDuplicateAndDeleteClip() {
        let appState = makeAppState()
        let scene = appState.project.scenes.sortedByOrder[0]
        let clip = appState.createClip(sceneIDs: [scene.id])!

        appState.duplicateClip(id: clip.id)

        XCTAssertEqual(appState.project.clips.count, 2)
        let copy = appState.project.clips[1]
        XCTAssertNotEqual(copy.id, clip.id)
        XCTAssertEqual(copy.status, .idea)
        XCTAssertTrue(copy.title.contains("copia"))

        appState.deleteClip(id: copy.id)
        XCTAssertEqual(appState.project.clips.count, 1)
    }

    // MARK: - Staleness

    func testStalenessAndMarkReviewed() {        let appState = makeAppState()
        let scene = appState.project.scenes.sortedByOrder[1]
        let clip = appState.createClip(sceneIDs: [scene.id])!

        scene.scriptText = scene.scriptText + " Texto nuevo."

        let report = appState.clipStaleness(for: clip)
        XCTAssertTrue(report.isStale)
        XCTAssertEqual(report.changes.first?.kind, .changed)
        XCTAssertFalse(report.changes.first?.changeSummary().isEmpty ?? true)

        appState.markClipReviewed(id: clip.id)

        let reviewed = appState.clip(id: clip.id)!
        XCTAssertFalse(appState.clipIsStale(reviewed))
        XCTAssertTrue(reviewed.sceneSourceHashes.first?.sourceText.contains("Texto nuevo") ?? false)
    }

    func testRemovingSourceSceneDoesNotMarkClipStale() {
        let appState = makeAppState()
        let scenes = appState.project.scenes.sortedByOrder
        var clip = appState.createClip(sceneIDs: [scenes[0].id, scenes[1].id])!

        clip.sourceSceneIDs.removeAll { $0 == scenes[1].id }
        appState.updateClip(clip)

        let updated = appState.clip(id: clip.id)!
        XCTAssertEqual(updated.sourceSceneIDs, [scenes[0].id])
        XCTAssertEqual(updated.sceneSourceHashes.map(\.sceneID), [scenes[0].id])
        XCTAssertFalse(appState.clipIsStale(updated))
    }

    func testAddingSourceSceneSamplesItsCurrentText() {
        let appState = makeAppState()
        let scenes = appState.project.scenes.sortedByOrder
        var clip = appState.createClip(sceneIDs: [scenes[0].id])!

        clip.sourceSceneIDs.append(scenes[1].id)
        appState.updateClip(clip)

        let updated = appState.clip(id: clip.id)!
        XCTAssertEqual(updated.sceneSourceHashes.count, 2)
        XCTAssertEqual(updated.sceneSourceHashes.last?.sourceText, scenes[1].scriptText)
        XCTAssertFalse(appState.clipIsStale(updated))
    }

    // MARK: - Estimates

    func testEstimateUsesLearnedSpeakingRate() {
        let appState = makeAppState()
        appState.project.learnedWordsPerMinuteByLanguage["es"] = 120
        let scene = appState.project.scenes.sortedByOrder[0]
        var clip = appState.createClip(sceneIDs: [scene.id])!
        clip.hook = ""
        clip.adaptedText = Array(repeating: "palabra", count: 60).joined(separator: " ")
        appState.updateClip(clip)

        let estimate = appState.clipEstimate(for: appState.clip(id: clip.id)!)

        XCTAssertEqual(estimate.seconds, 30, accuracy: 0.01)
        XCTAssertEqual(estimate.fit, .onTarget)
        XCTAssertEqual(estimate.wordCount, 60)
    }

    func testSummaryCountsClips() {
        let appState = makeAppState()
        let scenes = appState.project.scenes.sortedByOrder
        let first = appState.createClip(sceneIDs: [scenes[0].id])!
        var second = appState.createClip(sceneIDs: [scenes[1].id])!
        second.status = .ready
        appState.updateClip(second)

        let summary = appState.clipsSummary

        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.count(for: .idea), 1)
        XCTAssertEqual(summary.count(for: .ready), 1)
        XCTAssertEqual(summary.stale, 0)
        XCTAssertNotNil(first.id)
    }

    // MARK: - Export

    func testExportTextAndMarkers() {
        let appState = makeAppState()
        let scene = appState.project.scenes.sortedByOrder[1]
        var clip = appState.createClip(sceneIDs: [scene.id])!
        clip.hook = "Gancho de prueba"
        clip.adaptedText = "Texto adaptado de prueba: más rápido"
        clip.onScreenText = "Dato clave"
        clip.description = "Descripción de prueba"
        clip.hashtags = ["#uno", "#dos"]
        appState.updateClip(clip)

        let document = appState.clipExportDocument(for: appState.clip(id: clip.id)!)

        XCTAssertTrue(document.plainText.contains("Gancho de prueba"))
        XCTAssertTrue(document.plainText.contains("Texto adaptado de prueba: más rápido"))
        XCTAssertTrue(document.plainText.contains("Dato clave"))
        XCTAssertTrue(document.plainText.contains("Descripción de prueba"))
        XCTAssertTrue(document.plainText.contains("#uno #dos"))
        XCTAssertTrue(document.plainText.contains("más rápido"), "accents must survive the export")
    }

    // MARK: - AI response parsing

    func testGeneratedClipAdaptationParsesJSONAndNormalizesHashtags() throws {
        let response = """
        ```json
        {"hook":"Un gancho","adaptedText":"Texto adaptado","onScreenText":"Dos palabras","description":"Descripción","hashtags":["simracing","#SIMRACING","#dos"]}
        ```
        """

        let generated = try GeneratedClipAdaptation(json: response)

        XCTAssertEqual(generated.hook, "Un gancho")
        XCTAssertEqual(generated.adaptedText, "Texto adaptado")
        XCTAssertEqual(generated.hashtags, ["#simracing", "#dos"])
    }

    func testGeneratedClipAdaptationRejectsInvalidJSON() {
        XCTAssertThrowsError(try GeneratedClipAdaptation(json: "no json"))
    }

    func testPromptKeepsFactsStrictlyFromSource() {
        let coreClip = FrameScriptDocument.ShortClip(
            title: "Clip",
            hook: "",
            adaptedText: "",
            targetSeconds: 30
        )
        let prompt = ClipPromptBuilder.userPrompt(
            clip: coreClip,
            sourceText: "El coche hace 150 km/h."
        )

        XCTAssertTrue(prompt.contains("Target duration: 30 seconds"))
        XCTAssertTrue(prompt.contains("El coche hace 150 km/h."))
        XCTAssertTrue(ClipPromptBuilder.jsonSchema.contains("hashtags"))
    }

    // MARK: - Snapshots

    func testClipsPanelSnapshotsAtBothSizesAndAppearances() {
        for (name, size, scheme, selectsStale) in snapshotConfigurations() {
            let appState = makeSnapshotAppState(scheme: scheme, selectsStale: selectsStale)
            let token = "panel-\(name)"
            ClipLayoutRegistry.shared.reset()
            let theme = FrameTheme(colorScheme: scheme, accent: .sage)
            let root = ClipsPanel(layoutProbeToken: token)
                .environment(appState)
                .environment(\.frameTheme, theme)
                .environment(\.colorScheme, scheme)
                .frame(width: size.width, height: size.height)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()

            let image = render(hosting, size: size)
            XCTAssertNotNil(image, "\(name) did not render")
            assertRenderedContent(image, size: size, name: name)
            assertLayoutFrames(
                ClipLayoutRegistry.shared.frames(for: token),
                size: size,
                name: name
            )
            XCTAssertEqual(
                L10n.tr("clips.hook", language: .spanish),
                "Gancho (1–3 s)",
                "\(name) must render Spanish text"
            )
            XCTAssertEqual(
                L10n.tr("clips.adaptedText", language: .spanish),
                "Texto adaptado",
                "\(name) must render Spanish text"
            )
            writeSnapshot(image, name: "clips-panel-\(name).png")
        }
    }


    func testClipsPanelEmptyStateSnapshots() {
        for scheme in [ColorScheme.light, .dark] {
            let appState = makeAppState()
            let theme = FrameTheme(colorScheme: scheme, accent: .sage)
            let size = CGSize(width: 980, height: 712)
            let token = "empty-\(scheme == .dark ? "dark" : "light")"
            ClipLayoutRegistry.shared.reset()
            let root = ClipsPanel(layoutProbeToken: token)
                .environment(appState)
                .environment(\.frameTheme, theme)
                .environment(\.colorScheme, scheme)
                .frame(width: size.width, height: size.height)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()

            let name = "clips-panel-empty-980-\(scheme == .dark ? "dark" : "light")"
            let image = render(hosting, size: size)
            XCTAssertNotNil(image, "\(name) did not render")
            assertRenderedContent(image, size: size, name: name)
            assertLayoutFrames(
                ClipLayoutRegistry.shared.frames(for: token),
                size: size,
                name: name,
                requiresEditorSections: false
            )
            writeSnapshot(image, name: "\(name).png")
        }
    }

    /// Six workspace modes cannot fit the old button row at the minimum window
    /// width, so the switcher falls back to a menu. Rendering through the
    /// window-based snapshot renderer is what makes the menu label draw.
    func testModeSwitcherFitsEveryModeAtTheWindowMinimum() {
        let appState = makeAppState()
        let theme = FrameTheme(colorScheme: .light, accent: .sage)
        let root = ModeSwitcher(selection: .constant(.clips))
            .environment(appState)
            .environment(\.frameTheme, theme)
            .environment(\.colorScheme, ColorScheme.light)
        let hosting = NSHostingView(rootView: root.frame(width: 342, height: 40))
        XCTAssertLessThanOrEqual(hosting.fittingSize.width, 343)

        let result = SnapshotRenderer.render(
            root,
            name: "mode-switcher-980",
            suite: "w3-f-clips",
            size: CGSize(width: 342, height: 40),
            appearance: .light,
            language: .spanish,
            appState: appState
        )
        XCTAssertGreaterThan(result.pixelSize.width, 0)
        XCTAssertGreaterThan(result.distinctColorCount, 4, "mode switcher did not render")
        XCTAssertEqual(
            L10n.tr("mode.clips", language: .spanish),
            "Clips",
            "the collapsed switcher must show the selected mode"
        )
        XCTAssertTrue(
            result.textFragments.contains { $0.contains("Clips") },
            "the selected mode is not laid out: \(result.textFragments)"
        )
    }

    func testClipExportSheetSnapshots() {
        for scheme in [ColorScheme.light, .dark] {
            let appState = makeSnapshotAppState(scheme: scheme, selectsStale: false)
            let clip = appState.project.clips.first!
            let theme = FrameTheme(colorScheme: scheme, accent: .sage)
            let root = ZStack(alignment: .top) {
                theme.windowBackground
                ClipExportSheet(clip: clip)
                    .environment(appState)
                    .environment(\.frameTheme, theme)
                    .environment(\.colorScheme, scheme)
            }
            .frame(width: 620, height: 520)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(x: 0, y: 0, width: 620, height: 520)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()

            let name = "clip-export-sheet-\(scheme == .dark ? "dark" : "light")"
            let image = render(hosting, size: CGSize(width: 620, height: 520))
            XCTAssertNotNil(image, "\(name) did not render")
            assertRenderedContent(image, size: CGSize(width: 620, height: 520), name: name)
            writeSnapshot(image, name: "\(name).png")
        }
    }

    // MARK: - Snapshot helpers

    private func snapshotConfigurations() -> [(String, CGSize, ColorScheme, Bool)] {
        [
            ("1180x760-light", CGSize(width: 1180, height: 760), .light, false),
            ("1180x760-dark", CGSize(width: 1180, height: 760), .dark, true),
            ("980x712-light", CGSize(width: 980, height: 712), .light, false),
            ("980x712-dark", CGSize(width: 980, height: 712), .dark, true),
            // The real editor area at the 980 pt window minimum with the
            // default 195 pt sidebar.
            ("784x712-light", CGSize(width: 784, height: 712), .light, false),
            ("784x712-dark", CGSize(width: 784, height: 712), .dark, true)
        ]
    }

    private func render<V: View>(_ hosting: NSHostingView<V>, size: CGSize) -> NSBitmapImageRep? {
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: CGRect(origin: .zero, size: size)) else {
            return nil
        }
        hosting.cacheDisplay(in: CGRect(origin: .zero, size: size), to: rep)
        return rep
    }

    private func assertRenderedContent(
        _ image: NSBitmapImageRep?,
        size: CGSize,
        name: String
    ) {
        guard let image else {
            XCTFail("\(name): no image")
            return
        }
        XCTAssertGreaterThan(image.pixelsWide, 0, "\(name): empty image width")
        XCTAssertGreaterThan(image.pixelsHigh, 0, "\(name): empty image height")
        XCTAssertEqual(image.size.width, size.width, accuracy: 1, "\(name): width changed")
        XCTAssertEqual(image.size.height, size.height, accuracy: 1, "\(name): height changed")
        let center = image.colorAt(x: Int(size.width / 2), y: Int(size.height / 2))
        XCTAssertGreaterThan(center?.alphaComponent ?? 0, 0, "\(name): transparent center")

        var colors: Set<String> = []
        var contrastingPixels = 0
        let step = max(1, Int(size.width / 120))
        for x in stride(from: 0, to: Int(size.width), by: step) {
            for y in stride(from: 0, to: Int(size.height), by: step) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                colors.insert("\(Int(color.redComponent * 40))-\(Int(color.greenComponent * 40))-\(Int(color.blueComponent * 40))")
                let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                if luminance < 0.45 || luminance > 0.85 {
                    contrastingPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(colors.count, 4, "\(name): rendered image looks flat")
        XCTAssertGreaterThan(contrastingPixels, 20, "\(name): no visible text pixels")
    }

    private func assertLayoutFrames(
        _ frames: [String: CGRect],
        size: CGSize,
        name: String,
        requiresEditorSections: Bool = true
    ) {
        XCTAssertFalse(frames.isEmpty, "\(name): layout probe did not report frames")
        for (key, frame) in frames {
            XCTAssertGreaterThan(frame.width, 0, "\(name): \(key) has no width")
            XCTAssertGreaterThan(frame.height, 0, "\(name): \(key) has no height")
            XCTAssertGreaterThanOrEqual(frame.minX, -1, "\(name): \(key) is clipped on the left")
            XCTAssertLessThanOrEqual(frame.maxX, size.width + 1, "\(name): \(key) is clipped on the right")
        }

        if let list = frames["list"], let editor = frames["editor"] {
            XCTAssertLessThanOrEqual(list.maxX, editor.minX + 1, "\(name): list overlaps the editor")
        }

        guard requiresEditorSections else { return }
        let sectionNames = ["header", "source", "hook", "adapted", "publishing", "coverage", "export"]
        let sections = sectionNames.compactMap { frames[$0] }
        XCTAssertEqual(sections.count, sectionNames.count, "\(name): missing editor sections")
        for (first, second) in zip(sections, sections.dropFirst()) {
            XCTAssertLessThanOrEqual(
                first.maxY,
                second.minY + 1,
                "\(name): editor sections overlap vertically"
            )
        }

        for name in ["header", "source", "hook"] {
            if let frame = frames[name] {
                XCTAssertLessThanOrEqual(
                    frame.maxY,
                    size.height + 1,
                    "\(name): first editor sections do not fit the canvas"
                )
            }
        }
    }

    private func writeSnapshot(_ image: NSBitmapImageRep?, name: String) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FS_SNAPSHOTS"] == "1" || environment["TEST_RUNNER_FS_SNAPSHOTS"] == "1",
              let data = image?.representation(using: .png, properties: [:]) else {
            return
        }
        let directory = URL(fileURLWithPath: "/tmp/fs-snapshots/w3-f-clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - Test data

    private func makeAppState() -> AppState {
        let isolated = TestDefaults.make()
        testDefaults.append(isolated)
        let defaults = isolated.defaults
        let project = makeProject()
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        let appState = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            recording: RecordingController(
                preferences: OBSPreferencesStore(defaults: defaults, secretStore: FakeClipSecretStore()),
                defaults: defaults
            ),
            subscriptionRuntime: SubscriptionAIRuntime(
                store: SubscriptionAISettingsStore(userDefaults: defaults)
            ),
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults)
        )
        return appState
    }

    private func makeSnapshotAppState(
        scheme: ColorScheme,
        selectsStale: Bool
    ) -> AppState {
        let isolated = TestDefaults.make()
        testDefaults.append(isolated)
        let defaults = isolated.defaults
        let project = makeProject()
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        let appState = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            recording: RecordingController(
                preferences: OBSPreferencesStore(defaults: defaults, secretStore: FakeClipSecretStore()),
                defaults: defaults
            ),
            subscriptionRuntime: SubscriptionAIRuntime(
                store: SubscriptionAISettingsStore(userDefaults: defaults)
            ),
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults)
        )

        let scenes = project.scenes.sortedByOrder
        let ready = appState.createClip(sceneIDs: [scenes[1].id])!
        var readyClip = ready
        readyClip.hook = "La segunda vuelta lo cambió todo."
        readyClip.adaptedText = """
        La primera vuelta fue lenta. La segunda cambió todo: el coche giraba con una calma que no esperaba.

        No es el más rápido, pero sí el más divertido.
        """
        readyClip.onScreenText = "La segunda vuelta"
        readyClip.description = "Prueba en mojado, sin datos inventados."
        readyClip.hashtags = ["#simracing", "#mojado"]
        readyClip.status = .ready
        appState.updateClip(readyClip)

        let anchored = appState.createClip(
            sceneIDs: [scenes[0].id],
            anchorSceneID: scenes[0].id,
            anchor: TextAnchorRepair.anchor(
                in: scenes[0].scriptText,
                range: (scenes[0].scriptText as NSString).range(of: "mojado")
            )
        )!
        var anchoredClip = anchored
        anchoredClip.title = "El detalle del mojado"
        anchoredClip.hook = "El detalle está en el mojado."
        anchoredClip.adaptedText = "El detalle está en el mojado."
        anchoredClip.status = .draft
        appState.updateClip(anchoredClip)

        let stale = appState.createClip(sceneIDs: [scenes[2].id])!
        var staleClip = stale
        staleClip.title = "Cierre en tres frases"
        staleClip.hook = "No es el más rápido."
        staleClip.adaptedText = "No es el más rápido, pero sí el más divertido."
        appState.updateClip(staleClip)
        scenes[2].scriptText = scenes[2].scriptText + " Y eso se nota en cada curva."

        appState.windowState.selectedClipID = selectsStale ? staleClip.id : readyClip.id
        return appState
    }

    private func makeProject() -> FrameProject {
        let first = Scene(
            order: 0,
            sectionType: .hook,
            title: "Gancho",
            scriptText: "Hoy probamos el coche en mojado y el resultado sorprende."
        )
        let second = Scene(
            order: 1,
            sectionType: .explanation,
            title: "Prueba",
            scriptText: "La primera vuelta fue lenta. La segunda vuelta cambió todo."
        )
        let third = Scene(
            order: 2,
            sectionType: .takeaway,
            title: "Cierre",
            scriptText: "No es el coche más rápido, pero sí el más divertido."
        )
        first.takes = [
            Take(
                number: 1,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                duration: 6.5,
                rating: .good,
                languageCode: "es",
                readText: first.scriptText,
                sceneTextHash: FrameScriptDocument.TextHash.hash(first.scriptText)
            )
        ]
        second.takes = [
            Take(
                number: 1,
                startedAt: Date(timeIntervalSince1970: 1_700_000_100),
                duration: 8.2,
                rating: .safe,
                languageCode: "es",
                readText: second.scriptText,
                sceneTextHash: FrameScriptDocument.TextHash.hash(second.scriptText)
            )
        ]
        return FrameProject(
            title: "Prueba de clips",
            scenes: [first, second, third],
            primaryLanguage: "es",
            learnedWordsPerMinuteByLanguage: ["es": 148]
        )
    }
}

private final class FakeClipSecretStore: OBSSecretStoring, @unchecked Sendable {
    func readPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
}
