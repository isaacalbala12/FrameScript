import Foundation
import Testing
@testable import FrameScriptCore

/// Timing assertions only run on demand: CI and loaded machines must still get
/// the equivalence checks, never a flaky stopwatch.
private let wp9PerformanceAssertionsEnabled =
    ProcessInfo.processInfo.environment["FS_WP9_PERF"] == "1"

// MARK: - Export anchor index

@Suite("WP9 export anchor index")
struct WP9ExportAnchorIndexTests {
    private let sceneID = UUID()

    private func makeSegments(
        _ text: String,
        splitMode: FrameScriptDocument.SegmentType
    ) -> [FrameScriptDocument.TextSegment] {
        FrameScriptDocument.TextSegmenter
            .segmentTexts(in: text, splitMode: splitMode)
            .enumerated()
            .map { index, value in
                FrameScriptDocument.TextSegment(
                    sceneID: sceneID,
                    order: index,
                    sourceText: value,
                    segmentType: splitMode
                )
            }
    }

    private func sampleText() -> String {
        (0..<12).map { index in
            "Cuando la ciudad despierta cada mañana \(index), los vecinos caminan hacia el mercado. "
                + "El sol calienta las piedras del parque y una mujer vende naranjas."
        }
        .joined(separator: "\n\n")
    }

    @Test("Precomputed ranges equal one anchor lookup per segment")
    func segmentRangesMatchPerSegmentAnchors() throws {
        let text = sampleText()
        for splitMode in FrameScriptDocument.SegmentType.allCases {
            let segments = makeSegments(text, splitMode: splitMode)
            #expect(!segments.isEmpty)
            let ranges = FrameScriptDocument.TextAnchorRepair.segmentRanges(for: segments, in: text)

            for segment in segments {
                let expected = FrameScriptDocument.TextAnchorRepair
                    .anchor(for: segment, in: text)?
                    .nsRange
                #expect(ranges[segment.id] == expected, "mode \(splitMode) order \(segment.order)")
            }
        }
    }

    @Test("Mixed split modes keep each mode's own candidate list")
    func mixedSplitModesMatchPerSegmentAnchors() throws {
        let text = sampleText()
        let paragraphSegments = makeSegments(text, splitMode: .paragraph)
        let sentenceSegments = makeSegments(text, splitMode: .sentence)
        let segments = paragraphSegments + sentenceSegments
        let ranges = FrameScriptDocument.TextAnchorRepair.segmentRanges(for: segments, in: text)

        for segment in segments {
            let expected = FrameScriptDocument.TextAnchorRepair
                .anchor(for: segment, in: text)?
                .nsRange
            #expect(ranges[segment.id] == expected)
        }
    }

    @Test("A segment whose text no longer matches its candidate stays unlinked")
    func staleSegmentTextStaysUnlinked() throws {
        let text = sampleText()
        var segments = makeSegments(text, splitMode: .sentence)
        let index = try #require(segments.indices.dropFirst().first)
        segments[index].sourceText = "Este texto ya no está en la escena"
        let ranges = FrameScriptDocument.TextAnchorRepair.segmentRanges(for: segments, in: text)

        let expected = FrameScriptDocument.TextAnchorRepair
            .anchor(for: segments[index], in: text)?
            .nsRange
        #expect(expected == nil)
        #expect(ranges[segments[index].id] == nil)
    }

    @Test("Containment agrees with isAnchor at every boundary")
    func containmentMatchesIsAnchor() throws {
        let text = sampleText()
        let segments = makeSegments(text, splitMode: .sentence)
        let ranges = FrameScriptDocument.TextAnchorRepair.segmentRanges(for: segments, in: text)
        let length = (text as NSString).length

        for segment in segments {
            for location in stride(from: 0, through: length, by: 11) {
                let anchor = FrameScriptDocument.TextAnchor(
                    startUTF16: location,
                    lengthUTF16: 1,
                    selectedText: "x",
                    prefixContext: "",
                    suffixContext: ""
                )
                let expected = FrameScriptDocument.TextAnchorRepair.isAnchor(anchor, in: segment, text: text)
                let actual = ranges[segment.id].map { NSLocationInRange(location, $0) } ?? false
                #expect(actual == expected, "order \(segment.order) location \(location)")
            }
        }
    }

    @Test("Indexed lookup is at least three times faster than per-segment repair")
    func indexedLookupIsFaster() throws {
        let sceneTexts = (0..<12).map { _ in sampleText() }
        let scenes: [[FrameScriptDocument.TextSegment]] = sceneTexts.map {
            makeSegments($0, splitMode: .sentence)
        }
        let items = (0..<7).map { itemIndex in
            let all = FrameScriptDocument.TextSegmenter.segmentTexts(
                in: sceneTexts[0],
                splitMode: .sentence
            )
            let value = all[itemIndex % all.count]
            let range = (sceneTexts[0] as NSString).range(of: value)
            return FrameScriptDocument.TextAnchor(
                startUTF16: range.location + 2,
                lengthUTF16: 4,
                selectedText: "x",
                prefixContext: "",
                suffixContext: ""
            )
        }

        let clock = ContinuousClock()
        let legacy = clock.measure {
            var linked = 0
            for (sceneIndex, segments) in scenes.enumerated() {
                let text = sceneTexts[sceneIndex]
                for segment in segments {
                    for item in items where
                        FrameScriptDocument.TextAnchorRepair.isAnchor(item, in: segment, text: text) {
                        linked += 1
                    }
                }
            }
            #expect(linked >= 0)
        }
        let indexed = clock.measure {
            var linked = 0
            for (sceneIndex, segments) in scenes.enumerated() {
                let ranges = FrameScriptDocument.TextAnchorRepair.segmentRanges(
                    for: segments,
                    in: sceneTexts[sceneIndex]
                )
                for segment in segments {
                    guard let range = ranges[segment.id] else { continue }
                    for item in items where NSLocationInRange(item.startUTF16, range) {
                        linked += 1
                    }
                }
            }
            #expect(linked >= 0)
        }
        if wp9PerformanceAssertionsEnabled {
            #expect(
                indexed < legacy / 3,
                "indexed \(indexed) should beat per-segment \(legacy) by 3x"
            )
        }
    }
}

// MARK: - Contiguous anchor edit

@Suite("WP9 contiguous anchor edit")
struct WP9ContiguousAnchorEditTests {
    private let baseText = """
    Cuando la ciudad despierta, los vecinos caminan hacia el mercado con sus bolsas de tela. \
    El sol calienta las piedras del parque y una mujer vende naranjas. \
    Un hombre afina su guitarra mientras los niños corren entre las fuentes.
    """

    private func anchors(in text: String) -> [FrameScriptDocument.TextAnchor] {
        let nsText = text as NSString
        let lengths = [1, 4, 12, 40]
        var result: [FrameScriptDocument.TextAnchor] = []
        for length in lengths {
            for location in stride(from: 0, to: nsText.length - length, by: 37) {
                let range = NSRange(location: location, length: length)
                if let anchor = FrameScriptDocument.TextAnchorRepair.anchor(in: text, range: range) {
                    result.append(anchor)
                }
            }
        }
        return result
    }

    private func editedTexts(_ text: String) -> [String] {
        let nsText = text as NSString
        return [
            text,
            text + " Fin.",
            "Prólogo. " + text,
            nsText.replacingCharacters(in: NSRange(location: 10, length: 5), with: "X"),
            nsText.replacingCharacters(in: NSRange(location: 0, length: 20), with: ""),
            nsText.replacingCharacters(in: NSRange(location: 30, length: 0), with: "😀 ñ"),
            nsText.replacingCharacters(in: NSRange(location: 60, length: 40), with: "otro texto"),
            nsText.replacingCharacters(in: NSRange(location: nsText.length - 5, length: 5), with: "")
        ]
    }

    @Test("Computing the edit once gives the same anchors as the legacy call")
    func precomputedEditMatchesLegacyRepair() {
        let cases = anchors(in: baseText)
        for newText in editedTexts(baseText) {
            let edit = FrameScriptDocument.TextAnchorRepair.contiguousEdit(
                from: baseText,
                to: newText
            )
            for anchor in cases {
                let legacy = FrameScriptDocument.TextAnchorRepair.repair(
                    anchor,
                    from: baseText,
                    to: newText
                )
                let optimized = FrameScriptDocument.TextAnchorRepair.repair(
                    anchor,
                    from: baseText,
                    to: newText,
                    edit: edit
                )
                #expect(legacy == optimized)
            }
        }
    }

    @Test("A zero-length edit is what equality implies")
    func unchangedTextProducesAZeroLengthEdit() {
        let edit = FrameScriptDocument.TextAnchorRepair.contiguousEdit(
            from: baseText,
            to: baseText
        )
        #expect(edit.oldRange.length == 0)
        #expect(edit.newRange.length == 0)
        #expect(edit.oldRange.location == edit.newRange.location)
    }

    @Test("Reusing one edit is at least three times faster than rescanning per anchor")
    func reusedEditIsFaster() throws {
        let anchors = anchors(in: baseText)
        let newText = baseText + " Una frase más al final."
        let clock = ContinuousClock()

        let legacy = clock.measure {
            for anchor in anchors {
                _ = FrameScriptDocument.TextAnchorRepair.repair(
                    anchor,
                    from: baseText,
                    to: newText
                )
            }
        }
        let optimized = clock.measure {
            let edit = FrameScriptDocument.TextAnchorRepair.contiguousEdit(
                from: baseText,
                to: newText
            )
            for anchor in anchors {
                _ = FrameScriptDocument.TextAnchorRepair.repair(
                    anchor,
                    from: baseText,
                    to: newText,
                    edit: edit
                )
            }
        }
        if wp9PerformanceAssertionsEnabled {
            #expect(
                optimized < legacy / 3,
                "one edit \(optimized) should beat \(anchors.count) scans \(legacy)"
            )
        }
    }
}

// MARK: - Markdown regex cache

@Suite("WP9 markdown regex cache")
struct WP9MarkdownRegexTests {
    private let lines = [
        "# Título",
        "## 01:20 — Escena de apertura",
        "## 01:20:30 — Escena con horas",
        "## 01:20 —",
        "**VISUAL:** plano general",
        "**Nota** sin dos puntos",
        "- primer punto",
        "1. primer punto numerado",
        "| A | B |",
        "| --- | --- |",
        "[VISUAL]",
        "[VISUAL: plano cerrado]",
        "Texto con [una nota](https://example.com) y https://example.com/suelto.",
        "Concepto A — Idea principal — Recomendado",
        "Concepto B — Alternativa",
        "---",
        "Texto normal sin nada"
    ]

    @Test("Cached regexes return the same values as freshly compiled literals")
    func cachedRegexesMatchLiterals() {
        for line in lines {
            #expect(
                MarkdownParsingSupport.heading(line)?.level
                    == (line.wholeMatch(of: #/^\s{0,3}(#{1,6})\s+(.+?)\s*$/#)?.1.count)
            )
            #expect(
                MarkdownParsingSupport.isHorizontalRule(line)
                    == (line.wholeMatch(of: #/^\s{0,3}(?:-{3,}|\*{3,}|_{3,})\s*$/#) != nil)
            )
            #expect(
                MarkdownParsingSupport.looksLikeSceneHeading(line)
                    == (line.firstMatch(of: #/^\s{0,3}##\s+\d{1,2}:\d{2}/#) != nil)
            )
            #expect(
                MarkdownParsingSupport.cue(line)?.label
                    == line.wholeMatch(of: #/^\s*\[([A-ZÁÉÍÓÚÜÑ0-9 /-]+?)(?::\s*(.*?))?\]\s*$/#).map { String($0.1).trimmingCharacters(in: .whitespaces) }
            )
            let literalBoldLabel = line.wholeMatch(of: #/^\s*\*\*(.+?)\*\*\s*:?\s*(.*)$/#).map { match in
                var label = String(match.1).trimmingCharacters(in: .whitespaces)
                if label.hasSuffix(":") {
                    label.removeLast()
                    label = label.trimmingCharacters(in: .whitespaces)
                }
                return label
            }
            #expect(
                MarkdownParsingSupport.boldLabel(line)?.label == literalBoldLabel
            )
            #expect(
                (MarkdownParsingSupport.listItem(line, lineNumber: 0)?.marker)
                    == (line.wholeMatch(of: #/^(\d{1,2})[.)]\s+(.+?)\s*$/#).flatMap { match in
                        Int(match.1).map(EscaletaOutlineMarker.numbered)
                    } ?? line.wholeMatch(of: #/^[-*+]\s+(.+?)\s*$/#).map { _ in .bullet })
            )
            #expect(
                MarkdownParsingSupport.linkMatches(in: line).map(\.url)
                    == line.matches(of: #/\[([^\]]+)\]\(([^)]+)\)/#).map { String($0.2) }
            )
        }
    }

    @Test("Cached heading matching is at least three times faster than literal per call")
    func cachedHeadingIsFaster() {
        let sample = (0..<2_000).map { index in
            index.isMultiple(of: 4) ? "## \(index) — Título \(index)" : "Texto de la línea \(index)"
        }
        let clock = ContinuousClock()
        let literal = clock.measure {
            for line in sample {
                _ = line.wholeMatch(of: #/^\s{0,3}(#{1,6})\s+(.+?)\s*$/#)
            }
        }
        let cached = clock.measure {
            for line in sample {
                _ = MarkdownParsingSupport.heading(line)
            }
        }
        if wp9PerformanceAssertionsEnabled {
            #expect(cached < literal / 3, "cached \(cached) should beat literal \(literal)")
        }
    }
}

// MARK: - Version history

@Suite("WP9 version history encoding")
struct WP9VersionHistoryTests {
    private func document(snapshotCount: Int) -> FrameScriptDocument {
        let scenes = (0..<3).map { index in
            FrameScriptDocument.Scene(
                order: index,
                sectionType: .custom,
                title: "Scene \(index)",
                scriptText: "Texto sintético de la escena \(index)."
            )
        }
        let snapshots = (0..<snapshotCount).map { index in
            FrameScriptDocument.VersionSnapshot(
                createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)),
                name: nil,
                isAutomatic: true,
                label: "snapshot \(index)",
                compressedPayload: Data((0..<512).map { UInt8(($0 + index) & 0xFF) })
            )
        }
        return FrameScriptDocument(
            project: FrameScriptDocument.Project(
                title: "History",
                scenes: scenes,
                versionHistory: snapshots
            )
        )
    }

    @Test("A v4 file with history opens, keeps every snapshot and round-trips byte-identically")
    func versionFourWithHistoryOpensAndRoundTrips() throws {
        let original = document(snapshotCount: 5)
        let data = try FrameScriptDocumentCodec.encode(original)
        let decoded = try FrameScriptDocumentCodec.decode(data)

        #expect(decoded.fileVersion == FrameScriptFormat.currentFileVersion)
        #expect(decoded.project.versionHistory.count == 5)
        #expect(decoded.project.versionHistory == original.project.versionHistory)
        #expect(decoded.project.versionHistory.allSatisfy { !$0.encodedPayloadBase64IsEmpty })

        let reencoded = try FrameScriptDocumentCodec.encode(decoded)
        #expect(reencoded == data)
        let payloads = decoded.project.versionHistory.map(\.compressedPayload)
        let decodedAgain = try FrameScriptDocumentCodec.decode(reencoded)
        #expect(decodedAgain.project.versionHistory.map(\.compressedPayload) == payloads)
    }

    @Test("Changing a payload drops the cached base64 and writes the new bytes")
    func changedPayloadIsReencoded() throws {
        let original = document(snapshotCount: 2)
        let data = try FrameScriptDocumentCodec.encode(original)
        var decoded = try FrameScriptDocumentCodec.decode(data)
        let newPayload = Data([0x01, 0x02, 0x03])
        decoded.project.versionHistory[0].compressedPayload = newPayload

        let reencoded = try FrameScriptDocumentCodec.encode(decoded)
        let roundTripped = try FrameScriptDocumentCodec.decode(reencoded)
        #expect(roundTripped.project.versionHistory[0].compressedPayload == newPayload)
        #expect(roundTripped.project.versionHistory[1].compressedPayload == original.project.versionHistory[1].compressedPayload)
    }

    @Test("Decoded history keeps the exact base64 text for the next write")
    func unchangedHistoryReusesBase64() throws {
        let snapshots = (0..<8).map { index in
            FrameScriptDocument.VersionSnapshot(
                createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)),
                isAutomatic: true,
                label: "snapshot \(index)",
                compressedPayload: Data(repeating: UInt8(index & 0xFF), count: 4096)
            )
        }
        let original = FrameScriptDocument(
            project: FrameScriptDocument.Project(
                title: "History",
                scenes: [],
                versionHistory: snapshots
            )
        )
        let data = try FrameScriptDocumentCodec.encode(original)
        let decoded = try FrameScriptDocumentCodec.decode(data)

        for snapshot in decoded.project.versionHistory {
            #expect(
                snapshot.encodedPayloadBase64
                    == snapshot.compressedPayload.base64EncodedString()
            )
        }
        #expect(try FrameScriptDocumentCodec.encode(decoded) == data)
    }
}

private extension FrameScriptDocument.VersionSnapshot {
    var encodedPayloadBase64IsEmpty: Bool {
        encodedPayloadBase64?.isEmpty != false
    }
}
