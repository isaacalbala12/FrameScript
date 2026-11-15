import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Short clips")
struct ClipsTests {
    // MARK: - Range extraction

    @Test("Whole-scene clips keep the requested scene order")
    func wholeSceneClipKeepsSceneOrder() {
        let first = makeScene(order: 0, title: "Uno", text: "uno dos")
        let second = makeScene(order: 1, title: "Dos", text: "tres cuatro")

        let clip = ClipFactory.make(
            title: "Clip",
            sceneIDs: [second.id, first.id],
            scenes: [first, second]
        )

        #expect(clip.sourceSceneIDs == [second.id, first.id])
        #expect(clip.adaptedText == "tres cuatro\n\nuno dos")
        #expect(clip.sceneSourceHashes.map(\.sceneID) == [second.id, first.id])
        #expect(clip.sceneSourceHashes.map(\.sourceText) == ["tres cuatro", "uno dos"])
        #expect(clip.anchor == nil)
    }

    @Test("Anchored clips use only the selected fragment")
    func anchoredClipUsesOnlySelectedFragment() throws {
        let scene = makeScene(order: 0, title: "Escena", text: "alfa beta gamma delta")
        let anchor = try #require(
            FrameScriptDocument.TextAnchorRepair.anchor(
                in: scene.scriptText,
                range: NSRange(location: 5, length: 10)
            )
        )

        let clip = ClipFactory.make(
            title: "Fragmento",
            sceneIDs: [scene.id],
            anchorSceneID: scene.id,
            anchor: anchor,
            scenes: [scene]
        )

        #expect(clip.anchor?.selectedText == "beta gamma")
        #expect(clip.adaptedText == "beta gamma")
        #expect(clip.sceneSourceHashes.count == 1)
        #expect(clip.sceneSourceHashes.first?.sourceText == "beta gamma")
        #expect(clip.sourceHash == ClipSourceHashing.combinedHash(clip.sceneSourceHashes))
    }

    @Test("The anchor scene is added and duplicate scene IDs are removed")
    func anchorSceneIsAddedOnce() throws {
        let first = makeScene(order: 0, title: "Uno", text: "alfa beta")
        let second = makeScene(order: 1, title: "Dos", text: "gamma")
        let anchor = try #require(
            FrameScriptDocument.TextAnchorRepair.anchor(
                in: first.scriptText,
                range: NSRange(location: 5, length: 4)
            )
        )

        let clip = ClipFactory.make(
            title: "Clip",
            sceneIDs: [second.id, first.id, second.id],
            anchorSceneID: first.id,
            anchor: anchor,
            scenes: [first, second]
        )

        #expect(clip.sourceSceneIDs == [first.id, second.id])
    }

    @Test("Unknown scene IDs are ignored")
    func unknownSceneIDsAreIgnored() {
        let scene = makeScene(order: 0, title: "Uno", text: "uno")
        let clip = ClipFactory.make(
            title: "Clip",
            sceneIDs: [scene.id, UUID()],
            scenes: [scene]
        )

        #expect(clip.sourceSceneIDs == [scene.id])
        #expect(clip.adaptedText == "uno")
    }

    @Test("An anchor whose scene is missing is dropped")
    func missingAnchorSceneIsDropped() {
        let scene = makeScene(order: 0, title: "Uno", text: "alfa beta")
        let anchor = FrameScriptDocument.TextAnchor(
            startUTF16: 5,
            lengthUTF16: 4,
            selectedText: "beta"
        )

        let clip = ClipFactory.make(
            title: "Clip",
            sceneIDs: [scene.id],
            anchorSceneID: UUID(),
            anchor: anchor,
            scenes: [scene]
        )

        #expect(clip.anchor == nil)
        #expect(clip.anchorSceneID == nil)
        #expect(clip.adaptedText == "alfa beta")
    }

    @Test("The combined source hash matches the extracted source text")
    func sourceHashMatchesExtractedText() {
        let first = makeScene(order: 0, title: "Uno", text: "uno dos")
        let second = makeScene(order: 1, title: "Dos", text: "tres cuatro")
        let clip = ClipFactory.make(title: "Clip", sceneIDs: [first.id, second.id], scenes: [first, second])
        let source = ClipSourceExtractor.sourceText(clip: clip, scenes: [first, second])

        #expect(!clip.isStale(comparedToSourceText: source))
        #expect(clip.isStale(comparedToSourceText: source + " cambiado"))
    }

    // MARK: - Staleness

    @Test("A fresh clip is not stale")
    func freshClipIsNotStale() {
        let scene = makeScene(order: 0, title: "Uno", text: "uno dos")
        let clip = ClipFactory.make(title: "Clip", sceneIDs: [scene.id], scenes: [scene])

        #expect(!ClipStaleness.isStale(clip: clip, scenes: [scene]))
        #expect(ClipStaleness.report(clip: clip, scenes: [scene]).changes.isEmpty)
    }

    @Test("A rewritten scene is stale and carries a word diff")
    func rewrittenSceneIsStale() {
        var scene = makeScene(order: 0, title: "Uno", text: "uno dos")
        let clip = ClipFactory.make(title: "Clip", sceneIDs: [scene.id], scenes: [scene])
        scene.scriptText = "uno tres"

        let report = ClipStaleness.report(clip: clip, scenes: [scene])

        #expect(report.isStale)
        #expect(report.changes.count == 1)
        #expect(report.changes.first?.kind == .changed)
        #expect(report.changes.first?.previousText == "uno dos")
        #expect(report.changes.first?.currentText == "uno tres")
        let summary = report.changes.first?.changeSummary() ?? []
        #expect(summary.contains { $0.kind == .removed && $0.text.contains("dos") })
        #expect(summary.contains { $0.kind == .inserted && $0.text.contains("tres") })
    }

    @Test("A deleted scene is reported as missing")
    func deletedSceneIsMissing() {
        let scene = makeScene(order: 0, title: "Uno", text: "uno dos")
        let clip = ClipFactory.make(title: "Clip", sceneIDs: [scene.id], scenes: [scene])

        let report = ClipStaleness.report(clip: clip, scenes: [])

        #expect(report.isStale)
        #expect(report.changes.first?.kind == .missingScene)
        #expect(report.changes.first?.currentText == "")
    }

    @Test("A removed anchored passage is unresolved")
    func removedAnchorIsUnresolved() throws {
        var scene = makeScene(order: 0, title: "Uno", text: "alfa beta gamma")
        let anchor = try #require(
            FrameScriptDocument.TextAnchorRepair.anchor(
                in: scene.scriptText,
                range: NSRange(location: 5, length: 4)
            )
        )
        let clip = ClipFactory.make(
            title: "Clip",
            sceneIDs: [scene.id],
            anchorSceneID: scene.id,
            anchor: anchor,
            scenes: [scene]
        )
        scene.scriptText = "texto completamente distinto"

        let report = ClipStaleness.report(clip: clip, scenes: [scene])

        #expect(report.isStale)
        #expect(report.hasUnresolvedAnchor)
        #expect(report.changes.first?.kind == .unresolvedAnchor)
        #expect(report.changes.first?.currentText == "")
    }

    @Test("Mark as reviewed accepts the new text and refreshes the anchor")
    func markReviewedClearsStaleness() throws {
        var scene = makeScene(order: 0, title: "Uno", text: "alfa beta gamma delta")
        let anchor = try #require(
            FrameScriptDocument.TextAnchorRepair.anchor(
                in: scene.scriptText,
                range: NSRange(location: 5, length: 10)
            )
        )
        var clip = ClipFactory.make(
            title: "Clip",
            sceneIDs: [scene.id],
            anchorSceneID: scene.id,
            anchor: anchor,
            scenes: [scene]
        )
        scene.scriptText = "alfa beta nuevo gamma delta"

        #expect(ClipStaleness.isStale(clip: clip, scenes: [scene]))
        ClipStaleness.markReviewed(&clip, scenes: [scene])

        #expect(!ClipStaleness.isStale(clip: clip, scenes: [scene]))
        #expect(clip.anchor?.selectedText == "beta nuevo gamma")
        #expect(clip.sceneSourceHashes.first?.sourceText == "beta nuevo gamma")
    }

    @Test("A new source scene is reported as a change")
    func newSourceSceneIsReported() {
        let first = makeScene(order: 0, title: "Uno", text: "uno")
        let second = makeScene(order: 1, title: "Dos", text: "dos")
        var clip = ClipFactory.make(title: "Clip", sceneIDs: [first.id], scenes: [first, second])
        clip.sourceSceneIDs.append(second.id)

        let report = ClipStaleness.report(clip: clip, scenes: [first, second])

        #expect(report.isStale)
        #expect(report.changes.first?.kind == .changed)
        #expect(report.changes.first?.previousText == "")
        #expect(report.changes.first?.currentText == "dos")
    }

    // MARK: - Estimates

    @Test("The estimate is markup-aware and adds the hook")
    func estimateAddsHookAndPauses() {
        let estimate = ClipEstimator.estimate(
            hook: "gancho",
            adaptedText: "uno dos / tres",
            targetSeconds: 15,
            wordsPerMinute: 60
        )

        #expect(abs(estimate.hookSeconds - 1) < 0.001)
        #expect(abs(estimate.adaptedSeconds - 3.5) < 0.001)
        #expect(abs(estimate.seconds - 4.5) < 0.001)
        #expect(estimate.wordCount == 4)
        #expect(estimate.fit == .under)
        #expect(estimate.hookFit == .ok)
    }

    @Test("Estimates compare with the target inside a tolerance")
    func estimateFitBoundaries() {
        #expect(ClipEstimator.fit(seconds: 15, targetSeconds: 30) == .under)
        #expect(ClipEstimator.fit(seconds: 27, targetSeconds: 30) == .onTarget)
        #expect(ClipEstimator.fit(seconds: 33, targetSeconds: 30) == .onTarget)
        #expect(ClipEstimator.fit(seconds: 34, targetSeconds: 30) == .over)
        #expect(ClipEstimator.fit(seconds: 15, targetSeconds: 15) == .onTarget)
        #expect(ClipEstimator.fit(seconds: 14, targetSeconds: 15) == .onTarget)
        #expect(ClipEstimator.fit(seconds: 13, targetSeconds: 15) == .under)
    }

    @Test("Hook fit flags empty, short and long hooks")
    func hookFit() {
        #expect(ClipEstimator.hookFit(seconds: 0, hasHook: false) == .empty)
        #expect(ClipEstimator.hookFit(seconds: 0.4, hasHook: true) == .tooShort)
        #expect(ClipEstimator.hookFit(seconds: 1, hasHook: true) == .ok)
        #expect(ClipEstimator.hookFit(seconds: 3, hasHook: true) == .ok)
        #expect(ClipEstimator.hookFit(seconds: 3.2, hasHook: true) == .tooLong)
    }

    @Test("Targets are clamped to the supported range")
    func targetSanitization() {
        #expect(ClipLimits.sanitizedTarget(nil) == nil)
        #expect(ClipLimits.sanitizedTarget(0) == nil)
        #expect(ClipLimits.sanitizedTarget(.nan) == nil)
        #expect(ClipLimits.sanitizedTarget(1) == ClipLimits.minimumTarget)
        #expect(ClipLimits.sanitizedTarget(10_000) == ClipLimits.maximumTarget)
        #expect(ClipLimits.targetOptions == [15, 30, 60, 90])
    }

    // MARK: - Coverage

    @Test("Coverage includes scene and variant takes")
    func coverageIncludesSceneAndVariantTakes() {
        let scene = makeScene(
            order: 0,
            title: "Uno",
            text: "alfa beta gamma",
            takes: [makeTake(number: 1, readText: "alfa beta gamma", languageCode: "")],
            variants: [
                FrameScriptDocument.SceneLanguageVariant(
                    languageCode: "en",
                    text: "alpha beta gamma",
                    takes: [makeTake(number: 2, readText: "alpha beta gamma", languageCode: "en")]
                )
            ]
        )
        let anchor = FrameScriptDocument.TextAnchorRepair.anchor(
            in: scene.scriptText,
            range: NSRange(location: 5, length: 4)
        )
        let clip = ClipFactory.make(
            title: "Clip",
            sceneIDs: [scene.id],
            anchorSceneID: scene.id,
            anchor: anchor,
            scenes: [scene]
        )

        let coverage = ClipCoverage.takes(for: clip, scenes: [scene], primaryLanguage: "es")

        #expect(coverage.count == 2)
        #expect(coverage.map(\.languageCode) == ["es", "en"])
        #expect(coverage.allSatisfy { $0.coversAnchor == true })
    }

    @Test("Coverage is unknown when a take has no read text")
    func coverageWithoutReadText() {
        let scene = makeScene(
            order: 0,
            title: "Uno",
            text: "alfa beta",
            takes: [makeTake(number: 1, readText: "", languageCode: "es")]
        )
        let anchor = FrameScriptDocument.TextAnchorRepair.anchor(
            in: scene.scriptText,
            range: NSRange(location: 5, length: 4)
        )
        let clip = ClipFactory.make(
            title: "Clip",
            sceneIDs: [scene.id],
            anchorSceneID: scene.id,
            anchor: anchor,
            scenes: [scene]
        )

        let coverage = ClipCoverage.takes(for: clip, scenes: [scene], primaryLanguage: "es")

        #expect(coverage.first?.coversAnchor == nil)
    }

    @Test("Assets linked to a clip scene or take are reused")
    func coverageIncludesAssets() {
        let take = makeTake(number: 1, readText: "uno", languageCode: "es")
        let scene = makeScene(order: 0, title: "Uno", text: "uno", takes: [take])
        let clip = ClipFactory.make(title: "Clip", sceneIDs: [scene.id], scenes: [scene])
        let byScene = FrameScriptDocument.ProjectAsset(path: "/a.mp4", linkedSceneIDs: [scene.id])
        let byTake = FrameScriptDocument.ProjectAsset(path: "/b.mp4", linkedTakeIDs: [take.id])
        let unrelated = FrameScriptDocument.ProjectAsset(path: "/c.mp4")

        let assets = ClipCoverage.assets(for: clip, scenes: [scene], assets: [unrelated, byScene, byTake])

        #expect(assets.map(\.path) == ["/a.mp4", "/b.mp4"])
    }

    // MARK: - Summary

    @Test("The summary counts statuses, formats and stale clips")
    func summaryCounts() {
        var scene = makeScene(order: 0, title: "Uno", text: "uno dos")
        var idea = ClipFactory.make(title: "Idea", sceneIDs: [scene.id], scenes: [scene])
        idea.status = .idea
        var ready = ClipFactory.make(title: "Ready", sceneIDs: [scene.id], scenes: [scene])
        ready.status = .ready
        ready.format = .story
        scene.scriptText = "uno tres"

        let summary = ClipSummaryBuilder.summary(
            clips: [idea, ready],
            scenes: [scene],
            wordsPerMinute: 150
        )

        #expect(summary.total == 2)
        #expect(summary.count(for: .idea) == 1)
        #expect(summary.count(for: .ready) == 1)
        #expect(summary.count(for: .reel) == 1)
        #expect(summary.count(for: .story) == 1)
        #expect(summary.stale == 2)
        #expect(summary.nextStatus == .idea)
        #expect(!summary.isEmpty)
    }

    @Test("Production items expose the checklist state")
    func productionItems() {
        let scene = makeScene(order: 0, title: "Uno", text: "uno dos")
        var clip = ClipFactory.make(title: "Clip", sceneIDs: [scene.id], scenes: [scene])
        clip.status = .ready

        let items = ClipSummaryBuilder.productionItems(
            clips: [clip],
            scenes: [scene],
            wordsPerMinute: 150
        )

        #expect(items.count == 1)
        #expect(items.first?.isReadyToPublish == true)
        #expect(items.first?.targetSeconds == 30)
        #expect((items.first?.estimatedSeconds ?? 0) > 0)
    }

    @Test("An empty project has an empty summary")
    func emptySummary() {
        let summary = ClipSummaryBuilder.summary(clips: [], scenes: [], wordsPerMinute: 150)

        #expect(summary.isEmpty)
        #expect(summary.total == 0)
        #expect(summary.nextStatus == nil)
    }

    // MARK: - Export

    @Test("The text export includes every publishing field")
    func textExportIncludesFields() {
        let scene = makeScene(order: 0, title: "Escena uno", text: "uno dos")
        var clip = ClipFactory.make(title: "Mi clip", sceneIDs: [scene.id], scenes: [scene])
        clip.hook = "Gancho corto"
        clip.adaptedText = "Texto adaptado"
        clip.onScreenText = "Dato clave"
        clip.description = "Descripción del clip"
        clip.hashtags = ["#uno", "#dos"]

        let document = ClipExport.document(
            for: clip,
            scenes: [scene],
            wordsPerMinute: 150
        )

        #expect(document.plainText.contains("Mi clip"))
        #expect(document.plainText.contains("Gancho corto"))
        #expect(document.plainText.contains("Texto adaptado"))
        #expect(document.plainText.contains("Dato clave"))
        #expect(document.plainText.contains("Descripción del clip"))
        #expect(document.plainText.contains("#uno #dos"))
        #expect(document.plainText.contains("Escena uno"))
        #expect(document.markdown.contains("**Gancho**"))
    }

    @Test("Resolve markers use the clip's own zero time base")
    func resolveMarkersUseZeroTimeBase() {
        let scene = makeScene(order: 0, title: "Escena", text: "uno dos")
        var clip = ClipFactory.make(title: "Clip", sceneIDs: [scene.id], scenes: [scene])
        clip.hook = "Gancho de prueba"
        clip.onScreenText = "Texto en pantalla"
        let settings = ExportSettings(projectName: "Long video", fps: .fps25)

        let markers = ClipExport.markers(for: clip, wordsPerMinute: 150)
        let edl = ClipExport.edl(for: clip, wordsPerMinute: 150, settings: settings)
        let fcpxml = ClipExport.fcpxml(for: clip, wordsPerMinute: 150, settings: settings)

        #expect(markers.count == 2)
        #expect(markers.first?.frame == 0)
        #expect(edl.contains("TITLE: Clip"))
        #expect(edl.contains("00:00:00:00"))
        #expect(edl.contains("|M:Gancho"))
        #expect(edl.contains("|M:Texto en pantalla"))
        #expect(fcpxml.contains("tcStart=\"0s\""))
        #expect(fcpxml.contains("<marker start=\"0s\""))
    }

    // MARK: - Fact guard

    @Test("Numbers absent from the source are flagged")
    func factGuardFlagsUnsupportedNumbers() {
        let source = "El coche hace 150 km/h y cuesta 30.000 euros."
        let generated = "El coche hace 150 km/h, cuesta 30.000 euros y pesa 1.250 kg."

        let unsupported = ClipFactGuard.unsupportedNumbers(in: generated, source: source)

        #expect(unsupported == ["1.250"])
    }

    @Test("Comma and dot decimals compare equally")
    func factGuardNormalizesDecimals() {
        let unsupported = ClipFactGuard.unsupportedNumbers(
            in: "Consume 4,5 litros.",
            source: "Consume 4.5 litros."
        )

        #expect(unsupported.isEmpty)
    }

    // MARK: - Document

    @Test("The new source text survives a document round trip")
    func sourceTextRoundTrip() throws {
        let scene = makeScene(order: 0, title: "Escena", text: "uno dos")
        let clip = ClipFactory.make(title: "Clip", sceneIDs: [scene.id], scenes: [scene])
        let document = FrameScriptDocument(
            project: FrameScriptDocument.Project(
                title: "Proyecto",
                scenes: [
                    FrameScriptDocument.Scene(
                        id: scene.id,
                        order: scene.order,
                        sectionType: scene.sectionType,
                        title: scene.title,
                        scriptText: scene.scriptText
                    )
                ],
                clips: [clip]
            )
        )
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(FrameScriptDocument.self, from: data)

        #expect(decoded.project.clips.first?.sceneSourceHashes.first?.sourceText == "uno dos")
        #expect(decoded.project.clips.first?.sceneSourceHashes.first?.hash == FrameScriptDocument.TextHash.hash("uno dos"))
    }

    // MARK: - Helpers

    private func makeScene(
        order: Int,
        title: String,
        text: String,
        takes: [FrameScriptDocument.Take] = [],
        variants: [FrameScriptDocument.SceneLanguageVariant] = []
    ) -> FrameScriptDocument.Scene {
        FrameScriptDocument.Scene(
            order: order,
            sectionType: .custom,
            title: title,
            scriptText: text,
            takes: takes,
            languageVariants: variants
        )
    }

    private func makeTake(
        number: Int,
        readText: String,
        languageCode: String
    ) -> FrameScriptDocument.Take {
        FrameScriptDocument.Take(
            number: number,
            startedAt: Date(timeIntervalSince1970: Double(number) * 60),
            duration: 30,
            rating: .good,
            languageCode: languageCode,
            readText: readText
        )
    }
}
