import Foundation

/// Splits a scene script into narration paragraphs and pairs each visual or
/// editing note with the paragraph that contains its anchor.
///
/// Splitting is intentionally simple and stable: a paragraph is a run of
/// non-blank lines. Blank lines are separators and never become empty rows.
/// Ranges are UTF-16 offsets, the same unit `TextAnchor` stores.
public enum AVScriptBuilder {
    public static func document(title: String, scenes: [AVScriptSceneInput]) -> AVScriptDocument {
        AVScriptDocument(
            title: title,
            scenes: scenes.map(scene)
        )
    }

    public static func scene(_ input: AVScriptSceneInput) -> AVScriptScene {
        let paragraphs = paragraphs(in: input.scriptText, sceneID: input.id)
        var annotationsByParagraph: [Int: [AVScriptAnnotation]] = [:]
        var unanchored: [AVScriptAnnotation] = []

        for annotation in input.annotations {
            let resolved = resolve(annotation, in: input.scriptText, paragraphs: paragraphs)
            let output = AVScriptAnnotation(
                id: annotation.id,
                kind: annotation.kind,
                text: annotation.text,
                source: annotation.source,
                status: annotation.status,
                isDone: annotation.isDone,
                anchorExcerpt: annotation.anchor?.selectedText ?? ""
            )
            if let index = resolved {
                annotationsByParagraph[index, default: []].append(output)
            } else {
                unanchored.append(output)
            }
        }

        var rows = paragraphs.map { paragraph in
            AVScriptRow(
                sceneID: input.id,
                paragraph: paragraph,
                annotations: annotationsByParagraph[paragraph.index] ?? []
            )
        }
        if !unanchored.isEmpty {
            rows.append(
                AVScriptRow(
                    sceneID: input.id,
                    paragraph: nil,
                    annotations: unanchored
                )
            )
        }

        return AVScriptScene(id: input.id, title: input.title, rows: rows)
    }

    /// Paragraph ranges for one script, in document order.
    public static func paragraphs(in text: String, sceneID: UUID) -> [AVScriptParagraph] {
        let nsText = text as NSString
        guard nsText.length > 0 else { return [] }

        var ranges: [NSRange] = []
        var paragraphStart: Int?
        var paragraphEnd = 0
        var cursor = 0

        while cursor < nsText.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            nsText.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: cursor, length: 0)
            )
            let lineLength = max(0, contentsEnd - lineStart)
            let line = nsText.substring(with: NSRange(location: lineStart, length: lineLength))
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if let start = paragraphStart {
                    ranges.append(NSRange(location: start, length: paragraphEnd - start))
                    paragraphStart = nil
                }
            } else {
                if paragraphStart == nil {
                    paragraphStart = lineStart
                }
                paragraphEnd = contentsEnd
            }

            guard lineEnd > cursor else { break }
            cursor = lineEnd
        }

        if let start = paragraphStart {
            ranges.append(NSRange(location: start, length: paragraphEnd - start))
        }

        return ranges.enumerated().compactMap { index, range in
            guard range.length > 0,
                  range.location >= 0,
                  range.location <= nsText.length,
                  range.length <= nsText.length - range.location else {
                return nil
            }
            return AVScriptParagraph(
                sceneID: sceneID,
                index: index,
                text: nsText.substring(with: range),
                range: AVScriptTextRange(range)
            )
        }
    }

    /// Returns the paragraph index that contains the anchor start, or `nil`
    /// when the anchor is missing, stale, or points at a deleted paragraph.
    private static func resolve(
        _ annotation: AVScriptAnnotationInput,
        in text: String,
        paragraphs: [AVScriptParagraph]
    ) -> Int? {
        guard let anchor = FrameScriptDocument.TextAnchorRepair.current(annotation.anchor, in: text),
              anchor.lengthUTF16 > 0 else {
            return nil
        }
        let start = anchor.startUTF16
        return paragraphs.first { paragraph in
            NSLocationInRange(start, paragraph.range.nsRange)
        }?.index
    }
}
