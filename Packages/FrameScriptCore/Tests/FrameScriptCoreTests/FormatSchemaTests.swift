import CoreFoundation
import Foundation
import Testing
@testable import FrameScriptCore

/// Guards `docs/format/fscr-v4.schema.json` against drift from the Swift types.
///
/// The schema lives in the repository (not in the package) because it is a
/// documentation artifact. The tests locate it by walking up from this file's
/// path, so `swift test` must run inside the FrameScript checkout.
///
/// No third-party dependency is used: the small JSON-Schema subset that the
/// schema needs (type, properties, required, items, enum, const, $ref, format,
/// minimum, additionalProperties-as-schema) is implemented at the bottom of
/// this file.
@Suite("Format schema v4")
struct FormatSchemaTests {
    private static let schemaRelativePath = "docs/format/fscr-v4.schema.json"

    // MARK: - Structural checks

    @Test("Schema is self-consistent: refs resolve, objects document unknown keys, everything has a description")
    func schemaIsSelfConsistent() throws {
        let schema = try Self.loadSchema()

        #expect(schema.root["$schema"] as? String == "https://json-schema.org/draft/2020-12/schema")
        #expect(JSONSchema.definitionName(fromReference: schema.root["$ref"] as? String ?? "") == "FrameScriptDocument")
        #expect(!schema.defNames.isEmpty)

        var reachable: Set<String> = []
        var pending = ["FrameScriptDocument"]

        while let name = pending.popLast() {
            guard reachable.insert(name).inserted else { continue }
            let definition = try #require(schema.defs[name], "missing $defs entry \(name)")
            #expect(Self.nonEmptyDescription(definition), "$defs/\(name) needs a description")

            for reference in Self.references(in: definition) {
                let target = try #require(
                    JSONSchema.definitionName(fromReference: reference),
                    "unsupported $ref \(reference) in \(name)"
                )
                #expect(schema.defs[target] != nil, "dangling $ref \(reference) in \(name)")
                pending.append(target)
            }

            guard definition["type"] as? String == "object" else { continue }
            let properties = try #require(definition["properties"] as? [String: Any], "\(name) has no properties")
            let required = definition["required"] as? [String] ?? []

            // Forward compatibility: object definitions must let unknown keys pass.
            #expect(definition["additionalProperties"] as? Bool == true, "\(name) must set additionalProperties: true")

            for key in required {
                #expect(properties[key] != nil, "\(name).required lists undeclared property \(key)")
            }
            for (key, value) in properties {
                let property = try #require(value as? [String: Any], "\(name).\(key) is not a schema object")
                #expect(Self.nonEmptyDescription(property), "\(name).\(key) needs a description")
            }
        }

        let unreachable = Set(schema.defs.keys).subtracting(reachable)
        #expect(unreachable.isEmpty, "unreachable $defs entries: \(unreachable.sorted())")
    }

    @Test("Schema enums match the Swift raw values exactly")
    func enumsMatchSwiftRawValues() throws {
        let schema = try Self.loadSchema()
        let expected: [String: [String]] = [
            "SectionType": FrameScriptDocument.SectionType.allCases.map(\.rawValue),
            "SegmentType": FrameScriptDocument.SegmentType.allCases.map(\.rawValue),
            "BRollSourceType": FrameScriptDocument.BRollSourceType.allCases.map(\.rawValue),
            "BRollStatus": FrameScriptDocument.BRollStatus.allCases.map(\.rawValue),
            "AICommentStatus": FrameScriptDocument.AICommentStatus.allCases.map(\.rawValue),
            "AICommentSeverity": FrameScriptDocument.AICommentSeverity.allCases.map(\.rawValue),
            "ExportFormat": FrameScriptDocument.ExportFormat.allCases.map(\.rawValue),
            "EditingStatus": FrameScriptDocument.EditingStatus.allCases.map(\.rawValue),
            "ProductionStatus": FrameScriptDocument.ProductionStatus.allCases.map(\.rawValue),
            "TakeRating": FrameScriptDocument.TakeRating.allCases.map(\.rawValue),
            "AssetKind": FrameScriptDocument.AssetKind.allCases.map(\.rawValue),
            "ClaimStatus": FrameScriptDocument.ClaimStatus.allCases.map(\.rawValue),
            "ChecklistTaskKind": FrameScriptDocument.ChecklistTaskKind.allCases.map(\.rawValue),
            "ShortClipFormat": FrameScriptDocument.ShortClipFormat.allCases.map(\.rawValue),
            "ShortClipStatus": FrameScriptDocument.ShortClipStatus.allCases.map(\.rawValue)
        ]

        let schemaEnums = Set(
            schema.defNames.filter { schema.defs[$0]?["enum"] is [String] }
        )
        #expect(schemaEnums == Set(expected.keys), "schema enum defs drifted: \(schemaEnums.symmetricDifference(Set(expected.keys)).sorted())")

        for (name, rawValues) in expected {
            let definition = try #require(schema.defs[name], "missing $defs entry \(name)")
            #expect(definition["type"] as? String == "string", "\(name) must be a string enum")
            let declared = try #require(definition["enum"] as? [String], "\(name) has no enum")
            #expect(Set(declared) == Set(rawValues), "\(name) raw values drifted: schema \(declared), Swift \(rawValues)")
        }
    }

    @Test("The maximal document validates against the published schema")
    func maximalDocumentValidates() throws {
        let data = try FrameScriptDocumentCodec.encode(DocumentFormatTests.fullDocument())
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["fileVersion"] as? Int == FrameScriptFormat.currentFileVersion)

        let schema = try Self.loadSchema()
        var validator = DocumentValidator(schema: schema)
        try validator.validate(root)
        #expect(!validator.samples.isEmpty)
    }

    @Test("A sparse document encodes exactly the required keys of every type")
    func sparseDocumentEncodesOnlyRequiredKeys() throws {
        let schema = try Self.loadSchema()
        var validator = DocumentValidator(schema: schema)
        try validator.validate(try Self.jsonObject(of: Self.sparseDocument()))
        var samples = validator.samples

        // The sparse project leaves both overrides nil, so the only way to
        // sample these two types is to encode an empty instance directly.
        for name in ["ProjectSettingsOverride", "RhythmThresholds"] {
            let empty: Any
            if name == "ProjectSettingsOverride" {
                empty = try Self.jsonObject(of: FrameScriptDocument.ProjectSettingsOverride())
            } else {
                empty = try Self.jsonObject(of: FrameScriptDocument.RhythmThresholds())
            }
            var emptyValidator = DocumentValidator(schema: schema)
            try emptyValidator.validate(empty, definition: name)
            samples += emptyValidator.samples
        }

        for name in schema.defNames {
            guard let definition = schema.defs[name], definition["type"] as? String == "object" else { continue }
            let properties = Set((definition["properties"] as? [String: Any] ?? [:]).keys)
            let required = Set(definition["required"] as? [String] ?? [])

            // A sparse instance has every optional Swift property set to nil, so
            // the encoder writes exactly the always-present keys. Comparing that
            // set with `required` proves the two definitions agree.
            let matchesRequired = samples.contains { $0.definition == name && $0.keys == required }
            if !matchesRequired {
                // Types without any optional member cannot have a sparse sample
                // that differs, so equality of the two sets is enough.
                #expect(
                    properties == required,
                    "\(name): no sparse sample encodes exactly \(required.sorted()); encoded \(samples.filter { $0.definition == name }.map(\.keys))"
                )
            }
        }
    }

    @Test("Migrated v1, v2 and v3 fixtures produce schema-valid v4 documents")
    func migratedFixturesValidate() throws {
        let schema = try Self.loadSchema()

        for fixture in ["v1-minimal.fscr", "v2-shifted-anchor.fscr", "v3-full.fscr"] {
            let migrated = try Self.decodeFixture(fixture)
            #expect(migrated.fileVersion == 4)
            let data = try FrameScriptDocumentCodec.encode(migrated)
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(root["fileVersion"] as? Int == 4, "\(fixture) did not migrate to version 4")

            var validator = DocumentValidator(schema: schema)
            try validator.validate(root)
        }
    }

    @Test("Encoded keys and schema properties agree in both directions")
    func encodedKeysMatchSchemaProperties() throws {
        let schema = try Self.loadSchema()
        let maximal = try Self.samples(of: DocumentFormatTests.fullDocument(), schema: schema)
        let sparse = try Self.samples(of: Self.sparseDocument(), schema: schema)
        let allSamples = maximal + sparse

        var encodedKeysByDefinition: [String: Set<String>] = [:]
        for sample in allSamples {
            encodedKeysByDefinition[sample.definition, default: []].formUnion(sample.keys)
        }
        let sampledDefinitions = Set(allSamples.map(\.definition))

        for name in schema.defNames {
            guard let definition = schema.defs[name], definition["type"] as? String == "object" else { continue }
            let properties = definition["properties"] as? [String: Any] ?? [:]
            let declared = Set(properties.keys)

            // Facts about objects that framed a document must be described.
            #expect(
                sampledDefinitions.contains(name),
                "\(name) is never encoded; the schema entry (or the maximal builder) is stale"
            )

            let encoded = encodedKeysByDefinition[name] ?? []
            let undeclared = encoded.subtracting(declared)
            #expect(undeclared.isEmpty, "\(name) encodes keys absent from the schema: \(undeclared.sorted())")
            if !encoded.isEmpty {
                // `deprecated` properties are read-only legacy aliases that the
                // encoder never writes, so they are exempt from this direction.
                let writable = declared.filter { key in
                    (properties[key] as? [String: Any])?["deprecated"] as? Bool != true
                }
                let neverEncoded = writable.subtracting(encoded)
                #expect(neverEncoded.isEmpty, "\(name) declares properties the encoder never writes: \(neverEncoded.sorted())")
            }
        }
    }

    // MARK: - README examples

    @Test("README minimal example is valid v4 and decodes")
    func readmeMinimalExampleIsValid() throws {
        let data = try Self.readmeExample(named: "minimal")
        let schema = try Self.loadSchema()
        var validator = DocumentValidator(schema: schema)
        try validator.validate(try JSONSerialization.jsonObject(with: data))

        let document = try FrameScriptDocumentCodec.decode(data)
        #expect(document.fileVersion == 4)
        #expect(document.project.title == "Minimal project")
        #expect(document.project.scenes.isEmpty)
    }

    @Test("README fuller example is valid v4, decodes and carries a decompressible snapshot")
    func readmeFullExampleIsValid() throws {
        let data = try Self.readmeExample(named: "full")
        let schema = try Self.loadSchema()
        var validator = DocumentValidator(schema: schema)
        try validator.validate(try JSONSerialization.jsonObject(with: data))

        let document = try FrameScriptDocumentCodec.decode(data)
        #expect(document.fileVersion == 4)
        #expect(document.project.scenes.count == 1)
        #expect(document.project.scenes.first?.bRollItems.first?.textAnchor?.selectedText == "target")

        let snapshot = try #require(document.project.versionHistory.first)
        let payload = try SnapshotCodec.decompress(base64: snapshot.compressedPayload.base64EncodedString())
        let decompressed = try #require(try JSONSerialization.jsonObject(with: payload) as? NSDictionary)

        // The guide claims this payload decompresses to the minimal example.
        let minimal = try Self.readmeExample(named: "minimal")
        let minimalObject = try #require(try JSONSerialization.jsonObject(with: minimal) as? NSDictionary)
        #expect(decompressed == minimalObject)
    }

    // MARK: - Documents

    /// Every optional Swift property is nil and every collection has exactly the
    /// members needed to instantiate each nested type once.
    private static func sparseDocument() -> FrameScriptDocument {
        let sceneID = UUID()
        let segmentID = UUID()

        let scene = FrameScriptDocument.Scene(
            id: sceneID,
            order: 0,
            sectionType: .custom,
            title: "Sparse scene",
            scriptText: "alpha",
            notes: "",
            estimatedDuration: 0,
            textSegments: [
                FrameScriptDocument.TextSegment(
                    id: segmentID,
                    sceneID: sceneID,
                    order: 0,
                    sourceText: "alpha",
                    segmentType: .scene,
                    timingEstimate: 0
                )
            ],
            aiComments: [
                FrameScriptDocument.AIComment(type: "pacing", severity: .note, message: "message")
            ],
            bRollItems: [
                FrameScriptDocument.BRollItem(descriptionText: "visual")
            ],
            editingItems: [
                FrameScriptDocument.EditingItem(cutStyle: "cut")
            ],
            takes: [
                FrameScriptDocument.Take(number: 1, startedAt: Date(timeIntervalSince1970: 0))
            ],
            languageVariants: [
                FrameScriptDocument.SceneLanguageVariant(languageCode: "en")
            ]
        )

        let pack = FrameScriptDocument.PublishingPack(
            chapterOverrides: [FrameScriptDocument.ChapterOverride()],
            thumbnailVariants: [FrameScriptDocument.ThumbnailVariant()]
        )

        let comparison = FrameScriptDocument.PublishedVideoComparison(
            transcriptSegments: [
                FrameScriptDocument.TranscriptSegment(start: 0, end: 1, text: "text")
            ],
            retentionPoints: [
                FrameScriptDocument.RetentionPoint(time: 0, percent: 100)
            ],
            sceneResults: [
                FrameScriptDocument.PublishedVideoComparison.SceneResult(sceneID: sceneID)
            ]
        )

        let project = FrameScriptDocument.Project(
            title: "Sparse project",
            exportPresets: [
                FrameScriptDocument.ExportPreset(name: "Preset", format: .plainText)
            ],
            scenes: [scene],
            assets: [
                FrameScriptDocument.ProjectAsset(path: "/tmp/asset.png")
            ],
            publishingPacks: ["es": pack],
            checklistTasks: [
                FrameScriptDocument.ChecklistTask(text: "Task")
            ],
            sources: [
                FrameScriptDocument.Source(title: "Source")
            ],
            claims: [
                FrameScriptDocument.Claim(text: "Claim")
            ],
            comparisonTables: [
                FrameScriptDocument.ComparisonTable(title: "Table")
            ],
            glossary: [
                FrameScriptDocument.GlossaryTerm(source: "Term")
            ],
            clips: [
                FrameScriptDocument.ShortClip(title: "Clip")
            ],
            versionHistory: [
                FrameScriptDocument.VersionSnapshot(createdAt: Date(timeIntervalSince1970: 0))
            ],
            aiThreadMap: FrameScriptDocument.AIThreadMap(),
            unparsedSections: [
                FrameScriptDocument.UnparsedSection(heading: "Heading", body: "Body")
            ],
            publishedVideos: ["es": comparison]
        )

        return FrameScriptDocument(project: project)
    }

    // MARK: - Helpers

    private static func samples(
        of document: FrameScriptDocument,
        schema: JSONSchema
    ) throws -> [DocumentValidator.ObjectSample] {
        var validator = DocumentValidator(schema: schema)
        try validator.validate(try jsonObject(of: document))
        return validator.samples
    }

    private static func jsonObject(of value: some Encodable) throws -> Any {
        let data = try FrameScriptDocumentCodec.makeEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func decodeFixture(_ name: String) throws -> FrameScriptDocument {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Document"),
            "missing fixture \(name)"
        )
        return try FrameScriptDocumentCodec.decode(Data(contentsOf: url))
    }

    private static func loadSchema() throws -> JSONSchema {
        try JSONSchema(data: Data(contentsOf: repositoryFile(schemaRelativePath)))
    }

    /// Finds a repository-relative file by walking up from this test file. The
    /// schema and the README are repository documents, not package resources.
    private static func repositoryFile(_ relativePath: String) throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw SchemaTestError.fileNotFound(relativePath)
    }

    private static func nonEmptyDescription(_ schema: [String: Any]) -> Bool {
        guard let description = schema["description"] as? String else { return false }
        return !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// All `$ref` strings anywhere inside a schema fragment.
    private static func references(in value: Any) -> [String] {
        var found: [String] = []
        func walk(_ value: Any) {
            switch value {
            case let dictionary as [String: Any]:
                for (key, child) in dictionary {
                    if key == "$ref", let reference = child as? String {
                        found.append(reference)
                    } else {
                        walk(child)
                    }
                }
            case let array as [Any]:
                for child in array { walk(child) }
            default:
                break
            }
        }
        walk(value)
        return found
    }

    // MARK: - README

    /// Reads a fenced example from docs/format/README.md. The README is the
    /// single source of truth for the examples; a broken or stale example fails
    /// here instead of drifting silently.
    private static func readmeExample(named name: String) throws -> Data {
        let readme = try String(contentsOf: readmeURL(), encoding: .utf8)
        let marker = "<!-- example:\(name) -->"
        let markerRange = try #require(readme.range(of: marker), "missing \(marker) in docs/format/README.md")
        let remainder = readme[markerRange.upperBound...]
        let opening = try #require(remainder.range(of: "```json"), "missing json block after \(marker)")
        let closing = try #require(
            remainder.range(of: "```", range: opening.upperBound..<remainder.endIndex),
            "unterminated json block after \(marker)"
        )
        return Data(remainder[opening.upperBound..<closing.lowerBound].utf8)
    }

    private static func readmeURL() throws -> URL {
        try repositoryFile("docs/format/README.md")
    }
}

// MARK: - Errors

private enum SchemaTestError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case malformedSchema(String)
    case invalidRoot

    var description: String {
        switch self {
        case .fileNotFound(let path):
            return "Could not find \(path) above this test file. Run swift test inside the FrameScript repository."
        case .malformedSchema(let reason):
            return "Malformed JSON schema: \(reason)"
        case .invalidRoot:
            return "The schema root must be a JSON object with $defs."
        }
    }
}

// MARK: - Minimal JSON-Schema (draft 2020-12) evaluator

/// Implements only the keywords used by `docs/format/fscr-v4.schema.json`.
///
/// Unknown keywords are ignored (they are annotations in JSON Schema). Unknown
/// object members are accepted, matching the schema's `additionalProperties`.
private struct DocumentValidator {
    struct ObjectSample {
        let definition: String
        let path: String
        let keys: Set<String>
    }

    let schema: JSONSchema
    private(set) var samples: [ObjectSample] = []

    init(schema: JSONSchema) {
        self.schema = schema
    }

    mutating func validate(_ value: Any) throws {
        try validate(value, against: schema.root, path: "$", definitionHint: nil)
    }

    /// Validates `value` directly against one `$defs` entry. Used for types that
    /// only appear as optional members and therefore need a standalone sample.
    mutating func validate(_ value: Any, definition name: String) throws {
        guard let definition = schema.defs[name] else {
            throw SchemaTestError.malformedSchema("missing $defs entry \(name)")
        }
        try validate(value, against: definition, path: "$", definitionHint: name)
    }

    private mutating func validate(
        _ value: Any,
        against rawSchema: [String: Any],
        path: String,
        definitionHint: String?
    ) throws {
        let resolved = try schema.resolve(rawSchema)
        let definition = resolved.schema
        let name = resolved.name ?? definitionHint

        if let expected = definition["const"] {
            guard Self.jsonEquals(expected, value) else {
                throw SchemaViolation(path: path, message: "expected constant \(expected), got \(value)")
            }
        }

        if let allowed = definition["enum"] as? [Any] {
            guard allowed.contains(where: { Self.jsonEquals($0, value) }) else {
                throw SchemaViolation(path: path, message: "value \(value) is not one of \(allowed)")
            }
        }

        if let minimum = definition["minimum"] as? NSNumber,
           let number = value as? NSNumber, !Self.isBoolean(number),
           number.doubleValue < minimum.doubleValue {
            throw SchemaViolation(path: path, message: "value \(number) is below minimum \(minimum)")
        }

        guard let type = definition["type"] as? String else {
            // No type constraint: nothing more to assert.
            return
        }

        switch type {
        case "object":
            try validateObject(value, definition: definition, name: name, path: path)
        case "array":
            guard let array = value as? [Any] else {
                throw SchemaViolation(path: path, message: "expected array, got \(Self.describe(value))")
            }
            guard let items = definition["items"] as? [String: Any] else { return }
            for (index, element) in array.enumerated() {
                try validate(element, against: items, path: "\(path)[\(index)]", definitionHint: nil)
            }
        case "string":
            guard let string = value as? String else {
                throw SchemaViolation(path: path, message: "expected string, got \(Self.describe(value))")
            }
            try validateString(string, format: definition["format"] as? String, path: path)
        case "integer":
            guard let number = value as? NSNumber, !Self.isBoolean(number) else {
                throw SchemaViolation(path: path, message: "expected integer, got \(Self.describe(value))")
            }
            guard number.doubleValue.rounded(.towardZero) == number.doubleValue else {
                throw SchemaViolation(path: path, message: "expected integer, got \(number)")
            }
        case "number":
            guard let number = value as? NSNumber, !Self.isBoolean(number) else {
                throw SchemaViolation(path: path, message: "expected number, got \(Self.describe(value))")
            }
            // JSON cannot represent NaN or infinity, so a parsed number is finite.
            guard number.doubleValue.isFinite else {
                throw SchemaViolation(path: path, message: "number is not finite")
            }
        case "boolean":
            guard let number = value as? NSNumber, Self.isBoolean(number) else {
                throw SchemaViolation(path: path, message: "expected boolean, got \(Self.describe(value))")
            }
        default:
            throw SchemaTestError.malformedSchema("unsupported type \(type) at \(path)")
        }
    }

    private mutating func validateObject(
        _ value: Any,
        definition: [String: Any],
        name: String?,
        path: String
    ) throws {
        guard let object = value as? [String: Any] else {
            throw SchemaViolation(path: path, message: "expected object, got \(Self.describe(value))")
        }

        let properties = definition["properties"] as? [String: Any] ?? [:]
        let required = definition["required"] as? [String] ?? []

        for key in required where object[key] == nil {
            throw SchemaViolation(path: path, message: "missing required property \(key)")
        }

        if let name {
            samples.append(ObjectSample(definition: name, path: path, keys: Set(object.keys)))
        }

        for key in object.keys.sorted() {
            guard let child = object[key] else { continue }
            if let propertySchema = properties[key] as? [String: Any] {
                try validate(child, against: propertySchema, path: "\(path).\(key)", definitionHint: nil)
            } else if let additional = definition["additionalProperties"] as? [String: Any] {
                try validate(child, against: additional, path: "\(path).\(key)", definitionHint: nil)
            } else if definition["additionalProperties"] as? Bool == false {
                throw SchemaViolation(path: path, message: "unexpected property \(key)")
            }
            // `true` or absent additionalProperties: accept the member.
        }
    }

    private func validateString(_ string: String, format: String?, path: String) throws {
        switch format {
        case "uuid":
            guard UUID(uuidString: string) != nil else {
                throw SchemaViolation(path: path, message: "\(string) is not a UUID")
            }
        case "date-time":
            guard FrameScriptDocumentCodec.date(fromISO8601: string) != nil else {
                throw SchemaViolation(path: path, message: "\(string) is not an ISO-8601 date-time")
            }
        default:
            break
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func jsonEquals(_ lhs: Any, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case let (left as String, right as String):
            return left == right
        case let (left as NSNumber, right as NSNumber):
            if isBoolean(left) || isBoolean(right) {
                return isBoolean(left) && isBoolean(right) && left.boolValue == right.boolValue
            }
            return left == right
        default:
            return false
        }
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case is NSNull: return "null"
        case is [String: Any]: return "object"
        case is [Any]: return "array"
        case is String: return "string"
        case let number as NSNumber: return isBoolean(number) ? "boolean" : "number"
        default: return String(describing: type(of: value))
        }
    }
}

private struct SchemaViolation: Error, CustomStringConvertible {
    let path: String
    let message: String

    var description: String { "\(path): \(message)" }
}

private struct JSONSchema {
    let root: [String: Any]
    let defs: [String: [String: Any]]

    init(data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SchemaTestError.malformedSchema("invalid JSON: \(error)")
        }
        guard let root = object as? [String: Any],
              let defs = root["$defs"] as? [String: [String: Any]] else {
            throw SchemaTestError.invalidRoot
        }
        self.root = root
        self.defs = defs
    }

    var defNames: [String] { defs.keys.sorted() }

    func resolve(_ schema: [String: Any]) throws -> (schema: [String: Any], name: String?) {
        guard let reference = schema["$ref"] as? String else {
            return (schema, nil)
        }
        guard let name = Self.definitionName(fromReference: reference),
              let definition = defs[name] else {
            throw SchemaTestError.malformedSchema("dangling $ref \(reference)")
        }
        return (definition, name)
    }

    static func definitionName(fromReference reference: String) -> String? {
        let prefix = "#/$defs/"
        guard reference.hasPrefix(prefix) else { return nil }
        return String(reference.dropFirst(prefix.count))
    }
}
