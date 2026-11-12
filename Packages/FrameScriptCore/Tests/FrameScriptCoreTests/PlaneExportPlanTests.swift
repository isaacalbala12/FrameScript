import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Plane export plan")
struct PlaneExportPlanTests {
    private func date(_ value: String) throws -> PlaneDate {
        try #require(PlaneDate(iso8601: value))
    }

    @Test func buildsDraftWithContextAndStableExternalID() throws {
        let task = PlanePendingTask(
            id: "task-1",
            projectID: "project-1",
            title: "  Grabar la intro  ",
            kind: .grabar,
            sceneTitle: "Intro",
            projectTitle: "Mi vídeo",
            dueDate: try date("2026-11-20")
        )

        let plan = PlaneExportPlan(tasks: [task])

        #expect(plan.entries.count == 1)
        let entry = try #require(plan.entries.first)
        let draft = entry.draft
        let expectedDueDate = try date("2026-11-20")
        #expect(draft.name == "Grabar la intro")
        #expect(draft.externalID == "framescript:project-1:task-1")
        #expect(draft.externalSource == "framescript")
        #expect(draft.priority == .none)
        #expect(draft.targetDate == expectedDueDate)
        #expect(draft.stateID == nil)
        #expect(draft.labelIDs == nil)
        #expect(
            draft.descriptionHTML
                == "<p><strong>Record</strong></p><p>Scene: Intro<br>Project: Mi vídeo</p>"
        )
        #expect(!entry.wasNameTruncated)
        #expect(!draft.descriptionHTML.contains("Escena"))
    }

    @Test func usesInjectedLabelsForDescription() throws {
        let labels = PlaneExportLabels(
            scene: "Escena",
            project: "Proyecto",
            kindNames: [
                .grabar: "Grabar",
                .conseguirBroll: "Conseguir B-roll",
                .editar: "Editar",
                .investigar: "Investigar",
                .manual: "Manual"
            ]
        )
        let task = PlanePendingTask(
            id: "task-1",
            projectID: "project-1",
            title: "Grabar la intro",
            kind: .grabar,
            sceneTitle: "Intro",
            projectTitle: "Mi vídeo"
        )

        let draft = try #require(PlaneExportPlan(tasks: [task], labels: labels).drafts.first)

        #expect(
            draft.descriptionHTML
                == "<p><strong>Grabar</strong></p><p>Escena: Intro<br>Proyecto: Mi vídeo</p>"
        )
    }

    @Test func escapesHTMLInDescription() throws {
        let task = PlanePendingTask(
            id: "task-1",
            projectID: "project-1",
            title: "Grabar",
            kind: .grabar,
            sceneTitle: "Intro <script>alert(\"x\") & 'y'</script>",
            projectTitle: "A & B"
        )

        let draft = try #require(PlaneExportPlan(tasks: [task]).drafts.first)

        #expect(!draft.descriptionHTML.contains("<script>"))
        #expect(draft.descriptionHTML.contains("&lt;script&gt;"))
        #expect(draft.descriptionHTML.contains("&quot;x&quot;"))
        #expect(draft.descriptionHTML.contains("&#39;y&#39;"))
        #expect(draft.descriptionHTML.contains("A &amp; B"))
    }

    @Test func omitsEmptySceneAndProject() throws {
        let task = PlanePendingTask(
            id: "task-1",
            projectID: "project-1",
            title: "Anotar idea",
            kind: .manual,
            sceneTitle: "   ",
            projectTitle: ""
        )

        let draft = try #require(PlaneExportPlan(tasks: [task]).drafts.first)
        #expect(draft.descriptionHTML == "<p><strong>Manual</strong></p>")
    }

    @Test func externalIDDoesNotDependOnEditableFields() throws {
        let original = PlanePendingTask(
            id: "task-1",
            projectID: "project-1",
            title: "Primer título",
            kind: .grabar,
            sceneTitle: "Escena 1",
            projectTitle: "Proyecto 1"
        )
        let edited = PlanePendingTask(
            id: "task-1",
            projectID: "project-1",
            title: "Otro título",
            kind: .editar,
            sceneTitle: "Escena 2",
            projectTitle: "Proyecto 2",
            dueDate: try date("2026-12-01")
        )

        let first = try #require(PlaneExportPlan(tasks: [original]).drafts.first)
        let second = try #require(PlaneExportPlan(tasks: [edited]).drafts.first)

        #expect(first.externalID == second.externalID)
        #expect(first.descriptionHTML != second.descriptionHTML)
    }

    @Test func externalIDEscapesSeparatorsToAvoidAmbiguity() {
        let taskColon = PlaneExternalID.make(projectID: "a", taskID: "b:c")
        let projectColon = PlaneExternalID.make(projectID: "a:b", taskID: "c")

        #expect(taskColon == "framescript:a:b%3Ac")
        #expect(projectColon == "framescript:a%3Ab:c")
        #expect(taskColon != projectColon)
        #expect(
            PlaneExternalID.make(projectID: "a%3Ab", taskID: "c")
                == "framescript:a%253Ab:c"
        )

        let tasks = [
            PlanePendingTask(
                id: "b:c",
                projectID: "a",
                title: "First",
                kind: .grabar,
                sceneTitle: "",
                projectTitle: ""
            ),
            PlanePendingTask(
                id: "c",
                projectID: "a:b",
                title: "Second",
                kind: .editar,
                sceneTitle: "",
                projectTitle: ""
            )
        ]
        let plan = PlaneExportPlan(tasks: tasks)
        #expect(plan.entries.count == 2)
        #expect(plan.drafts.map(\.externalID) == ["framescript:a:b%3Ac", "framescript:a%3Ab:c"])
    }

    @Test func truncatesLongNamesGraphemeSafely() throws {
        let longTitle = String(repeating: "e\u{301}", count: 300)
        let task = PlanePendingTask(
            id: "task-1",
            projectID: "project-1",
            title: longTitle,
            kind: .grabar,
            sceneTitle: "Intro",
            projectTitle: "Proyecto"
        )

        let plan = PlaneExportPlan(tasks: [task])
        let entry = try #require(plan.entries.first)

        #expect(entry.draft.name.count == 255)
        #expect(entry.draft.name.unicodeScalars.count == 510)
        #expect(entry.draft.name == String(longTitle.prefix(255)))
        #expect(entry.wasNameTruncated)
        #expect(plan.summary.truncatedNameCount == 1)
    }

    @Test func doesNotFlagNamesAtTheLimit() throws {
        let task = PlanePendingTask(
            id: "task-1",
            projectID: "project-1",
            title: String(repeating: "a", count: 255),
            kind: .grabar,
            sceneTitle: "Intro",
            projectTitle: "Proyecto"
        )

        let plan = PlaneExportPlan(tasks: [task])
        let entry = try #require(plan.entries.first)

        #expect(!entry.wasNameTruncated)
        #expect(plan.summary.truncatedNameCount == 0)
    }

    @Test func skipsTasksWithoutATitle() throws {
        let task = PlanePendingTask(
            id: "task-1",
            projectID: "project-1",
            title: "   ",
            kind: .grabar,
            sceneTitle: "Intro",
            projectTitle: "Proyecto"
        )

        let plan = PlaneExportPlan(tasks: [task])

        #expect(plan.isEmpty)
        #expect(plan.skipped.count == 1)
        #expect(plan.skipped.first?.reason == .emptyTitle)
        #expect(plan.summary.taskCount == 1)
        #expect(plan.summary.workItemCount == 0)
        #expect(plan.summary.skippedCount == 1)
        #expect(plan.summary.skippedByReason == [.emptyTitle: 1])
        #expect(plan.summary.truncatedNameCount == 0)
    }

    @Test func skipsTasksWithoutStableIdentifiers() throws {
        let task = PlanePendingTask(
            id: "  ",
            projectID: "project-1",
            title: "Grabar",
            kind: .grabar,
            sceneTitle: "Intro",
            projectTitle: "Proyecto"
        )

        let plan = PlaneExportPlan(tasks: [task])

        #expect(plan.isEmpty)
        #expect(plan.skipped.first?.reason == .missingIdentifier)
    }

    @Test func skipsDuplicateExternalIDs() throws {
        let first = PlanePendingTask(
            id: "task-1",
            projectID: "project-1",
            title: "Primera versión",
            kind: .grabar,
            sceneTitle: "Intro",
            projectTitle: "Proyecto"
        )
        let duplicate = PlanePendingTask(
            id: "task-1",
            projectID: "project-1",
            title: "Segunda versión",
            kind: .editar,
            sceneTitle: "Intro",
            projectTitle: "Proyecto"
        )

        let plan = PlaneExportPlan(tasks: [first, duplicate])

        #expect(plan.entries.count == 1)
        #expect(plan.drafts.first?.name == "Primera versión")
        #expect(plan.skipped.count == 1)
        #expect(plan.skipped.first?.reason == .duplicateTask)
    }

    @Test func skipsExternalIDsLongerThanPlaneLimit() throws {
        let task = PlanePendingTask(
            id: String(repeating: "t", count: 200),
            projectID: String(repeating: "p", count: 100),
            title: "Grabar",
            kind: .grabar,
            sceneTitle: "Intro",
            projectTitle: "Proyecto"
        )

        let plan = PlaneExportPlan(tasks: [task])

        #expect(plan.isEmpty)
        #expect(plan.skipped.first?.reason == .externalIdentifierTooLong)
    }

    @Test func summaryCountsKindsAndDueDates() throws {
        let tasks = [
            PlanePendingTask(
                id: "task-1",
                projectID: "project-1",
                title: "Grabar",
                kind: .grabar,
                sceneTitle: "Intro",
                projectTitle: "Proyecto",
                dueDate: try date("2026-11-20")
            ),
            PlanePendingTask(
                id: "task-2",
                projectID: "project-1",
                title: "Editar",
                kind: .editar,
                sceneTitle: "Nudo",
                projectTitle: "Proyecto",
                dueDate: try date("2026-11-18")
            ),
            PlanePendingTask(
                id: "task-3",
                projectID: "project-2",
                title: "Investigar",
                kind: .investigar,
                sceneTitle: "Cierre",
                projectTitle: "Otro proyecto"
            )
        ]

        let summary = PlaneExportPlan(tasks: tasks).summary

        #expect(summary.taskCount == 3)
        #expect(summary.workItemCount == 3)
        #expect(summary.skippedCount == 0)
        #expect(summary.hasWorkItems)
        #expect(summary.workItemsByKind == [.grabar: 1, .editar: 1, .investigar: 1])
        #expect(summary.truncatedNameCount == 0)
        #expect(summary.dueDateCount == 2)
        let earliest = try date("2026-11-18")
        let latest = try date("2026-11-20")
        #expect(summary.earliestTargetDate == earliest)
        #expect(summary.latestTargetDate == latest)
    }

    @Test func emptyPlanHasZeroedSummary() {
        let summary = PlaneExportPlan(tasks: []).summary

        #expect(!summary.hasWorkItems)
        #expect(summary.taskCount == 0)
        #expect(summary.workItemCount == 0)
        #expect(summary.skippedCount == 0)
        #expect(summary.skippedByReason.isEmpty)
        #expect(summary.workItemsByKind.isEmpty)
        #expect(summary.truncatedNameCount == 0)
        #expect(summary.dueDateCount == 0)
        #expect(summary.earliestTargetDate == nil)
        #expect(summary.latestTargetDate == nil)
    }

    @Test func externalIDFormatIsDocumentedShape() {
        #expect(PlaneExternalID.make(projectID: "p1", taskID: "t1") == "framescript:p1:t1")
        #expect(PlaneExternalID.source == "framescript")
    }
}

@Suite("Plane dates, labels and ledger")
struct PlaneSupportTests {
    @Test func parsesAndFormatsDates() throws {
        let date = try #require(PlaneDate(iso8601: "2026-11-20"))
        #expect(date.year == 2026)
        #expect(date.month == 11)
        #expect(date.day == 20)
        #expect(date.iso8601 == "2026-11-20")
        #expect(date.description == "2026-11-20")

        #expect(PlaneDate(iso8601: "2024-02-29") != nil)
        #expect(PlaneDate(iso8601: "2026-02-29") == nil)
        #expect(PlaneDate(iso8601: "2026-04-31") == nil)
        #expect(PlaneDate(iso8601: "2026-13-01") == nil)
        #expect(PlaneDate(iso8601: "2026-1-01") == nil)
        #expect(PlaneDate(iso8601: "not-a-date") == nil)
    }

    @Test func comparesDatesChronologically() throws {
        let earlier = try #require(PlaneDate(iso8601: "2026-11-18"))
        let later = try #require(PlaneDate(iso8601: "2026-11-20"))

        #expect(earlier < later)
        #expect(!(later < earlier))
    }

    @Test func dateRoundTripsAsAJSONString() throws {
        let date = try #require(PlaneDate(iso8601: "2026-11-20"))
        let data = try JSONEncoder().encode(date)

        #expect(try JSONDecoder().decode(String.self, from: data) == "2026-11-20")
        #expect(try JSONDecoder().decode(PlaneDate.self, from: data) == date)
    }

    @Test func parsesRetryAfterSecondsAndHTTPDate() {
        #expect(PlaneRetryAfter.parse("17") == 17)
        #expect(PlaneRetryAfter.parse(" 0 ") == 0)
        #expect(PlaneRetryAfter.parse("-5") == 0)
        #expect(PlaneRetryAfter.parse("") == nil)
        #expect(PlaneRetryAfter.parse(nil) == nil)
        #expect(PlaneRetryAfter.parse("soon") == nil)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(PlaneRetryAfter.parse("Tue, 14 Nov 2023 22:13:40 GMT", now: now) == 20)
    }

    @Test func derivesRetryAfterFromResetHeader() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(PlaneRetryAfter.fromResetHeader("1700000030", now: now) == 30)
        #expect(PlaneRetryAfter.fromResetHeader("1700000000", now: now) == 0)
        #expect(PlaneRetryAfter.fromResetHeader("", now: now) == nil)
        #expect(PlaneRetryAfter.fromResetHeader(nil, now: now) == nil)
        #expect(PlaneRetryAfter.fromResetHeader("soon", now: now) == nil)
    }

    @Test func responseHeadersAreCaseInsensitive() {
        let response = PlaneHTTPResponse(
            statusCode: 200,
            headers: ["X-RateLimit-Remaining": "45"],
            data: Data()
        )

        #expect(response.header("x-ratelimit-remaining") == "45")
        #expect(response.header("X-RATELIMIT-REMAINING") == "45")
    }

    @Test func defaultLabelsAreEnglishAndComplete() {
        let labels = PlaneExportLabels()

        #expect(labels.scene == "Scene")
        #expect(labels.project == "Project")
        #expect(Set(labels.kindNames.keys) == Set(PlaneTaskKind.allCases))
        #expect(labels.name(for: .grabar) == "Record")
        #expect(labels.name(for: .conseguirBroll) == "Get B-roll")

        let partial = PlaneExportLabels(scene: "Scene", project: "Project", kindNames: [:])
        #expect(partial.name(for: .grabar) == "Record")
        #expect(partial.name(for: .investigar) == "Research")
    }

    @Test func truncatesNamesGraphemeSafely() throws {
        #expect(PlaneWorkItemName.truncated(String(repeating: "a", count: 300)).count == 255)
        #expect(!PlaneWorkItemName.isTruncated(String(repeating: "a", count: 255)))
        #expect(PlaneWorkItemName.isTruncated(String(repeating: "a", count: 256)))

        let composed = String(repeating: "e\u{301}", count: 300)
        let truncated = PlaneWorkItemName.truncated(composed)
        #expect(truncated.count == 255)
        #expect(truncated.unicodeScalars.count == 510)
        let lastCharacter = try #require(truncated.last)
        #expect(String(lastCharacter) == "e\u{301}")
    }

    @Test func ledgerRoundTripsAndMutates() throws {
        var ledger = PlaneExportLedger()
        #expect(ledger.isEmpty)

        ledger["framescript:a:b"] = "wi-1"
        #expect(ledger["framescript:a:b"] == "wi-1")

        ledger.record(workItemID: "wi-2", forTaskExternalID: "framescript:c:d")
        ledger.remove(taskExternalID: "framescript:a:b")
        #expect(ledger.workItemIDsByTaskExternalID == ["framescript:c:d": "wi-2"])

        let data = try JSONEncoder().encode(ledger)
        #expect(
            try JSONDecoder().decode([String: String].self, from: data)
                == ["framescript:c:d": "wi-2"]
        )
        #expect(try JSONDecoder().decode(PlaneExportLedger.self, from: data) == ledger)
    }
}
