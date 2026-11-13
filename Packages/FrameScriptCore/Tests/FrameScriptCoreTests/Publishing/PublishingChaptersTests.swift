import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Publishing chapters")
struct PublishingChaptersTests {
    private func scene(
        _ title: String,
        _ duration: TimeInterval,
        id: UUID = UUID(),
        override: String? = nil,
        excluded: Bool = false
    ) -> ChapterSceneInput {
        ChapterSceneInput(
            sceneID: id,
            title: title,
            duration: duration,
            overrideTitle: override,
            isExcluded: excluded
        )
    }

    @Test("Three scenes produce a valid chapter block starting at 0:00")
    func basicPlan() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let plan = PublishingChapters.plan(scenes: [
            scene("Gancho", 40, id: first),
            scene("Qué cambia", 60, id: second),
            scene("Veredicto", 50, id: third),
        ])

        #expect(plan.text == """
        0:00 Gancho
        0:40 Qué cambia
        1:40 Veredicto
        """)
        #expect(plan.chapters.map(\.sceneID) == [first, second, third])
        #expect(plan.isValidForYouTube)
        #expect(plan.videoEndSeconds == 150)
        #expect(plan.warnings.isEmpty)
    }

    @Test("A short middle scene merges into the previous chapter")
    func shortMiddleMerges() {
        let plan = PublishingChapters.plan(scenes: [
            scene("A", 20),
            scene("B corta", 5),
            scene("C", 20),
            scene("D", 20),
        ])

        #expect(plan.chapters.map(\.title) == ["A", "C", "D"])
        #expect(plan.text.hasPrefix("0:00 A"))
        #expect(plan.warnings.contains { $0.kind == .shortSceneMerged })
        #expect(plan.isValidForYouTube)
    }

    @Test("A short last scene merges into the previous chapter")
    func shortLastMerges() {
        let plan = PublishingChapters.plan(scenes: [
            scene("A", 20),
            scene("B", 20),
            scene("C corta", 4),
        ])

        #expect(plan.chapters.map(\.title) == ["A", "B"])
        #expect(plan.videoEndSeconds == 44)
        #expect(plan.warnings.contains { $0.kind == .shortSceneMerged })
        #expect(!plan.isValidForYouTube)
        #expect(plan.warnings.contains { $0.kind == .tooFewChapters })
    }

    @Test("An excluded scene is absorbed by the previous chapter")
    func excludedScene() {
        let plan = PublishingChapters.plan(scenes: [
            scene("A", 20),
            scene("B", 30, excluded: true),
            scene("C", 20),
            scene("D", 20),
        ])

        #expect(plan.chapters.map(\.title) == ["A", "C", "D"])
        #expect(plan.chapters.map(\.startSeconds) == [0, 50, 70])
        #expect(plan.isValidForYouTube)
    }

    @Test("Chapter titles lose Markdown and emoji and stop at 60 characters")
    func titleSanitizing() {
        let long = String(repeating: "palabra ", count: 12)
        let plan = PublishingChapters.plan(scenes: [
            scene("Escena uno", 20, override: "**Gancho** 🚀"),
            scene("Escena dos", 20, override: long),
            scene("Escena tres", 20),
            scene("Escena cuatro", 20),
        ])

        #expect(plan.chapters.first?.title == "Gancho")
        #expect(plan.chapters[1].title.count == PublishingLimits.chapterTitleMaximum)
        #expect(plan.warnings.contains { $0.kind == .titleTruncated })
    }

    @Test("Two chapters are not valid for YouTube")
    func tooFewChapters() {
        let plan = PublishingChapters.plan(scenes: [
            scene("A", 40),
            scene("B", 60),
        ])
        #expect(plan.chapters.count == 2)
        #expect(!plan.isValidForYouTube)
    }

    @Test("Zero-duration scenes do not produce duplicate timestamps")
    func zeroDurationScene() {
        let plan = PublishingChapters.plan(scenes: [
            scene("A", 20),
            scene("Vacía", 0),
            scene("C", 20),
            scene("D", 20),
        ])
        #expect(plan.chapters.map(\.title) == ["A", "C", "D"])
        #expect(Set(plan.chapters.map(\.startSeconds)).count == plan.chapters.count)
    }

    @Test("Diff only reports titles the user actually changed")
    func diffReportsEdits() {
        let first = UUID()
        let second = UUID()
        let plan = PublishingChapters.plan(scenes: [
            scene("Gancho", 40, id: first),
            scene("Qué cambia", 60, id: second),
            scene("Veredicto", 50),
        ])

        let unchanged = PublishingChapters.diff(
            existing: [FrameScriptDocument.ChapterOverride(sceneID: first, title: "Gancho")],
            plan: plan
        )
        #expect(!unchanged.hasChanges)

        let edited = PublishingChapters.diff(
            existing: [
                FrameScriptDocument.ChapterOverride(sceneID: first, title: "Mi gancho"),
                FrameScriptDocument.ChapterOverride(sceneID: second, title: "Qué cambia"),
            ],
            plan: plan
        )
        #expect(edited.titleChanges.count == 1)
        #expect(edited.titleChanges.first?.sceneID == first)
        #expect(edited.titleChanges.first?.oldTitle == "Mi gancho")
        #expect(edited.titleChanges.first?.newTitle == "Gancho")
        #expect(edited.hasChanges)
    }

    @Test("Imported chapters without a scene are reported as removed")
    func importedChaptersRemoved() {
        let plan = PublishingChapters.plan(scenes: [
            scene("A", 40),
            scene("B", 60),
            scene("C", 50),
        ])
        let diff = PublishingChapters.diff(
            existing: [FrameScriptDocument.ChapterOverride(sceneID: nil, title: "Capítulo importado")],
            plan: plan
        )
        #expect(diff.removedImportedTitles == ["Capítulo importado"])
        #expect(diff.hasChanges)
    }

    @Test("Regeneration keeps edited titles only when asked")
    func regenerationPolicy() {
        let first = UUID()
        let excluded = UUID()
        let plan = PublishingChapters.plan(scenes: [
            scene("Gancho", 40, id: first),
            scene("Qué cambia", 60),
            scene("Fuera", 50, id: excluded, excluded: true),
            scene("Veredicto", 50),
        ])

        let existing = [
            FrameScriptDocument.ChapterOverride(sceneID: first, title: "Mi gancho", startSeconds: 2),
            FrameScriptDocument.ChapterOverride(sceneID: excluded, title: "Fuera", isExcluded: true),
            FrameScriptDocument.ChapterOverride(sceneID: nil, title: "Importado"),
        ]

        let keep = PublishingChapters.overrides(
            from: plan,
            existing: existing,
            keepingEditedTitles: true
        )
        #expect(keep.first { $0.sceneID == first }?.title == "Mi gancho")
        #expect(keep.first { $0.sceneID == excluded }?.isExcluded == true)
        #expect(!keep.contains { $0.sceneID == nil })
        #expect(keep.first { $0.sceneID == first }?.startSeconds == 0)

        let replace = PublishingChapters.overrides(
            from: plan,
            existing: existing,
            keepingEditedTitles: false
        )
        #expect(replace.first { $0.sceneID == first }?.title == "Gancho")
        #expect(replace.first { $0.sceneID == excluded }?.isExcluded == true)
    }

    @Test("Plan keeps the scene order even when durations repeat")
    func keepsOrder() {
        let ids = (0..<4).map { _ in UUID() }
        let plan = PublishingChapters.plan(scenes: ids.map { scene("Escena", 20, id: $0) })
        #expect(plan.chapters.map(\.sceneID) == ids)
    }
}
