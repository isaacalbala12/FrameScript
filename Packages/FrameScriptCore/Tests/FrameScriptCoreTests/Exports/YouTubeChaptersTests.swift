import Foundation
import Testing
@testable import FrameScriptCore

@Suite("YouTube chapters")
struct YouTubeChaptersTests {
    private func scene(
        _ title: String,
        start: TimeInterval,
        duration: TimeInterval,
        rehook: Bool = false
    ) -> ExportScene {
        ExportScene(title: title, start: start, duration: duration, isRehook: rehook)
    }

    @Test("Golden three-chapter block")
    func goldenBasic() {
        let scenes = [
            scene("Gancho", start: 0, duration: 45),
            scene("Qué cambia", start: 45, duration: 60),
            scene("Veredicto", start: 105, duration: 45),
        ]

        let result = YouTubeChapters.make(scenes: scenes)

        #expect(result.text == """
        0:00 Gancho
        0:45 Qué cambia
        1:45 Veredicto
        """)
        #expect(result.chapters.count == 3)
        #expect(result.chapters.map(\.startFrame) == [0, 1_125, 2_625])
        #expect(result.warnings.isEmpty)
        #expect(result.isValidForYouTube)
    }

    @Test("Uses h:mm:ss past the first hour")
    func hourFormat() {
        let scenes = [
            scene("A", start: 0, duration: 10),
            scene("B", start: 3_600, duration: 10),
            scene("C", start: 3_700, duration: 10),
            scene("D", start: 4_000, duration: 10),
        ]

        let result = YouTubeChapters.make(scenes: scenes)

        #expect(result.text == """
        0:00 A
        1:00:00 B
        1:01:40 C
        1:06:40 D
        """)
        #expect(result.warnings.isEmpty)
    }

    @Test("Clamps the first chapter to 0:00 and reports it")
    func firstChapterClamped() {
        let scenes = [
            scene("Intro", start: 2, duration: 20),
            scene("Uno", start: 20, duration: 20),
            scene("Dos", start: 40, duration: 20),
        ]

        let result = YouTubeChapters.make(scenes: scenes)

        #expect(result.chapters.first?.startFrame == 0)
        #expect(result.text.hasPrefix("0:00 Intro"))
        #expect(result.warnings.contains { $0.kind == .firstSceneNotAtZero })
    }

    @Test("Merges a short middle scene into the previous chapter")
    func mergesShortMiddleScene() {
        let scenes = [
            scene("A", start: 0, duration: 20),
            scene("B corta", start: 20, duration: 5),
            scene("C", start: 25, duration: 20),
        ]

        let result = YouTubeChapters.make(scenes: scenes)

        #expect(result.text == """
        0:00 A
        0:25 C
        """)
        #expect(result.chapters.count == 2)
        #expect(result.warnings.contains { $0.kind == .shortSceneMerged && $0.sceneIndex == 1 })
        #expect(result.warnings.contains { $0.kind == .tooFewChapters })
        #expect(!result.isValidForYouTube)
    }

    @Test("Merges a short first scene with the next")
    func mergesShortFirstScene() {
        let scenes = [
            scene("A corta", start: 0, duration: 5),
            scene("B", start: 5, duration: 30),
            scene("C", start: 35, duration: 30),
        ]

        let result = YouTubeChapters.make(scenes: scenes)

        #expect(result.text == """
        0:00 A corta
        0:35 C
        """)
        #expect(result.warnings.contains { $0.kind == .shortSceneMerged && $0.sceneIndex == 0 })
    }

    @Test("Merges a short last scene into the previous chapter")
    func mergesShortLastScene() {
        let scenes = [
            scene("A", start: 0, duration: 20),
            scene("B", start: 20, duration: 20),
            scene("C corta", start: 40, duration: 4),
        ]

        let result = YouTubeChapters.make(scenes: scenes)

        #expect(result.text == """
        0:00 A
        0:20 B
        """)
        #expect(result.warnings.contains { $0.kind == .shortSceneMerged && $0.sceneIndex == 2 })
        #expect(result.warnings.contains { $0.kind == .tooFewChapters })
    }

    @Test("Sorts unsorted scenes and warns")
    func sortsUnsortedScenes() {
        let scenes = [
            scene("Dos", start: 20, duration: 20),
            scene("Uno", start: 0, duration: 20),
            scene("Tres", start: 40, duration: 20),
        ]

        let result = YouTubeChapters.make(scenes: scenes)

        #expect(result.text == """
        0:00 Uno
        0:20 Dos
        0:40 Tres
        """)
        #expect(result.warnings.contains { $0.kind == .unsortedScenes })
    }

    @Test("Deduplicates scenes sharing a start frame")
    func deduplicatesStarts() {
        let scenes = [
            scene("A", start: 0, duration: 20),
            scene("B duplicada", start: 0, duration: 20),
            scene("C", start: 20, duration: 20),
            scene("D", start: 40, duration: 20),
        ]

        let result = YouTubeChapters.make(scenes: scenes)

        #expect(result.chapters.count == 3)
        #expect(!result.text.contains("B duplicada"))
        #expect(result.warnings.contains { $0.kind == .duplicateStart })
    }

    @Test("Cleans titles, trims whitespace and strips Markdown and emoji")
    func cleansTitles() {
        let scenes = [
            scene("  **Gancho** 🎬  ", start: 0, duration: 20),
            scene("__Qué cambia__", start: 20, duration: 20),
            scene("Veredicto", start: 40, duration: 20),
        ]

        let result = YouTubeChapters.make(scenes: scenes)

        #expect(result.text == """
        0:00 Gancho
        0:20 Qué cambia
        0:40 Veredicto
        """)
    }

    @Test("Falls back for an empty title and warns")
    func emptyTitleFallback() {
        let scenes = [
            scene("   ", start: 0, duration: 20),
            scene("B", start: 20, duration: 20),
            scene("C", start: 40, duration: 20),
        ]

        let result = YouTubeChapters.make(scenes: scenes)

        #expect(result.text.hasPrefix("0:00 Capítulo 1"))
        #expect(result.warnings.contains { $0.kind == .emptyTitle })
    }

    @Test("Truncates overlong titles at 60 characters and warns")
    func truncatesLongTitles() {
        let long = String(repeating: "a", count: 70)
        let scenes = [
            scene(long, start: 0, duration: 20),
            scene("B", start: 20, duration: 20),
            scene("C", start: 40, duration: 20),
        ]

        let result = YouTubeChapters.make(scenes: scenes)

        #expect(result.chapters.first?.title.count == 60)
        #expect(result.warnings.contains { $0.kind == .titleTruncated })
    }

    @Test("Honours chapterTitle and includeInChapters")
    func overrides() {
        var excluded = scene("No va", start: 20, duration: 20)
        excluded.includesInChapters = false
        var renamed = scene("Interno", start: 40, duration: 20)
        renamed.chapterTitle = "Título público"

        let scenes = [
            scene("A", start: 0, duration: 20),
            excluded,
            renamed,
        ]

        let result = YouTubeChapters.make(scenes: scenes)

        #expect(result.text == """
        0:00 A
        0:40 Título público
        """)
    }

    @Test("Is frame-accurate at 29.97: 299 frames is shorter than 10 s")
    func frameAccurateMinimum() {
        // 9.98 s at 29.97 rounds to 299 frames, one frame short of 10 s.
        let scenes = [
            scene("A", start: 0, duration: 9.98),
            scene("B", start: 9.98, duration: 20),
            scene("C", start: 29.98, duration: 20),
        ]

        let result = YouTubeChapters.make(scenes: scenes, rate: .fps29_97)

        #expect(result.text == """
        0:00 A
        0:29 C
        """)
        #expect(result.warnings.contains { $0.kind == .shortSceneMerged && $0.sceneIndex == 0 })
    }

    @Test("Returns an empty list for no scenes")
    func noScenes() {
        let result = YouTubeChapters.make(scenes: [])
        #expect(result.text.isEmpty)
        #expect(result.chapters.isEmpty)
        #expect(result.warnings.map(\.kind) == [.noScenes])
        #expect(!result.isValidForYouTube)
    }

    @Test("A three-scene list that totals under 30 s cannot satisfy YouTube")
    func tooShortVideo() {
        let scenes = [
            scene("A", start: 0, duration: 8),
            scene("B", start: 8, duration: 8),
            scene("C", start: 16, duration: 8),
        ]

        let result = YouTubeChapters.make(scenes: scenes)

        #expect(result.chapters.count == 1)
        #expect(result.warnings.contains { $0.kind == .tooFewChapters })
        #expect(!result.isValidForYouTube)
    }
}
