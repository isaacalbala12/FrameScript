import Foundation
@testable import FrameScript
import XCTest

@MainActor
final class DuplicateCoverageTests: XCTestCase {
    func testDuplicateProjectCopiesEveryStoredProperty() throws {
        let source = try DocumentMappingTests.makeFullProject()
        source.scenes.first?.order = 0
        let store = ProjectStore(project: source)

        let copy = store.duplicateProject(copySuffix: "copy")

        assertMirrorEqual(source, copy, path: "project", ignoredAtRoot: ["title"])
    }

    func testDuplicateSceneCopiesEveryStoredProperty() throws {
        let sourceProject = try DocumentMappingTests.makeFullProject()
        let sourceScene = try XCTUnwrap(sourceProject.scenes.first)
        sourceScene.order = 0
        let store = ProjectStore(project: FrameProject(title: "Empty", scenes: []))

        let copy = store.duplicate(sourceScene, copySuffix: "copy")

        assertMirrorEqual(sourceScene, copy, path: "scene", ignoredAtRoot: ["title"])
    }

    // MARK: Mirror comparator

    private let identityLabels: Set<String> = [
        "id", "sceneID", "segmentID", "linkedSegmentID",
        "sourceIDs", "sceneIDs", "linkedSceneIDs", "linkedBRollItemIDs", "linkedTakeIDs",
        "assetID", "sourceSceneIDs", "anchorSceneID", "sceneSourceHashes"
    ]

    private func assertMirrorEqual(
        _ source: Any,
        _ copy: Any,
        path: String,
        ignoredAtRoot: Set<String> = []
    ) {
        let sourceMirror = Mirror(reflecting: source)
        let copyMirror = Mirror(reflecting: copy)

        if sourceMirror.displayStyle == .optional || copyMirror.displayStyle == .optional {
            guard let sourceValue = sourceMirror.children.first?.value,
                  let copyValue = copyMirror.children.first?.value else {
                XCTAssertEqual(
                    sourceMirror.children.count,
                    copyMirror.children.count,
                    "Optional mismatch at \(path)"
                )
                return
            }
            assertMirrorEqual(sourceValue, copyValue, path: path)
            return
        }

        if let source = source as? String, let copy = copy as? String {
            XCTAssertEqual(copy, source, "String mismatch at \(path)")
            return
        }
        if let source = source as? Bool, let copy = copy as? Bool {
            XCTAssertEqual(copy, source, "Bool mismatch at \(path)")
            return
        }
        if let source = source as? Int, let copy = copy as? Int {
            XCTAssertEqual(copy, source, "Int mismatch at \(path)")
            return
        }
        if let source = source as? Int64, let copy = copy as? Int64 {
            XCTAssertEqual(copy, source, "Int64 mismatch at \(path)")
            return
        }
        if let source = source as? Double, let copy = copy as? Double {
            XCTAssertEqual(copy, source, accuracy: 0.000_001, "Double mismatch at \(path)")
            return
        }
        if let source = source as? Date, let copy = copy as? Date {
            XCTAssertEqual(copy, source, "Date mismatch at \(path)")
            return
        }
        if let source = source as? Data, let copy = copy as? Data {
            XCTAssertEqual(copy, source, "Data mismatch at \(path)")
            return
        }
        if let source = source as? UUID, let copy = copy as? UUID {
            XCTAssertEqual(copy, source, "UUID mismatch at \(path)")
            return
        }
        if sourceMirror.displayStyle == .enum {
            XCTAssertEqual(
                String(describing: copy),
                String(describing: source),
                "Enum mismatch at \(path)"
            )
            return
        }

        if sourceMirror.displayStyle == .collection {
            let sourceElements = Array(sourceMirror.children)
            let copyElements = Array(copyMirror.children)
            XCTAssertEqual(
                copyElements.count,
                sourceElements.count,
                "Collection count mismatch at \(path)"
            )
            for (sourceChild, copyChild) in zip(sourceElements, copyElements) {
                assertMirrorEqual(sourceChild.value, copyChild.value, path: "\(path)[]")
            }
            return
        }

        if sourceMirror.displayStyle == .dictionary {
            var copyEntries: [String: Any] = [:]
            for child in copyMirror.children {
                let tuple = Array(Mirror(reflecting: child.value).children)
                guard tuple.count == 2 else { continue }
                copyEntries[String(describing: tuple[0].value)] = tuple[1].value
            }
            for child in sourceMirror.children {
                let tuple = Array(Mirror(reflecting: child.value).children)
                guard tuple.count == 2 else { continue }
                let key = String(describing: tuple[0].value)
                guard let copyValue = copyEntries.removeValue(forKey: key) else {
                    XCTFail("Missing dictionary key \(key) at \(path)")
                    continue
                }
                assertMirrorEqual(tuple[1].value, copyValue, path: "\(path)[\(key)]")
            }
            XCTAssertTrue(copyEntries.isEmpty, "Unexpected dictionary keys at \(path)")
            return
        }

        let childLabels = sourceMirror.children.compactMap { $0.label.map(normalizedLabel) }
        var copyChildren: [String: Any] = [:]
        for child in copyMirror.children {
            guard let label = child.label else { continue }
            copyChildren[normalizedLabel(label)] = child.value
        }

        for child in sourceMirror.children {
            guard let rawLabel = child.label else { continue }
            let label = normalizedLabel(rawLabel)
            if path == "project" || path == "scene", ignoredAtRoot.contains(label) {
                copyChildren.removeValue(forKey: label)
                continue
            }
            if isIdentityLabel(label) {
                assertIDShapePreserved(
                    source: child.value,
                    copy: copyChildren[label],
                    label: label,
                    path: path
                )
                copyChildren.removeValue(forKey: label)
                continue
            }
            guard let copyValue = copyChildren.removeValue(forKey: label) else {
                XCTFail("Missing stored property \(label) at \(path) (source labels: \(childLabels))")
                continue
            }
            assertMirrorEqual(child.value, copyValue, path: "\(path).\(label)")
        }
        XCTAssertTrue(copyChildren.isEmpty, "Unexpected properties at \(path): \(copyChildren.keys.sorted())")
    }

    private func normalizedLabel(_ label: String) -> String {
        label.hasPrefix("_") ? String(label.dropFirst()) : label
    }

    private func isIdentityLabel(_ label: String) -> Bool {
        identityLabels.contains(label)
    }

    private func assertIDShapePreserved(source: Any, copy: Any?, label: String, path: String) {
        guard let copy else {
            XCTFail("Missing identity property \(label) at \(path)")
            return
        }
        let sourceMirror = Mirror(reflecting: source)
        let copyMirror = Mirror(reflecting: copy)
        if sourceMirror.displayStyle == .collection {
            let sourceCount = sourceMirror.children.count
            XCTAssertEqual(copyMirror.children.count, sourceCount, "Identity count mismatch \(path).\(label)")
        } else if sourceMirror.displayStyle == .optional {
            XCTAssertEqual(
                copyMirror.children.count,
                sourceMirror.children.count,
                "Identity presence mismatch \(path).\(label)"
            )
        }
    }
}

extension DuplicateCoverageTests {
    func testCopySurfaceMatchesFrozenSchema() throws {
        let project = try DocumentMappingTests.makeFullProject()
        let scene = try XCTUnwrap(project.scenes.first)
        let visual = try XCTUnwrap(scene.bRollItems.first)
        let edit = try XCTUnwrap(scene.editingItems.first)
        let take = try XCTUnwrap(scene.takes.first)
        let asset = try XCTUnwrap(project.assets.first)
        let pack = try XCTUnwrap(project.publishingPacks["es"])
        let clip = try XCTUnwrap(project.clips.first)
        let comparison = try XCTUnwrap(project.publishedVideos["es"])

        XCTAssertEqual(storedLabels(project), [
            "id", "title", "createdAt", "updatedAt", "templateID", "settingsOverride",
            "exportPresets", "scenes", "primaryLanguage", "topic", "videoType",
            "productionStatus", "targetDate", "publishDate", "targetDuration",
            "learnedWordsPerMinuteByLanguage", "assets", "publishingPacks",
            "checklistTasks", "rhythmThresholdsOverride", "sources", "claims",
            "comparisonTables", "glossary", "clips", "versionHistory", "aiThreadMap",
            "unparsedSections", "publishedVideos"
        ])
        XCTAssertEqual(storedLabels(scene), [
            "id", "order", "sectionType", "title", "scriptText", "notes",
            "estimatedDuration", "textSegments", "aiComments", "bRollItems",
            "editingItems", "targetDuration", "takes", "languageVariants", "obsSceneName"
        ])
        XCTAssertEqual(storedLabels(visual), [
            "id", "textAnchor", "linkedSegmentID", "templateType", "sourceType",
            "descriptionText", "mood", "framing", "motion", "duration", "notes", "status"
        ])
        XCTAssertEqual(storedLabels(edit), [
            "id", "textAnchor", "linkedSegmentID", "templateType", "cutStyle",
            "transition", "subtitleStyle", "emphasis", "zoom", "sfx", "musicCue",
            "graphics", "notes", "status"
        ])
        XCTAssertEqual(storedLabels(take), [
            "id", "number", "startedAt", "duration", "filePath", "bookmarkData",
            "rating", "note", "languageCode", "readText", "sceneTextHash"
        ])
        XCTAssertEqual(storedLabels(asset), [
            "id", "path", "bookmarkData", "kind", "tags", "linkedSceneIDs",
            "linkedBRollItemIDs", "linkedTakeIDs", "isCopiedIntoProject", "duration",
            "fileSize", "modifiedAt", "isLastKnownMissing"
        ])
        XCTAssertEqual(storedLabels(pack), [
            "titleCandidates", "chosenTitle", "description", "tags", "hashtags",
            "pinnedComment", "communityPost", "chapterOverrides", "thumbnailVariants",
            "thumbnailConceptNotes"
        ])
        XCTAssertEqual(storedLabels(clip), [
            "id", "title", "sourceSceneIDs", "anchorSceneID", "anchor", "hook",
            "adaptedText", "targetSeconds", "format", "onScreenText", "description",
            "hashtags", "sourceHash", "languageCode", "sceneSourceHashes", "status"
        ])
        XCTAssertEqual(storedLabels(comparison), [
            "videoID", "url", "title", "publishedAt", "transcriptSegments",
            "retentionPoints", "sceneResults", "learnings", "importedAt"
        ])
    }

    private func storedLabels(_ value: Any) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap { child in
            guard let label = child.label.map(normalizedLabel) else { return nil }
            return label.hasPrefix("$") ? nil : label
        })
    }
}
