import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

/// WP9 regression and performance tests for the export anchor index, dirty-only
/// duration passes, background saves, incremental rhythm review, cached duration
/// hashes and the escaleta import path.
@MainActor
final class WP9PerformanceTests: FrameScriptTestCase {
    // MARK: - Fixtures

    private static let words = [
        "cuando", "la", "ciudad", "despierta", "cada", "mañana", "los", "vecinos",
        "caminan", "hacia", "el", "mercado", "con", "sus", "bolsas", "de", "tela",
        "mientras", "el", "sol", "calienta", "las", "piedras", "del", "parque"
    ]

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameScriptWP9-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func sentence(_ index: Int, words count: Int = 14) -> String {
        var values: [String] = []
        for offset in 0..<count {
            values.append(Self.words[(index * 5 + offset * 3) % Self.words.count])
        }
        let joined = values.joined(separator: " ")
        return joined.prefix(1).uppercased() + String(joined.dropFirst()) + "."
    }

    private func sceneText(sceneIndex: Int, sentenceCount: Int = 6) -> String {
        (0..<sentenceCount).map { sentence(sceneIndex * 17 + $0) }.joined(separator: " ")
    }

    private func project(sceneCount: Int = 8, sentenceCount: Int = 6) -> FrameProject {
        let scenes = (0..<sceneCount).map { index in
            Scene(
                order: index,
                sectionType: index == 0 ? .hook : .custom,
                title: "Scene \(index)",
                scriptText: sceneText(sceneIndex: index, sentenceCount: sentenceCount)
            )
        }
        return FrameProject(title: "WP9 synthetic", scenes: scenes, primaryLanguage: "es")
    }

    private func makeAppState(
        store: ProjectStore? = nil,
        autosaveEnabled: Bool = true,
        closeConfirmation: AppState.CloseConfirmation? = { .save }
    ) -> AppState {
        let suite = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.autosaveEnabled = autosaveEnabled
        settings.generalPreferences.autosaveIntervalSeconds = 3_600
        return AppState(
            projectStore: store ?? ProjectStore(project: SampleData.defaultProject),
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: settings, userDefaults: suite, key: "settings"),
            closeConfirmation: closeConfirmation,
            externalChangeConfirmation: { .keepMine }
        )
    }

    private func writeProject(_ project: FrameProject, in directory: URL, name: String = "Project.fscr") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FrameScriptFileStore.write(project: project, to: url)
        return url
    }

    // MARK: - Export anchor index

    func testExportLinkedPairsMatchTheLegacyPerSegmentCheck() throws {
        let text = sceneText(sceneIndex: 1, sentenceCount: 4)
        let scene = Scene(order: 0, sectionType: .hook, title: "Export", scriptText: text)
        let coreSegments = FrameScriptDocument.TextSegmenter.segmentTexts(in: text, splitMode: .sentence)
        scene.textSegments = coreSegments.enumerated().map { index, value in
            TextSegment(
                sceneID: scene.id,
                order: index,
                sourceText: value,
                segmentType: .sentence
            )
        }
        let layout = scene.textSegments.sortedByOrder

        func anchor(at order: Int, offset: Int) -> TextAnchor? {
            guard let range = TextAnchorRepair.anchor(for: layout[order], in: text)?.nsRange else {
                return nil
            }
            return TextAnchor(
                startUTF16: range.location + min(offset, max(0, range.length - 1)),
                lengthUTF16: 1,
                selectedText: "",
                prefixContext: "",
                suffixContext: ""
            )
        }

        scene.bRollItems = [
            BRollItem(textAnchor: anchor(at: 0, offset: 1), templateType: "", sourceType: .stockFootage, descriptionText: "B0"),
            BRollItem(textAnchor: anchor(at: 2, offset: 0), templateType: "", sourceType: .stockFootage, descriptionText: "B1"),
            BRollItem(textAnchor: anchor(at: 2, offset: 2), templateType: "", sourceType: .stockFootage, descriptionText: "B2"),
            BRollItem(textAnchor: TextAnchor(startUTF16: 99_999, lengthUTF16: 1, selectedText: "", prefixContext: "", suffixContext: ""), templateType: "", sourceType: .stockFootage, descriptionText: "B-stale"),
            BRollItem(textAnchor: nil, templateType: "", sourceType: .stockFootage, descriptionText: "B-unlinked")
        ]
        scene.editingItems = [
            EditingItem(textAnchor: anchor(at: 1, offset: 0), templateType: "", cutStyle: "E0", transition: "", subtitleStyle: ""),
            EditingItem(textAnchor: anchor(at: 3, offset: 0), templateType: "", cutStyle: "E1", transition: "", subtitleStyle: ""),
            EditingItem(textAnchor: nil, templateType: "", cutStyle: "E-unlinked", transition: "", subtitleStyle: "")
        ]

        var expected: [[String]] = []
        for segment in layout {
            for item in scene.bRollItems {
                guard let anchor = item.textAnchor,
                      TextAnchorRepair.isAnchor(anchor, in: segment, text: text) else { continue }
                expected.append([segment.sourceText, item.descriptionText])
            }
            for item in scene.editingItems {
                guard let anchor = item.textAnchor,
                      TextAnchorRepair.isAnchor(anchor, in: segment, text: text) else { continue }
                expected.append([segment.sourceText, item.cutStyle])
            }
        }
        for item in scene.bRollItems where item.textAnchor == nil {
            expected.append(["", item.descriptionText])
        }
        for item in scene.editingItems where item.textAnchor == nil {
            expected.append(["", item.cutStyle])
        }

        let project = FrameProject(title: "Export", scenes: [scene])
        let prefs = AppSettings.defaults.exportPreferences
        let csv = ExportService().render(
            project: project,
            format: .csv,
            preferences: prefs,
            language: .spanish
        )
        let rows = csv.split(separator: "\r\n").dropFirst().map(csvCells)
        let actual = rows.map { [$0[3], $0[6]] }
        XCTAssertEqual(actual, expected)

        let markdown = ExportService().render(
            project: project,
            format: .markdown,
            preferences: prefs,
            language: .spanish
        )
        var cursor = markdown.startIndex
        for pair in expected where !pair[0].isEmpty {
            let found = try XCTUnwrap(
                markdown.range(of: pair[1], range: cursor..<markdown.endIndex),
                "\(pair[1]) must appear in segment order"
            )
            cursor = found.upperBound
        }
    }

    private func csvCells(_ row: Substring) -> [String] {
        row.split(separator: ",", omittingEmptySubsequences: false).map { value in
            var text = String(value)
            if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
                text.removeFirst()
                text.removeLast()
            }
            return text.replacingOccurrences(of: "\"\"", with: "\"")
        }
    }

    // MARK: - Duration passes

    func testSaveRecomputesOnlyEditedScenesAndOpenTrustsStoredEstimates() throws {
        let directory = try temporaryDirectory()
        let url = try writeProject(project(sceneCount: 8), in: directory)
        let appState = makeAppState()
        appState.openProject(at: url)
        XCTAssertTrue(appState.saveProject(), "The first save stores every estimate")

        var openCalls = 0
        appState.projectStore.durationConfigurationProvider = { _ in
            openCalls += 1
            return .standard
        }
        appState.openProject(at: url)
        // One configuration probe is not a parse: the regression was one full
        // estimate per scene (twice).
        XCTAssertLessThanOrEqual(openCalls, 1, "A file with valid stored estimates must not re-parse on open")
        XCTAssertLessThan(openCalls, appState.project.scenes.count)

        var saveCalls = 0
        appState.projectStore.durationConfigurationProvider = { _ in
            saveCalls += 1
            return .standard
        }
        let scene = try XCTUnwrap(appState.project.scenes.first)
        let editedText = scene.scriptText + " Una frase nueva."
        appState.commitScriptTextChange(sceneID: scene.id, text: editedText)
        XCTAssertTrue(appState.saveProject())
        XCTAssertLessThanOrEqual(saveCalls, 2, "Only the edited scene recomputes its duration")
        XCTAssertLessThan(saveCalls, appState.project.scenes.count / 2)

        let saved = try FrameScriptFileStore.read(from: url)
        let savedScene = try XCTUnwrap(saved.scenes.first(where: { $0.id == scene.id }))
        let expected = DurationEstimator.estimate(
            text: editedText,
            configuration: appState.durationConfiguration(for: scene)
        )
        XCTAssertEqual(savedScene.estimatedDuration, expected, accuracy: 0.0001)
    }

    func testReadingSpeedChangeWithoutATextEditRefreshesSavedEstimates() throws {
        let directory = try temporaryDirectory()
        let url = try writeProject(project(sceneCount: 2), in: directory)
        let appState = makeAppState()
        appState.openProject(at: url)
        XCTAssertTrue(appState.saveProject())
        let before = try XCTUnwrap(FrameScriptFileStore.read(from: url).scenes.first?.estimatedDuration)

        appState.settings.editorPreferences.wordsPerMinuteByLanguage["es"] = 240
        XCTAssertTrue(appState.saveProject())
        let after = try XCTUnwrap(FrameScriptFileStore.read(from: url).scenes.first?.estimatedDuration)
        XCTAssertLessThan(after, before, "A faster pace must shorten the saved estimate")
    }

    func testDirtyOnlySaveProducesTheSameScenesAsAFullDurationPass() throws {
        let directory = try temporaryDirectory()
        let url = try writeProject(project(sceneCount: 12), in: directory)
        let editedText = "Texto editado para comparar la pasada completa y la incremental."

        func savedProject(forceFullPass: Bool) throws -> FrameProject {
            let appState = makeAppState()
            appState.openProject(at: url)
            let scene = try XCTUnwrap(appState.project.scenes.first)
            appState.commitScriptTextChange(sceneID: scene.id, text: editedText)
            if forceFullPass {
                appState.refreshDurationEstimates()
            }
            XCTAssertTrue(appState.saveProject())
            return try FrameScriptFileStore.read(from: url)
        }

        let incremental = try savedProject(forceFullPass: false)
        let full = try savedProject(forceFullPass: true)
        XCTAssertEqual(incremental.scenes.count, full.scenes.count)
        for (lhs, rhs) in zip(
            incremental.scenes.sortedByOrder,
            full.scenes.sortedByOrder
        ) {
            XCTAssertEqual(lhs.scriptText, rhs.scriptText)
            XCTAssertEqual(lhs.estimatedDuration, rhs.estimatedDuration, accuracy: 0.0001)
            XCTAssertEqual(
                lhs.textSegments.sortedByOrder.map(\.sourceText),
                rhs.textSegments.sortedByOrder.map(\.sourceText)
            )
        }
    }

    func testLegacyZeroEstimateStillGetsFilledOnOpen() throws {        let directory = try temporaryDirectory()
        let source = project(sceneCount: 2)
        for scene in source.scenes { scene.estimatedDuration = 0 }
        let url = try writeProject(source, in: directory)
        let appState = makeAppState()
        appState.openProject(at: url)
        for scene in appState.project.scenes {
            XCTAssertGreaterThan(scene.estimatedDuration, 0)
        }
    }

    // MARK: - Background saves

    func testBackgroundAutosaveWritesTheSnapshotAndClearsDirtyState() async throws {
        let directory = try temporaryDirectory()
        let url = try writeProject(project(sceneCount: 20), in: directory)
        let appState = makeAppState()
        appState.openProject(at: url)
        let scene = try XCTUnwrap(appState.project.scenes.first)
        let newText = scene.scriptText + " Autosave."
        appState.commitScriptTextChange(sceneID: scene.id, text: newText)

        appState.performAutosave()
        try await waitUntil("background autosave", timeout: .seconds(15)) {
            !appState.projectStore.hasPendingBackgroundWrite
                && !appState.projectStore.hasUnsavedFileChanges
        }

        let saved = try FrameScriptFileStore.read(from: url)
        XCTAssertEqual(saved.scenes.first(where: { $0.id == scene.id })?.scriptText, newText)
        XCTAssertEqual(appState.saveState, .saved)
        XCTAssertEqual(
            appState.trackedProjectFileSnapshot?.contentHash,
            ProjectFileSnapshotReader.hash(of: try Data(contentsOf: url))
        )
    }

    func testEditDuringBackgroundSaveKeepsTheProjectDirtyAndSavesAgain() async throws {
        let directory = try temporaryDirectory()
        let url = try writeProject(project(sceneCount: 20), in: directory)
        let appState = makeAppState()
        appState.openProject(at: url)
        let scene = try XCTUnwrap(appState.project.scenes.first)
        let firstText = scene.scriptText + " Primera."
        appState.commitScriptTextChange(sceneID: scene.id, text: firstText)

        appState.performAutosave()
        let secondText = firstText + " Segunda."
        appState.commitScriptTextChange(sceneID: scene.id, text: secondText)

        try await waitUntil("first background save", timeout: .seconds(15)) {
            !appState.projectStore.hasPendingBackgroundWrite
        }
        XCTAssertTrue(
            appState.projectStore.hasUnsavedFileChanges,
            "An edit after the snapshot must keep the project dirty"
        )
        let firstSave = try FrameScriptFileStore.read(from: url)
        XCTAssertEqual(firstSave.scenes.first(where: { $0.id == scene.id })?.scriptText, firstText)

        appState.performAutosave()
        try await waitUntil("second background save", timeout: .seconds(15)) {
            !appState.projectStore.hasPendingBackgroundWrite
                && !appState.projectStore.hasUnsavedFileChanges
        }
        let secondSave = try FrameScriptFileStore.read(from: url)
        XCTAssertEqual(secondSave.scenes.first(where: { $0.id == scene.id })?.scriptText, secondText)
    }

    func testSynchronousSaveWaitsForAPendingBackgroundWrite() async throws {
        let directory = try temporaryDirectory()
        let url = try writeProject(project(sceneCount: 20), in: directory)
        let appState = makeAppState()
        appState.openProject(at: url)
        let scene = try XCTUnwrap(appState.project.scenes.first)
        let newText = scene.scriptText + " Antes de cerrar."
        appState.commitScriptTextChange(sceneID: scene.id, text: newText)

        appState.performAutosave()
        XCTAssertTrue(appState.saveProject(), "A manual save must serialize after the background write")
        XCTAssertFalse(appState.projectStore.hasPendingBackgroundWrite)
        XCTAssertFalse(appState.projectStore.hasUnsavedFileChanges)
        let saved = try FrameScriptFileStore.read(from: url)
        XCTAssertEqual(saved.scenes.first(where: { $0.id == scene.id })?.scriptText, newText)
        _ = await Task.yield()
    }

    func testBackgroundAutosaveFailureSurfacesAsAnAutosaveError() async throws {
        let directory = try temporaryDirectory()
        let url = try writeProject(project(sceneCount: 4), in: directory)
        let appState = makeAppState()
        appState.openProject(at: url)
        let scene = try XCTUnwrap(appState.project.scenes.first)
        appState.commitScriptTextChange(sceneID: scene.id, text: scene.scriptText + " Falla.")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directory.path
            )
        }

        appState.performAutosave()
        try await waitUntil("autosave error", timeout: .seconds(15)) {
            appState.errorCenter.presentedError?.kind == .autosave
        }
        XCTAssertTrue(appState.projectStore.hasUnsavedFileChanges)
    }

    func testTerminationWaitsForAPendingBackgroundWrite() async throws {
        let directory = try temporaryDirectory()
        let url = try writeProject(project(sceneCount: 20), in: directory)
        let appState = makeAppState(closeConfirmation: { .save })
        appState.openProject(at: url)
        let scene = try XCTUnwrap(appState.project.scenes.first)
        let newText = scene.scriptText + " Al salir."
        appState.commitScriptTextChange(sceneID: scene.id, text: newText)

        appState.performAutosave()
        XCTAssertTrue(appState.confirmApplicationTermination())
        let saved = try FrameScriptFileStore.read(from: url)
        XCTAssertEqual(saved.scenes.first(where: { $0.id == scene.id })?.scriptText, newText)
        _ = await Task.yield()
    }

    // MARK: - Rhythm review

    func testIncrementalRhythmReviewMatchesAFullPass() throws {
        let fixture = project(sceneCount: 30, sentenceCount: 12)
        let settings = AppSettings.defaults
        let configuration = DurationEstimator.configuration(
            language: fixture.primaryLanguage,
            learnedWordsPerMinute: fixture.learnedWordsPerMinuteByLanguage,
            settings: settings
        )
        let snapshots = fixture.scenes.sortedByOrder.map { scene in
            RhythmSceneSnapshot(
                sceneID: scene.id,
                text: scene.scriptText,
                visualChangeOffsets: [],
                isHook: scene.sectionType == .hook,
                pauseDefaults: configuration.pauseDefaults,
                wordsPerMinute: configuration.wordsPerMinute,
                utf16Length: (scene.scriptText as NSString).length
            )
        }
        let calibration = RhythmReview.effectiveThresholds(project: fixture, settings: settings)
        let full = RhythmAnalysisRunner.analyze(snapshots, calibration: calibration)
        let cache = RhythmAnalysisCache(
            analyses: full.analyses,
            snapshots: full.analyzedSnapshots,
            calibration: calibration
        )

        var changed = snapshots
        let first = changed[0]
        changed[0] = RhythmSceneSnapshot(
            sceneID: first.sceneID,
            text: first.text + " Una frase extra para cambiar el ritmo.",
            visualChangeOffsets: first.visualChangeOffsets,
            isHook: first.isHook,
            pauseDefaults: first.pauseDefaults,
            wordsPerMinute: first.wordsPerMinute,
            utf16Length: first.utf16Length + 40
        )

        let clock = ContinuousClock()
        var incremental: RhythmAnalysisOutput?
        let incrementalTime = clock.measure {
            incremental = RhythmAnalysisRunner.analyze(changed, calibration: calibration, reusing: cache)
        }
        var fresh: RhythmAnalysisOutput?
        let freshTime = clock.measure {
            fresh = RhythmAnalysisRunner.analyze(changed, calibration: calibration)
        }

        XCTAssertEqual(incremental?.analyses, fresh?.analyses)
        XCTAssertEqual(incremental?.projectWarnings, fresh?.projectWarnings)
        XCTAssertLessThan(
            incrementalTime,
            freshTime / 3,
            "one changed scene \(incrementalTime) must beat a full pass \(freshTime)"
        )
    }

    // MARK: - Duration text hash cache

    func testDurationSummaryUsesTheCachedTextHashAndDetectsStaleTakes() throws {
        let fixture = project(sceneCount: 4)
        for scene in fixture.scenes {
            scene.takes = [
                Take(
                    number: 1,
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    duration: 42,
                    rating: .good,
                    languageCode: "",
                    readText: scene.scriptText,
                    sceneTextHash: FrameScriptDocument.TextHash.hash(scene.scriptText)
                )
            ]
        }
        let store = ProjectStore(project: fixture)
        store.openProject(fixture, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        let appState = makeAppState(store: store, autosaveEnabled: false)
        let scene = try XCTUnwrap(fixture.scenes.first)

        XCTAssertEqual(appState.sceneDurationSummary(for: scene).real, 42)
        for _ in 0..<20 {
            XCTAssertEqual(appState.sceneDurationSummary(for: scene).real, 42)
        }
        XCTAssertEqual(
            store.textHash(for: scene),
            FrameScriptDocument.TextHash.hash(scene.scriptText)
        )

        let newText = scene.scriptText + " Texto nuevo."
        appState.commitScriptTextChange(sceneID: scene.id, text: newText)
        XCTAssertNil(
            appState.sceneDurationSummary(for: scene).real,
            "A take recorded against old text is stale after the edit"
        )
        XCTAssertEqual(store.textHash(for: scene), FrameScriptDocument.TextHash.hash(newText))
    }

    // MARK: - Escaleta import

    func testEscaletaImportParsesAsynchronouslyAndReturnsThePreview() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("Escaleta.md")
        let markdown = """
        # Escaleta de prueba

        ## 00:00 — Apertura

        - Primer punto de la escaleta
        - Segundo punto de la escaleta

        **[VISUAL]** Plano general de la ciudad

        ## 00:45 — Desarrollo

        - Tercer punto
        """
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        let appState = makeAppState(autosaveEnabled: false)

        let prepared = await appState.prepareEscaletaImport(url: url)
        let request = try XCTUnwrap(prepared)
        XCTAssertEqual(request.fileName, "Escaleta.md")
        XCTAssertEqual(request.mode, .newProject)
        XCTAssertNotNil(request.mapping)
        XCTAssertFalse(request.document.scenes.isEmpty)
    }

    // MARK: - History

    func testVersionHistoryWithFiftySnapshotsStillOpensAndSaves() throws {
        let directory = try temporaryDirectory()
        let snapshots = (0..<50).map { index in
            FrameScriptDocument.VersionSnapshot(
                createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index * 60)),
                label: "snapshot \(index)",
                compressedPayload: Data(repeating: UInt8(index & 0xFF), count: 2_048)
            )
        }
        let document = FrameScriptDocument(
            project: FrameScriptDocument.Project(
                title: "History",
                scenes: (0..<3).map {
                    FrameScriptDocument.Scene(
                        order: $0,
                        sectionType: .custom,
                        title: "Scene \($0)",
                        scriptText: "Texto \($0)."
                    )
                },
                versionHistory: snapshots
            )
        )
        let originalData = try FrameScriptDocumentCodec.encode(document)
        let url = directory.appendingPathComponent("History.fscr")
        try originalData.write(to: url)

        let project = try FrameScriptFileStore.read(from: url)
        XCTAssertEqual(project.versionHistory.count, 50)
        XCTAssertEqual(project.versionHistory.map(\.label), snapshots.map(\.label))
        XCTAssertEqual(project.versionHistory.map(\.compressedPayload), snapshots.map(\.compressedPayload))

        let savedURL = directory.appendingPathComponent("HistorySaved.fscr")
        try FrameScriptFileStore.write(project: project, to: savedURL)
        let savedData = try Data(contentsOf: savedURL)
        XCTAssertEqual(
            savedData,
            originalData,
            "An unchanged history must round-trip byte for byte"
        )
    }
}

// MARK: - Budget probes

@MainActor
final class WP9PerformanceBudgetTests: FrameScriptTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameScriptWP9Budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeAppState(autosaveEnabled: Bool = true) -> AppState {
        let suite = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.autosaveEnabled = autosaveEnabled
        settings.generalPreferences.autosaveIntervalSeconds = 3_600
        return AppState(
            projectStore: ProjectStore(project: SampleData.defaultProject),
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: settings, userDefaults: suite, key: "settings"),
            closeConfirmation: { .discard },
            externalChangeConfirmation: { .keepMine }
        )
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    func testBackgroundAutosaveStartIsCheaperThanASynchronousSave() async throws {
        let directory = try temporaryDirectory()
        let words = ["cuando", "la", "ciudad", "despierta", "cada", "mañana", "los", "vecinos"]
        let scenes = (0..<60).map { index in
            Scene(
                order: index,
                sectionType: .custom,
                title: "Scene \(index)",
                scriptText: (0..<28).map { sentence in
                    (0..<18).map { offset in
                        words[(index + sentence + offset) % words.count]
                    }.joined(separator: " ")
                }.joined(separator: " ")
            )
        }
        let url = directory.appendingPathComponent("Budget.fscr")
        try FrameScriptFileStore.write(project: FrameProject(title: "Budget", scenes: scenes), to: url)
        let appState = makeAppState()
        appState.openProject(at: url)
        appState.projectStore.synchronizeTextSegments(
            splitMode: .sentence,
            wordsPerMinute: 150,
            markUnsaved: false
        )

        var saveTimes: [Double] = []
        for index in 0..<3 {
            let scene = appState.project.scenes[index]
            appState.commitScriptTextChange(sceneID: scene.id, text: scene.scriptText + " s\(index)")
            let start = DispatchTime.now().uptimeNanoseconds
            _ = appState.saveProject()
            saveTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }

        var autosaveTimes: [Double] = []
        for index in 0..<3 {
            try await waitUntil("previous write", timeout: .seconds(15)) {
                !appState.projectStore.hasPendingBackgroundWrite
            }
            let scene = appState.project.scenes[3 + index]
            appState.commitScriptTextChange(sceneID: scene.id, text: scene.scriptText + " a\(index)")
            let start = DispatchTime.now().uptimeNanoseconds
            appState.performAutosave()
            autosaveTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        try await waitUntil("final write", timeout: .seconds(15)) {
            !appState.projectStore.hasPendingBackgroundWrite
        }

        XCTAssertLessThan(
            median(autosaveTimes),
            median(saveTimes) / 2,
            "autosave start \(median(autosaveTimes)) ms must beat a synchronous save \(median(saveTimes)) ms"
        )
    }

    func testDurationSummaryStaysBelowAFewMillisecondsPerCall() throws {
        let words = ["cuando", "la", "ciudad", "despierta", "cada", "mañana"]
        let scenes = (0..<60).map { index in
            Scene(
                order: index,
                sectionType: .custom,
                title: "Scene \(index)",
                scriptText: (0..<500).map { words[$0 % words.count] }.joined(separator: " ")
            )
        }
        for scene in scenes {
            scene.takes = [
                Take(
                    number: 1,
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    duration: 40,
                    rating: .good,
                    languageCode: "",
                    readText: scene.scriptText,
                    sceneTextHash: FrameScriptDocument.TextHash.hash(scene.scriptText)
                )
            ]
        }
        let project = FrameProject(title: "Summary", scenes: scenes)
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        let appState = makeAppState(autosaveEnabled: false)

        for _ in 0..<5 { _ = appState.projectDurationSummary() }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<100 {
            _ = appState.projectDurationSummary()
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        XCTAssertLessThan(elapsed, 500, "100 cross-project summaries took \(elapsed) ms")
    }

    func testTypingCommitWithThreeHundredAnchorsStaysBelowOneHundredMilliseconds() throws {
        let text = (0..<28).map { index in
            "Cuando la ciudad despierta cada mañana los vecinos caminan hacia el mercado \(index)."
        }.joined(separator: " ")
        let scene = Scene(order: 0, sectionType: .hook, title: "Heavy", scriptText: text)
        let length = (text as NSString).length
        for index in 0..<300 {
            let start = (index * 37) % max(1, length - 14)
            scene.bRollItems.append(
                BRollItem(
                    textAnchor: TextAnchor(
                        startUTF16: start,
                        lengthUTF16: 12,
                        selectedText: "",
                        prefixContext: "",
                        suffixContext: ""
                    ),
                    templateType: "",
                    sourceType: .stockFootage,
                    descriptionText: "Item \(index)"
                )
            )
        }
        let project = FrameProject(title: "Typing", scenes: [scene])
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)

        var times: [Double] = []
        var current = text
        for _ in 0..<10 {
            let next = current + "x"
            let start = DispatchTime.now().uptimeNanoseconds
            store.commitScriptText(next, sceneID: scene.id, previousText: current)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            current = next
        }
        XCTAssertLessThan(median(times), 100, "300 anchored items took \(median(times)) ms per keystroke")
    }
}
