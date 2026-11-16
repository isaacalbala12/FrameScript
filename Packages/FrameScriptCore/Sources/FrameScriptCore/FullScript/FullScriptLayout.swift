import Foundation

/// One scene as it appears in the continuous "Full script" editor.
///
/// The header text is supplied by the app (it owns localization and duration
/// formatting); the core only guarantees the structural contract:
///
/// `headerText + "\n" + bodyText + "\n"` for every scene.
///
/// The body is hidden when `isCollapsed` is true, but its slot still exists so
/// the range map stays unambiguous and the header can be toggled back.
public struct FullScriptSceneDescriptor: Equatable, Sendable {
    public var id: UUID
    public var headerText: String
    public var bodyText: String
    public var isCollapsed: Bool

    public init(
        id: UUID,
        headerText: String,
        bodyText: String,
        isCollapsed: Bool = false
    ) {
        self.id = id
        self.headerText = headerText
        self.bodyText = bodyText
        self.isCollapsed = isCollapsed
    }
}

/// UTF-16 ranges for one scene in the concatenated document.
public struct FullScriptSegment: Equatable, Sendable {
    public var sceneID: UUID
    /// The whole header, including its trailing newline. Never editable.
    public var headerRange: NSRange
    /// Exactly the scene's `scriptText` (zero-length for an empty or collapsed
    /// scene). This is the only editable region in the document.
    public var bodyRange: NSRange
    /// The newline after the body. Never editable; it separates the scene from
    /// the next header.
    public var separatorRange: NSRange
    public var isCollapsed: Bool

    public var sceneRange: NSRange {
        NSRange(
            location: headerRange.location,
            length: NSMaxRange(separatorRange) - headerRange.location
        )
    }
}

/// The result of asking a layout whether AppKit may apply an edit.
public struct FullScriptEditTarget: Equatable, Sendable {
    public var sceneID: UUID
    /// The affected range translated into the scene's own `scriptText`.
    public var localRange: NSRange
    /// The scene body range in the concatenated document.
    public var bodyRange: NSRange

    public init(sceneID: UUID, localRange: NSRange, bodyRange: NSRange) {
        self.sceneID = sceneID
        self.localRange = localRange
        self.bodyRange = bodyRange
    }
}

/// Immutable range-to-scene map for the full-script editor.
///
/// Ranges are in UTF-16 units, matching `NSRange`, `NSString` and NSTextStorage.
/// Build a new layout after every text change; building is O(document length)
/// and never touches AppKit.
public struct FullScriptLayout: Equatable, Sendable {
    public let text: String
    public let segments: [FullScriptSegment]

    public init(scenes: [FullScriptSceneDescriptor]) {
        var pieces: [String] = []
        pieces.reserveCapacity(scenes.count * 3)
        var ranges: [FullScriptSegment] = []
        ranges.reserveCapacity(scenes.count)
        var location = 0

        for scene in scenes {
            let header = scene.headerText + "\n"
            let headerLength = header.utf16.count
            let headerRange = NSRange(location: location, length: headerLength)
            location += headerLength

            let body = scene.isCollapsed ? "" : scene.bodyText
            let bodyLength = body.utf16.count
            let bodyRange = NSRange(location: location, length: bodyLength)
            location += bodyLength

            let separatorRange = NSRange(location: location, length: 1)
            location += 1

            pieces.append(header)
            pieces.append(body)
            pieces.append("\n")
            ranges.append(FullScriptSegment(
                sceneID: scene.id,
                headerRange: headerRange,
                bodyRange: bodyRange,
                separatorRange: separatorRange,
                isCollapsed: scene.isCollapsed
            ))
        }

        text = pieces.joined()
        segments = ranges
    }

    public var utf16Length: Int {
        (text as NSString).length
    }

    public var isEmpty: Bool {
        segments.isEmpty
    }

    public func segment(for sceneID: UUID) -> FullScriptSegment? {
        segments.first { $0.sceneID == sceneID }
    }

    /// Scene that owns `location`, including the header half of a boundary.
    ///
    /// The body wins at its own start (so typing at the very start of a scene
    /// never resolves to the previous scene), the containing header wins over
    /// a separator, and the end of the document belongs to the last scene.
    public func sceneID(atUTF16Location location: Int) -> UUID? {
        guard location >= 0, location <= utf16Length else { return nil }
        for segment in segments {
            let body = segment.bodyRange
            if location >= body.location, location <= NSMaxRange(body) {
                return segment.sceneID
            }
        }
        for segment in segments {
            let header = segment.headerRange
            if location >= header.location, location < NSMaxRange(header) {
                return segment.sceneID
            }
        }
        for segment in segments {
            let separator = segment.separatorRange
            if location >= separator.location, location <= NSMaxRange(separator) {
                return segment.sceneID
            }
        }
        return nil
    }

    /// Returns the scene that must receive this edit, or `nil` when the edit
    /// touches a header, a separator, spans scenes, is out of bounds or targets
    /// a collapsed scene.
    ///
    /// - Zero-length edits (typing/Return) are accepted at both body edges.
    /// - Non-empty edits are accepted only when the whole range is inside one
    ///   body. This is what rejects select-all, cross-scene paste and Backspace
    ///   at a body start / forward-delete at a body end.
    public func resolveEdit(in range: NSRange) -> FullScriptEditTarget? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        let documentLength = utf16Length
        guard range.location <= documentLength else { return nil }
        guard range.length <= documentLength - range.location else { return nil }

        for segment in segments where !segment.isCollapsed {
            let body = segment.bodyRange
            if range.length == 0 {
                guard range.location >= body.location, range.location <= NSMaxRange(body) else {
                    continue
                }
            } else {
                guard range.location >= body.location,
                      range.length <= NSMaxRange(body) - range.location else {
                    continue
                }
            }
            return FullScriptEditTarget(
                sceneID: segment.sceneID,
                localRange: NSRange(
                    location: range.location - body.location,
                    length: range.length
                ),
                bodyRange: body
            )
        }
        return nil
    }

    /// Body length after applying `edit`. The app uses this to validate that
    /// AppKit changed only the authorized scene before committing anything.
    public func bodyLength(
        afterApplying edit: FullScriptEditTarget,
        replacementLength: Int
    ) -> Int? {
        guard let segment = segment(for: edit.sceneID),
              edit.localRange.location >= 0,
              edit.localRange.length >= 0,
              edit.localRange.location <= segment.bodyRange.length,
              edit.localRange.length <= segment.bodyRange.length - edit.localRange.location,
              replacementLength >= 0 else {
            return nil
        }
        return segment.bodyRange.length - edit.localRange.length + replacementLength
    }
}
