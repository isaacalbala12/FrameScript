import Foundation
import Testing
@testable import FrameScriptCore

/// Regression tests for the wave-3 E/G/I review fixes. Synthetic data only.
@Suite("W3FixEGI research repair")
struct W3FixEGIResearchRepairTests {
    @Test func w3FixEGIDuplicateSourceIDsDoNotTrapResearchSummary() {
        let sourceID = UUID()
        let project = FrameScriptDocument.Project(
            title: "Duplicate sources",
            primaryLanguage: "es",
            sources: [
                FrameScriptDocument.Source(id: sourceID, title: "Primera"),
                FrameScriptDocument.Source(id: sourceID, title: "Segunda")
            ],
            claims: [
                FrameScriptDocument.Claim(
                    text: "Dato",
                    status: .probable,
                    sourceIDs: [sourceID],
                    needsVerification: true
                )
            ]
        )

        let items = ResearchSummary.pendingItems(project: project)
        #expect(items.count == 1)
        #expect(items[0].sourceTitles == ["Primera"])

        let appendix = ResearchExport.markdownAppendix(project: project)
        #expect(appendix.contains("Primera"))
        #expect(appendix.contains("Segunda"))
    }

    @Test func w3FixEGIDecodeRepairsDuplicateSourceIdentifiers() throws {
        let sourceID = UUID()
        let project = FrameScriptDocument.Project(
            title: "Duplicate sources",
            primaryLanguage: "es",
            sources: [
                FrameScriptDocument.Source(id: sourceID, title: "Primera"),
                FrameScriptDocument.Source(id: sourceID, title: "Segunda")
            ],
            claims: [
                FrameScriptDocument.Claim(
                    text: "Dato",
                    status: .probable,
                    sourceIDs: [sourceID],
                    needsVerification: true
                )
            ]
        )
        let document = FrameScriptDocument(project: project)
        let data = try FrameScriptDocumentCodec.encode(document)
        let decoded = try FrameScriptDocumentCodec.decode(data)

        #expect(decoded.project.sources.count == 2)
        #expect(Set(decoded.project.sources.map(\.id)).count == 2)
        #expect(decoded.project.sources[0].id == sourceID)
        #expect(decoded.project.claims[0].sourceIDs == [sourceID])
    }

    @Test func w3FixEGIv4DecodeCleansDanglingClaimTableAndClipLinks() throws {
        let keptScene = FrameScriptDocument.Scene(
            order: 0,
            sectionType: .custom,
            title: "Escena",
            scriptText: "Texto."
        )
        let missingSceneID = UUID()
        let project = FrameScriptDocument.Project(
            title: "Dangling",
            scenes: [keptScene],
            primaryLanguage: "es",
            claims: [
                FrameScriptDocument.Claim(
                    text: "Dato",
                    status: .probable,
                    sceneIDs: [missingSceneID],
                    anchorSceneID: missingSceneID,
                    anchor: FrameScriptDocument.TextAnchor(
                        startUTF16: 0,
                        lengthUTF16: 1,
                        selectedText: "T"
                    )
                )
            ],
            comparisonTables: [
                FrameScriptDocument.ComparisonTable(
                    title: "Tabla",
                    header: ["A"],
                    rows: [["1"]],
                    sceneID: missingSceneID
                )
            ],
            clips: [
                FrameScriptDocument.ShortClip(
                    title: "Clip",
                    sourceSceneIDs: [missingSceneID],
                    anchorSceneID: missingSceneID
                )
            ]
        )
        var document = FrameScriptDocument(project: project)
        document.fileVersion = 4
        let data = try FrameScriptDocumentCodec.encode(document)
        let decoded = try FrameScriptDocumentCodec.decode(data)

        #expect(decoded.project.claims[0].sceneIDs.isEmpty)
        #expect(decoded.project.claims[0].anchorSceneID == nil)
        #expect(decoded.project.claims[0].anchor == nil)
        #expect(decoded.project.comparisonTables[0].sceneID == nil)
        #expect(decoded.project.clips[0].sourceSceneIDs.isEmpty)
        #expect(decoded.project.clips[0].anchorSceneID == nil)
    }

    @Test func w3FixEGIRemovingAClaimLeavesDoneAndUnrelatedTasks() {
        let tasks = [
            FrameScriptDocument.ChecklistTask(text: "Dato  ", kind: .research, isDone: false),
            FrameScriptDocument.ChecklistTask(text: "DATO", kind: .research, isDone: true),
            FrameScriptDocument.ChecklistTask(text: "Otra cosa", kind: .research, isDone: false),
            FrameScriptDocument.ChecklistTask(text: "Dato", kind: .other, isDone: false)
        ]

        let result = ResearchChecklist.removing(claimText: "dato", in: tasks)
        #expect(result.count == 3)
        #expect(result.map(\.text) == ["DATO", "Otra cosa", "Dato"])
    }

    @Test func w3FixEGIStaleAnchorIsReportedAndCanBeRepaired() throws {
        let fragment = "récord del circuito"
        let scene = FrameScriptDocument.Scene(
            order: 0,
            sectionType: .custom,
            title: "Escena",
            scriptText: "Antes. \(fragment) es 1:42.3."
        )
        let anchor = try #require(
            ResearchAnchoring.anchor(for: fragment, in: scene.scriptText)
        )
        let claim = FrameScriptDocument.Claim(
            text: "El récord",
            status: .probable,
            sceneIDs: [scene.id],
            anchorSceneID: scene.id,
            anchor: anchor,
            needsVerification: true
        )
        var project = FrameScriptDocument.Project(
            title: "Anclas",
            scenes: [scene],
            primaryLanguage: "es",
            claims: [claim]
        )

        #expect(ResearchAnchoring.state(for: claim, in: project) == .current(text: fragment))

        // Insert text before the range: the stored range now points at other
        // words, so the claim must be reported stale (I-4).
        project.scenes[0].scriptText = "Mucho antes de todo. Antes. \(fragment) es 1:42.3."
        let stale = ResearchAnchoring.state(for: claim, in: project)
        #expect(stale.isStale)
        #expect(stale.displayText == fragment)

        // The context still identifies the fragment, so the shared repair can
        // find it even while the card asks the user to re-link.
        let repaired = FrameScriptDocument.TextAnchorRepair.repair(
            anchor,
            in: project.scenes[0].scriptText
        )
        #expect(repaired?.selectedText == fragment)
    }

    @Test func w3FixEGIResearchCountsMatchProductionForTheSameFixture() {
        let claims = [
            FrameScriptDocument.Claim(text: "Probable", status: .probable, needsVerification: true),
            FrameScriptDocument.Claim(text: "Confirmada", status: .confirmed),
            FrameScriptDocument.Claim(text: "Confirmada con recheck", status: .confirmed, needsVerification: true),
            FrameScriptDocument.Claim(text: "Rumor", status: .rumor),
            FrameScriptDocument.Claim(text: "Experiencia", status: .probable, personalExperience: true)
        ]
        let project = FrameScriptDocument.Project(
            title: "Fixture",
            primaryLanguage: "es",
            claims: claims
        )

        #expect(
            ResearchSummary.counts(claims: claims).pending
                == ProductionChecklist.summary(for: project).pendingCount(for: .research)
        )
        #expect(ResearchSummary.unconfirmedCountsByScene(claims: claims).isEmpty)
    }
}
