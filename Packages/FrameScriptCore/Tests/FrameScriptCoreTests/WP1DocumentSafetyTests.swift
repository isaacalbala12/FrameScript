import Foundation
import Testing
@testable import FrameScriptCore

/// WP1 regression tests: files that used to be unopenable (unknown enum values,
/// out-of-range version-4 anchors, missing `scenes`) and saves through symlinks.
@Suite("WP1 document safety")
struct WP1DocumentSafetyTests {
    // MARK: Unknown enum values

    @Test("Unknown persisted enum values fall back instead of failing the whole file")
    func unknownEnumRawValuesFallBack() throws {
        let data = try minimalJSON { project in
            var project = project
            var scenes = try #require(project["scenes"] as? [[String: Any]])
            var scene = scenes[0]
            scene["sectionType"] = "Futuristic section"
            var segments = try #require(scene["textSegments"] as? [[String: Any]])
            segments[0]["segmentType"] = "word"
            scene["textSegments"] = segments
            var visuals = try #require(scene["bRollItems"] as? [[String: Any]])
            visuals[0]["sourceType"] = "Hologram"
            visuals[0]["status"] = "Rendered"
            scene["bRollItems"] = visuals
            var edits = try #require(scene["editingItems"] as? [[String: Any]])
            edits[0]["status"] = "Exported"
            scene["editingItems"] = edits
            var comments = try #require(scene["aiComments"] as? [[String: Any]])
            comments[0]["severity"] = "critical"
            comments[0]["status"] = "archived"
            scene["aiComments"] = comments
            var takes = try #require(scene["takes"] as? [[String: Any]])
            takes[0]["rating"] = "perfect"
            scene["takes"] = takes
            scenes[0] = scene
            project["scenes"] = scenes
            project["productionStatus"] = "released"
            var assets = try #require(project["assets"] as? [[String: Any]])
            assets[0]["kind"] = "hologram"
            project["assets"] = assets
            var claims = try #require(project["claims"] as? [[String: Any]])
            claims[0]["status"] = "certain"
            project["claims"] = claims
            var tasks = try #require(project["checklistTasks"] as? [[String: Any]])
            tasks[0]["kind"] = "chore"
            project["checklistTasks"] = tasks
            var clips = try #require(project["clips"] as? [[String: Any]])
            clips[0]["format"] = "minidoc"
            clips[0]["status"] = "archived"
            project["clips"] = clips
            var presets = try #require(project["exportPresets"] as? [[String: Any]])
            presets[0]["format"] = "telepathy"
            project["exportPresets"] = presets
            project["settingsOverride"] = ["defaultSplitMode": "word"]
            return project
        }

        let document = try FrameScriptDocumentCodec.decode(data)
        let scene = try #require(document.project.scenes.first)
        #expect(scene.sectionType == .custom)
        #expect(scene.textSegments.first?.segmentType == .scene)
        #expect(scene.bRollItems.first?.sourceType == .custom)
        #expect(scene.bRollItems.first?.status == .idea)
        #expect(scene.editingItems.first?.status == .pending)
        #expect(scene.aiComments.first?.severity == .note)
        #expect(scene.aiComments.first?.status == .new)
        #expect(scene.takes.first?.rating == .unrated)
        #expect(document.project.productionStatus == .idea)
        #expect(document.project.assets.first?.kind == .web)
        #expect(document.project.claims.first?.status == .probable)
        #expect(document.project.checklistTasks.first?.kind == .other)
        #expect(document.project.clips.first?.format == .reel)
        #expect(document.project.clips.first?.status == .idea)
        #expect(document.project.exportPresets.first?.format == .productionOutline)
        #expect(document.project.settingsOverride?.defaultSplitMode == nil)
        // The user's text is never part of the fallback.
        #expect(scene.scriptText == "alpha target omega")
        #expect(scene.title == "Scene")
    }

    @Test("Non-string enum values also fall back instead of failing")
    func nonStringEnumValueFallsBack() throws {
        let data = try minimalJSON { project in
            var project = project
            var scenes = try #require(project["scenes"] as? [[String: Any]])
            var scene = scenes[0]
            scene["sectionType"] = 42
            scenes[0] = scene
            project["scenes"] = scenes
            return project
        }

        let document = try FrameScriptDocumentCodec.decode(data)
        #expect(document.project.scenes.first?.sectionType == .custom)
    }

    // MARK: Anchors

    @Test("A v4 out-of-range anchor is dropped and the project still opens")
    func v4InvalidAnchorIsDropped() throws {
        let data = try minimalJSON { project in
            var project = project
            var scenes = try #require(project["scenes"] as? [[String: Any]])
            var scene = scenes[0]
            var visuals = try #require(scene["bRollItems"] as? [[String: Any]])
            visuals[0]["textAnchor"] = [
                "startUTF16": 9_000,
                "lengthUTF16": 5,
                "selectedText": "target",
                "prefixContext": "",
                "suffixContext": ""
            ]
            visuals[0]["linkedSegmentID"] = UUID().uuidString
            scene["bRollItems"] = visuals
            scenes[0] = scene
            project["scenes"] = scenes
            return project
        }

        let document = try FrameScriptDocumentCodec.decode(data)
        let scene = try #require(document.project.scenes.first)
        #expect(scene.scriptText == "alpha target omega")
        #expect(scene.bRollItems.first?.textAnchor == nil)
        #expect(scene.bRollItems.first?.linkedSegmentID == nil)
        #expect(scene.bRollItems.first?.descriptionText == "visual")
    }

    // MARK: scenes key

    @Test("A v4 file without scenes is rejected")
    func v4WithoutScenesIsRejected() throws {
        let payload: [String: Any] = [
            "fileVersion": 4,
            "project": [
                "id": UUID().uuidString,
                "title": "Truncated",
                "createdAt": "2024-01-01T10:00:00Z",
                "updatedAt": "2024-01-01T10:00:00Z"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        var didThrow = false
        do {
            _ = try FrameScriptDocumentCodec.decode(data)
        } catch {
            didThrow = true
        }
        #expect(didThrow, "A v4 file without scenes must not open as an empty project")
    }

    @Test("A v1-v3 file without scenes still opens as an empty project")
    func legacyWithoutScenesStillOpens() throws {
        for version in 1...3 {
            let payload: [String: Any] = [
                "fileVersion": version,
                "project": [
                    "id": UUID().uuidString,
                    "title": "Legacy",
                    "createdAt": "2024-01-01T10:00:00Z",
                    "updatedAt": "2024-01-01T10:00:00Z"
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let document = try FrameScriptDocumentCodec.decode(data)
            #expect(document.project.scenes.isEmpty)
            #expect(document.fileVersion == FrameScriptFormat.currentFileVersion)
        }
    }

    // MARK: Symlinks

    @Test("Saving through a symlink keeps the link and updates the target")
    func savingThroughSymlinkKeepsTheLink() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("Real.fscr")
        let link = directory.appendingPathComponent("Linked.fscr")
        try Data("old".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let attributeName = "com.framescript.wp1"
        let attributeValue = Data([0x0A, 0x0B, 0x0C])
        setExtendedAttribute(attributeName, value: attributeValue, at: target)

        try FrameScriptDocumentCodec.write(Self.document(title: "Through the link"), to: link)

        let values = try link.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink == true)
        #expect(try FrameScriptDocumentCodec.read(from: link).project.title == "Through the link")
        #expect(try FrameScriptDocumentCodec.read(from: target).project.title == "Through the link")
        #expect(try extendedAttribute(attributeName, at: target) == attributeValue)
    }

    @Test("Creating a symlink to a missing target writes the target and keeps the link")
    func symlinkToMissingTargetIsCreated() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("Later.fscr")
        let link = directory.appendingPathComponent("Linked.fscr")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try FrameScriptDocumentCodec.write(Self.document(title: "New"), to: link)

        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(try FrameScriptDocumentCodec.read(from: target).project.title == "New")
    }

    // MARK: Helpers

    private static func document(title: String) -> FrameScriptDocument {
        FrameScriptDocument(
            project: FrameScriptDocument.Project(
                title: title,
                scenes: [
                    FrameScriptDocument.Scene(order: 0, sectionType: .custom, title: "Scene", scriptText: "text")
                ]
            )
        )
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameScriptWP1-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A complete v4 document with one of every persisted type, so a single
    /// unknown raw value per enum can be injected.
    private func minimalJSON(
        transform: ([String: Any]) throws -> [String: Any]
    ) throws -> Data {
        let sceneID = UUID().uuidString
        let segmentID = UUID().uuidString
        var project: [String: Any] = [
            "id": UUID().uuidString,
            "title": "Enums",
            "createdAt": "2024-01-01T10:00:00Z",
            "updatedAt": "2024-01-01T10:00:00Z",
            "primaryLanguage": "es",
            "scenes": [
                [
                    "id": sceneID,
                    "order": 0,
                    "sectionType": "Custom",
                    "title": "Scene",
                    "scriptText": "alpha target omega",
                    "textSegments": [
                        [
                            "id": segmentID,
                            "sceneID": sceneID,
                            "order": 0,
                            "sourceText": "alpha target omega",
                            "segmentType": "scene",
                            "timingEstimate": 1.5
                        ]
                    ],
                    "aiComments": [
                        [
                            "id": UUID().uuidString,
                            "sceneID": sceneID,
                            "type": "pacing",
                            "severity": "note",
                            "message": "message",
                            "suggestion": "",
                            "status": "new"
                        ]
                    ],
                    "bRollItems": [
                        [
                            "id": UUID().uuidString,
                            "sourceType": "Custom",
                            "descriptionText": "visual",
                            "notes": "",
                            "status": "Idea"
                        ]
                    ],
                    "editingItems": [
                        [
                            "id": UUID().uuidString,
                            "cutStyle": "cut",
                            "notes": "",
                            "status": "Pending"
                        ]
                    ],
                    "takes": [
                        [
                            "id": UUID().uuidString,
                            "number": 1,
                            "startedAt": "2024-01-01T10:00:00Z",
                            "rating": "Unrated"
                        ]
                    ]
                ]
            ],
            "exportPresets": [
                ["id": UUID().uuidString, "name": "Preset", "format": "Plain text"]
            ],
            "settingsOverride": ["defaultSplitMode": "scene"],
            "productionStatus": "Idea",
            "assets": [
                ["id": UUID().uuidString, "path": "/tmp/asset.png", "kind": "Web"]
            ],
            "claims": [
                ["id": UUID().uuidString, "text": "claim", "status": "Probable"]
            ],
            "checklistTasks": [
                ["id": UUID().uuidString, "text": "task", "kind": "Other"]
            ],
            "clips": [
                ["id": UUID().uuidString, "title": "clip", "format": "Reel", "status": "Idea"]
            ]
        ]
        project = try transform(project)
        let root: [String: Any] = ["fileVersion": 4, "project": project]
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func setExtendedAttribute(_ name: String, value: Data, at url: URL) {
        #if canImport(Darwin)
        _ = url.path.withCString { path in
            name.withCString { namePointer in
                value.withUnsafeBytes { buffer in
                    setxattr(path, namePointer, buffer.baseAddress, value.count, 0, 0)
                }
            }
        }
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
        return Data()
        #endif
    }
}
