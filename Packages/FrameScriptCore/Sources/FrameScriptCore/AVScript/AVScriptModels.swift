import Foundation

/// One narration paragraph in an AV script row.
///
/// `range` always points at the exact paragraph substring in the scene script,
/// so the two-column editor can edit the paragraph in place without rebuilding
/// the whole script.
public struct AVScriptParagraph: Identifiable, Sendable, Hashable {
    public struct ID: Sendable, Hashable {
        public var sceneID: UUID
        public var index: Int

        public init(sceneID: UUID, index: Int) {
            self.sceneID = sceneID
            self.index = index
        }
    }

    public var id: ID { ID(sceneID: sceneID, index: index) }
    public var sceneID: UUID
    /// Zero-based position of the paragraph inside its scene.
    public var index: Int
    /// Exact text of the paragraph, without the blank lines that separate it
    /// from the next one.
    public var text: String
    public var range: AVScriptTextRange

    public init(sceneID: UUID, index: Int, text: String, range: AVScriptTextRange) {
        self.sceneID = sceneID
        self.index = index
        self.text = text
        self.range = range
    }
}

/// UTF-16 span of a paragraph inside `Scene.scriptText`.
public struct AVScriptTextRange: Sendable, Hashable {
    public var startUTF16: Int
    public var lengthUTF16: Int

    public init(startUTF16: Int, lengthUTF16: Int) {
        self.startUTF16 = max(0, startUTF16)
        self.lengthUTF16 = max(0, lengthUTF16)
    }

    public init(_ range: NSRange) {
        self.init(startUTF16: range.location, lengthUTF16: range.length)
    }

    public var nsRange: NSRange {
        NSRange(location: startUTF16, length: lengthUTF16)
    }
}

/// The two kinds of annotations the AV script shows beside a paragraph.
public enum AVScriptAnnotationKind: String, Sendable, Hashable, Codable, CaseIterable {
    case bRoll
    case editing
}

/// A visual or editing note attached to a paragraph.
public struct AVScriptAnnotation: Identifiable, Sendable, Hashable {
    public var id: UUID
    public var kind: AVScriptAnnotationKind
    /// Editable description (`BRollItem.descriptionText` / `EditingItem.cutStyle`).
    public var text: String
    /// Localized source label for visuals. Empty for editing notes.
    public var source: String
    /// Localized status label.
    public var status: String
    public var isDone: Bool
    /// Original anchor text. Used to identify items whose paragraph is gone.
    public var anchorExcerpt: String

    public init(
        id: UUID,
        kind: AVScriptAnnotationKind,
        text: String,
        source: String = "",
        status: String = "",
        isDone: Bool = false,
        anchorExcerpt: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.source = source
        self.status = status
        self.isDone = isDone
        self.anchorExcerpt = anchorExcerpt
    }
}

/// Input annotation, before it is resolved against the scene text.
public struct AVScriptAnnotationInput: Identifiable, Sendable, Hashable {
    public var id: UUID
    public var kind: AVScriptAnnotationKind
    public var text: String
    public var source: String
    public var status: String
    public var isDone: Bool
    public var anchor: FrameScriptDocument.TextAnchor?

    public init(
        id: UUID,
        kind: AVScriptAnnotationKind,
        text: String,
        source: String = "",
        status: String = "",
        isDone: Bool = false,
        anchor: FrameScriptDocument.TextAnchor? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.source = source
        self.status = status
        self.isDone = isDone
        self.anchor = anchor
    }
}

/// One row of the two-column sheet: a paragraph on the left and its
/// annotations on the right. A row with `paragraph == nil` is the
/// "unanchored" group shown at the end of a scene.
public struct AVScriptRow: Identifiable, Sendable, Hashable {
    public struct ID: Sendable, Hashable {
        public var sceneID: UUID
        /// `nil` identifies the unanchored group.
        public var paragraphIndex: Int?

        public init(sceneID: UUID, paragraphIndex: Int?) {
            self.sceneID = sceneID
            self.paragraphIndex = paragraphIndex
        }
    }

    public var id: ID { ID(sceneID: sceneID, paragraphIndex: paragraph?.index) }
    public var sceneID: UUID
    public var paragraph: AVScriptParagraph?
    public var annotations: [AVScriptAnnotation]

    public var isUnanchored: Bool { paragraph == nil }

    public init(sceneID: UUID, paragraph: AVScriptParagraph?, annotations: [AVScriptAnnotation]) {
        self.sceneID = sceneID
        self.paragraph = paragraph
        self.annotations = annotations
    }
}

/// One scene of the AV script.
public struct AVScriptScene: Identifiable, Sendable, Hashable {
    public var id: UUID
    public var title: String
    public var rows: [AVScriptRow]

    public var unanchoredRow: AVScriptRow? {
        rows.first(where: \.isUnanchored)
    }

    public var annotationCount: Int {
        rows.reduce(0) { $0 + $1.annotations.count }
    }

    public init(id: UUID, title: String, rows: [AVScriptRow]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}

/// A project rendered as an AV script.
public struct AVScriptDocument: Sendable, Hashable {
    public var title: String
    public var scenes: [AVScriptScene]

    public var isEmpty: Bool {
        scenes.allSatisfy { $0.rows.isEmpty }
    }

    public init(title: String, scenes: [AVScriptScene]) {
        self.title = title
        self.scenes = scenes
    }
}

/// Scene input for ``AVScriptBuilder``. Kept independent from the app models so
/// the CLI and tests can build an AV script too.
public struct AVScriptSceneInput: Identifiable, Sendable, Hashable {
    public var id: UUID
    public var title: String
    public var scriptText: String
    public var annotations: [AVScriptAnnotationInput]

    public init(
        id: UUID,
        title: String,
        scriptText: String,
        annotations: [AVScriptAnnotationInput] = []
    ) {
        self.id = id
        self.title = title
        self.scriptText = scriptText
        self.annotations = annotations
    }
}
