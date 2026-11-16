import Foundation
@testable import FrameScriptCore
import Testing

@Suite("Board filters, grouping and sorting")
struct BoardFiltersTests {
    private func summary(
        _ title: String,
        topic: String = "",
        type: String = "",
        status: FrameScriptDocument.ProductionStatus = .idea,
        targetDate: Date? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        duration: TimeInterval = 300,
        pendingTasks: [BoardPendingTask] = []
    ) -> BoardProjectSummary {
        boardSummary(
            path: "/tmp/\(title).fscr",
            title: title,
            topic: topic,
            videoType: type,
            status: status,
            targetDate: targetDate,
            updatedAt: updatedAt,
            duration: duration,
            pendingTasks: pendingTasks
        )
    }

    @Test func filtersByStatusTopicTypeAndSearch() {
        let summaries = [
            summary("Monza analysis", topic: "iRacing", type: "análisis", status: .script),
            summary("Spa recap", topic: "Vantare", type: "crónica", status: .published),
            summary("Watkins Glen", topic: "iRacing", type: "gameplay", status: .edited)
        ]

        #expect(BoardFilter().matches(summaries[0]))
        #expect(!BoardFilter(statuses: [.published]).matches(summaries[0]))
        #expect(BoardFilter(statuses: [.published]).matches(summaries[1]))
        #expect(BoardFilter(topics: ["iracing"]).matches(summaries[0]))
        #expect(!BoardFilter(topics: ["Vantare"]).matches(summaries[0]))
        #expect(BoardFilter(videoTypes: ["GAMEPLAY"]).matches(summaries[2]))
        #expect(BoardFilter(searchText: "monza").matches(summaries[0]))
        #expect(BoardFilter(searchText: "iracing").matches(summaries[2]))
        #expect(!BoardFilter(searchText: "nothing here").matches(summaries[0]))
    }

    @Test func filterSearchIgnoresDiacriticsAndMatchesFolderName() {
        let summary = summary("Analisis", topic: "Automovilismo", type: "crónica")
        #expect(BoardFilter(searchText: "análisis").matches(summary))
        #expect(BoardFilter(searchText: "cronica").matches(summary))

        let nested = boardSummary(path: "/tmp/Library/Session 3/file.fscr", title: "Unrelated")
        #expect(BoardFilter(searchText: "session 3").matches(nested))
    }

    @Test func unfinishedFilterKeepsOnlyProjectsWithPendingTasks() {
        let pending = summary("Pending", pendingTasks: [boardPendingTask(kind: .editar)])
        let done = summary("Done", pendingTasks: [])
        let filter = BoardFilter(unfinishedOnly: true)

        #expect(filter.matches(pending))
        #expect(!filter.matches(done))
    }

    @Test func statusGroupingUsesTheCanonicalColumnOrderAndDropsEmptyColumns() {
        let summaries = [
            summary("Published", status: .published),
            summary("Idea", status: .idea),
            summary("Script", status: .script)
        ]
        let groups = BoardQuery.groups(
            summaries: summaries,
            filter: BoardFilter(),
            grouping: .status,
            sort: BoardSort(key: .title, ascending: true)
        )

        #expect(groups.map(\.kind) == [
            .status(.idea),
            .status(.script),
            .status(.published)
        ])
        #expect(groups.map { $0.summaries.map(\.title) } == [["Idea"], ["Script"], ["Published"]])
    }

    @Test func topicGroupingIsAlphabeticalWithUnclassifiedLast() {
        let summaries = [
            summary("B", topic: "iRacing"),
            summary("A", topic: ""),
            summary("C", topic: "Assetto Corsa")
        ]
        let groups = BoardQuery.groups(
            summaries: summaries,
            filter: BoardFilter(),
            grouping: .topic,
            sort: BoardSort(key: .title, ascending: true)
        )

        #expect(groups.map(\.kind) == [
            .topic("Assetto Corsa"),
            .topic("iRacing"),
            .topic("")
        ])
        #expect(groups.last?.summaries.map(\.title) == ["A"])
    }

    @Test func typeGroupingAndNoneGroupingReturnEveryFilteredProject() {
        let summaries = [
            summary("A", topic: "iRacing", type: "análisis"),
            summary("B", topic: "iRacing", type: "gameplay"),
            summary("C", topic: "Vantare", type: "análisis")
        ]

        let byType = BoardQuery.groups(
            summaries: summaries,
            filter: BoardFilter(topics: ["iRacing"]),
            grouping: .videoType,
            sort: BoardSort(key: .title, ascending: true)
        )
        #expect(byType.count == 2)
        #expect(byType.flatMap(\.summaries).map(\.title) == ["A", "B"])

        let flat = BoardQuery.groups(
            summaries: summaries,
            filter: BoardFilter(),
            grouping: .none,
            sort: BoardSort(key: .title, ascending: true)
        )
        #expect(flat.count == 1)
        #expect(flat[0].kind == .all)
        #expect(flat[0].summaries.map(\.title) == ["A", "B", "C"])
    }

    @Test func sortingByTargetDateKeepsUnscheduledProjectsLastInBothDirections() {
        let early = summary("Early", targetDate: Date(timeIntervalSince1970: 100))
        let late = summary("Late", targetDate: Date(timeIntervalSince1970: 200))
        let none = summary("None", targetDate: nil)

        let ascending = BoardSort(key: .targetDate, ascending: true).sorted([late, none, early])
        let descending = BoardSort(key: .targetDate, ascending: false).sorted([early, none, late])

        #expect(ascending.map(\.title) == ["Early", "Late", "None"])
        #expect(descending.map(\.title) == ["Late", "Early", "None"])
    }

    @Test func sortingByDurationPendingAndStatusWorks() {
        let a = summary(
            "A",
            status: .script,
            duration: 100,
            pendingTasks: [boardPendingTask(), boardPendingTask()]
        )
        let b = summary(
            "B",
            status: .recorded,
            duration: 300,
            pendingTasks: [boardPendingTask()]
        )

        #expect(BoardSort(key: .duration, ascending: true).sorted([b, a]).map(\.title) == ["A", "B"])
        #expect(BoardSort(key: .title, ascending: false).sorted([a, b]).map(\.title) == ["B", "A"])
        #expect(BoardSort(key: .pending, ascending: false).sorted([a, b]).map(\.title) == ["A", "B"])
        #expect(BoardSort(key: .status, ascending: true).sorted([b, a]).map(\.title) == ["A", "B"])
    }

    @Test func availableTopicsMergeCatalogAndProjectsWithoutDuplicates() {
        let catalog = BoardCatalog(topics: ["iRacing", "Vantare"], videoTypes: ["análisis"])
        let summaries = [
            summary("A", topic: "vantare"),
            summary("B", topic: "Assetto Corsa"),
            summary("C", topic: "")
        ]

        #expect(BoardQuery.availableTopics(catalog: catalog, summaries: summaries) == [
            "Assetto Corsa",
            "iRacing",
            "Vantare"
        ])
    }
}
