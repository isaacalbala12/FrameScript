import Foundation
@testable import FrameScriptCore
import Testing

@Suite("Board classification")
struct BoardClassificationTests {
    @Test func editOnlyTouchesClassificationFieldsAndUpdatedAt() throws {
        let scene = boardScene(order: 0, title: "Intro", text: "Texto que no debe cambiar.")
        let original = boardDocument(
            title: "Original",
            topic: "Assetto Corsa",
            videoType: "análisis",
            status: .idea,
            scenes: [scene]
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var edited = original

        BoardDocumentEditor.apply(
            BoardProjectEdit(
                topic: "  Vantare  ",
                videoType: "comparativa",
                productionStatus: .script,
                targetDate: now,
                publishDate: now.addingTimeInterval(86_400)
            ),
            to: &edited,
            now: now
        )

        #expect(edited.project.topic == "Vantare")
        #expect(edited.project.videoType == "comparativa")
        #expect(edited.project.productionStatus == .script)
        #expect(edited.project.targetDate == now)
        #expect(edited.project.publishDate == now.addingTimeInterval(86_400))
        #expect(edited.project.updatedAt == now)
        #expect(edited.project.scenes == original.project.scenes)
        #expect(edited.project.title == original.project.title)
    }

    @Test func editCanClearDatesAndLeavesUntouchedFieldsAlone() {
        let target = Date(timeIntervalSince1970: 100)
        let publish = Date(timeIntervalSince1970: 200)
        var document = boardDocument(
            title: "Dates",
            topic: "Keep",
            targetDate: target,
            publishDate: publish
        )

        BoardDocumentEditor.apply(
            BoardProjectEdit(clearsPublishDate: true),
            to: &document
        )

        #expect(document.project.topic == "Keep")
        #expect(document.project.targetDate == target)
        #expect(document.project.publishDate == nil)
    }

    @Test func emptyEditIsANoOpAndDoesNotChangeUpdatedAt() {
        let original = boardDocument(title: "No-op")
        var edited = original
        BoardDocumentEditor.apply(BoardProjectEdit(), to: &edited)
        #expect(edited.project.updatedAt == original.project.updatedAt)
    }

    @Test func editReportsWhetherAReloadedSummarySatisfiesIt() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let summary = boardSummary(
            path: "/tmp/check.fscr",
            title: "Check",
            topic: "Vantare",
            videoType: "análisis",
            status: .script,
            targetDate: date
        )
        let edit = BoardProjectEdit(
            topic: "Vantare",
            videoType: "crónica",
            productionStatus: .script,
            targetDate: date
        )

        #expect(!edit.isSatisfied(by: summary))
        let refreshed = summary.applying(
            BoardProjectEdit(topic: "Vantare", videoType: "crónica"),
            fingerprint: summary.fingerprint
        )
        #expect(edit.isSatisfied(by: refreshed))
        #expect(!BoardProjectEdit(clearsTargetDate: true).isSatisfied(by: refreshed))
        #expect(BoardProjectEdit(clearsTargetDate: true).isSatisfied(by: summary.applying(
            BoardProjectEdit(clearsTargetDate: true),
            fingerprint: summary.fingerprint
        )))
    }

    @Test func statusTransitionUsesTheBoardColumnOrder() {
        #expect(BoardProductionStatus.order == [.idea, .outline, .script, .recorded, .edited, .published])
        #expect(BoardProductionStatus.transition(from: .idea, to: .idea) == .unchanged)
        #expect(BoardProductionStatus.transition(from: .idea, to: .published) == .forward)
        #expect(BoardProductionStatus.transition(from: .edited, to: .script) == .backward)
        #expect(BoardProductionStatus.next(after: .idea) == .outline)
        #expect(BoardProductionStatus.next(after: .published) == nil)
        #expect(BoardProductionStatus.previous(before: .idea) == nil)
        #expect(BoardProductionStatus.previous(before: .script) == .outline)
    }

    @Test func templateNamesMapToTheBriefVideoTypes() {
        #expect(BoardTemplateDefaults.videoType(forTemplateNamed: "Simracing Update Analysis") == "análisis")
        #expect(BoardTemplateDefaults.videoType(forTemplateNamed: "Simracing Mod or Car Review") == "review de mod/coche")
        #expect(BoardTemplateDefaults.videoType(forTemplateNamed: "Product Review") == "review de mod/coche")
        #expect(BoardTemplateDefaults.videoType(forTemplateNamed: "Simracing Comparison") == "comparativa")
        #expect(BoardTemplateDefaults.videoType(forTemplateNamed: "Simracing News and Reaction") == "noticia")
        #expect(BoardTemplateDefaults.videoType(forTemplateNamed: "Simracing Race Chronicle") == "crónica")
        #expect(BoardTemplateDefaults.videoType(forTemplateNamed: "Tutorial") == "tutorial")
        #expect(BoardTemplateDefaults.videoType(forTemplateNamed: "Blank") == nil)
        #expect(BoardTemplateDefaults.videoType(forTemplateNamed: "Custom") == nil)
    }

    @Test func seededCatalogContainsEveryBriefValueAndVantare() {
        #expect(Set(BoardTemplateDefaults.videoTypes) == [
            "análisis", "gameplay", "review de mod/coche", "comparativa",
            "noticia", "crónica", "tutorial", "Vantare"
        ])
        #expect(BoardTemplateDefaults.topics.contains("Vantare"))
        #expect(BoardTemplateDefaults.topics.count >= 5)
    }

    @Test func catalogAddsNormalizesDeduplicatesAndRemovesValues() {
        var catalog = BoardCatalog(topics: [" iRacing ", "IRACING", "", "Vantare"], videoTypes: ["análisis"])

        #expect(catalog.topics == ["iRacing", "Vantare"])
        let duplicateAdded = catalog.addTopic("vantare")
        #expect(!duplicateAdded)
        let newTopicAdded = catalog.addTopic("  Le Mans Ultimate  ")
        #expect(newTopicAdded)
        #expect(catalog.topics.last == "Le Mans Ultimate")
        catalog.removeTopic("iracing")
        #expect(!catalog.topics.contains { BoardCatalog.matches($0, "iRacing") })
    }

    @Test func catalogSuggestionsPreferPrefixMatchesAndIgnoreCaseAndAccents() {
        let catalog = BoardCatalog(
            topics: ["Assetto Corsa", "Assetto Corsa Competizione", "iRacing", "Vantare"],
            videoTypes: []
        )

        #expect(catalog.topicSuggestions(for: "asset", limit: 2) == [
            "Assetto Corsa",
            "Assetto Corsa Competizione"
        ])
        #expect(catalog.topicSuggestions(for: "rac", limit: 3) == ["iRacing"])
        #expect(catalog.topicSuggestions(for: "ANALIS", limit: 3).isEmpty)
        #expect(catalog.topicSuggestions(for: "", limit: 2) == ["Assetto Corsa", "Assetto Corsa Competizione"])
    }

    @Test func restoringSeedsKeepsUserValuesAndAddsMissingDefaults() {
        var catalog = BoardCatalog(topics: ["My game"], videoTypes: ["mi tipo"])
        catalog.restoreSeeds()

        #expect(catalog.topics.first == "My game")
        #expect(catalog.topics.contains("Vantare"))
        #expect(catalog.videoTypes.contains("mi tipo"))
        #expect(catalog.videoTypes.contains("análisis"))
    }

    @Test func catalogCodableRoundTrips() throws {
        let catalog = BoardCatalog(topics: ["iRacing", "Vantare"], videoTypes: ["análisis", "crónica"])
        let data = try JSONEncoder().encode(catalog)
        let decoded = try JSONDecoder().decode(BoardCatalog.self, from: data)
        #expect(decoded == catalog)
    }

    @Test func planeDateUsesUTCGregorianComponentsAndRejectsNothing() {
        let date = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z
        let utc = TimeZone(secondsFromGMT: 0) ?? .current
        let planeDate = BoardPlaneDate.make(from: date, timeZone: utc)
        #expect(planeDate?.iso8601 == "2027-01-15")
        #expect(BoardPlaneDate.make(from: nil) == nil)
    }
}
