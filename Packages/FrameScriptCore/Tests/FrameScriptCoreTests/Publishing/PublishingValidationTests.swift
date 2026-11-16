import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Publishing validation")
struct PublishingValidationTests {
    /// The validator now also reports empty required fields. Focused tests fill
    /// them unless the test is explicitly about a missing title/description.
    private func input(
        title: String = "Título",
        description: String = "Descripción",
        studioDescription: String = "",
        tags: [String] = [],
        hashtags: [String] = [],
        pinnedComment: String = "",
        thumbnailTexts: [String] = []
    ) -> PublishingValidationInput {
        PublishingValidationInput(
            title: title,
            description: description,
            studioDescription: studioDescription,
            tags: tags,
            hashtags: hashtags,
            pinnedComment: pinnedComment,
            thumbnailTexts: thumbnailTexts
        )
    }
    @Test("Title hard and soft limits")
    func titleLimits() {
        let atSoft = PublishingValidator.issues(
            for: input(title: String(repeating: "a", count: 70))
        )
        #expect(atSoft.isEmpty)

        let overSoft = PublishingValidator.issues(
            for: input(title: String(repeating: "a", count: 71))
        )
        #expect(overSoft.map(\.rule) == [.titleNearLimit])
        #expect(overSoft.first?.severity == .warning)
        #expect(overSoft.first?.field == .title)

        let atHard = PublishingValidator.issues(
            for: input(title: String(repeating: "a", count: 100))
        )
        #expect(atHard.map(\.rule) == [.titleNearLimit])

        let overHard = PublishingValidator.issues(
            for: input(title: String(repeating: "a", count: 101))
        )
        #expect(overHard.map(\.rule) == [.titleTooLong])
        #expect(overHard.first?.severity == .error)
    }

    @Test("Description hard and soft limits")
    func descriptionLimits() {
        #expect(PublishingValidator.issues(
            for: input(description: String(repeating: "a", count: 4_500))
        ).isEmpty)
        #expect(PublishingValidator.issues(
            for: input(description: String(repeating: "a", count: 4_501))
        ).map(\.rule) == [.descriptionNearLimit])
        #expect(PublishingValidator.issues(
            for: input(description: String(repeating: "a", count: 5_001))
        ).map(\.rule) == [.descriptionTooLong])
    }

    @Test("Tags count the separators and warn above twenty tags")
    func tagLimits() {
        let nineteen = (1...19).map { "etiqueta\($0)" }
        #expect(PublishingValidator.issues(for: input(tags: nineteen)).isEmpty)

        let twentyOne = (1...21).map { "etiqueta\($0)" }
        let issues = PublishingValidator.issues(for: input(tags: twentyOne))
        #expect(issues.map(\.rule) == [.tooManyTags])
        #expect(issues.first?.count == 21)

        let longTags = ["a", String(repeating: "b", count: 500)]
        let long = PublishingValidator.issues(for: input(tags: longTags))
        #expect(long.map(\.rule) == [.tagsTooLong])
        #expect(long.first?.count == 502)
    }

    @Test("Hashtags warn above three")
    func hashtagLimit() {
        #expect(PublishingValidator.issues(
            for: input(hashtags: ["#a", "#b", "#c"])
        ).isEmpty)
        let issues = PublishingValidator.issues(
            for: input(hashtags: ["#a", "#b", "#c", "#d"])
        )
        #expect(issues.map(\.rule) == [.tooManyHashtags])
        #expect(issues.first?.field == .hashtags)
    }

    @Test("Thumbnail text warns above three words")
    func thumbnailWords() {
        #expect(PublishingValidator.issues(
            for: input(thumbnailTexts: ["Tres palabras más"])
        ).isEmpty)
        let issues = PublishingValidator.issues(
            for: input(thumbnailTexts: ["Tres palabras más", "Una dos tres cuatro"])
        )
        #expect(issues.map(\.rule) == [.thumbnailTextTooLong])
        #expect(issues.first?.count == 4)
    }

    @Test("Pinned comment hard and soft limits")
    func pinnedLimits() {
        #expect(PublishingValidator.issues(
            for: input(pinnedComment: String(repeating: "a", count: 500))
        ).isEmpty)
        #expect(PublishingValidator.issues(
            for: input(pinnedComment: String(repeating: "a", count: 501))
        ).map(\.rule) == [.pinnedCommentNearLimit])
        #expect(PublishingValidator.issues(
            for: input(pinnedComment: String(repeating: "a", count: 10_001))
        ).map(\.rule) == [.pinnedCommentTooLong])
    }

    @Test("Errors are distinguishable from warnings")
    func errorDetection() {
        let errors = PublishingValidator.issues(for: input(title: String(repeating: "a", count: 101)))
        let warnings = PublishingValidator.issues(for: input(title: String(repeating: "a", count: 90)))
        #expect(PublishingValidator.hasErrors(errors))
        #expect(!PublishingValidator.hasErrors(warnings))
    }

    @Test("Tag and hashtag parsing normalizes and deduplicates")
    func parsing() {
        #expect(PublishingText.tags(from: "uno, Dos\ndos, , tres") == ["uno", "Dos", "tres"])
        #expect(PublishingText.hashtags(from: "simracing #motor, Simracing\n#F1") == ["#simracing", "#motor", "#F1"])
        #expect(PublishingText.tagCharacterCount(["uno", "dos"]) == 7)
    }
}
