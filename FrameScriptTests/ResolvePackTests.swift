import CoreGraphics
import Foundation
import FrameScriptCore
import XCTest
@testable import FrameScript

/// Pure logic tests for the DaVinci Resolve delivery pack (F19).
///
/// Every fixture is in-memory and synthetic: no `UserDefaults`, Keychain,
/// Application Support folder or recents are touched.
final class ResolvePackTests: XCTestCase {
    // MARK: - Fixtures

    private let tenWords = "uno dos tres cuatro cinco seis siete ocho nueve diez"
    private let twentyWords = "uno dos tres cuatro cinco seis siete ocho nueve diez once doce trece catorce quince dieciséis diecisiete dieciocho diecinueve veinte"

    private func anchor(_ phrase: String, in text: String) -> TextAnchor {
        let range = (text as NSString).range(of: phrase)
        XCTAssertNotEqual(range.location, NSNotFound, "fixture phrase \(phrase) missing")
        return TextAnchor(
            startUTF16: range.location,
            lengthUTF16: range.length,
            selectedText: phrase
        )
    }

    private func take(
        number: Int = 1,
        duration: TimeInterval,
        rating: TakeRating = .good,
        language: String = "es",
        text: String
    ) -> Take {
        Take(
            number: number,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: duration,
            rating: rating,
            languageCode: language,
            readText: text,
            sceneTextHash: FrameScriptDocument.TextHash.hash(text)
        )
    }

    private func makeProject(
        scenes: [Scene],
        claims: [ProjectClaim] = []
    ) -> FrameProject {
        FrameProject(
            title: "Prueba sintética",
            scenes: scenes,
            primaryLanguage: "es",
            claims: claims
        )
    }

    private func mapper(
        language: String = "es",
        source: ResolvePackDurationSource = .realTakes,
        wpm: Double = 120
    ) -> ResolveSceneMapper {
        ResolveSceneMapper(
            languageCode: language,
            durationSource: source,
            wordsPerMinute: wpm,
            pauseDefaults: .standard
        )
    }

    // MARK: - Configuration

    func testFrameRateOptionsCoverTheRequestedRatesAndDefaultTo25() {
        XCTAssertEqual(ResolvePackFrameRate.allCases.count, 8)
        XCTAssertEqual(ResolvePackFrameRate.default, .fps25)
        XCTAssertEqual(ResolvePackFrameRate.allCases.map(\.label), [
            "23.976", "24", "25", "29.97 DF", "30", "50", "59.94 DF", "60"
        ])
        XCTAssertTrue(ResolvePackFrameRate.fps29_97.dropFrame)
        XCTAssertTrue(ResolvePackFrameRate.fps59_94.dropFrame)
        XCTAssertFalse(ResolvePackFrameRate.fps30.dropFrame)
    }

    func testConfigurationDefaultsAndRateChangeResetTheStartTimecode() {
        var configuration = ResolvePackConfiguration.defaults(languageCode: "es")
        XCTAssertEqual(configuration.rate, .fps25)
        XCTAssertEqual(configuration.startTimecodeText, "01:00:00:00")
        XCTAssertTrue(configuration.asciiSafeNames)
        XCTAssertEqual(configuration.durationSource, .realTakes)
        XCTAssertTrue(configuration.hasAnyFile)

        configuration.setRate(.fps29_97)
        XCTAssertEqual(configuration.startTimecodeText, "01:00:00;00")
        XCTAssertEqual(configuration.parsedStartTimecode?.frames, 107_892)

        configuration.setRate(.fps59_94)
        XCTAssertEqual(configuration.startTimecodeText, "01:00:00;00")
        XCTAssertEqual(configuration.parsedStartTimecode?.frames, 215_784)

        configuration.setRate(.fps24)
        XCTAssertEqual(configuration.startTimecodeText, "01:00:00:00")
        XCTAssertEqual(configuration.parsedStartTimecode?.frames, 86_400)
    }

    func testTimecodeFieldAcceptsColonOrSemicolonBeforeFrames() throws {
        XCTAssertEqual(
            ResolvePackTimecodeField.parse("01:00:00:00", rate: .fps29_97, dropFrame: true)?.frames,
            107_892
        )
        XCTAssertEqual(
            ResolvePackTimecodeField.parse("01:00:00;00", rate: .fps29_97, dropFrame: true)?.frames,
            107_892
        )
        XCTAssertEqual(
            ResolvePackTimecodeField.parse("00:00:10:00", rate: .fps25, dropFrame: false)?.frames,
            250
        )
        XCTAssertEqual(
            ResolvePackTimecodeField.parse("00:00:10;00", rate: .fps25, dropFrame: false)?.frames,
            250
        )
        XCTAssertNil(ResolvePackTimecodeField.parse("1:00:00:00", rate: .fps25, dropFrame: false))
        XCTAssertNil(ResolvePackTimecodeField.parse("", rate: .fps25, dropFrame: false))
        XCTAssertNil(ResolvePackTimecodeField.parse("00:01:00;00", rate: .fps29_97, dropFrame: true))
    }

    func testOptionsRequireAtLeastOneFileAndAValidTimecode() {
        var configuration = ResolvePackConfiguration.defaults(languageCode: "es")
        XCTAssertNotNil(configuration.options())

        configuration.includeMarkerEDL = false
        configuration.includeFCPXML = false
        configuration.includeShotList = false
        configuration.includeEditingNotes = false
        configuration.includeChapters = false
        configuration.includeReadme = false
        XCTAssertFalse(configuration.hasAnyFile)
        XCTAssertNil(configuration.options())

        configuration.includeReadme = true
        configuration.startTimecodeText = "nope"
        XCTAssertNil(configuration.options())
        configuration.startTimecodeText = "01:00:00:00"
        XCTAssertNotNil(configuration.options())
    }

    // MARK: - Mapping

    func testMapperUsesLearnedPaceAndCumulativeStarts() throws {
        let first = Scene(order: 0, sectionType: .hook, title: "Gancho", scriptText: tenWords)
        let second = Scene(order: 1, sectionType: .explanation, title: "Problema", scriptText: twentyWords)
        let project = makeProject(scenes: [first, second])

        let result = mapper(wpm: 120).map(project: project)

        XCTAssertEqual(result.scenes.count, 2)
        XCTAssertEqual(result.scenes[0].duration, 5, accuracy: 0.001)
        XCTAssertEqual(result.scenes[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(result.scenes[1].duration, 10, accuracy: 0.001)
        XCTAssertEqual(result.scenes[1].start, 5, accuracy: 0.001)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testRealTakesWinAndCueOffsetsScaleIntoTheTakeDuration() throws {
        let text = tenWords
        let anchor = anchor("cinco", in: text)
        let item = BRollItem(
            textAnchor: anchor,
            templateType: "gameplay",
            sourceType: .screenRecording,
            descriptionText: "Gameplay en Spa"
        )
        let scene = Scene(
            order: 0,
            sectionType: .hook,
            title: "Gancho",
            scriptText: text,
            bRollItems: [item],
            takes: [take(duration: 4, text: text)]
        )
        let project = makeProject(scenes: [scene])

        let result = mapper().map(project: project)
        let exported = try XCTUnwrap(result.scenes.first)

        // 10 words at 120 wpm is 5 s, but the good take is 4 s.
        XCTAssertEqual(exported.duration, 4, accuracy: 0.001)
        let marker = try XCTUnwrap(exported.markers.first)
        XCTAssertEqual(marker.name, "OBS · Gameplay en Spa")
        XCTAssertEqual(marker.color, .yellow)
        // "cinco" starts after four words: 2 s of the 5 s estimate, scaled to
        // 1.6 s of the 4 s take.
        XCTAssertEqual(marker.offset, 1.6, accuracy: 0.001)
    }

    func testEstimatesIgnoreRealTakes() throws {
        let scene = Scene(
            order: 0,
            sectionType: .hook,
            title: "Gancho",
            scriptText: tenWords,
            takes: [take(duration: 4, text: tenWords)]
        )
        let project = makeProject(scenes: [scene])

        let result = mapper(source: .estimates).map(project: project)
        XCTAssertEqual(try XCTUnwrap(result.scenes.first).duration, 5, accuracy: 0.001)
    }

    func testStaleTakesAreIgnored() throws {
        let stale = take(duration: 4, text: "texto antiguo")
        let scene = Scene(
            order: 0,
            sectionType: .hook,
            title: "Gancho",
            scriptText: tenWords,
            takes: [stale]
        )
        let result = mapper().map(project: makeProject(scenes: [scene]))
        XCTAssertEqual(try XCTUnwrap(result.scenes.first).duration, 5, accuracy: 0.001)
    }

    func testBRollSourceTypesUseTheDeliveryLegend() throws {
        let text = "uno dos tres cuatro cinco seis siete ocho nueve diez once doce"
        let sources: [BRollSourceType] = [
            .talkingHead, .screenRecording, .screenshot, .infographic, .textOnScreen, .custom
        ]
        let items = sources.enumerated().map { index, source in
            BRollItem(
                textAnchor: anchor("dos", in: text),
                templateType: "",
                sourceType: source,
                descriptionText: "Plano \(index)"
            )
        }
        let scene = Scene(
            order: 0,
            sectionType: .hook,
            title: "Gancho",
            scriptText: text,
            bRollItems: items
        )
        let result = mapper().map(project: makeProject(scenes: [scene]))
        let exported = try XCTUnwrap(result.scenes.first)
        let colors = exported.markers.map(\.color)
        XCTAssertEqual(colors, [.green, .yellow, .pink, .sand, .sand, .green])
        XCTAssertEqual(exported.markers.map(\.name), [
            "CAM · Plano 0",
            "OBS · Plano 1",
            "WEB · Plano 2",
            "GRÁFICO · Plano 3",
            "GRÁFICO · Plano 4",
            "CAM · Plano 5"
        ])
    }

    func testRehookEditingItemsCreateAPurpleCue() throws {
        let text = "uno dos tres cuatro cinco seis siete ocho nueve diez"
        let item = EditingItem(
            textAnchor: anchor("seis", in: text),
            templateType: "",
            cutStyle: "RE-HOOK",
            transition: "",
            subtitleStyle: ""
        )
        let scene = Scene(
            order: 0,
            sectionType: .explanation,
            title: "Problema",
            scriptText: text,
            editingItems: [item]
        )
        let exported = try XCTUnwrap(mapper().map(project: makeProject(scenes: [scene])).scenes.first)

        XCTAssertTrue(exported.isRehook)
        let purple = exported.markers.filter { $0.color == .purple }
        XCTAssertEqual(purple.count, 1)
        XCTAssertEqual(purple.first?.name, "RE-HOOK")
        XCTAssertEqual(Int(((purple.first?.offset ?? 0) * 25).rounded()), 63)
    }

    func testScriptRehookCueAlsoCreatesARehookMarker() throws {
        let text = "uno dos tres [RE-HOOK] cuatro cinco"
        let scene = Scene(order: 0, sectionType: .explanation, title: "Problema", scriptText: text)
        let exported = try XCTUnwrap(mapper().map(project: makeProject(scenes: [scene])).scenes.first)
        XCTAssertTrue(exported.isRehook)
        XCTAssertTrue(exported.markers.contains { $0.color == .purple && $0.name == "RE-HOOK" })
    }

    func testUnconfirmedClaimsBecomeRedRigorMarkers() throws {
        let scene = Scene(order: 0, sectionType: .explanation, title: "Problema", scriptText: tenWords)
        let probable = ProjectClaim(text: "El circuito cuesta 40 millones", status: .probable, sceneIDs: [scene.id])
        let rumor = ProjectClaim(text: "Salen 12 coches nuevos", status: .rumor, sceneIDs: [scene.id])
        let confirmed = ProjectClaim(text: "Hay 24 horas", status: .confirmed, sceneIDs: [scene.id])
        let project = makeProject(scenes: [scene], claims: [probable, rumor, confirmed])

        let exported = try XCTUnwrap(mapper().map(project: project).scenes.first)
        let rigor = exported.markers.filter { $0.name.hasPrefix("RIGOR") }
        XCTAssertEqual(rigor.count, 2)
        XCTAssertTrue(rigor.allSatisfy { $0.color == .red })
        XCTAssertTrue(rigor.contains { $0.note == probable.text })
        XCTAssertFalse(rigor.contains { $0.note == confirmed.text })
        XCTAssertEqual(exported.warnings.count, 2)
    }

    func testRhythmWarningsBecomeRedMarkersAndSceneNotes() throws {
        let scene = Scene(order: 0, sectionType: .explanation, title: "Problema", scriptText: tenWords)
        let warning = RhythmWarning(
            sceneID: scene.id.uuidString,
            kind: .longSentence,
            range: UTF16Span(location: 4, length: 20),
            messageKey: RhythmMessageKey.longSentence,
            arguments: [
                RhythmArgument("words", 42),
                RhythmArgument("seconds", 18),
                RhythmArgument("maxWords", 35),
                RhythmArgument("maxSeconds", 15)
            ]
        )
        var mapper = mapper()
        mapper.rhythmWarningsByScene = [scene.id: [warning]]

        let exported = try XCTUnwrap(mapper.map(project: makeProject(scenes: [scene])).scenes.first)
        let rhythm = exported.markers.filter { $0.name.hasPrefix("RITMO") }
        XCTAssertEqual(rhythm.count, 1)
        XCTAssertEqual(rhythm.first?.color, .red)
        XCTAssertFalse(try XCTUnwrap(rhythm.first).note.isEmpty)
    }

    func testLanguageVariantUsesItsTextDurationAndScaledCues() throws {
        let spanish = tenWords
        let english = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty"
        let englishTake = take(duration: 6, language: "en", text: english)
        let variant = SceneLanguageVariant(
            languageCode: "en",
            text: english,
            sourceHash: FrameScriptDocument.TextHash.hash(english),
            takes: [englishTake]
        )
        let item = BRollItem(
            textAnchor: anchor("seis", in: spanish),
            templateType: "",
            sourceType: .talkingHead,
            descriptionText: "Plano a cámara"
        )
        let scene = Scene(
            order: 0,
            sectionType: .hook,
            title: "Gancho",
            scriptText: spanish,
            bRollItems: [item],
            languageVariants: [variant]
        )
        let exported = try XCTUnwrap(
            mapper(language: "en").map(project: makeProject(scenes: [scene])).scenes.first
        )

        XCTAssertEqual(exported.scriptExcerpt, english)
        XCTAssertEqual(exported.duration, 6, accuracy: 0.001)
        // Spanish anchor after five words: 2.5 s of the 5 s estimate → 3 s of
        // the 6 s English take.
        XCTAssertEqual(exported.markers.first?.offset ?? 0, 3, accuracy: 0.001)
    }

    func testMissingVariantFallsBackToTheOriginalWithAWarning() throws {
        let scene = Scene(order: 0, sectionType: .hook, title: "Gancho", scriptText: tenWords)
        let result = mapper(language: "en").map(project: makeProject(scenes: [scene]))
        XCTAssertEqual(result.scenes.first?.scriptExcerpt, tenWords)
        XCTAssertTrue(result.warnings.contains { $0.contains("no tiene texto en «en»") })
    }

    func testCuesSharingAnAnchorKeepTheirOwnFrameAndColour() throws {
        let text = "uno dos tres cuatro cinco seis siete ocho nueve diez"
        let item = EditingItem(
            textAnchor: anchor("seis", in: text),
            templateType: "",
            cutStyle: "",
            transition: "",
            subtitleStyle: "Rótulo: precio",
            musicCue: "Música tensa",
            graphics: "Tabla comparativa"
        )
        let scene = Scene(
            order: 0,
            sectionType: .explanation,
            title: "Problema",
            scriptText: text,
            editingItems: [item]
        )
        let result = mapper().map(project: makeProject(scenes: [scene]))
        let exported = try XCTUnwrap(result.scenes.first)

        XCTAssertEqual(exported.markers.count, 3)
        XCTAssertEqual(exported.markers.filter { $0.color == .sand }.count, 2)
        XCTAssertEqual(exported.markers.filter { $0.color == .lavender }.count, 1)
        let frames = Set(exported.markers.map { Int(($0.offset * 25).rounded()) })
        XCTAssertEqual(frames.count, 3, "cues must not share a frame")

        let options = try XCTUnwrap(ResolvePackConfiguration.defaults(languageCode: "es").options())
        let plan = ResolveDeliveryPack.plan(
            scenes: result.scenes,
            projectName: "Prueba",
            options: options
        )
        XCTAssertEqual(plan.markers.count, plan.sceneCount + plan.cueCount)
    }

    func testUnanchoredBRollWarnsAndLandsAtSceneStart() throws {
        let item = BRollItem(
            templateType: "",
            sourceType: .screenshot,
            descriptionText: "Captura del menú"
        )
        let scene = Scene(
            order: 0,
            sectionType: .hook,
            title: "Gancho",
            scriptText: tenWords,
            bRollItems: [item]
        )
        let result = mapper().map(project: makeProject(scenes: [scene]))
        let exported = try XCTUnwrap(result.scenes.first)
        XCTAssertLessThanOrEqual(exported.markers.first?.offset ?? 99, 2.0 / 25.0)
        XCTAssertTrue(result.warnings.contains { $0.contains("no tiene ancla") })
    }

    // MARK: - Pack

    func testPackPlanUsesMapperOutputAndWritesEverySelectedFile() throws {
        let scene = Scene(order: 0, sectionType: .hook, title: "Gancho", scriptText: tenWords)
        let mapping = mapper().map(project: makeProject(scenes: [scene]))
        let configuration = ResolvePackConfiguration.defaults(languageCode: "es")
        let options = try XCTUnwrap(configuration.options())
        let plan = ResolveDeliveryPack.plan(
            scenes: mapping.scenes,
            projectName: "Prueba sintética",
            options: options,
            extraWarnings: mapping.warnings
        )

        XCTAssertEqual(plan.names.folder, "Prueba sintetica_resolve")
        XCTAssertEqual(plan.markers.count, 1)
        XCTAssertEqual(plan.markerPreviews.first?.timecode, "01:00:00:00")

        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResolvePackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let folder = try ResolveDeliveryPack.write(plan, to: parent)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(Set(files), Set(plan.names.all))
        let readme = try String(
            contentsOf: folder.appendingPathComponent(plan.names.readme),
            encoding: .utf8
        )
        XCTAssertTrue(readme.contains("Timelines > Import > Timeline Markers from EDL"))
        XCTAssertTrue(readme.contains("File > Import > Timeline"))
        XCTAssertTrue(readme.contains("Numbers"))
    }

    func testDropFramePackStartsWithSemicolonAndNoHourOffset() throws {
        var configuration = ResolvePackConfiguration.defaults(languageCode: "es")
        configuration.setRate(.fps29_97)
        let options = try XCTUnwrap(configuration.options())
        let scene = Scene(order: 0, sectionType: .hook, title: "Gancho", scriptText: tenWords)
        let mapping = mapper().map(project: makeProject(scenes: [scene]))
        let plan = ResolveDeliveryPack.plan(
            scenes: mapping.scenes,
            projectName: "Prueba",
            options: options
        )

        XCTAssertEqual(plan.markerPreviews.first?.timecode, "01:00:00;00")
        XCTAssertEqual(plan.settings.timecodeFormatLabel, "DF")
        let edl = ResolveMarkerEDL.make(scenes: plan.scenes, settings: plan.settings)
        XCTAssertTrue(edl.contains("FCM: DROP FRAME"))
        XCTAssertTrue(edl.contains("01:00:00;00 01:00:00;01"))
        XCTAssertFalse(edl.contains("02:00:"))
    }

    func testLongSceneTitleProducesATruncationWarning() throws {
        let long = String(repeating: "palabra ", count: 20)
        let scene = Scene(order: 0, sectionType: .hook, title: long, scriptText: tenWords)
        let mapping = mapper().map(project: makeProject(scenes: [scene]))
        let options = try XCTUnwrap(ResolvePackConfiguration.defaults(languageCode: "es").options())
        let plan = ResolveDeliveryPack.plan(
            scenes: mapping.scenes,
            projectName: "Prueba",
            options: options
        )
        XCTAssertTrue(plan.warnings.contains { $0.contains("60 caracteres") })
        XCTAssertEqual(plan.markerPreviews.first?.name.count, 60)
    }

    // MARK: - Layout and chrome

    func testLayoutFitsTheMinimumWindowAndHasNoOverlappingChrome() {
        for size in [
            ResolvePackSheetLayout.minimumWindowSize,
            CGSize(width: 1180, height: 760)
        ] {
            let frames = ResolvePackSheetLayout.frames(in: size)
            XCTAssertGreaterThan(frames.body.height, 0)
            XCTAssertGreaterThanOrEqual(frames.preview.width, 500)
            XCTAssertEqual(frames.header.minX, 0)
            XCTAssertEqual(frames.header.width, size.width)
            XCTAssertEqual(frames.footer.maxY, size.height, accuracy: 0.001)
            XCTAssertEqual(frames.preview.maxX, size.width, accuracy: 0.001)

            let chrome = [frames.header, frames.footer, frames.options, frames.divider, frames.preview]
            for (index, first) in chrome.enumerated() {
                for second in chrome[(index + 1)...] where !first.isEmpty && !second.isEmpty {
                    XCTAssertFalse(first.intersects(second), "overlap \(first) / \(second)")
                }
            }
            for rect in [frames.options, frames.divider, frames.preview] {
                XCTAssertTrue(frames.body.contains(rect), "\(rect) outside body")
            }
            XCTAssertTrue(frames.options.union(frames.divider).union(frames.preview).equalTo(frames.body))
        }
    }

    func testShortcutIsRegisteredAndDoesNotClash() {
        let definition = ShortcutRegistry.definition(for: .resolvePack)
        XCTAssertEqual(definition.category, .project)
        // ⌘E (export), ⇧⌘E (escaleta) and ⌥⌘E (AV script) were taken when the
        // pack landed, so integration moved it to ⌃⌘E.
        XCTAssertEqual(definition.factoryDefault, ShortcutBinding("e", modifiers: [.command, .control]))
        XCTAssertNil(
            ShortcutRegistry.conflict(
                for: definition.factoryDefault,
                excluding: .resolvePack,
                overrides: [:]
            )
        )
        XCTAssertEqual(definition.factoryDefault.display, "⌃⌘E")
    }

    func testEveryResolvePackStringExistsInEnglishSpanishAndRussian() throws {
        let table = L10n.resolvePackStrings
        let english = try XCTUnwrap(table[.english])
        let spanish = try XCTUnwrap(table[.spanish])
        let russian = try XCTUnwrap(table[.russian])

        XCTAssertFalse(english.isEmpty)
        XCTAssertEqual(Set(english.keys), Set(spanish.keys))
        XCTAssertEqual(Set(english.keys), Set(russian.keys))
        for key in english.keys {
            XCTAssertNotEqual(L10n.tr(key, language: .english), key)
            XCTAssertNotEqual(L10n.tr(key, language: .spanish), key)
            XCTAssertNotEqual(L10n.tr(key, language: .russian), key)
        }

        XCTAssertEqual(spanish["resolvePack.title"], "Pack para DaVinci Resolve")
        XCTAssertEqual(spanish["resolvePack.menu"], "Pack para DaVinci Resolve…")
        XCTAssertEqual(spanish["resolvePack.export"], "Exportar…")
        XCTAssertEqual(spanish["resolvePack.duration.real"], "Tomas reales si hay; si no, estimación")
        XCTAssertEqual(spanish["resolvePack.legend.graphic"], "Gráfico / tabla")
        XCTAssertTrue(try XCTUnwrap(spanish["resolvePack.subtitle"]).contains("Resolve FREE"))
        XCTAssertTrue(try XCTUnwrap(spanish["resolvePack.note.authoritative"]).contains("EDL"))
    }
}

private extension CGRect {
    func equalTo(_ other: CGRect) -> Bool {
        abs(minX - other.minX) < 0.001
            && abs(minY - other.minY) < 0.001
            && abs(width - other.width) < 0.001
            && abs(height - other.height) < 0.001
    }
}
