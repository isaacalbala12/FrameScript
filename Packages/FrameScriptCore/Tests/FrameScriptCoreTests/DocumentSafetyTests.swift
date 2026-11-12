import Foundation
import Testing
@testable import FrameScriptCore
#if canImport(Darwin)
import Darwin
#endif

@Suite("Document safety and compatibility")
struct DocumentSafetyTests {
    // MARK: Real v3 fixture shape

    @Test("v3 fixture contains only fields the bb4a8e2 writer emitted")
    func v3FixtureMatchesOldWriterShape() throws {
        let root = try fixtureJSON("v3-full.fscr")
        let project = try #require(root["project"] as? [String: Any])
        let scenes = try #require(project["scenes"] as? [[String: Any]])
        let scene = try #require(scenes.first)
        let visuals = try #require(scene["bRollItems"] as? [[String: Any]])
        let visual = try #require(visuals.first)
        let edits = try #require(scene["editingItems"] as? [[String: Any]])
        let edit = try #require(edits.first)
        let segments = try #require(scene["textSegments"] as? [[String: Any]])
        let segment = try #require(segments.first)
        let comments = try #require(scene["aiComments"] as? [[String: Any]])
        let comment = try #require(comments.first)

        #expect(Set(project.keys) == Set([
            "id", "title", "createdAt", "updatedAt", "templateID", "exportPresets", "scenes"
        ]))
        #expect(Set(scene.keys) == Set([
            "id", "order", "sectionType", "title", "scriptText", "notes",
            "estimatedDuration", "textSegments", "aiComments", "bRollItems", "editingItems"
        ]))
        #expect(Set(visual.keys) == Set([
            "id", "textAnchor", "sourceType", "descriptionText", "notes"
        ]))
        #expect(Set(edit.keys) == Set([
            "id", "textAnchor", "description", "notes"
        ]))
        #expect(Set(segment.keys) == Set([
            "id", "sceneID", "order", "sourceText", "segmentType", "timingEstimate"
        ]))
        #expect(Set(comment.keys) == Set([
            "id", "sceneID", "segmentID", "type", "severity", "message", "suggestion", "status"
        ]))
    }

    @Test("Legacy cutStyle key remains readable")
    func legacyCutStyleKeyDecodes() throws {
        var root = try fixtureJSON("v3-full.fscr")
        var project = try #require(root["project"] as? [String: Any])
        var scenes = try #require(project["scenes"] as? [[String: Any]])
        var scene = scenes[0]
        var edits = try #require(scene["editingItems"] as? [[String: Any]])
        var edit = edits[0]
        let description = try #require(edit.removeValue(forKey: "description") as? String)
        edit["cutStyle"] = description
        edits[0] = edit
        scene["editingItems"] = edits
        scenes[0] = scene
        project["scenes"] = scenes
        root["project"] = project

        let data = try JSONSerialization.data(withJSONObject: root)
        let document = try FrameScriptDocumentCodec.decode(data)
        #expect(document.project.scenes.first?.editingItems.first?.cutStyle == "hard cut")
    }

    // MARK: v4 identity

    @Test("v4 decode is identity even for non-canonical but valid anchors")
    func v4DecodeIsIdentity() throws {
        let anchor = FrameScriptDocument.TextAnchor(
            startUTF16: 6,
            lengthUTF16: 6,
            selectedText: "target",
            prefixContext: "custom prefix",
            suffixContext: "custom suffix"
        )
        let document = makeDocument(
            fileVersion: 4,
            text: "alpha target omega",
            anchors: [anchor]
        )

        let decoded = try FrameScriptDocumentCodec.decode(try FrameScriptDocumentCodec.encode(document))
        #expect(decoded == document)
        #expect(decoded.project.scenes.first?.bRollItems.first?.textAnchor == anchor)
    }

    // MARK: Corrupt anchors

    @Test("Corrupt anchors throw or clear but never crash")
    func corruptAnchorsAreSafe() throws {
        let text = "alpha target omega"
        let values = [
            Int.max, Int.max - 1, Int.min, Int.min + 1,
            -1, 0, 1, 18, 19
        ]

        for version in [1, 4] {
            for start in values {
                for length in values {
                    let data = try anchorJSON(version: version, text: text, start: start, length: length)
                    do {
                        let document = try FrameScriptDocumentCodec.decode(data)
                        if version == 1 {
                            let anchor = document.project.scenes.first?.bRollItems.first?.textAnchor
                            if let anchor {
                                #expect(anchor.startUTF16 >= 0)
                                #expect(anchor.lengthUTF16 >= 0)
                                #expect(anchor.startUTF16 <= (text as NSString).length)
                                #expect(anchor.lengthUTF16 <= (text as NSString).length - anchor.startUTF16)
                            }
                        }
                    } catch let error as FrameScriptDocumentError {
                        #expect(error == .invalidAnchor)
                    } catch {
                        Issue.record("Unexpected error type: \(error)")
                    }
                }
            }
        }
    }

    // MARK: Context snapping

    @Test("Anchor contexts never split a grapheme cluster")
    func contextsSnapToComposedCharacters() throws {
        let family = "👨‍👩‍👧‍👦"
        let text = String(repeating: "a", count: 40) + family + String(repeating: "b", count: 40) + "TARGET"
        let full = text as NSString
        let range = full.range(of: "TARGET")
        let anchor = try #require(FrameScriptDocument.TextAnchorRepair.anchor(in: text, range: range))

        #expect(!anchor.prefixContext.contains("\u{FFFD}"))
        #expect(!anchor.suffixContext.contains("\u{FFFD}"))
        #expect(text.contains(anchor.prefixContext + anchor.selectedText + anchor.suffixContext))
        #expect(anchor.prefixContext.utf16.count <= 64)
        #expect(anchor.suffixContext.utf16.count <= 64)

        let prefixUnits = Array(anchor.prefixContext.utf16)
        if let last = prefixUnits.last {
            #expect(!(0xD800...0xDBFF).contains(last), "prefix ends on a high surrogate")
        }
        let suffixUnits = Array(anchor.suffixContext.utf16)
        if let first = suffixUnits.first {
            #expect(!(0xDC00...0xDFFF).contains(first), "suffix starts on a low surrogate")
        }
    }

    // MARK: Dates and metadata

    @Test("Dates keep fractional seconds and plain ISO-8601 still decodes")
    func datesKeepFractionalSeconds() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000.125)
        let document = makeDocument(fileVersion: 4, text: "text", anchor: nil, createdAt: date)

        let data = try FrameScriptDocumentCodec.encode(document)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(".125"))
        let decoded = try FrameScriptDocumentCodec.decode(data)
        #expect(abs(decoded.project.createdAt.timeIntervalSince1970 - date.timeIntervalSince1970) < 0.001)
        #expect(decoded == document)

        let plain = FrameScriptDocumentCodec.date(fromISO8601: "2024-01-01T10:00:00Z")
        #expect(plain?.timeIntervalSince1970 == 1_704_103_200)
    }

    @Test("Atomic write preserves extended attributes")
    func atomicWritePreservesExtendedAttributes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameScriptCore-xattr-\(UUID().uuidString).fscr")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("old".utf8).write(to: url)

        let attributeName = "com.framescript.test"
        let attributeValue = Data([0x01, 0x02, 0x03, 0xFE])
        try setExtendedAttribute(attributeName, value: attributeValue, at: url)

        try FrameScriptDocumentCodec.write(makeDocument(fileVersion: 4, text: "text", anchor: nil), to: url)

        #expect(try extendedAttribute(attributeName, at: url) == attributeValue)
        #expect(try FrameScriptDocumentCodec.read(from: url).project.title == "Minimal project")
    }

    // MARK: Stale-anchor performance

    @Test("100 stale anchors on a 10 MB script repair well under 500 ms")
    func staleAnchorRepairIsBounded() throws {
        let repeated = String(repeating: "lorem ipsum dolor sit amet ", count: 380_000)
        let sceneID = UUID()
        let items = (0..<100).map { index in
            FrameScriptDocument.BRollItem(
                id: UUID(),
                textAnchor: FrameScriptDocument.TextAnchor(
                    startUTF16: 1,
                    lengthUTF16: 5,
                    selectedText: "needle-\(index)",
                    prefixContext: "prefix-\(index)",
                    suffixContext: "suffix-\(index)"
                ),
                sourceType: .custom,
                descriptionText: "stale \(index)"
            )
        }
        let scene = FrameScriptDocument.Scene(
            id: sceneID,
            order: 0,
            sectionType: .custom,
            title: "Large",
            scriptText: repeated,
            bRollItems: items
        )
        let document = FrameScriptDocument(
            fileVersion: 1,
            project: FrameScriptDocument.Project(title: "Large project", scenes: [scene])
        )
        let data = try FrameScriptDocumentCodec.encode(document)

        let clock = ContinuousClock()
        let started = clock.now
        let decoded = try FrameScriptDocumentCodec.decode(data)
        let elapsed = clock.now - started

        #expect(decoded.project.scenes.first?.bRollItems.count == 100)
        #expect(elapsed < .milliseconds(500), "Stale anchor repair took \(elapsed)")
    }

    // MARK: Helpers

    private func fixtureJSON(_ name: String) throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Document"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try #require(object as? [String: Any])
    }

    private func makeDocument(
        fileVersion: Int,
        text: String,
        anchor: FrameScriptDocument.TextAnchor?,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> FrameScriptDocument {
        let sceneID = UUID()
        let item = FrameScriptDocument.BRollItem(
            id: UUID(),
            textAnchor: anchor,
            sourceType: .custom,
            descriptionText: "visual"
        )
        let scene = FrameScriptDocument.Scene(
            id: sceneID,
            order: 0,
            sectionType: .custom,
            title: "Scene",
            scriptText: text,
            bRollItems: [item]
        )
        return FrameScriptDocument(
            fileVersion: fileVersion,
            project: FrameScriptDocument.Project(
                title: "Minimal project",
                createdAt: createdAt,
                updatedAt: createdAt,
                scenes: [scene]
            )
        )
    }

    private func makeDocument(
        fileVersion: Int,
        text: String,
        anchors: [FrameScriptDocument.TextAnchor]
    ) -> FrameScriptDocument {
        let sceneID = UUID()
        let items = anchors.map {
            FrameScriptDocument.BRollItem(textAnchor: $0, sourceType: .custom, descriptionText: "visual")
        }
        let scene = FrameScriptDocument.Scene(
            id: sceneID,
            order: 0,
            sectionType: .custom,
            title: "Scene",
            scriptText: text,
            bRollItems: items
        )
        return FrameScriptDocument(
            fileVersion: fileVersion,
            project: FrameScriptDocument.Project(
                title: "Minimal project",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                scenes: [scene]
            )
        )
    }

    private func anchorJSON(version: Int, text: String, start: Int, length: Int) throws -> Data {
        let payload: [String: Any] = [
            "fileVersion": version,
            "project": [
                "id": UUID().uuidString,
                "title": "Corrupt anchor",
                "createdAt": "2024-01-01T10:00:00Z",
                "updatedAt": "2024-01-01T10:00:00Z",
                "scenes": [
                    [
                        "id": UUID().uuidString,
                        "order": 0,
                        "sectionType": "Custom",
                        "title": "Scene",
                        "scriptText": text,
                        "bRollItems": [
                            [
                                "id": UUID().uuidString,
                                "textAnchor": [
                                    "startUTF16": start,
                                    "lengthUTF16": length,
                                    "selectedText": "target",
                                    "prefixContext": "",
                                    "suffixContext": ""
                                ],
                                "sourceType": "Custom",
                                "descriptionText": "visual",
                                "notes": ""
                            ]
                        ]
                    ]
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func setExtendedAttribute(_ name: String, value: Data, at url: URL) throws {
        #if canImport(Darwin)
        let result = url.path.withCString { path in
            name.withCString { namePointer in
                value.withUnsafeBytes { buffer in
                    setxattr(path, namePointer, buffer.baseAddress, value.count, 0, 0)
                }
            }
        }
        #expect(result == 0)
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    private func extendedAttribute(_ name: String, at url: URL) throws -> Data {
        #if canImport(Darwin)
        let size = url.path.withCString { path in
            name.withCString { namePointer in
                getxattr(path, namePointer, nil, 0, 0, 0)
            }
        }
        guard size > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: size)
        let read = url.path.withCString { path in
            name.withCString { namePointer in
                bytes.withUnsafeMutableBytes { buffer in
                    getxattr(path, namePointer, buffer.baseAddress, size, 0, 0)
                }
            }
        }
        return Data(bytes.prefix(max(0, read)))
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }
}
