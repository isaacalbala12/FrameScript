import AppKit
import Foundation
import SwiftUI
@testable import FrameScript
import XCTest

@MainActor
final class EditorPersistenceTests: XCTestCase {
    func testVisualsTerminologyUsesNaturalLocalizedValues() throws {
        let englishVisualsKeys = [
            "production.addBRollForSelection", "dialog.deleteScene.message", "settings.defaultSplit",
            "broll.linkedSubtitle", "broll.emptyTitle", "broll.addItem", "broll.addEmpty",
            "broll.segmentEmpty", "broll.writeScriptFirst", "settings.includeBRoll",
            "export.label.broll", "help.defaultSplit"
        ]
        for key in englishVisualsKeys {
            XCTAssertTrue(L10n.tr(key, language: .english).contains("Visual"), "Expected natural Visuals terminology for \(key)")
        }
        XCTAssertEqual(L10n.tr("broll.item", language: .english), "Visual")
        XCTAssertEqual(L10n.tr("broll.duplicateItem", language: .english), "Duplicate Visual")
        XCTAssertEqual(L10n.tr("broll.deleteItem", language: .english), "Delete Visual")

        let russianVisualsKeys = [
            "production.addBRollForSelection", "dialog.deleteScene.message", "settings.defaultSplit",
            "broll.linkedSubtitle", "broll.emptyTitle", "broll.emptyMessage", "broll.addItem",
            "broll.addEmpty", "broll.segmentEmpty", "broll.writeScriptFirst", "broll.item",
            "broll.duplicateItem", "broll.deleteItem", "settings.includeBRoll", "export.label.broll",
            "help.defaultSplit"
        ]
        for key in russianVisualsKeys {
            XCTAssertTrue(L10n.tr(key, language: .russian).localizedLowercase.contains("видеоряд"), "Expected natural видеоряд terminology for \(key)")
        }

        try assertNoVisibleBRoll(in: repositoryText("FrameScript/Core/Utilities/Localization.swift"), file: "Localization.swift")
    }

    func testAllExportFormatsUseVisualsHeadings() {
        let service = ExportService()
        let preferences = AppSettings.defaults.exportPreferences

        for (language, expectedHeading) in [(AppLanguage.english, "Visuals"), (.russian, "Видеоряд")] {
            let project = SampleData.demoProject(language: language)
            for format in ExportFormat.allCases {
                let output = service.render(project: project, format: format, preferences: preferences, language: language)
                XCTAssertTrue(output.contains(expectedHeading), "Expected \(expectedHeading) in \(format.rawValue) export")
                assertNoVisibleBRoll(in: output, file: "\(format.rawValue) export")
            }
        }
    }

    func testCurrentDocsAndDemoContainNoVisibleBRollAndUseWebPBanner() throws {
        for path in ["README.md", "RELEASE_NOTES.md", "FrameScript/Models/SampleData.swift"] {
            try assertNoVisibleBRoll(in: repositoryText(path), file: path)
        }

        let readme = try repositoryText("README.md")
        XCTAssertTrue(readme.contains("](docs/banner.webp)"))
        XCTAssertFalse(readme.contains("docs/banner.svg"))

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let banner = try Data(contentsOf: root.appendingPathComponent("docs/banner.webp"))
        XCTAssertEqual(Array(banner.prefix(4)), Array("RIFF".utf8))
        XCTAssertEqual(Array(banner.dropFirst(8).prefix(4)), Array("WEBP".utf8))

        let changelog = try repositoryText("CHANGELOG.md")
        let unreleased = try XCTUnwrap(changelog.components(separatedBy: "## [0.2.0]").first)
        assertNoVisibleBRoll(in: unreleased, file: "CHANGELOG.md [Unreleased]")
    }

    func testFSCRCompatibilityKeepsBRollCodableNames() throws {
        XCTAssertEqual(WorkspaceMode.bRoll.rawValue, "B-Roll")
        XCTAssertEqual(BRollSourceType.stockFootage.rawValue, "Stock footage")

        let project = SampleData.demoProject(language: .english)
        let data = try FrameScriptFileStore.encoder.encode(FrameScriptFile(project: project))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"bRollItems\""))
        XCTAssertTrue(json.contains("\"descriptionText\""))

        let roundTripped = try FrameScriptFileStore.decoder.decode(FrameScriptFile.self, from: data).makeProject()
        XCTAssertEqual(roundTripped.scenes.first?.bRollItems.count, project.scenes.first?.bRollItems.count)

        var legacyFile = FrameScriptFile(project: project)
        legacyFile.fileVersion = 1
        let legacyData = try FrameScriptFileStore.encoder.encode(legacyFile)
        let legacyProject = try FrameScriptFileStore.decoder.decode(FrameScriptFile.self, from: legacyData).makeProject()
        XCTAssertEqual(legacyProject.scenes.first?.bRollItems.first?.descriptionText, project.scenes.first?.bRollItems.first?.descriptionText)
    }

    func testSynchronizeShiftsAnchorForInsertionBeforeIt() throws {
        let (store, scene, item) = try makeAnchorStore()
        scene.scriptText = "alpha INSERT target omega"

        store.synchronizeTextSegments(splitMode: .scene, wordsPerMinute: 150)

        let anchor = try XCTUnwrap(item.textAnchor)
        XCTAssertEqual(anchor.startUTF16, 13)
        XCTAssertEqual(anchor.selectedText, "target")
        XCTAssertEqual(anchor.prefixContext, "alpha INSERT ")
    }

    func testSynchronizeExpandsAnchorForInsertionInsideIt() throws {
        let (store, scene, item) = try makeAnchorStore()
        scene.scriptText = "alpha tarXget omega"

        store.synchronizeTextSegments(splitMode: .scene, wordsPerMinute: 150)

        let anchor = try XCTUnwrap(item.textAnchor)
        XCTAssertEqual(anchor.startUTF16, 6)
        XCTAssertEqual(anchor.selectedText, "tarXget")
        XCTAssertEqual(anchor.lengthUTF16, 7)
    }

    func testSynchronizeShiftsAnchorForDeletionBeforeIt() throws {
        let (store, scene, item) = try makeAnchorStore()
        scene.scriptText = "target omega"

        store.synchronizeTextSegments(splitMode: .scene, wordsPerMinute: 150)

        let anchor = try XCTUnwrap(item.textAnchor)
        XCTAssertEqual(anchor.startUTF16, 0)
        XCTAssertEqual(anchor.selectedText, "target")
    }

    func testSynchronizeShrinksAnchorForDeletionInsideIt() throws {
        let (store, scene, item) = try makeAnchorStore()
        scene.scriptText = "alpha taget omega"

        store.synchronizeTextSegments(splitMode: .scene, wordsPerMinute: 150)

        let anchor = try XCTUnwrap(item.textAnchor)
        XCTAssertEqual(anchor.startUTF16, 6)
        XCTAssertEqual(anchor.selectedText, "taget")
        XCTAssertEqual(anchor.lengthUTF16, 5)
        XCTAssertEqual(anchor.suffixContext, " omega")
    }

    func testCurrentAnchorRepairPreservesStoredRangeWithDuplicateIdenticalContext() throws {
        let anchor = try XCTUnwrap(TextAnchorRepair.anchor(in: "left target right", range: NSRange(location: 5, length: 6)))
        let text = "left target right and left target right"
        let secondRange = (text as NSString).range(of: "target", options: [], range: NSRange(location: 18, length: (text as NSString).length - 18))
        let secondAnchor = try XCTUnwrap(TextAnchorRepair.anchor(in: text, range: secondRange))

        XCTAssertEqual(TextAnchorRepair.repair(anchor, in: "left other right and left target right and left target right"), nil)
        XCTAssertEqual(TextAnchorRepair.repair(secondAnchor, in: text)?.nsRange, secondRange)
    }

    func testDelayedSegmentSynchronizationPreservesCurrentAnchorWithDuplicateIdenticalContext() throws {
        let text = "left target right and left target right"
        let secondRange = (text as NSString).range(of: "target", options: [], range: NSRange(location: 18, length: (text as NSString).length - 18))
        let item = BRollItem(
            textAnchor: try XCTUnwrap(TextAnchorRepair.anchor(in: text, range: secondRange)),
            templateType: "",
            sourceType: .custom,
            descriptionText: ""
        )
        let scene = Scene(order: 0, sectionType: .custom, title: "Scene", scriptText: text, bRollItems: [item])
        let store = ProjectStore(project: FrameProject(title: "Project", scenes: [scene]))

        store.synchronizeTextSegments(splitMode: .scene, wordsPerMinute: 150)

        XCTAssertEqual(item.textAnchor?.nsRange, secondRange)
    }

    func testProjectFileLoadingPreservesCurrentAnchorWithDuplicateIdenticalContext() throws {
        let text = "left target right and left target right"
        let secondRange = (text as NSString).range(of: "target", options: [], range: NSRange(location: 18, length: (text as NSString).length - 18))
        let item = BRollItem(
            textAnchor: try XCTUnwrap(TextAnchorRepair.anchor(in: text, range: secondRange)),
            templateType: "",
            sourceType: .custom,
            descriptionText: ""
        )
        let project = FrameProject(title: "Project", scenes: [Scene(order: 0, sectionType: .custom, title: "Scene", scriptText: text, bRollItems: [item])])
        let data = try FrameScriptFileStore.encoder.encode(FrameScriptFile(project: project))
        let loaded = try FrameScriptFileStore.decoder.decode(FrameScriptFile.self, from: data).makeProject()
        let loadedItem = try XCTUnwrap(loaded.scenes.first?.bRollItems.first)

        XCTAssertEqual(loadedItem.textAnchor?.nsRange, secondRange)
    }

    func testAnchorRepairRejectsDistantContextForAnExactMatch() throws {
        let anchor = try XCTUnwrap(TextAnchorRepair.anchor(in: "before target after", range: NSRange(location: 7, length: 6)))

        XCTAssertNil(TextAnchorRepair.repair(anchor, in: "before unrelated target unrelated after"))
    }

    func testAnchorRepairRejectsRepeatedContextPairs() throws {
        let anchor = try XCTUnwrap(TextAnchorRepair.anchor(in: "left target right", range: NSRange(location: 5, length: 6)))

        XCTAssertNil(TextAnchorRepair.repair(anchor, in: "left changed right left changed right"))
    }

    func testCommittedTextImmediatelyRepairsInsertionsBeforeAndInsideAnchors() throws {
        let (beforeState, beforeScene, beforeItem) = try makeAnchoredAppState()
        beforeState.commitScriptTextChange(sceneID: beforeScene.id, text: "alpha INSERT target omega")
        XCTAssertEqual(beforeItem.textAnchor?.startUTF16, 13)
        XCTAssertEqual(beforeItem.textAnchor?.selectedText, "target")
        XCTAssertNil(beforeItem.linkedSegmentID)
        XCTAssertEqual(beforeScene.textSegments.first?.sourceText, "alpha target omega")

        let (insideState, insideScene, insideItem) = try makeAnchoredAppState()
        insideState.commitScriptTextChange(sceneID: insideScene.id, text: "alpha tarXget omega")
        XCTAssertEqual(insideItem.textAnchor?.startUTF16, 6)
        XCTAssertEqual(insideItem.textAnchor?.selectedText, "tarXget")
    }

    func testCommittedTextImmediatelyRepairsDeletionsBeforeAndInsideAnchors() throws {
        let (beforeState, beforeScene, beforeItem) = try makeAnchoredAppState()
        beforeState.commitScriptTextChange(sceneID: beforeScene.id, text: "target omega")
        XCTAssertEqual(beforeItem.textAnchor?.startUTF16, 0)
        XCTAssertEqual(beforeItem.textAnchor?.selectedText, "target")

        let (insideState, insideScene, insideItem) = try makeAnchoredAppState()
        insideState.commitScriptTextChange(sceneID: insideScene.id, text: "alpha taget omega")
        XCTAssertEqual(insideItem.textAnchor?.startUTF16, 6)
        XCTAssertEqual(insideItem.textAnchor?.selectedText, "taget")
    }

    func testLiveRepairCrossingOneAnchorBoundaryPreservesTheSurvivingBoundary() throws {
        let (appState, scene, item) = try makeAnchoredAppState(linkedSegmentID: UUID())

        appState.commitScriptTextChange(sceneID: scene.id, text: "alphget omega")

        XCTAssertEqual(item.textAnchor?.startUTF16, 4)
        XCTAssertEqual(item.textAnchor?.selectedText, "get")
        XCTAssertEqual(item.textAnchor?.prefixContext, "alph")
        XCTAssertEqual(item.textAnchor?.suffixContext, " omega")
        XCTAssertNotNil(item.linkedSegmentID)
    }

    func testLiveRepairClearsBothRelationshipFieldsWhenBothAnchorBoundariesAreDestroyed() throws {
        let (appState, scene, item) = try makeAnchoredAppState(linkedSegmentID: UUID())

        appState.commitScriptTextChange(sceneID: scene.id, text: "alpha X omega")

        XCTAssertNil(item.textAnchor)
        XCTAssertNil(item.linkedSegmentID)
    }

    func testCommittedTextClearsBothRelationshipFieldsWhenRepairFails() throws {
        let (appState, scene, item) = try makeAnchoredAppState(linkedSegmentID: UUID())

        appState.commitScriptTextChange(sceneID: scene.id, text: "entirely unrelated")

        XCTAssertNil(item.textAnchor)
        XCTAssertNil(item.linkedSegmentID)
    }

    func testUnrepairableAnchorClearsAnchorAndSegmentMetadata() throws {
        let (store, scene, item) = try makeAnchorStore(linkedSegmentID: UUID())
        scene.scriptText = "entirely unrelated"

        store.synchronizeTextSegments(splitMode: .scene, wordsPerMinute: 150)

        XCTAssertNil(item.textAnchor)
        XCTAssertNil(item.linkedSegmentID)
    }

    func testAnchorOnlyRelationshipRemainsLinked() throws {
        let (store, _, item) = try makeAnchorStore(linkedSegmentID: nil)

        store.synchronizeTextSegments(splitMode: .scene, wordsPerMinute: 150)

        XCTAssertEqual(item.textAnchor?.selectedText, "target")
        XCTAssertNil(item.linkedSegmentID)
    }

    func testProductionGroupingTreatsAnchorOnlyAndStaleSegmentMetadataAsLinked() throws {
        let text = "alpha target omega"
        let anchor = try XCTUnwrap(TextAnchorRepair.anchor(in: text, range: NSRange(location: 6, length: 6)))
        let anchorOnly = BRollItem(textAnchor: anchor, linkedSegmentID: nil, templateType: "", sourceType: .custom, descriptionText: "")
        let staleSegment = BRollItem(textAnchor: anchor, linkedSegmentID: UUID(), templateType: "", sourceType: .custom, descriptionText: "")
        let invalidAnchor = BRollItem(
            textAnchor: TextAnchor(startUTF16: 0, lengthUTF16: 5, selectedText: "wrong"),
            linkedSegmentID: UUID(),
            templateType: "",
            sourceType: .custom,
            descriptionText: ""
        )
        let segmentOnly = BRollItem(linkedSegmentID: UUID(), templateType: "", sourceType: .custom, descriptionText: "")
        let items = [anchorOnly, staleSegment, invalidAnchor, segmentOnly]

        let sections = ProductionAnchorGrouping.sections(for: items, in: text) { $0.textAnchor }
        let unlinked = ProductionAnchorGrouping.unlinkedItems(from: items, in: text) { $0.textAnchor }

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].excerpt, "target")
        XCTAssertEqual(sections[0].items.map(\.id), [anchorOnly.id, staleSegment.id])
        XCTAssertEqual(unlinked.map(\.id), [invalidAnchor.id, segmentOnly.id])
    }

    func testProductionAnchorSectionsGroupExactRangesAndSortStably() throws {
        let text = "abcdef"
        let short = try XCTUnwrap(TextAnchorRepair.anchor(in: text, range: NSRange(location: 0, length: 2)))
        let long = try XCTUnwrap(TextAnchorRepair.anchor(in: text, range: NSRange(location: 0, length: 3)))
        let late = try XCTUnwrap(TextAnchorRepair.anchor(in: text, range: NSRange(location: 4, length: 2)))
        let lateItem = BRollItem(textAnchor: late, templateType: "", sourceType: .custom, descriptionText: "")
        let longItem = BRollItem(textAnchor: long, templateType: "", sourceType: .custom, descriptionText: "")
        let firstShortItem = BRollItem(textAnchor: short, templateType: "", sourceType: .custom, descriptionText: "")
        let secondShortItem = BRollItem(textAnchor: short, templateType: "", sourceType: .custom, descriptionText: "")

        let sections = ProductionAnchorGrouping.sections(
            for: [lateItem, longItem, firstShortItem, secondShortItem],
            in: text
        ) { $0.textAnchor }

        XCTAssertEqual(sections.map(\.excerpt), ["ab", "abc", "ef"])
        XCTAssertEqual(sections[0].items.map(\.id), [firstShortItem.id, secondShortItem.id])
        XCTAssertEqual(sections[1].items.map(\.id), [longItem.id])
        XCTAssertEqual(sections[2].items.map(\.id), [lateItem.id])
    }

    func testLinkingCreatesAnExactAnchorAndUnlinkingClearsAllRelationshipMetadata() throws {
        let text = "alpha target omega"
        let sceneID = UUID()
        let segment = TextSegment(id: UUID(), sceneID: sceneID, order: 0, sourceText: text, segmentType: .scene)
        let bRoll = BRollItem(linkedSegmentID: UUID(), templateType: "", sourceType: .custom, descriptionText: "")
        let editing = EditingItem(linkedSegmentID: UUID(), templateType: "", cutStyle: "", transition: "", subtitleStyle: "")
        let scene = Scene(id: sceneID, order: 0, sectionType: .custom, title: "Scene", scriptText: text, textSegments: [segment], bRollItems: [bRoll], editingItems: [editing])
        let store = ProjectStore(project: FrameProject(title: "Project", scenes: [scene]))

        store.link(bRoll, to: segment, in: scene)
        store.link(editing, to: segment, in: scene)

        XCTAssertEqual(bRoll.textAnchor?.selectedText, text)
        XCTAssertEqual(editing.textAnchor?.selectedText, text)
        XCTAssertEqual(bRoll.linkedSegmentID, segment.id)
        XCTAssertEqual(editing.linkedSegmentID, segment.id)

        store.unlink(bRoll)
        store.unlink(editing)

        XCTAssertNil(bRoll.textAnchor)
        XCTAssertNil(bRoll.linkedSegmentID)
        XCTAssertNil(editing.textAnchor)
        XCTAssertNil(editing.linkedSegmentID)
    }

    func testMarkerSelectionNavigatesByItemToItsAnchoredSection() throws {
        let text = "alpha target omega"
        let sceneID = UUID()
        let anchor = try XCTUnwrap(TextAnchorRepair.anchor(in: text, range: NSRange(location: 6, length: 6)))
        let item = BRollItem(textAnchor: anchor, linkedSegmentID: UUID(), templateType: "", sourceType: .custom, descriptionText: "")
        let scene = Scene(id: sceneID, order: 0, sectionType: .custom, title: "Scene", scriptText: text, bRollItems: [item])
        let (appState, _, _) = makeAppState(project: FrameProject(title: "Project", scenes: [scene]), fileURL: nil)

        appState.selectProductionItem(item.id, mode: .bRoll)
        let sections = ProductionAnchorGrouping.sections(for: scene.bRollItems, in: scene.scriptText) { $0.textAnchor }

        XCTAssertEqual(appState.editorState.selectedMode, .bRoll)
        XCTAssertEqual(appState.editorState.selectedProductionItemIDs, [item.id])
        XCTAssertEqual(sections.first?.items.map(\.id), [item.id])
    }

    func testMarkerGroupSelectionSelectsAllAnchoredItemsInWorkspaceOrder() throws {
        let text = "alpha target omega"
        let anchor = try XCTUnwrap(TextAnchorRepair.anchor(in: text, range: NSRange(location: 6, length: 6)))
        let first = BRollItem(textAnchor: anchor, linkedSegmentID: nil, templateType: "", sourceType: .custom, descriptionText: "")
        let second = BRollItem(textAnchor: anchor, linkedSegmentID: nil, templateType: "", sourceType: .custom, descriptionText: "")
        let scene = Scene(order: 0, sectionType: .custom, title: "Scene", scriptText: text, bRollItems: [first, second])
        let (appState, _, _) = makeAppState(project: FrameProject(title: "Project", scenes: [scene]), fileURL: nil)

        appState.selectProductionItems([first.id, second.id], mode: .bRoll)

        XCTAssertEqual(appState.editorState.selectedMode, .bRoll)
        XCTAssertEqual(appState.editorState.selectedProductionItemIDs, [first.id, second.id])
        XCTAssertTrue(appState.isProductionItemSelected(first.id))
        XCTAssertTrue(appState.isProductionItemSelected(second.id))

        appState.selectMode(.editing)
        XCTAssertTrue(appState.editorState.selectedProductionItemIDs.isEmpty)
    }

    func testProductionSelectionCollapsesToOneCurrentGroupWhenRepairSplitsIt() throws {
        let text = "abcdef"
        let first = BRollItem(textAnchor: try XCTUnwrap(TextAnchorRepair.anchor(in: text, range: NSRange(location: 0, length: 3))), templateType: "", sourceType: .custom, descriptionText: "")
        let second = BRollItem(textAnchor: try XCTUnwrap(TextAnchorRepair.anchor(in: text, range: NSRange(location: 3, length: 3))), templateType: "", sourceType: .custom, descriptionText: "")
        let scene = Scene(order: 0, sectionType: .custom, title: "Scene", scriptText: text, bRollItems: [first, second])
        let (appState, _, _) = makeAppState(project: FrameProject(title: "Project", scenes: [scene]), fileURL: nil)
        appState.selectProductionItems([first.id, second.id], mode: .bRoll)

        appState.commitScriptTextChange(sceneID: scene.id, text: "abcXdef")

        XCTAssertEqual(appState.editorState.selectedProductionItemIDs, [first.id])
        XCTAssertEqual(first.textAnchor?.selectedText, "abc")
        XCTAssertEqual(second.textAnchor?.selectedText, "def")
    }

    func testUnlinkingSelectedDuplicateGroupPreservesRemainingItemSelection() throws {
        let text = "First target. Second target."
        let anchor = try XCTUnwrap(TextAnchorRepair.anchor(in: text, range: (text as NSString).range(of: "First target.")))
        let first = BRollItem(textAnchor: anchor, templateType: "", sourceType: .custom, descriptionText: "")
        let second = BRollItem(textAnchor: anchor, templateType: "", sourceType: .custom, descriptionText: "")
        let scene = Scene(order: 0, sectionType: .custom, title: "Scene", scriptText: text, bRollItems: [first, second])
        let (appState, _, _) = makeAppState(project: FrameProject(title: "Project", scenes: [scene]), fileURL: nil)
        appState.selectProductionItems([first.id, second.id], mode: .bRoll)

        appState.projectStore.unlink(second)
        appState.normalizeProductionSelection()

        XCTAssertEqual(appState.editorState.selectedProductionItemIDs, [first.id])
    }

    func testRelinkingSecondSelectedDuplicateGroupItemSelectsItsNewGroup() throws {
        let text = "First target. Second target."
        let firstSegment = TextSegment(sceneID: UUID(), order: 0, sourceText: "First target.", segmentType: .sentence)
        let secondSegment = TextSegment(sceneID: firstSegment.sceneID, order: 1, sourceText: "Second target.", segmentType: .sentence)
        let anchor = try XCTUnwrap(TextAnchorRepair.anchor(in: text, range: (text as NSString).range(of: "First target.")))
        let first = BRollItem(textAnchor: anchor, templateType: "", sourceType: .custom, descriptionText: "")
        let second = BRollItem(textAnchor: anchor, templateType: "", sourceType: .custom, descriptionText: "")
        let scene = Scene(id: firstSegment.sceneID, order: 0, sectionType: .custom, title: "Scene", scriptText: text, textSegments: [firstSegment, secondSegment], bRollItems: [first, second])
        let (appState, _, _) = makeAppState(project: FrameProject(title: "Project", scenes: [scene]), fileURL: nil)
        appState.selectProductionItems([first.id, second.id], mode: .bRoll)

        appState.projectStore.link(second, to: secondSegment, in: scene)
        appState.normalizeProductionSelection(preferredItemID: second.id)

        XCTAssertEqual(appState.editorState.selectedProductionItemIDs, [second.id])
        XCTAssertEqual(second.textAnchor?.selectedText, "Second target.")
    }

    func testLegacySegmentLinksMigrateToAnchorsAndStaleLinksClear() throws {
        let sceneID = UUID()
        let segmentID = UUID()
        let segment = TextSegment(id: segmentID, sceneID: sceneID, order: 0, sourceText: "alpha target omega", segmentType: .scene)
        let scene = Scene(
            id: sceneID,
            order: 0,
            sectionType: .custom,
            title: "Scene",
            scriptText: "alpha target omega",
            textSegments: [segment],
            bRollItems: [BRollItem(linkedSegmentID: segmentID, templateType: "", sourceType: .custom, descriptionText: "")],
            editingItems: [EditingItem(linkedSegmentID: UUID(), templateType: "", cutStyle: "", transition: "", subtitleStyle: "")]
        )
        let project = FrameProject(title: "Project", scenes: [scene])

        for version in 1...3 {
            var file = FrameScriptFile(project: project)
            file.fileVersion = version
            let loaded = try file.makeProject()
            let loadedScene = try XCTUnwrap(loaded.scenes.first)
            XCTAssertEqual(loadedScene.bRollItems.first?.textAnchor?.selectedText, "alpha target omega")
            XCTAssertEqual(loadedScene.bRollItems.first?.linkedSegmentID, segmentID)
            XCTAssertNil(loadedScene.editingItems.first?.textAnchor)
            XCTAssertNil(loadedScene.editingItems.first?.linkedSegmentID)
        }
    }

    private func makeAnchorStore(linkedSegmentID: UUID? = nil) throws -> (ProjectStore, FrameScript.Scene, BRollItem) {
        let text = "alpha target omega"
        let sceneID = UUID()
        let segment = TextSegment(id: linkedSegmentID ?? UUID(), sceneID: sceneID, order: 0, sourceText: text, segmentType: .scene)
        let anchor = try XCTUnwrap(TextAnchorRepair.anchor(in: text, range: NSRange(location: 6, length: 6)))
        let item = BRollItem(textAnchor: anchor, linkedSegmentID: linkedSegmentID, templateType: "", sourceType: .custom, descriptionText: "")
        let scene = Scene(id: sceneID, order: 0, sectionType: .custom, title: "Scene", scriptText: text, textSegments: [segment], bRollItems: [item])
        return (ProjectStore(project: FrameProject(title: "Project", scenes: [scene])), scene, item)
    }

    private func makeAnchoredAppState(linkedSegmentID: UUID? = nil) throws -> (AppState, FrameScript.Scene, BRollItem) {
        let text = "alpha target omega"
        let sceneID = UUID()
        let segmentID = linkedSegmentID ?? UUID()
        let segment = TextSegment(id: segmentID, sceneID: sceneID, order: 0, sourceText: text, segmentType: .scene)
        let anchor = try XCTUnwrap(TextAnchorRepair.anchor(in: text, range: NSRange(location: 6, length: 6)))
        let item = BRollItem(textAnchor: anchor, linkedSegmentID: linkedSegmentID, templateType: "", sourceType: .custom, descriptionText: "")
        let scene = Scene(id: sceneID, order: 0, sectionType: .custom, title: "Scene", scriptText: text, textSegments: [segment], bRollItems: [item])
        let (appState, _, _) = makeAppState(project: FrameProject(title: "Project", scenes: [scene]), fileURL: nil)
        return (appState, scene, item)
    }

    private func repositoryText(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func assertNoVisibleBRoll(in text: String, file: String, line: UInt = #line) {
        for term in ["B-roll", "B-Roll", "b-roll"] {
            XCTAssertFalse(text.contains(term), "Unexpected visible \(term) in \(file)", line: line)
        }
    }

    private final class TextBox {
        var value: String
        init(_ value: String) { self.value = value }
    }

    private final class TestActiveEditor: ActiveScriptEditor {
        let flushAction: () -> Void
        let sceneID = UUID()
        let editorIdentity = UUID()
        var owningWindow: NSWindow?
        var isActualFirstResponder = true
        private(set) var didCancelAutocomplete = false

        init(_ flushAction: @escaping () -> Void) { self.flushAction = flushAction }
        func commitMarkedTextAndFlush() -> Bool {
            flushAction()
            return true
        }
        func cancelAutocomplete(clearStatus: Bool) { didCancelAutocomplete = clearStatus }
    }

    @MainActor
    private final class AutocompleteRequestRecorder {
        private(set) var requestCount = 0
        private(set) var completedRequestCount = 0
        private(set) var providerRequestCount = 0
        private(set) var cooldownBlockedRequestCount = 0
        private(set) var contexts: [AutocompleteContext] = []
        var isCooldownActive = false
        private var continuations: [CheckedContinuation<AutocompleteResult, Never>] = []

        func request(_ context: AutocompleteContext) async -> AutocompleteResult {
            if isCooldownActive {
                cooldownBlockedRequestCount += 1
                return .temporarilyUnavailable(.rateLimited)
            }
            requestCount += 1
            providerRequestCount += 1
            contexts.append(context)
            let result = await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
            completedRequestCount += 1
            return result
        }

        func respond(with result: AutocompleteResult) {
            precondition(!continuations.isEmpty)
            continuations.removeFirst().resume(returning: result)
        }
    }

    @MainActor
    private final class RetryingAutocompleteProvider: LLMProviderProtocol {
        private(set) var calls = 0
        private(set) var completedCalls = 0
        private var retryContinuation: CheckedContinuation<LLMResponse, Never>?

        func complete(request: LLMRequest, apiKey: String) async throws -> LLMResponse {
            calls += 1
            if calls == 1 {
                completedCalls += 1
                return LLMResponse(text: "The next beat", finishReason: "length")
            }
            let response = await withCheckedContinuation { continuation in
                retryContinuation = continuation
            }
            completedCalls += 1
            return response
        }

        func respondToRetry(with response: LLMResponse) {
            let continuation = retryContinuation
            retryContinuation = nil
            continuation?.resume(returning: response)
        }
    }

    func testUserEditSynchronouslyUpdatesModel() {
        let box = TextBox("Old")
        let (coordinator, view) = makeCoordinator(box: box)
        view.textView.string = "Exact new text"

        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))

        XCTAssertEqual(box.value, "Exact new text")
    }

    func testConsecutiveEditorEditsCommitTextAndMetricsBeforeAutosave() async throws {
        var writes = 0
        let (appState, scene, _) = makeAppState(fileURL: temporaryProjectURL()) { project, url in
            writes += 1
            try FrameScriptFileStore.write(project: project, to: url)
        }
        let (coordinator, view) = makeCoordinator(appState: appState, scene: scene)

        for text in ["one two", "one two three", "one two three four"] {
            view.textView.string = text
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
            // Text commits synchronously; word count and duration are debounced.
            XCTAssertEqual(scene.scriptText, text)
        }

        let expected = DurationEstimator.estimate(text: scene.scriptText, wordsPerMinute: 150)
        try await waitForSceneMetricsEntry(of: scene)
        try await waitForDebouncedDuration(of: scene, expected)
        XCTAssertEqual(
            SceneMetricsCache.shared.entry(for: scene.id)?.wordCount,
            scene.scriptText.split(whereSeparator: \.isWhitespace).count
        )
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(appState.saveState, .edited)
    }

    func testSceneAndTotalDurationObservationInvalidateFromEditorEdit() async throws {
        let first = Scene(order: 0, sectionType: .custom, title: "One", scriptText: "one")
        let second = Scene(order: 1, sectionType: .custom, title: "Two", scriptText: "one two three")
        let project = FrameProject(title: "Project", scenes: [first, second])
        let (appState, _, _) = makeAppState(project: project, fileURL: nil)
        let (coordinator, view) = makeCoordinator(appState: appState, scene: first)
        nonisolated(unsafe) var invalidated = false
        withObservationTracking {
            _ = first.estimatedDuration
            _ = appState.totalDuration
        } onChange: {
            invalidated = true
        }

        view.textView.string = "one two three four five six"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))

        let firstDuration = DurationEstimator.estimate(text: first.scriptText, wordsPerMinute: 150)
        let secondDuration = DurationEstimator.estimate(text: second.scriptText, wordsPerMinute: 150)
        try await waitForDebouncedDuration(of: first, firstDuration)
        XCTAssertEqual(appState.totalDuration, firstDuration + secondDuration)
        XCTAssertTrue(invalidated)
    }

    func testRepresentableDelegateEditUpdatesScriptAndDuration() async throws {
        let (appState, scene, _) = makeAppState(fileURL: nil)
        let representable = makeRepresentable(
            text: Binding(get: { scene.scriptText }, set: { _ in }),
            onTextCommitted: { previousText, text in appState.commitScriptTextChange(sceneID: scene.id, previousText: previousText, text: text) }
        )
        let host = NSHostingView(rootView: representable)
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        host.layoutSubtreeIfNeeded()
        let container = try XCTUnwrap(firstSubview(of: MarkerTextContainerView.self, in: host))
        let textView = container.textView
        XCTAssertNotNil(textView.delegate as? LinkedScriptTextView.Coordinator)

        textView.string = "one two three four five six"
        textView.didChangeText()

        XCTAssertEqual(scene.scriptText, textView.string)
        try await waitForDebouncedDuration(
            of: scene,
            DurationEstimator.estimate(text: textView.string, wordsPerMinute: 150)
        )
    }

    func testNativeTextEditKeepsAutocompleteThroughItsSelectionChangeAndCaretMovementCancels() async throws {
        let box = TextBox("This is enough editor context")
        let recorder = AutocompleteRequestRecorder()
        let parent = makeRepresentable(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            autocomplete: { @MainActor context in await recorder.request(context) }
        )
        let coordinator = LinkedScriptTextView.Coordinator(parent: parent)
        let view = MarkerTextContainerView()
        coordinator.attach(to: view)
        view.textView.delegate = coordinator
        view.textView.string = box.value
        view.textView.setSelectedRange(NSRange(location: (box.value as NSString).length, length: 0))

        view.textView.insertText("!", replacementRange: view.textView.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 1 }, message: "first request")
        recorder.respond(with: .suggestion("The next beat lands."))
        try await waitUntil { view.textView.ghostText == "The next beat lands." }

        XCTAssertEqual(recorder.requestCount, 1)
        XCTAssertEqual(view.textView.ghostText, "The next beat lands.")

        view.textView.insertText("?", replacementRange: view.textView.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil { recorder.requestCount == 2 }
        view.textView.setSelectedRange(NSRange(location: 0, length: 0))
        recorder.respond(with: .suggestion("The next beat lands."))
        await Task.yield()

        XCTAssertEqual(recorder.requestCount, 2)
        XCTAssertTrue(view.textView.ghostText.isEmpty)
    }

    func testAutocompleteAtAbsoluteDocumentEndSchedulesOneRequestAndShowsGhostText() async throws {
        let recorder = AutocompleteRequestRecorder()
        let (coordinator, view) = makeAutocompleteCoordinator(
            text: "This is enough editor context",
            recorder: recorder
        )
        view.textView.setSelectedRange(NSRange(location: (view.textView.string as NSString).length, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))

        try await waitUntil { recorder.requestCount == 1 }
        recorder.respond(with: .suggestion("The next beat lands."))
        try await waitUntil { view.textView.ghostText == "The next beat lands." }

        XCTAssertEqual(recorder.requestCount, 1)
    }

    func testAutocompleteInSentenceMiddleDoesNotSchedule() async {
        let recorder = AutocompleteRequestRecorder()
        let (coordinator, view) = makeAutocompleteCoordinator(
            text: "This is enough editor context",
            recorder: recorder
        )
        view.textView.setSelectedRange(NSRange(location: 8, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        await Task.yield()

        XCTAssertEqual(recorder.requestCount, 0)
        XCTAssertTrue(view.textView.ghostText.isEmpty)
    }

    func testAutocompleteBeforeExistingParagraphDoesNotSchedule() async {
        let recorder = AutocompleteRequestRecorder()
        let text = "This is enough first paragraph.\nA second paragraph already exists."
        let (coordinator, view) = makeAutocompleteCoordinator(text: text, recorder: recorder)
        let caret = (text as NSString).range(of: "\n").location
        view.textView.setSelectedRange(NSRange(location: caret, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        await Task.yield()

        XCTAssertEqual(recorder.requestCount, 0)
    }

    func testAutocompleteBeforeTrailingWhitespaceOrNewlineSchedules() async throws {
        let recorder = AutocompleteRequestRecorder()
        let text = "This is enough editor context \t\n"
        let (coordinator, view) = makeAutocompleteCoordinator(text: text, recorder: recorder)
        let caret = (text as NSString).length - 3
        view.textView.setSelectedRange(NSRange(location: caret, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 1 }, message: "trailing whitespace request")

        XCTAssertEqual(recorder.contexts[0].suffix, " \t\n")
    }

    func testAutocompleteBeforeZeroWidthSuffixDoesNotSchedule() async {
        let recorder = AutocompleteRequestRecorder()
        let text = "This is enough editor context\u{200B}"
        let (coordinator, view) = makeAutocompleteCoordinator(text: text, recorder: recorder)
        view.textView.setSelectedRange(NSRange(location: (text as NSString).length - 1, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        await Task.yield()

        XCTAssertEqual(recorder.requestCount, 0)
        XCTAssertTrue(view.textView.ghostText.isEmpty)
    }

    func testTabInsertsCompletionAtLogicalEndCaretAndPreservesTrailingWhitespace() async throws {
        let recorder = AutocompleteRequestRecorder()
        let text = "This is enough editor context   \n"
        let (coordinator, view) = makeAutocompleteCoordinator(text: text, recorder: recorder)
        let caret = (text as NSString).length - 4
        view.textView.setSelectedRange(NSRange(location: caret, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 1 }, message: "logical-end request")
        recorder.respond(with: .suggestion("The next beat lands."))
        try await waitUntil({ !view.textView.ghostText.isEmpty }, message: "logical-end ghost")

        view.textView.keyDown(with: try keyEvent(keyCode: 48, characters: "\t"))

        XCTAssertEqual(view.textView.string, "This is enough editor contextThe next beat lands.   \n")
    }

    func testMovingCaretFromDocumentEndCancelsAndClearsSuggestion() async throws {
        let recorder = AutocompleteRequestRecorder()
        let (coordinator, view) = makeAutocompleteCoordinator(
            text: "This is enough editor context",
            recorder: recorder
        )
        view.textView.setSelectedRange(NSRange(location: (view.textView.string as NSString).length, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil { recorder.requestCount == 1 }
        recorder.respond(with: .suggestion("A suggestion to clear."))
        try await waitUntil { !view.textView.ghostText.isEmpty }

        view.textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view.textView))

        XCTAssertTrue(view.textView.ghostText.isEmpty)
    }

    func testNoOpRightArrowAtLogicalEndPreservesVisibleSuggestion() async throws {
        let recorder = AutocompleteRequestRecorder()
        let (coordinator, view) = makeAutocompleteCoordinator(text: "This is enough editor context", recorder: recorder)
        view.textView.setSelectedRange(NSRange(location: (view.textView.string as NSString).length, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 1 }, message: "initial request")
        recorder.respond(with: .suggestion("A suggestion to preserve."))
        try await waitUntil({ !view.textView.ghostText.isEmpty }, message: "initial ghost")

        view.textView.keyDown(with: try keyEvent(keyCode: 124, characters: "\u{F703}"))

        XCTAssertEqual(view.textView.ghostText, "A suggestion to preserve.")
        XCTAssertEqual(recorder.requestCount, 1)
    }

    func testNoOpDownArrowAtLogicalEndDoesNotStartDuplicateRequest() async throws {
        let recorder = AutocompleteRequestRecorder()
        let (coordinator, view) = makeAutocompleteCoordinator(text: "This is enough editor context", recorder: recorder)
        view.textView.setSelectedRange(NSRange(location: (view.textView.string as NSString).length, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 1 }, message: "initial request")
        recorder.respond(with: .suggestion("A suggestion to preserve."))
        try await waitUntil({ !view.textView.ghostText.isEmpty }, message: "initial ghost")

        view.textView.keyDown(with: try keyEvent(keyCode: 125, characters: "\u{F701}"))
        await Task.yield()

        XCTAssertEqual(recorder.requestCount, 1)
        XCTAssertEqual(view.textView.ghostText, "A suggestion to preserve.")
    }

    func testCaretReturnSchedulesOneFreshRequestWithoutTextEdit() async throws {
        let recorder = AutocompleteRequestRecorder()
        let (coordinator, view) = makeAutocompleteCoordinator(text: "This is enough editor context", recorder: recorder)
        let end = (view.textView.string as NSString).length
        view.textView.setSelectedRange(NSRange(location: end, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 1 }, message: "first request")
        recorder.respond(with: .suggestion("First suggestion."))
        try await waitUntil({ !view.textView.ghostText.isEmpty }, message: "first ghost")

        view.textView.setSelectedRange(NSRange(location: end - 1, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view.textView))
        XCTAssertTrue(view.textView.ghostText.isEmpty)

        view.textView.setSelectedRange(NSRange(location: end, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view.textView))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 2 }, message: "caret return request")

        XCTAssertEqual(recorder.requestCount, 2)
    }

    func testLateResponseBeforeCaretMovementIsRejectedAfterCaretReturn() async throws {
        let recorder = AutocompleteRequestRecorder()
        let (coordinator, view) = makeAutocompleteCoordinator(text: "This is enough editor context", recorder: recorder)
        let end = (view.textView.string as NSString).length
        view.textView.setSelectedRange(NSRange(location: end, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 1 }, message: "first request")

        view.textView.setSelectedRange(NSRange(location: end - 1, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view.textView))
        view.textView.setSelectedRange(NSRange(location: end, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 2 }, message: "returned request")

        recorder.respond(with: .suggestion("Stale suggestion."))
        await Task.yield()
        XCTAssertTrue(view.textView.ghostText.isEmpty)
        recorder.respond(with: .suggestion("Fresh suggestion."))
        try await waitUntil({ view.textView.ghostText == "Fresh suggestion." }, message: "fresh ghost")
    }

    func testEscapeRequiresCaretDepartureBeforeCaretReturnRegenerates() async throws {
        let recorder = AutocompleteRequestRecorder()
        let (coordinator, view) = makeAutocompleteCoordinator(text: "This is enough editor context", recorder: recorder)
        let end = (view.textView.string as NSString).length
        view.textView.setSelectedRange(NSRange(location: end, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 1 }, message: "initial request")
        recorder.respond(with: .suggestion("Dismiss me."))
        try await waitUntil({ !view.textView.ghostText.isEmpty }, message: "initial ghost")

        view.textView.keyDown(with: try keyEvent(keyCode: 53, characters: "\u{1B}"))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view.textView))
        await Task.yield()
        XCTAssertEqual(recorder.requestCount, 1)

        view.textView.setSelectedRange(NSRange(location: end - 1, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view.textView))
        view.textView.setSelectedRange(NSRange(location: end, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 2 }, message: "post-Escape caret-return request")
    }

    func testLateEndOfDocumentResponseIsRejectedAfterCaretMovement() async throws {
        let recorder = AutocompleteRequestRecorder()
        let (coordinator, view) = makeAutocompleteCoordinator(
            text: "This is enough editor context",
            recorder: recorder
        )
        view.textView.setSelectedRange(NSRange(location: (view.textView.string as NSString).length, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil { recorder.requestCount == 1 }

        view.textView.setSelectedRange(NSRange(location: 5, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view.textView))
        recorder.respond(with: .suggestion("This must not appear."))
        try await waitUntil { recorder.completedRequestCount == 1 }

        XCTAssertTrue(view.textView.ghostText.isEmpty)
    }

    func testStaleSnapshotDuringAutocompleteRetryShowsNoGhostText() async throws {
        let provider = RetryingAutocompleteProvider()
        let dependencies = AppDependencies(
            rewriteService: RewriteService(provider: provider),
            analysisService: AnalysisService(provider: provider),
            exportService: ExportService(),
            llmProvider: provider,
            providerCredentials: ProviderCredentialSession(reader: { _ in "secret" })
        )
        let (appState, _, _) = makeAppState(
            fileURL: nil,
            dependencies: dependencies,
            hasAutocompleteStoredKey: true
        )
        appState.settings.aiPreferences.provider = .openAICompatible
        let text = "This is enough editor context"
        let box = TextBox(text)
        let parent = makeRepresentable(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            autocomplete: { @MainActor context in await appState.autocompleteScript(context: context) }
        )
        let coordinator = LinkedScriptTextView.Coordinator(parent: parent)
        let view = MarkerTextContainerView()
        coordinator.attach(to: view)
        view.textView.delegate = coordinator
        view.textView.string = text
        view.textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))

        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ provider.calls == 2 }, message: "retry request")

        view.textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view.textView))
        provider.respondToRetry(with: LLMResponse(text: "The next beat lands.", finishReason: "stop"))
        try await waitUntil({ provider.completedCalls == 2 }, message: "retry response")

        XCTAssertTrue(view.textView.ghostText.isEmpty)
    }

    func testGhostTextDoesNotLayOutOverExistingText() {
        let view = MarkerTextContainerView()
        view.textView.string = "Existing script text remains visible"
        view.textView.setSelectedRange(NSRange(location: 8, length: 0))
        view.textView.ghostText = "This must not cover the script."

        XCTAssertTrue(view.textView.ghostLineFragmentWidths().isEmpty)
    }

    func testGhostTextMovesAnUnfittingFirstWordToTheNextFullLine() throws {
        let textView = makeGhostLayoutTestView(text: "Narrator:", width: 160)
        textView.ghostText = "Supercalifragilisticexpialidocious continues."

        let metrics = try XCTUnwrap(textView.ghostTextLayoutMetrics())
        XCTAssertTrue(metrics.startsOnNextLine)
        XCTAssertFalse(metrics.firstWordFitsAtCaret)
        XCTAssertEqual(metrics.firstWordLineIndex, 0)
        XCTAssertEqual(metrics.firstWordRange.map { (textView.ghostText as NSString).substring(with: $0) }, "Supercalifragilisticexpialidocious")
    }

    func testGhostTextStartsAtCaretWhenItsFirstWordFits() throws {
        let textView = makeGhostLayoutTestView(text: "A", width: 300)
        textView.ghostText = "fits and can continue onto later rendered lines if needed."

        let metrics = try XCTUnwrap(textView.ghostTextLayoutMetrics())
        XCTAssertFalse(metrics.startsOnNextLine)
        XCTAssertTrue(metrics.firstWordFitsAtCaret)
        XCTAssertEqual(metrics.firstWordLineIndex, 0)
    }

    func testGhostTextLeadingWhitespaceCannotLeavePartOfItsFirstWordOnTheCaretLine() throws {
        let textView = makeGhostLayoutTestView(text: "Narrator:", width: 160)
        textView.ghostText = "   consequence continues."

        let metrics = try XCTUnwrap(textView.ghostTextLayoutMetrics())
        XCTAssertTrue(metrics.startsOnNextLine)
        XCTAssertEqual(metrics.firstWordRange?.location, 3)
        XCTAssertEqual(metrics.firstWordLineIndex, 0)
    }

    func testGhostTextMovesFirstWordWhenOnlyRightPaddingWouldMakeItFit() throws {
        let textView = makeGhostLayoutTestView(text: "A", width: 300, lineFragmentPadding: 12)
        textView.ghostText = "cat continues"
        let prefixWidth = try XCTUnwrap(textView.ghostTextLayoutMetrics()?.firstWordPrefixWidth)
        textView.frame.size.width = ceil(prefixWidth + 38)
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))

        let metrics = try XCTUnwrap(textView.ghostTextLayoutMetrics())
        XCTAssertTrue(metrics.startsOnNextLine)
        XCTAssertGreaterThan(prefixWidth, metrics.usableCaretLineWidth)
        XCTAssertLessThanOrEqual(prefixWidth, metrics.usableCaretLineWidth + metrics.lineFragmentPadding)
    }

    func testGhostTextMovesLeadingSpacesAndWordTogetherWhenTheirPrefixDoesNotFit() throws {
        let textView = makeGhostLayoutTestView(text: "A", width: 300)
        textView.ghostText = "word continues"
        let wordWidth = try XCTUnwrap(textView.ghostTextLayoutMetrics()?.firstWordPrefixWidth)
        textView.ghostText = "   word continues"
        textView.frame.size.width = ceil(wordWidth + 16)
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))

        let metrics = try XCTUnwrap(textView.ghostTextLayoutMetrics())
        XCTAssertTrue(metrics.startsOnNextLine)
        XCTAssertEqual(metrics.visualLineRanges.first?.location, 0)
        XCTAssertEqual(metrics.firstWordRange?.location, 3)
    }

    func testGhostTextKeepsAWordWiderThanTheEditorLineRenderable() throws {
        let textView = makeGhostLayoutTestView(text: "End", width: 120)
        textView.ghostText = String(repeating: "W", count: 96)

        let metrics = try XCTUnwrap(textView.ghostTextLayoutMetrics())
        XCTAssertTrue(metrics.startsOnNextLine)
        XCTAssertGreaterThan(metrics.visualLineRanges.count, 1)
        XCTAssertEqual(metrics.firstWordLineIndex, 0)
    }

    func testGhostTextPreservesExplicitCompletionNewlinesInTextKitLayout() throws {
        let textView = makeGhostLayoutTestView(text: "A", width: 300)
        textView.ghostText = "fits\nSecond line"

        let metrics = try XCTUnwrap(textView.ghostTextLayoutMetrics())
        let secondWord = (textView.ghostText as NSString).range(of: "Second")
        XCTAssertFalse(metrics.startsOnNextLine)
        XCTAssertEqual(metrics.visualLineRanges.count, 2)
        XCTAssertEqual(metrics.visualLineRanges.firstIndex { NSIntersectionRange($0, secondWord).length == secondWord.length }, 1)
    }

    func testGhostTextExplicitLeadingNewlineDoesNotGainAnArtificialBlankLine() throws {
        let textView = makeGhostLayoutTestView(text: "A", width: 300)
        textView.ghostText = "\nSecond line"

        let metrics = try XCTUnwrap(textView.ghostTextLayoutMetrics())
        XCTAssertFalse(metrics.startsOnNextLine)
        XCTAssertEqual(metrics.plannedLineOrigins.count, 2)
        let ordinary = textLayoutMetrics(for: makeGhostLayoutTestView(text: "A\nSecond line", width: 300))
        XCTAssertEqual(metrics.plannedBaselines[1] - metrics.plannedBaselines[0], ordinary.baselines[1] - ordinary.baselines[0], accuracy: 0.001)
    }

    func testMovedGhostLineMatchesRealTextKitBaselineAdvanceAndParagraphSpacing() throws {
        let source = "Narrator:"
        let completion = "longword continues onto another ghost line"
        let textView = makeGhostLayoutTestView(text: source, width: 100)
        configureCaretTestTypography(textView, fontSize: 16, lineSpacing: ScriptEditorLayout.textKitLineSpacing)
        textView.ghostText = completion
        let ghost = try XCTUnwrap(textView.ghostTextLayoutMetrics())
        XCTAssertTrue(ghost.startsOnNextLine)

        let realTextView = makeGhostLayoutTestView(text: source + completion, width: 100)
        let sourceTextView = makeGhostLayoutTestView(text: source, width: 100)
        configureCaretTestTypography(realTextView, fontSize: 16, lineSpacing: ScriptEditorLayout.textKitLineSpacing)
        configureCaretTestTypography(sourceTextView, fontSize: 16, lineSpacing: ScriptEditorLayout.textKitLineSpacing)
        let real = textLayoutMetrics(for: realTextView)
        let sourceOnly = textLayoutMetrics(for: sourceTextView)
        XCTAssertGreaterThanOrEqual(real.baselines.count, 3)
        XCTAssertEqual(ghost.plannedBaselines[0] - sourceOnly.baselines[0], real.baselines[1] - real.baselines[0], accuracy: 0.001)
        XCTAssertEqual(ghost.plannedBaselines[1] - ghost.plannedBaselines[0], real.baselines[2] - real.baselines[1], accuracy: 0.001)
        XCTAssertEqual(ghost.paragraphLineSpacing, ScriptEditorLayout.textKitLineSpacing, accuracy: 0.001)
    }

    func testExplicitGhostNewlineUsesFixedSpacingExactlyOnce() throws {
        let textView = makeGhostLayoutTestView(text: "A", width: 300)
        configureCaretTestTypography(textView, fontSize: 16, lineSpacing: ScriptEditorLayout.textKitLineSpacing)
        textView.ghostText = "\nSecond line\nThird line"

        let metrics = try XCTUnwrap(textView.ghostTextLayoutMetrics())
        XCTAssertEqual(metrics.plannedBaselines.count, 3)
        let ordinaryTextView = makeGhostLayoutTestView(text: "A\nSecond line\nThird line", width: 300)
        configureCaretTestTypography(ordinaryTextView, fontSize: 16, lineSpacing: ScriptEditorLayout.textKitLineSpacing)
        let ordinary = textLayoutMetrics(for: ordinaryTextView)
        XCTAssertEqual(metrics.plannedBaselines[1] - metrics.plannedBaselines[0], ordinary.baselines[1] - ordinary.baselines[0], accuracy: 0.001)
        XCTAssertEqual(metrics.plannedBaselines[2] - metrics.plannedBaselines[1], ordinary.baselines[2] - ordinary.baselines[1], accuracy: 0.001)
        XCTAssertEqual(metrics.paragraphLineSpacing, ScriptEditorLayout.textKitLineSpacing, accuracy: 0.001)
    }

    func testCuratedTextColumnWidthShrinksWithoutExceedingMaximum() {
        XCTAssertEqual(ScriptEditorLayout.textColumnWidth(for: 1_200), ScriptEditorLayout.maximumTextColumnWidth)
        XCTAssertEqual(ScriptEditorLayout.textColumnWidth(for: 640), 640)
        XCTAssertEqual(ScriptEditorLayout.textColumnWidth(for: -10), 0)
    }

    func testCuratedLineSpacingMatchesTheFormerDefaultMultiplier() {
        XCTAssertEqual(ScriptEditorLayout.visualLineHeightMultiplier, 1.48, accuracy: 0.001)
        XCTAssertEqual(ScriptEditorLayout.textKitLineSpacing, 5.92, accuracy: 0.001)
        XCTAssertEqual(ScriptEditorLayout.paragraphStyle().lineSpacing, ScriptEditorLayout.textKitLineSpacing, accuracy: 0.001)
    }

    func testGhostTextLeavesCaretSelectionAndSourceUnchangedUntilAccepted() throws {
        let source = "Narrator:"
        let textView = makeGhostLayoutTestView(text: source, width: 160)
        let selection = textView.selectedRange()
        textView.ghostText = "Supercalifragilisticexpialidocious continues."

        XCTAssertNotNil(textView.ghostTextLayoutMetrics())
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(textView.selectedRange(), selection)
    }

    func testTabAcceptsTheSameCompletionAfterGhostTextMovesToTheNextLine() async throws {
        let source = "This is enough editor context Narrator:"
        let completion = "Supercalifragilisticexpialidocious continues."
        let recorder = AutocompleteRequestRecorder()
        let (coordinator, view) = makeAutocompleteCoordinator(text: source, recorder: recorder)
        view.frame = NSRect(x: 0, y: 0, width: 160, height: 120)
        view.layoutSubtreeIfNeeded()
        view.textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 1 }, message: "autocomplete request")
        recorder.respond(with: .suggestion(completion))
        try await waitUntil({ view.textView.ghostText == completion }, message: "ghost completion")

        XCTAssertTrue(try XCTUnwrap(view.textView.ghostTextLayoutMetrics()).startsOnNextLine)
        view.textView.keyDown(with: try keyEvent(keyCode: 48, characters: "\t"))

        XCTAssertEqual(view.textView.string, source + completion)
    }

    func testAutocompleteRegeneratesForRepeatedEndOfDocumentContextsInOneEditor() async throws {
        let recorder = AutocompleteRequestRecorder()
        let (coordinator, view) = makeAutocompleteCoordinator(
            text: "This is enough editor context",
            recorder: recorder
        )
        view.textView.setSelectedRange(NSRange(location: (view.textView.string as NSString).length, length: 0))

        view.textView.insertText(" ", replacementRange: view.textView.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 1 }, message: "first request")
        let firstGeneration = coordinator.autocompleteRequestGeneration
        let firstTextRevision = coordinator.textRevision
        recorder.respond(with: .suggestion("First suggestion."))
        try await waitUntil({ view.textView.ghostText == "First suggestion." }, message: "first ghost")

        view.textView.insertText("", replacementRange: NSRange(location: (view.textView.string as NSString).length - 1, length: 1))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 2 }, message: "deletion request")
        view.textView.insertText(" ", replacementRange: view.textView.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 3 }, message: "regenerated identical-context request")
        XCTAssertEqual(recorder.contexts[0], recorder.contexts[2])
        XCTAssertGreaterThan(coordinator.autocompleteRequestGeneration, firstGeneration)
        XCTAssertGreaterThan(coordinator.textRevision, firstTextRevision)

        recorder.respond(with: .suggestion("Stale deletion response."))
        await Task.yield()
        XCTAssertTrue(view.textView.ghostText.isEmpty)
        recorder.respond(with: .suggestion("Second suggestion."))
        try await waitUntil({ view.textView.ghostText == "Second suggestion." }, message: "second ghost")

        view.textView.insertText("", replacementRange: NSRange(location: (view.textView.string as NSString).length - 1, length: 1))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 4 }, message: "second deletion request")
        view.textView.insertText(" ", replacementRange: view.textView.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 5 }, message: "third identical-context request")
        recorder.respond(with: .suggestion("Stale second deletion response."))
        await Task.yield()
        recorder.respond(with: .suggestion("Third suggestion."))
        try await waitUntil({ view.textView.ghostText == "Third suggestion." }, message: "third ghost")

        view.textView.keyDown(with: try keyEvent(keyCode: 53, characters: "\u{1B}"))
        XCTAssertTrue(view.textView.ghostText.isEmpty)
        view.textView.insertText("!", replacementRange: view.textView.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 6 }, message: "post-Escape request")
        recorder.respond(with: .suggestion("Escape suggestion."))
        try await waitUntil({ view.textView.ghostText == "Escape suggestion." }, message: "post-Escape ghost")

        coordinator.handleGhostAction(.replace)
        view.textView.insertText("?", replacementRange: view.textView.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 7 }, message: "replacement request")
        recorder.respond(with: .suggestion("Replacement suggestion."))
        try await waitUntil({ view.textView.ghostText == "Replacement suggestion." }, message: "replacement ghost")

        coordinator.handleGhostAction(.replace)
        view.textView.insertText(".", replacementRange: view.textView.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 8 }, message: "pre-undo request")
        view.textView.undoManager?.undo()
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 9 }, message: "undo request")
        view.textView.undoManager?.redo()
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 10 }, message: "redo request")
        XCTAssertEqual(view.textView.selectedRange().location, (view.textView.string as NSString).length)

        recorder.isCooldownActive = true
        let providerRequestCount = recorder.providerRequestCount
        view.textView.insertText(" ", replacementRange: view.textView.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.cooldownBlockedRequestCount == 1 }, message: "cooldown block")
        recorder.respond(with: .suggestion("Stale undo response."))
        recorder.respond(with: .suggestion("Stale redo response."))
        recorder.respond(with: .suggestion("Stale cooldown response."))
        XCTAssertEqual(recorder.providerRequestCount, providerRequestCount)

        XCTAssertEqual(recorder.contexts[0], recorder.contexts[2])
    }

    func testMissingAutocompleteEligibilityStartsNoDebounceOrRequest() async {
        let text = "This is enough editor context"
        let recorder = AutocompleteRequestRecorder()
        let parent = makeRepresentable(
            text: .constant(text),
            autocompleteConfigurationEligibility: .blockedMissingKeyMetadata,
            autocomplete: { @MainActor context in await recorder.request(context) }
        )
        let coordinator = LinkedScriptTextView.Coordinator(parent: parent)
        let view = MarkerTextContainerView()
        coordinator.attach(to: view)
        view.textView.string = text
        view.textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))

        view.textView.insertText("!", replacementRange: view.textView.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        await Task.yield()

        XCTAssertEqual(recorder.requestCount, 0)
        XCTAssertTrue(view.textView.ghostText.isEmpty)
    }

    func testAutocompleteEligibilityChangesWithoutRecreatingTheEditor() async throws {
        let text = "This is enough editor context"
        let recorder = AutocompleteRequestRecorder()
        let initial = makeRepresentable(
            text: .constant(text),
            autocompleteConfigurationVersion: 0,
            autocompleteConfigurationEligibility: .eligible,
            autocomplete: { @MainActor context in await recorder.request(context) }
        )
        let coordinator = LinkedScriptTextView.Coordinator(parent: initial)
        let view = MarkerTextContainerView()
        coordinator.attach(to: view)
        view.textView.string = text
        view.textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        view.textView.insertText("!", replacementRange: view.textView.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 1 }, message: "initial eligible request")
        recorder.respond(with: .none)

        coordinator.parent = makeRepresentable(
            text: .constant(view.textView.string),
            autocompleteConfigurationVersion: 1,
            autocompleteConfigurationEligibility: .blockedMissingKeyMetadata,
            autocomplete: { @MainActor context in await recorder.request(context) }
        )
        coordinator.applyModelTextIfNeeded()
        view.textView.insertText("!", replacementRange: view.textView.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        await Task.yield()
        XCTAssertEqual(recorder.requestCount, 1)

        coordinator.parent = makeRepresentable(
            text: .constant(view.textView.string),
            autocompleteConfigurationVersion: 2,
            autocompleteConfigurationEligibility: .eligible,
            autocomplete: { @MainActor context in await recorder.request(context) }
        )
        coordinator.applyModelTextIfNeeded()
        view.textView.insertText("!", replacementRange: view.textView.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        try await waitUntil({ recorder.requestCount == 2 }, message: "restored eligible request")
    }

    func testUntitledEditorEditUpdatesMetricsWithoutSaveAs() async throws {
        let (appState, scene, _) = makeAppState(fileURL: nil)
        let (coordinator, view) = makeCoordinator(appState: appState, scene: scene)

        view.textView.string = "untitled projects update right now"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))

        XCTAssertEqual(scene.scriptText, "untitled projects update right now")
        try await waitForDebouncedDuration(
            of: scene,
            DurationEstimator.estimate(text: scene.scriptText, wordsPerMinute: 150)
        )
        XCTAssertNil(appState.projectStore.currentFileURL)
        XCTAssertEqual(appState.saveState, .edited)
    }

    func testRapidEditorEditsCoalesceIntoOneAutosave() async throws {
        let fileURL = temporaryProjectURL()
        var writes = 0
        let (appState, scene, _) = makeAppState(fileURL: fileURL) { project, url in
            writes += 1
            try FrameScriptFileStore.write(project: project, to: url)
        }
        let (coordinator, view) = makeCoordinator(appState: appState, scene: scene)

        for text in ["first", "first second", "first second third"] {
            view.textView.string = text
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        }
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(writes, 0, "Editor commits must not wait for the autosave interval to update the model")

        appState.flushActiveEditorBoundary()

        XCTAssertEqual(writes, 1)
        XCTAssertEqual(appState.saveState, .saved)
        XCTAssertEqual(try FrameScriptFileStore.read(from: fileURL).scenes.first?.scriptText, "first second third")
    }

    func testFailedAutosaveAfterEditorEditLeavesProjectDirty() async throws {
        enum WriteFailure: Error { case expected }
        let (appState, scene, _) = makeAppState(fileURL: temporaryProjectURL()) { _, _ in
            throw WriteFailure.expected
        }
        let (coordinator, view) = makeCoordinator(appState: appState, scene: scene)

        view.textView.string = "this write will fail"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        appState.flushActiveEditorBoundary()

        XCTAssertTrue(appState.projectStore.hasUnsavedFileChanges)
        XCTAssertEqual(appState.saveState, .edited)
        XCTAssertEqual(appState.errorCenter.presentedError?.kind, .autosave)
    }

    func testStaleRepresentableUpdateCannotReplaceLastUserText() {
        var emitted = ""
        let staleBinding = Binding<String>(get: { "Old model value" }, set: { emitted = $0 })
        let parent = makeRepresentable(text: staleBinding)
        let coordinator = LinkedScriptTextView.Coordinator(parent: parent)
        let view = MarkerTextContainerView()
        coordinator.attach(to: view)
        view.textView.string = "Newest editor value"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))

        coordinator.applyModelTextIfNeeded()

        XCTAssertEqual(view.textView.string, "Newest editor value")
        XCTAssertEqual(emitted, "Newest editor value")
    }

    func testLegitimateExternalModelUpdateReachesTextView() {
        let box = TextBox("Old")
        let (coordinator, view) = makeCoordinator(box: box)
        view.textView.string = "User edit"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
        box.value = "AI rewrite"

        coordinator.applyModelTextIfNeeded()

        XCTAssertEqual(view.textView.string, "AI rewrite")
        XCTAssertEqual(box.value, "AI rewrite")
    }

    func testCaretSelectionAndScrollRestoreAndClamp() {
        let box = TextBox(String(repeating: "line of text\n", count: 80))
        var saved: ScriptEditorRestorationState?
        let parent = makeRepresentable(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            loadState: { saved },
            saveState: { saved = $0 }
        )
        let first = LinkedScriptTextView.Coordinator(parent: parent)
        let firstView = MarkerTextContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 140))
        first.attach(to: firstView)
        first.applyModelTextIfNeeded()
        firstView.layoutSubtreeIfNeeded()
        let maximumOriginY = max(
            0,
            firstView.scrollView.documentView!.bounds.maxY - firstView.scrollView.contentView.bounds.height
        )
        let savedOriginY = min(120, maximumOriginY)
        firstView.textView.setSelectedRange(NSRange(location: 42, length: 12))
        firstView.scrollView.contentView.scroll(to: NSPoint(x: 120, y: savedOriginY))
        first.captureRestorationState()

        let recreated = LinkedScriptTextView.Coordinator(parent: parent)
        let recreatedView = MarkerTextContainerView(frame: firstView.frame)
        recreated.attach(to: recreatedView)
        recreated.applyModelTextIfNeeded()
        recreated.restoreEditorStateIfAvailable()

        XCTAssertEqual(recreatedView.textView.selectedRange(), NSRange(location: 42, length: 12))
        XCTAssertEqual(recreatedView.scrollView.contentView.bounds.origin.y, savedOriginY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(recreatedView.scrollView.contentView.bounds.origin.x, 0)

        box.value = "short"
        recreated.applyModelTextIfNeeded()
        recreated.restoreEditorStateIfAvailable()
        XCTAssertLessThanOrEqual(NSMaxRange(recreatedView.textView.selectedRange()), 5)
        XCTAssertGreaterThanOrEqual(recreatedView.scrollView.contentView.bounds.origin.x, 0)
        XCTAssertGreaterThanOrEqual(recreatedView.scrollView.contentView.bounds.origin.y, 0)
        XCTAssertLessThanOrEqual(
            recreatedView.scrollView.contentView.bounds.maxX,
            recreatedView.scrollView.documentView!.bounds.maxX + 1
        )
        XCTAssertLessThanOrEqual(
            recreatedView.scrollView.contentView.bounds.maxY,
            recreatedView.scrollView.documentView!.bounds.maxY + 1
        )
    }

    func testRestorationStateIsIndependentPerSceneAndEditor() {
        let state = EditorState()
        let sceneA = UUID(), sceneB = UUID(), windowA = UUID(), windowB = UUID()
        let first = ScriptEditorRestorationState(selectedRange: NSRange(location: 3, length: 2), visibleOrigin: NSPoint(x: 0, y: 40))
        let second = ScriptEditorRestorationState(selectedRange: NSRange(location: 8, length: 1), visibleOrigin: NSPoint(x: 0, y: 90))
        state.setScriptEditorState(first, sceneID: sceneA, editorIdentity: windowA)
        state.setScriptEditorState(second, sceneID: sceneB, editorIdentity: windowB)

        XCTAssertEqual(state.scriptEditorState(sceneID: sceneA, editorIdentity: windowA), first)
        XCTAssertEqual(state.scriptEditorState(sceneID: sceneB, editorIdentity: windowB), second)
        XCTAssertNil(state.scriptEditorState(sceneID: sceneA, editorIdentity: windowB))
    }

    func testDismantleFlushesAndRunsImmediateTeardownBoundary() {
        let box = TextBox("Old")
        var toreDown = false
        let parent = makeRepresentable(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            onTeardown: { toreDown = true }
        )
        let coordinator = LinkedScriptTextView.Coordinator(parent: parent)
        let view = MarkerTextContainerView()
        coordinator.attach(to: view)
        view.textView.string = "Latest"

        LinkedScriptTextView.dismantleNSView(view, coordinator: coordinator)

        XCTAssertEqual(box.value, "Latest")
        XCTAssertTrue(toreDown)
    }

    func testEditorFlushCommitsCurrentTextBeforeDismantle() {
        let box = TextBox("Old")
        let (coordinator, view) = makeCoordinator(box: box)
        view.textView.string = "Text present only in NSTextView"

        coordinator.commitMarkedTextAndFlush()

        XCTAssertEqual(box.value, "Text present only in NSTextView")
    }

    func testModeSwitchesPreserveExactText() {
        for mode in [WorkspaceMode.bRoll, .editing] {
            let (appState, scene, _) = makeAppState(fileURL: nil)
            let exact = "Typed immediately before \(mode.rawValue)"
            let editor = TestActiveEditor {
                scene.scriptText = exact
                appState.commitScriptTextChange(sceneID: scene.id)
            }
            ActiveScriptEditorSession.shared.register(editor)
            defer { ActiveScriptEditorSession.shared.unregister(editor) }

            appState.selectMode(mode)

            XCTAssertEqual(scene.scriptText, exact)
            XCTAssertEqual(appState.selectedMode, mode)
            XCTAssertEqual(appState.saveState, .edited)
        }
    }

    func testSelectingAnotherScenePreservesPreviousText() {
        let first = Scene(order: 0, sectionType: .custom, title: "One", scriptText: "Old")
        let second = Scene(order: 1, sectionType: .custom, title: "Two", scriptText: "")
        let project = FrameProject(title: "Project", scenes: [first, second])
        let (appState, _, _) = makeAppState(project: project, fileURL: nil)
        appState.editorState.selectedSceneID = first.id
        let editor = TestActiveEditor {
            first.scriptText = "Preserved before scene switch"
            appState.commitScriptTextChange(sceneID: first.id)
        }
        ActiveScriptEditorSession.shared.register(editor)
        defer { ActiveScriptEditorSession.shared.unregister(editor) }

        appState.selectScene(second.id)

        XCTAssertEqual(first.scriptText, "Preserved before scene switch")
        XCTAssertEqual(appState.editorState.selectedSceneID, second.id)
    }

    func testResignActiveFlushesTextAndSegments() {
        let (appState, scene, _) = makeAppState(fileURL: nil)
        appState.configure()
        let editor = TestActiveEditor {
            scene.scriptText = "First sentence. Second sentence."
            appState.commitScriptTextChange(sceneID: scene.id)
        }
        ActiveScriptEditorSession.shared.register(editor)
        defer { ActiveScriptEditorSession.shared.unregister(editor) }

        NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: nil)

        XCTAssertEqual(scene.scriptText, "First sentence. Second sentence.")
        XCTAssertFalse(scene.textSegments.isEmpty)
    }

    func testResignActiveFlushesAndCancelsTwoRegisteredEditors() {
        let (appState, scene, _) = makeAppState(fileURL: nil)
        appState.configure()
        var firstFlushes = 0
        var secondFlushes = 0
        let first = TestActiveEditor { firstFlushes += 1 }
        let second = TestActiveEditor { secondFlushes += 1 }
        ActiveScriptEditorSession.shared.register(first)
        ActiveScriptEditorSession.shared.register(second)
        defer {
            ActiveScriptEditorSession.shared.unregister(first)
            ActiveScriptEditorSession.shared.unregister(second)
        }

        XCTAssertTrue(ActiveScriptEditorSession.shared.flushAllForAppResignation())

        XCTAssertEqual(firstFlushes, 1)
        XCTAssertEqual(secondFlushes, 1)
        XCTAssertTrue(first.didCancelAutocomplete)
        XCTAssertTrue(second.didCancelAutocomplete)
        XCTAssertEqual(appState.selectedScene?.id, scene.id)
    }

    func testSessionFlushSelectsTheKeyWindowEditor() {
        let firstWindow = NSWindow()
        let secondWindow = NSWindow()
        var firstFlushes = 0
        var secondFlushes = 0
        let first = TestActiveEditor { firstFlushes += 1 }
        let second = TestActiveEditor { secondFlushes += 1 }
        first.isActualFirstResponder = false
        second.isActualFirstResponder = false
        first.owningWindow = firstWindow
        second.owningWindow = secondWindow
        ActiveScriptEditorSession.shared.register(first)
        ActiveScriptEditorSession.shared.register(second)
        defer {
            ActiveScriptEditorSession.shared.unregister(first)
            ActiveScriptEditorSession.shared.unregister(second)
        }

        XCTAssertTrue(ActiveScriptEditorSession.shared.flush(keyWindow: firstWindow))
        XCTAssertEqual(firstFlushes, 1)
        XCTAssertEqual(secondFlushes, 0)
    }

    func testSessionFlushWithNoKeyWindowDoesNotUseLastRegisteredEditor() {
        var flushes = 0
        let editor = TestActiveEditor { flushes += 1 }
        editor.isActualFirstResponder = false
        ActiveScriptEditorSession.shared.register(editor)
        defer { ActiveScriptEditorSession.shared.unregister(editor) }

        XCTAssertFalse(ActiveScriptEditorSession.shared.flush(keyWindow: nil))
        XCTAssertEqual(flushes, 0)
    }

    func testResignActiveCapturesCaretAndScrollState() {
        let (appState, _, _) = makeAppState(fileURL: nil)
        appState.configure()
        var saved: ScriptEditorRestorationState?
        let parent = makeRepresentable(
            text: .constant(String(repeating: "line\n", count: 60)),
            loadState: { saved },
            saveState: { saved = $0 }
        )
        let coordinator = LinkedScriptTextView.Coordinator(parent: parent)
        let view = MarkerTextContainerView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        coordinator.attach(to: view)
        coordinator.applyModelTextIfNeeded()
        view.textView.setSelectedRange(NSRange(location: 24, length: 5))
        view.layoutSubtreeIfNeeded()
        let expectedOrigin = NSPoint(
            x: 0,
            y: max(0, view.scrollView.documentView!.bounds.maxY - view.scrollView.contentView.bounds.height)
        )
        view.scrollView.contentView.scroll(to: expectedOrigin)
        ActiveScriptEditorSession.shared.register(coordinator)
        defer { ActiveScriptEditorSession.shared.unregister(coordinator) }

        NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: nil)

        XCTAssertEqual(saved?.selectedRange, NSRange(location: 24, length: 5))
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved!.visibleOrigin, expectedOrigin)
    }

    func testExistingFileAutosaveWaitsForIntervalAndFlushesOnDemand() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("Immediate.fscr")
        let (appState, scene, _) = makeAppState(fileURL: fileURL)
        try FrameScriptFileStore.write(project: appState.project, to: fileURL)
        appState.startTrackingProjectFile(at: fileURL)

        scene.scriptText = "Persist after the coalesced window"
        let clock = ContinuousClock()
        let started = clock.now
        appState.commitScriptTextChange(sceneID: scene.id)
        while appState.saveState != .saved, clock.now - started < .milliseconds(180) {
            await Task.yield()
        }

        XCTAssertEqual(appState.saveState, .edited)

        appState.flushActiveEditorBoundary()

        let saved = try FrameScriptFileStore.read(from: fileURL)
        XCTAssertEqual(saved.scenes.first?.scriptText, "Persist after the coalesced window")
        XCTAssertEqual(appState.saveState, .saved)
    }

    func testUntitledProjectPreservesTextWithoutFileURL() {
        let (appState, scene, _) = makeAppState(fileURL: nil)
        let editor = TestActiveEditor {
            scene.scriptText = "Safe untitled text"
            appState.commitScriptTextChange(sceneID: scene.id)
        }
        ActiveScriptEditorSession.shared.register(editor)
        defer { ActiveScriptEditorSession.shared.unregister(editor) }

        appState.selectMode(.bRoll)

        XCTAssertNil(appState.projectStore.currentFileURL)
        XCTAssertEqual(scene.scriptText, "Safe untitled text")
        XCTAssertEqual(appState.saveState, .edited)
    }

    func testCommittedUntitledEditUpdatesMetricsWithoutSaving() async throws {
        let (appState, scene, _) = makeAppState(fileURL: nil)
        scene.scriptText = "one two three four five"

        appState.commitScriptTextChange(sceneID: scene.id)

        try await waitForDebouncedDuration(
            of: scene,
            DurationEstimator.estimate(text: scene.scriptText, wordsPerMinute: 150)
        )
        XCTAssertEqual(appState.saveState, .edited)
        XCTAssertNil(appState.projectStore.currentFileURL)
    }

    func testTextAndPlaceholderShareZeroHorizontalOrigin() {
        let view = MarkerTextContainerView()
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.textView.textContainerInset.width, 0)
        XCTAssertEqual(view.textView.textContainer?.lineFragmentPadding, 0)
        XCTAssertEqual(view.textView.placeholderOrigin.x, view.textView.textContainerOrigin.x)
        XCTAssertEqual(view.textView.placeholderOrigin.y, view.textView.textContainerOrigin.y)
    }

    func testInsertionCaretUsesFontHeightInsteadOfParagraphSpacing() {
        let view = makeCaretTestView(text: "First line\nSecond line", fontSize: 16, lineSpacing: 4)
        let systemRect = simulatedSystemCaretRect(in: view.textView, at: 0)
        let caretRect = normalizedCaretRect(in: view.textView, at: 0, systemRect: systemRect)
        let glyphHeight = caretGlyphHeight(in: view.textView)

        XCTAssertEqual(caretRect.height, glyphHeight, accuracy: 0.5)
        XCTAssertGreaterThan(systemRect.height, glyphHeight + 3)
        XCTAssertLessThan(caretRect.height, systemRect.height - 3)
    }

    func testInsertionCaretScalesWithFontWithoutFollowingLineSpacing() {
        for size in [CGFloat(14), 18, 24] {
            let view = makeCaretTestView(text: "First line\nSecond line", fontSize: size, lineSpacing: 16)
            let firstRect = simulatedSystemCaretRect(in: view.textView, at: 0)
            let secondIndex = (view.textView.string as NSString).range(of: "Second").location
            let secondRect = simulatedSystemCaretRect(in: view.textView, at: secondIndex)
            let caretRect = normalizedCaretRect(in: view.textView, at: 0, systemRect: firstRect)
            let glyphHeight = caretGlyphHeight(in: view.textView)

            XCTAssertEqual(caretRect.height, glyphHeight, accuracy: 0.5, "font size \(size)")
            XCTAssertGreaterThan(secondRect.minY - firstRect.minY, glyphHeight, "line spacing remains active at \(size)")
            XCTAssertLessThan(caretRect.height, firstRect.height, "caret excludes spacing at \(size)")
        }
    }

    func testInsertionCaretTracksGlyphBaselinesOnFirstLaterAndWrappedLines() {
        let view = makeCaretTestView(
            text: "First line\nSecond line is deliberately long enough to wrap within this narrow editor column.",
            fontSize: 18,
            lineSpacing: 12,
            width: 180
        )
        let indices = lineStartIndices(in: view.textView)
        XCTAssertGreaterThanOrEqual(indices.count, 3)

        for index in [indices[0], indices[1], indices[2]] {
            let systemRect = simulatedSystemCaretRect(in: view.textView, at: index)
            let caretRect = normalizedCaretRect(in: view.textView, at: index, systemRect: systemRect)
            XCTAssertEqual(caretRect.minY, expectedCaretOriginY(in: view.textView, at: index, systemRect: systemRect), accuracy: 0.5)
            XCTAssertTrue(caretRect.intersects(systemRect))
        }
    }

    func testInsertionCaretCentersInInteriorEmptyParagraph() {
        let text = "First\n\nSecond"
        let view = makeCaretTestView(text: text, fontSize: 18, lineSpacing: 16)
        let emptyParagraph = (text as NSString).range(of: "\n\n").location + 1
        let emptySystemRect = simulatedSystemCaretRect(in: view.textView, at: emptyParagraph)
        let emptyCaretRect = normalizedCaretRect(in: view.textView, at: emptyParagraph, systemRect: emptySystemRect)

        XCTAssertEqual(emptyCaretRect.height, caretGlyphHeight(in: view.textView), accuracy: 0.5)
        XCTAssertEqual(emptyCaretRect.midY, emptySystemRect.midY, accuracy: 0.5)

        let secondParagraph = (text as NSString).range(of: "Second").location
        for index in [0, secondParagraph] {
            let systemRect = simulatedSystemCaretRect(in: view.textView, at: index)
            let caretRect = normalizedCaretRect(in: view.textView, at: index, systemRect: systemRect)
            XCTAssertEqual(caretRect.minY, expectedCaretOriginY(in: view.textView, at: index, systemRect: systemRect), accuracy: 0.5)
        }
    }

    func testInsertionCaretCentersEachConsecutiveInteriorEmptyParagraph() {
        let text = "First\n\n\nSecond"
        let view = makeCaretTestView(text: text, fontSize: 18, lineSpacing: 16)
        let firstEmptyParagraph = (text as NSString).range(of: "\n\n\n").location + 1

        for index in [firstEmptyParagraph, firstEmptyParagraph + 1] {
            let systemRect = simulatedSystemCaretRect(in: view.textView, at: index)
            let caretRect = normalizedCaretRect(in: view.textView, at: index, systemRect: systemRect)
            XCTAssertEqual(caretRect.midY, systemRect.midY, accuracy: 0.5)
            XCTAssertEqual(caretRect.height, caretGlyphHeight(in: view.textView), accuracy: 0.5)
        }
    }

    func testInsertionCaretCentersInteriorEmptyParagraphWithCarriageReturns() {
        let text = "First\r\rSecond"
        let view = makeCaretTestView(text: text, fontSize: 18, lineSpacing: 16)
        let emptyParagraph = (text as NSString).range(of: "\r\r").location + 1
        let systemRect = simulatedSystemCaretRect(in: view.textView, at: emptyParagraph)
        let caretRect = normalizedCaretRect(in: view.textView, at: emptyParagraph, systemRect: systemRect)

        XCTAssertEqual(caretRect.midY, systemRect.midY, accuracy: 0.5)
    }

    func testInsertionCaretKeepsInteriorEmptyParagraphCenteredAcrossLineSpacing() {
        let text = "First\n\nSecond"
        let emptyParagraph = (text as NSString).range(of: "\n\n").location + 1
        var heights: [CGFloat] = []

        for lineSpacing in [CGFloat(0), 16] {
            let view = makeCaretTestView(text: text, fontSize: 18, lineSpacing: lineSpacing)
            let systemRect = simulatedSystemCaretRect(in: view.textView, at: emptyParagraph)
            let caretRect = normalizedCaretRect(in: view.textView, at: emptyParagraph, systemRect: systemRect)
            heights.append(caretRect.height)
            XCTAssertEqual(caretRect.midY, systemRect.midY, accuracy: 0.5, "line spacing \(lineSpacing)")
        }

        XCTAssertEqual(heights[0], heights[1], accuracy: 0.5)
    }

    func testInsertionCaretStaysValidForEmptyAndMixedUnicodeText() {
        let empty = makeCaretTestView(text: "", fontSize: 18, lineSpacing: 16)
        let emptyRect = normalizedCaretRect(in: empty.textView, at: 0, systemRect: simulatedSystemCaretRect(in: empty.textView, at: 0))
        XCTAssertEqual(emptyRect.height, caretGlyphHeight(in: empty.textView), accuracy: 0.5)

        let text = "Latin Привет 😀\n"
        let view = makeCaretTestView(text: text, fontSize: 18, lineSpacing: 16)
        let positions = [0, (text as NSString).length - 1, (text as NSString).length]
        for index in positions {
            let systemRect = simulatedSystemCaretRect(in: view.textView, at: index)
            let caretRect = normalizedCaretRect(in: view.textView, at: index, systemRect: systemRect)
            XCTAssertTrue(caretRect.origin.x.isFinite && caretRect.origin.y.isFinite && caretRect.width.isFinite && caretRect.height.isFinite)
            XCTAssertGreaterThan(caretRect.height, 0)
            XCTAssertLessThanOrEqual(caretRect.height, systemRect.height)
        }
    }

    func testInsertionCaretAtPhysicalDocumentEndUsesItsActualInsertionLine() {
        for text in ["ordinary final line", "a wrapped final line that is long enough to wrap in this narrow editor column", "", "line\n", "line\n\n", "Latin Привет 😀"] {
            let view = makeCaretTestView(text: text, fontSize: 18, lineSpacing: 16, width: 180)
            let end = (text as NSString).length
            let systemRect = simulatedSystemCaretRect(in: view.textView, at: end)
            let caretRect = normalizedCaretRect(in: view.textView, at: end, systemRect: systemRect)

            XCTAssertEqual(caretRect.height, caretGlyphHeight(in: view.textView), accuracy: 0.5, text)
            XCTAssertEqual(caretRect.minY, expectedCaretOriginY(in: view.textView, at: end, systemRect: systemRect), accuracy: 0.5, text)
            XCTAssertTrue(caretRect.origin.x.isFinite && caretRect.origin.y.isFinite, text)
        }
    }

    func testInsertionCaretKeepsEmptyDocumentAndTrailingNewlineBehavior() {
        let empty = makeCaretTestView(text: "", fontSize: 18, lineSpacing: 16)
        let emptySystemRect = simulatedSystemCaretRect(in: empty.textView, at: 0)
        let emptyCaretRect = normalizedCaretRect(in: empty.textView, at: 0, systemRect: emptySystemRect)
        XCTAssertEqual(emptyCaretRect.minY, emptySystemRect.minY, accuracy: 0.5)
        XCTAssertEqual(emptyCaretRect.height, caretGlyphHeight(in: empty.textView), accuracy: 0.5)

        let text = "First\n"
        let trailing = makeCaretTestView(text: text, fontSize: 18, lineSpacing: 16)
        let index = (text as NSString).length
        let trailingSystemRect = simulatedSystemCaretRect(in: trailing.textView, at: index)
        let trailingCaretRect = normalizedCaretRect(in: trailing.textView, at: index, systemRect: trailingSystemRect)
        XCTAssertEqual(trailingCaretRect.minY, expectedCaretOriginY(in: trailing.textView, at: index, systemRect: trailingSystemRect), accuracy: 0.5)
        XCTAssertEqual(trailingCaretRect.height, caretGlyphHeight(in: trailing.textView), accuracy: 0.5)
    }

    func testTypographyUpdatesCaretWithoutRecreatingTextViewOrChangingOrigins() {
        let view = makeCaretTestView(text: "Typing", fontSize: 14, lineSpacing: 4)
        let textView = view.textView
        let originalOrigin = textView.textContainerOrigin
        let originalPlaceholderOrigin = textView.placeholderOrigin
        textView.ghostText = " suggestion"
        let originalGhostX = textView.insertionPoint(at: 0, layoutManager: textView.layoutManager!, textContainer: textView.textContainer!).x

        configureCaretTestTypography(textView, fontSize: 24, lineSpacing: 16)
        let systemRect = simulatedSystemCaretRect(in: textView, at: (textView.string as NSString).length)
        let caretRect = normalizedCaretRect(in: textView, at: (textView.string as NSString).length, systemRect: systemRect)
        let updatedGhostX = textView.insertionPoint(at: 0, layoutManager: textView.layoutManager!, textContainer: textView.textContainer!).x

        XCTAssertTrue(textView === view.textView)
        XCTAssertEqual(caretRect.height, caretGlyphHeight(in: textView), accuracy: 0.5)
        XCTAssertEqual(textView.textContainerOrigin, originalOrigin)
        XCTAssertEqual(textView.placeholderOrigin, originalPlaceholderOrigin)
        XCTAssertEqual(updatedGhostX, originalGhostX, accuracy: 0.5)
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.insertText("!", replacementRange: textView.selectedRange())
        XCTAssertTrue(textView.string.contains("!"))
    }

    func testMarkerVisualsOnLinesOneAndThreeProduceTwoRuns() {
        let text = "one\ntwo\nthree"
        let ranges = lineRanges(in: text)
        let geometry = markerGeometry(text: text, markers: [marker(.bRoll, in: text, range: ranges[0]), marker(.bRoll, in: text, range: ranges[2])])

        XCTAssertEqual(runs(.bRoll, in: geometry).count, 2)
    }

    func testMarkerVisualsOnLinesOneTwoAndFourMergeOnlyFirstTwo() {
        let text = "one\ntwo\nthree\nfour"
        let ranges = lineRanges(in: text)
        let geometry = markerGeometry(text: text, markers: [marker(.bRoll, in: text, range: ranges[0]), marker(.bRoll, in: text, range: ranges[1]), marker(.bRoll, in: text, range: ranges[3])])
        let visualRuns = runs(.bRoll, in: geometry)

        XCTAssertEqual(visualRuns.count, 3)
    }

    func testMarkerOverlappingRangesProduceOneGroup() {
        let text = "abcdef"
        let first = marker(.bRoll, in: text, range: NSRange(location: 0, length: 4))
        let second = marker(.bRoll, in: text, range: NSRange(location: 2, length: 3))
        let geometry = markerGeometry(text: text, markers: [first, second])

        XCTAssertEqual(runs(.bRoll, in: geometry).count, 1)
        XCTAssertEqual(geometry.renderRuns.first?.itemIDs, [first.itemID, second.itemID])
    }

    func testMarkerTouchingRangesProduceOneGroup() {
        let text = "abcdef"
        let first = marker(.bRoll, in: text, range: NSRange(location: 0, length: 3))
        let second = marker(.bRoll, in: text, range: NSRange(location: 3, length: 3))
        let geometry = markerGeometry(text: text, markers: [first, second])

        XCTAssertNotEqual(first.itemID, second.itemID)
        XCTAssertEqual(runs(.bRoll, in: geometry).count, 1)
        XCTAssertEqual(geometry.renderRuns.first?.itemIDs, [first.itemID, second.itemID])
    }

    func testMarkerDuplicateIdenticalAnchorsDrawOneStripPerMarkerType() {
        let text = "one line"
        let range = NSRange(location: 0, length: 3)
        let geometry = markerGeometry(
            text: text,
            markers: [marker(.bRoll, in: text, range: range), marker(.bRoll, in: text, range: range)]
        )

        XCTAssertEqual(runs(.bRoll, in: geometry).count, 1)
        XCTAssertEqual(geometry.hitRegions.count, 1)
        XCTAssertEqual(geometry.renderRuns.first?.itemIDs.count, 2)
    }

    func testMarkerWhitespaceGapsProduceSeparateGroups() {
        for text in ["one three", "one\tthree", "one\nthree", "one\n\nthree"] {
            let secondStart = (text as NSString).range(of: "three").location
            let geometry = markerGeometry(text: text, markers: [marker(.bRoll, in: text, range: NSRange(location: 0, length: 3)), marker(.bRoll, in: text, range: NSRange(location: secondStart, length: 5))])

            XCTAssertEqual(runs(.bRoll, in: geometry).count, 2, text)
            XCTAssertEqual(geometry.hitRegions.count, 2, text)
        }
    }

    func testMarkerTextGapProducesSeparateGroups() {
        let text = "oneXthree"
        let geometry = markerGeometry(text: text, markers: [marker(.bRoll, in: text, range: NSRange(location: 0, length: 3)), marker(.bRoll, in: text, range: NSRange(location: 4, length: 5))])

        XCTAssertEqual(runs(.bRoll, in: geometry).count, 2)
        XCTAssertEqual(geometry.hitRegions.count, 2)
    }

    func testMarkerUkrainianSeparatedAnchorsRemainSeparateVisualRunsInNarrowTextView() {
        let text = "Всім привіт! Мене звати Микита. Сьогодні б хотів порозмовляти про Лінукс. Чому він краще за вінду, чому тобі слід перейти на нього прямо зараз, і який дистрибутив обрати початківцю."
        let string = text as NSString
        let firstSentence = string.range(of: "Всім привіт!")
        let thirdSentence = string.range(of: "Сьогодні б хотів порозмовляти про Лінукс.")
        let view = makeMarkerTestView(text: text, width: 130)
        view.markers = [marker(.bRoll, in: text, range: firstSentence), marker(.bRoll, in: text, range: thirdSentence)]

        XCTAssertEqual(runs(.bRoll, in: view.documentMarkerGeometry()).count, 2)
    }

    func testMarkerWrappedSentenceProducesContinuousRun() {
        let text = "This deliberately long marked sentence wraps across several rendered TextKit lines."
        let view = makeMarkerTestView(text: text, width: 145)
        view.markers = [marker(.bRoll, in: text, range: NSRange(location: 0, length: (text as NSString).length))]
        let geometry = view.documentMarkerGeometry()

        XCTAssertEqual(runs(.bRoll, in: geometry).count, 1)
        XCTAssertGreaterThan(geometry.hitRegions.count, 1)
    }

    func testMarkerSharingFirstRenderedLineKeepsWrappedRenderAndHitRegionsSeparate() {
        let text = String(repeating: "word ", count: 60)
        let view = makeMarkerTestView(text: text, width: 145)
        let lineRanges = renderedLineRanges(in: view.textView)
        let neighboringRange = NSRange(location: lineRanges[0].location, length: 4)
        let wrappedStart = NSMaxRange(neighboringRange) + 1
        let wrappedEnd = NSMaxRange(lineRanges[3])
        let neighbor = marker(.bRoll, in: text, range: neighboringRange)
        let wrapped = marker(.bRoll, in: text, range: NSRange(location: wrappedStart, length: wrappedEnd - wrappedStart))
        view.markers = [neighbor, wrapped]
        let geometry = view.documentMarkerGeometry()
        let neighborRuns = geometry.renderRuns.filter { $0.itemIDs == [neighbor.itemID] }
        let wrappedRuns = geometry.renderRuns.filter { $0.itemIDs == [wrapped.itemID] }
        let neighborHits = geometry.hitRegions.filter { $0.itemIDs == [neighbor.itemID] }
        let wrappedHits = geometry.hitRegions.filter { $0.itemIDs == [wrapped.itemID] }

        XCTAssertEqual(neighborRuns.count, 1)
        XCTAssertEqual(wrappedRuns.count, 2)
        XCTAssertEqual(neighborHits.count, 1)
        XCTAssertGreaterThan(wrappedHits.count, 1)
        XCTAssertFalse(wrappedRuns.contains { wrappedRun in neighborRuns.contains { $0.documentRect.intersects(wrappedRun.documentRect) } })
        XCTAssertFalse(wrappedHits.contains { wrappedHit in neighborHits.contains { $0.documentRect.intersects(wrappedHit.documentRect) } })
    }

    func testMarkerSharingLastRenderedLineKeepsWrappedRenderAndHitRegionsSeparate() {
        let text = String(repeating: "word ", count: 60)
        let view = makeMarkerTestView(text: text, width: 145)
        let lineRanges = renderedLineRanges(in: view.textView)
        let sharedLastLine = lineRanges[3]
        let neighbor = marker(.bRoll, in: text, range: NSRange(location: NSMaxRange(sharedLastLine) - 4, length: 4))
        let wrapped = marker(.bRoll, in: text, range: NSRange(location: 0, length: neighbor.anchor.startUTF16 - 1))
        view.markers = [wrapped, neighbor]
        let geometry = view.documentMarkerGeometry()
        let neighborRuns = geometry.renderRuns.filter { $0.itemIDs == [neighbor.itemID] }
        let wrappedRuns = geometry.renderRuns.filter { $0.itemIDs == [wrapped.itemID] }
        let neighborHits = geometry.hitRegions.filter { $0.itemIDs == [neighbor.itemID] }
        let wrappedHits = geometry.hitRegions.filter { $0.itemIDs == [wrapped.itemID] }

        XCTAssertEqual(neighborRuns.count, 1)
        XCTAssertEqual(wrappedRuns.count, 2)
        XCTAssertEqual(neighborHits.count, 1)
        XCTAssertGreaterThan(wrappedHits.count, 1)
        XCTAssertFalse(wrappedRuns.contains { wrappedRun in neighborRuns.contains { $0.documentRect.intersects(wrappedRun.documentRect) } })
        XCTAssertFalse(wrappedHits.contains { wrappedHit in neighborHits.contains { $0.documentRect.intersects(wrappedHit.documentRect) } })
    }

    func testMarkerVisualAndEditingUseFixedSeparateLanes() {
        let text = "one\ntwo"
        let ranges = lineRanges(in: text)
        let geometry = markerGeometry(text: text, markers: [marker(.bRoll, in: text, range: ranges[0]), marker(.bRoll, in: text, range: ranges[1]), marker(.editing, in: text, range: ranges[0]), marker(.editing, in: text, range: ranges[1])])
        let visual = try! XCTUnwrap(runs(.bRoll, in: geometry).first)
        let editing = try! XCTUnwrap(runs(.editing, in: geometry).first)

        XCTAssertEqual(visual.documentRect.minX, 2)
        XCTAssertEqual(editing.documentRect.minX, 8)
        XCTAssertGreaterThan(editing.documentRect.minX, visual.documentRect.maxX)
    }

    func testMarkerVisualAndEditingNeverMerge() {
        let text = "one\ntwo"
        let ranges = lineRanges(in: text)
        let geometry = markerGeometry(text: text, markers: [marker(.bRoll, in: text, range: ranges[0]), marker(.bRoll, in: text, range: ranges[1]), marker(.editing, in: text, range: ranges[0]), marker(.editing, in: text, range: ranges[1])])

        XCTAssertEqual(geometry.renderRuns.count, 4)
        XCTAssertEqual(runs(.bRoll, in: geometry).count, 2)
        XCTAssertEqual(runs(.editing, in: geometry).count, 2)
    }

    func testMarkerHitTestingUsesStableGroupItems() {
        let text = "abcdef"
        let first = marker(.bRoll, in: text, range: NSRange(location: 0, length: 4))
        let second = marker(.bRoll, in: text, range: NSRange(location: 2, length: 3))
        let view = makeMarkerTestView(text: text, height: 220)
        view.markers = [first, second]
        let hitRects = view.markerHitRects()

        let group = try! XCTUnwrap(hitRects.first)
        let point = NSPoint(x: group.rect.midX, y: group.rect.midY)
        XCTAssertEqual(group.itemIDs, [first.itemID, second.itemID])
        XCTAssertEqual(view.markerHitTest(at: point)?.itemIDs, [first.itemID, second.itemID])
    }

    func testSameLineSeparatedAnchorsUseDistinctClickableLaneRegions() {
        let text = "one three"
        let first = marker(.bRoll, in: text, range: NSRange(location: 0, length: 3))
        let second = marker(.bRoll, in: text, range: NSRange(location: 4, length: 5))
        let view = makeMarkerTestView(text: text)
        view.markers = [first, second]
        let render = runs(.bRoll, in: view.documentMarkerGeometry())
        let hits = view.markerHitRects().filter { $0.mode == .bRoll }

        XCTAssertEqual(render.count, 2)
        XCTAssertEqual(hits.count, 2)
        XCTAssertNotEqual(render[0].documentRect, render[1].documentRect)
        XCTAssertFalse(hits[0].rect.intersects(hits[1].rect))
        XCTAssertEqual(view.markerHitTest(at: NSPoint(x: hits[0].rect.midX, y: hits[0].rect.midY))?.itemIDs, [first.itemID])
        XCTAssertEqual(view.markerHitTest(at: NSPoint(x: hits[1].rect.midX, y: hits[1].rect.midY))?.itemIDs, [second.itemID])
    }

    func testVisualAndEditingLaneEdgesNeverHitTheOtherLane() {
        let text = "one"
        let visual = marker(.bRoll, in: text, range: NSRange(location: 0, length: 3))
        let editing = marker(.editing, in: text, range: NSRange(location: 0, length: 3))
        let view = makeMarkerTestView(text: text)
        view.markers = [visual, editing]
        let hits = view.markerHitRects()
        let visualHit = try! XCTUnwrap(hits.first { $0.mode == .bRoll })
        let editingHit = try! XCTUnwrap(hits.first { $0.mode == .editing })

        XCTAssertFalse(visualHit.rect.intersects(editingHit.rect))
        XCTAssertEqual(view.markerHitTest(at: NSPoint(x: visualHit.rect.maxX - 0.01, y: visualHit.rect.midY))?.mode, .bRoll)
        XCTAssertEqual(view.markerHitTest(at: NSPoint(x: editingHit.rect.minX, y: editingHit.rect.midY))?.mode, .editing)
    }

    func testMarkerSameLengthTextEditWithDifferentWrappingRebuildsGeometry() {
        let original = "a a a a a a a a a a"
        let replacement = String(repeating: "W", count: (original as NSString).length)
        let view = makeMarkerTestView(text: original, width: 100)
        view.markers = [marker(.bRoll, in: original, range: NSRange(location: 0, length: (original as NSString).length))]
        let before = view.documentMarkerGeometry()

        view.textView.string = replacement
        view.markerTextRevision += 1
        let after = view.documentMarkerGeometry()

        XCTAssertNotEqual(before, after)
    }

    func testMarkerFixedTypographyAndWidthChangesRebuildGeometry() {
        let text = "one two three four five six seven eight nine ten"
        let view = makeMarkerTestView(text: text, width: 180)
        view.markers = [marker(.bRoll, in: text, range: NSRange(location: 0, length: (text as NSString).length))]
        let before = view.documentMarkerGeometry()

        configureCaretTestTypography(view.textView, fontSize: 24, lineSpacing: ScriptEditorLayout.textKitLineSpacing)
        view.cachedFontSize = 24
        let typography = view.documentMarkerGeometry()
        view.frame.size.width = 120
        view.layoutSubtreeIfNeeded()
        let width = view.documentMarkerGeometry()

        XCTAssertNotEqual(before, typography)
        XCTAssertNotEqual(typography, width)
    }

    func testMarkerScrollingOnlyChangesViewportPositions() {
        let text = String(repeating: "line\n", count: 30)
        let ranges = lineRanges(in: text)
        let view = makeMarkerTestView(text: text, width: 220, height: 120)
        view.markers = [marker(.bRoll, in: text, range: ranges[1])]
        let document = view.documentMarkerGeometry()
        let rebuilds = view.markerGeometryRebuildCount
        let before = try! XCTUnwrap(view.markerHitRects().first)

        view.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 12))
        let after = try! XCTUnwrap(view.markerHitRects().first)

        XCTAssertEqual(view.documentMarkerGeometry(), document)
        XCTAssertEqual(view.markerGeometryRebuildCount, rebuilds)
        XCTAssertEqual(after.rect.minY, before.rect.minY + 12, accuracy: 0.5)
    }

    func testMarkerGeometryCacheRebuildsOnlyForGeometryInputs() {
        let text = "one target two"
        let view = makeMarkerTestView(text: text, width: 220)
        let targetRange = (text as NSString).range(of: "target")
        let first = marker(.bRoll, in: text, range: targetRange)
        view.markers = [first]

        _ = view.documentMarkerGeometry()
        XCTAssertEqual(view.markerGeometryRebuildCount, 1)
        _ = view.markerHitRects()
        view.textView.setSelectedRange(NSRange(location: 0, length: 0))
        view.bRollColor = .systemRed
        view.editingColor = .systemOrange
        view.addBRollLabel = "Add"
        view.addEditingLabel = "Edit"
        view.markerNeedsDisplay()
        _ = view.documentMarkerGeometry()
        XCTAssertEqual(view.markerGeometryRebuildCount, 1)

        let sameRangeWithChangedMetadata = ProductionTextMarker(
            itemID: first.itemID,
            mode: first.mode,
            anchor: TextAnchor(startUTF16: targetRange.location, lengthUTF16: targetRange.length, selectedText: "target", prefixContext: "changed", suffixContext: "metadata")
        )
        view.markers = [sameRangeWithChangedMetadata]
        _ = view.documentMarkerGeometry()
        XCTAssertEqual(view.markerGeometryRebuildCount, 1)

        view.markerTextRevision += 1
        _ = view.documentMarkerGeometry()
        XCTAssertEqual(view.markerGeometryRebuildCount, 2)

        view.textView.string = "two target two"
        _ = view.documentMarkerGeometry()
        XCTAssertEqual(view.markerGeometryRebuildCount, 3)

        view.frame.size.width = 180
        view.layoutSubtreeIfNeeded()
        _ = view.documentMarkerGeometry()
        XCTAssertEqual(view.markerGeometryRebuildCount, 4)

        view.cachedFontSize = 17
        _ = view.documentMarkerGeometry()
        XCTAssertEqual(view.markerGeometryRebuildCount, 5)

        view.markers = [marker(.bRoll, in: view.textView.string, range: NSRange(location: 0, length: 3))]
        _ = view.documentMarkerGeometry()
        XCTAssertEqual(view.markerGeometryRebuildCount, 6)

        let duplicateRange = marker(.bRoll, in: view.textView.string, range: NSRange(location: 0, length: 3))
        view.markers.append(duplicateRange)
        _ = view.documentMarkerGeometry()
        XCTAssertEqual(view.markerGeometryRebuildCount, 7)
    }

    func testMarkerInvalidAndZeroLengthAnchorsDrawNothing() {
        let text = "one"
        let geometry = markerGeometry(
            text: text,
            markers: [
                ProductionTextMarker(itemID: UUID(), mode: .bRoll, anchor: TextAnchor(startUTF16: 0, lengthUTF16: 0, selectedText: "")),
                ProductionTextMarker(itemID: UUID(), mode: .editing, anchor: TextAnchor(startUTF16: 100, lengthUTF16: 2, selectedText: "stale"))
            ]
        )

        XCTAssertTrue(geometry.hitRegions.isEmpty)
        XCTAssertTrue(geometry.renderRuns.isEmpty)
    }

    func testMarkerStaleAnchorProducesNoGeometry() {
        let geometry = markerGeometry(
            text: "new text",
            markers: [ProductionTextMarker(itemID: UUID(), mode: .bRoll, anchor: TextAnchor(startUTF16: 0, lengthUTF16: 3, selectedText: "old"))]
        )

        XCTAssertTrue(geometry.hitRegions.isEmpty)
        XCTAssertTrue(geometry.renderRuns.isEmpty)
    }

    func testMarkerRunsUseNarrowRoundedStripStyle() {
        let text = "one"
        let geometry = markerGeometry(text: text, markers: [marker(.bRoll, in: text, range: NSRange(location: 0, length: 3))])

        XCTAssertEqual(try! XCTUnwrap(geometry.renderRuns.first).documentRect.width, 3)
        XCTAssertEqual(TextMarkerStyle.stripWidth, 3)
        XCTAssertEqual(TextMarkerStyle.cornerRadius, 1.5)
    }

    private func makeCaretTestView(
        text: String,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        width: CGFloat = 320,
        height: CGFloat = 160
    ) -> MarkerTextContainerView {
        let view = MarkerTextContainerView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.layoutSubtreeIfNeeded()
        configureCaretTestTypography(view.textView, fontSize: fontSize, lineSpacing: lineSpacing)
        view.textView.string = text
        let attributes = view.textView.typingAttributes
        view.textView.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: (text as NSString).length))
        view.textView.layoutManager?.ensureLayout(for: view.textView.textContainer!)
        return view
    }

    private func makeGhostLayoutTestView(text: String, width: CGFloat, lineFragmentPadding: CGFloat = 0) -> PlaceholderTextView {
        let view = makeCaretTestView(text: text, fontSize: 16, lineSpacing: 5, width: width, height: 120)
        let textView = view.textView
        textView.textContainer?.lineFragmentPadding = lineFragmentPadding
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        return textView
    }

    private func textLayoutMetrics(for textView: PlaceholderTextView) -> (origins: [CGFloat], baselines: [CGFloat]) {
        let layout = textView.layoutManager!
        let container = textView.textContainer!
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(for: container)
        var origins: [CGFloat] = []
        var baselines: [CGFloat] = []
        layout.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphRange, _ in
            guard lineGlyphRange.length > 0 else { return }
            origins.append(textView.textContainerOrigin.y + lineRect.minY)
            baselines.append(textView.textContainerOrigin.y + layout.location(forGlyphAt: lineGlyphRange.location).y)
        }
        return (origins, baselines)
    }

    private func makeMarkerTestView(
        text: String,
        width: CGFloat = 320,
        height: CGFloat = 180
    ) -> MarkerTextContainerView {
        makeCaretTestView(text: text, fontSize: 16, lineSpacing: 4, width: width, height: height)
    }

    private func markerGeometry(text: String, markers: [ProductionTextMarker]) -> MarkerGeometry {
        let view = makeMarkerTestView(text: text)
        view.markers = markers
        return view.documentMarkerGeometry()
    }

    private func renderedLineRanges(in textView: NSTextView) -> [NSRange] {
        guard let layout = textView.layoutManager,
              let container = textView.textContainer else {
            return []
        }
        layout.ensureLayout(for: container)
        let glyphRange = layout.glyphRange(for: container)
        var ranges: [NSRange] = []
        layout.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, lineGlyphRange, _ in
            let range = layout.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
            if range.length > 0 {
                ranges.append(range)
            }
        }
        return ranges
    }

    private func marker(_ mode: WorkspaceMode, in text: String, range: NSRange) -> ProductionTextMarker {
        ProductionTextMarker(
            itemID: UUID(),
            mode: mode,
            anchor: TextAnchorRepair.anchor(in: text, range: range)!
        )
    }

    private func runs(_ mode: WorkspaceMode, in geometry: MarkerGeometry) -> [DocumentMarkerRect] {
        geometry.renderRuns.filter { $0.mode == mode }
    }

    private func lineRanges(in text: String) -> [NSRange] {
        let lines = text.components(separatedBy: "\n")
        var offset = 0
        return lines.map { line in
            defer { offset += (line as NSString).length + 1 }
            return NSRange(location: offset, length: (line as NSString).length)
        }
    }

    private func configureCaretTestTypography(_ textView: PlaceholderTextView, fontSize: CGFloat, lineSpacing: CGFloat) {
        let font = NSFont.systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        textView.font = font
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: font, .paragraphStyle: paragraph]
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttributes(textView.typingAttributes, range: NSRange(location: 0, length: storage.length))
        }
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
    }

    private func normalizedCaretRect(in textView: PlaceholderTextView, at index: Int, systemRect: NSRect) -> NSRect {
        textView.setSelectedRange(NSRange(location: index, length: 0))
        return textView.normalizedInsertionCaretRect(systemRect)
    }

    private func simulatedSystemCaretRect(in textView: PlaceholderTextView, at index: Int) -> NSRect {
        let layout = textView.layoutManager!
        let container = textView.textContainer!
        layout.ensureLayout(for: container)
        let length = (textView.string as NSString).length
        if index == length, !layout.extraLineFragmentRect.isEmpty {
            return layout.extraLineFragmentRect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        }
        guard length > 0 else {
            return NSRect(
                x: textView.textContainerOrigin.x,
                y: textView.textContainerOrigin.y,
                width: 1,
                height: layout.defaultLineHeight(for: textView.font!) + (textView.defaultParagraphStyle?.lineSpacing ?? 0)
            )
        }
        let glyph = layout.glyphIndexForCharacter(at: min(max(0, index), length - 1))
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
    }

    private func lineStartIndices(in textView: PlaceholderTextView) -> [Int] {
        let layout = textView.layoutManager!
        let container = textView.textContainer!
        layout.ensureLayout(for: container)
        let length = (textView.string as NSString).length
        var starts: [Int] = []
        var lineOrigins = Set<CGFloat>()
        for index in 0..<length {
            let glyph = layout.glyphIndexForCharacter(at: index)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            if lineOrigins.insert(line.minY).inserted { starts.append(index) }
        }
        return starts
    }

    private func expectedCaretOriginY(in textView: PlaceholderTextView, at index: Int, systemRect: NSRect) -> CGFloat {
        let font = textView.font!
        let height = caretGlyphHeight(in: textView)
        let length = (textView.string as NSString).length
        let layout = textView.layoutManager!
        if index == length {
            if length == 0 || (textView.string as NSString).character(at: length - 1) == 10 || (textView.string as NSString).character(at: length - 1) == 13 {
                let line = layout.extraLineFragmentRect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
                return min(max(line.minY, line.minY), line.maxY - height)
            }
            let glyph = layout.glyphIndexForCharacter(at: length - 1)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            let glyphTop = textView.textContainerOrigin.y + layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + layout.location(forGlyphAt: glyph).y - font.ascender
            return min(max(glyphTop, line.minY), line.maxY - height)
        }
        let glyph = layout.glyphIndexForCharacter(at: index)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        let glyphTop = textView.textContainerOrigin.y + layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + layout.location(forGlyphAt: glyph).y - font.ascender
        return min(max(glyphTop, line.minY), line.maxY - height)
    }

    private func caretGlyphHeight(in textView: PlaceholderTextView) -> CGFloat {
        let font = textView.font!
        return font.ascender - font.descender
    }

    private func makeCoordinator(box: TextBox) -> (LinkedScriptTextView.Coordinator, MarkerTextContainerView) {
        let parent = makeRepresentable(text: Binding(get: { box.value }, set: { box.value = $0 }))
        let coordinator = LinkedScriptTextView.Coordinator(parent: parent)
        let view = MarkerTextContainerView()
        coordinator.attach(to: view)
        coordinator.applyModelTextIfNeeded()
        return (coordinator, view)
    }

    private func makeAutocompleteCoordinator(
        text: String,
        recorder: AutocompleteRequestRecorder
    ) -> (LinkedScriptTextView.Coordinator, MarkerTextContainerView) {
        let box = TextBox(text)
        let parent = makeRepresentable(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            autocomplete: { @MainActor context in await recorder.request(context) }
        )
        let coordinator = LinkedScriptTextView.Coordinator(parent: parent)
        let view = MarkerTextContainerView()
        coordinator.attach(to: view)
        view.textView.delegate = coordinator
        view.textView.string = text
        return (coordinator, view)
    }

    private func makeRepresentable(
        text: Binding<String>,
        autocompleteConfigurationVersion: Int = 0,
        autocompleteConfigurationEligibility: AutocompleteConfigurationEligibility = .eligible,
        loadState: @escaping () -> ScriptEditorRestorationState? = { nil },
        saveState: @escaping (ScriptEditorRestorationState) -> Void = { _ in },
        onTextCommitted: @escaping (String, String) -> Void = { _, _ in },
        autocomplete: @escaping @MainActor (AutocompleteContext) async -> AutocompleteResult = { _ in .none },
        onTeardown: @escaping () -> Void = {}
    ) -> LinkedScriptTextView {
        LinkedScriptTextView(
            text: text,
            sceneID: UUID(),
            editorIdentity: UUID(),
            sceneTitle: "Scene",
            autocompleteProvider: .openAICompatible,
            autocompleteConfigurationVersion: autocompleteConfigurationVersion,
            autocompleteConfigurationEligibility: autocompleteConfigurationEligibility,
            autocompleteDelay: .zero,
            autocompleteFallbackLanguage: .english,
            autocompleteState: .constant(.idle),
            loadRestorationState: loadState,
            saveRestorationState: saveState,
            markers: [],
            fontSize: 16,
            spellcheck: false,
            smartQuotes: false,
            placeholder: "Placeholder",
            textColor: .labelColor,
            placeholderColor: .secondaryLabelColor,
            backgroundColor: .textBackgroundColor,
            bRollColor: .systemBlue,
            editingColor: .systemGreen,
            addBRollLabel: "Add Visual",
            addEditingLabel: "Editing",
            onTextCommitted: onTextCommitted,
            autocomplete: autocomplete,
            onTeardown: onTeardown,
            markerAction: { _, _ in },
            addMarkerAction: { _, _ in }
        )
    }

    private func makeAppState(
        project: FrameProject? = nil,
        fileURL: URL?,
        dependencies: AppDependencies = .live,
        hasAutocompleteStoredKey: Bool = false,
        projectWriter: @escaping (FrameProject, URL) throws -> Void = FrameScriptFileStore.write
    ) -> (AppState, FrameScript.Scene, UserDefaults) {
        let scene = project?.scenes.first ?? Scene(order: 0, sectionType: .custom, title: "Scene", scriptText: "")
        let project = project ?? FrameProject(title: "Project", scenes: [scene])
        let store = ProjectStore(project: project, projectWriter: projectWriter)
        store.openProject(project, fileURL: fileURL, wordsPerMinute: 150, markUnsaved: false)
        let suite = UserDefaults(suiteName: "EditorPersistenceTests-\(UUID().uuidString)")!
        let configurationStore = AIProviderConfigurationStore(userDefaults: suite)
        configurationStore.setHasStoredKey(hasAutocompleteStoredKey, for: .openAICompatible)
        var settings = AppSettings.defaults
        settings.generalPreferences.autosaveEnabled = true
        let appState = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            editorState: EditorState(),
            settingsStore: SettingsStore(settings: settings, userDefaults: suite, key: "settings"),
            dependencies: dependencies,
            aiProviderConfigurationStore: configurationStore
        )
        appState.editorState.selectedSceneID = scene.id
        appState.editorState.selectedMode = .script
        return (appState, scene, suite)
    }

    private func makeCoordinator(appState: AppState, scene: FrameScript.Scene) -> (LinkedScriptTextView.Coordinator, MarkerTextContainerView) {
        let parent = makeRepresentable(
            text: Binding(get: { scene.scriptText }, set: { _ in }),
            onTextCommitted: { previousText, text in appState.commitScriptTextChange(sceneID: scene.id, previousText: previousText, text: text) }
        )
        let coordinator = LinkedScriptTextView.Coordinator(parent: parent)
        let view = MarkerTextContainerView()
        coordinator.attach(to: view)
        coordinator.applyModelTextIfNeeded()
        return (coordinator, view)
    }

    private func temporaryProjectURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorPersistenceTests-\(UUID().uuidString).fscr")
    }

    private func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    /// Waits for the debounced metrics cache entry. Duration alone can be
    /// updated earlier by the segment rebuild, so cache tests must wait for
    /// the parse itself.
    private func waitForSceneMetricsEntry(
        of scene: FrameScript.Scene,
        timeout: Duration = .seconds(3)
    ) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while SceneMetricsCache.shared.entry(for: scene.id) == nil {
            guard clock.now - start < timeout else {
                XCTFail("Timed out waiting for debounced scene metrics")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Waits for the debounced scene metrics to land. The text path never
    /// parses the whole script synchronously, so tests must let the debouncer
    /// run instead of asserting immediately after a keystroke.
    private func waitForDebouncedDuration(
        of scene: FrameScript.Scene,
        _ expected: TimeInterval,
        timeout: Duration = .seconds(3)
    ) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while abs(scene.estimatedDuration - expected) > 0.001 {
            guard clock.now - start < timeout else {
                XCTFail("Timed out waiting for debounced duration \(scene.estimatedDuration) == \(expected)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        message: String = "editor delegate flow",
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while !condition() {
            guard clock.now - start < timeout else {
                XCTFail("Timed out waiting for \(message)")
                throw NSError(domain: "EditorPersistenceTests", code: 1)
            }
            await Task.yield()
        }
    }

    private func keyEvent(keyCode: UInt16, characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
