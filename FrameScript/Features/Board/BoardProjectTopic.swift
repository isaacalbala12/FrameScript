import Foundation

/// Bridges the board's game/topic field and `FrameProject.topic`.
///
/// F6 stores the escaleta's human-readable notes and round-trip metadata in
/// `FrameProject.topic` because the v4 schema is frozen. The board must not
/// overwrite that block when the user classifies an imported project, so its
/// game/topic travels in one extra marker line at the top of the same string.
/// Plain projects keep using the field as a plain game/topic string.
enum BoardProjectTopic {
    static let marker = "__framescript_board_topic__:"

    /// Value shown in the board and project info.
    static func display(from stored: String) -> String {
        if let value = markedTopic(in: stored) {
            return value
        }
        if hasEscaletaNotes(stored) {
            return ""
        }
        return stored.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes a game/topic while preserving an escaleta notes block.
    static func merging(_ value: String, into stored: String) -> String {
        let game = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutMarker = removingMarkerLine(from: stored)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard hasEscaletaNotes(stored) else {
            // Plain project: keep the field plain so other features that read
            // `topic` as text never see the marker.
            return game
        }
        guard !game.isEmpty else {
            return withoutMarker
        }
        let encoded = Data(game.utf8).base64EncodedString()
        let markerLine = marker + encoded
        guard !withoutMarker.isEmpty else { return markerLine }
        return "\(markerLine)\n\n\(withoutMarker)"
    }

    // MARK: Helpers

    static func markedTopic(in stored: String) -> String? {
        for line in stored.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(marker) else { continue }
            let encoded = String(trimmed.dropFirst(marker.count))
            guard let data = Data(base64Encoded: encoded),
                  let value = String(data: data, encoding: .utf8) else {
                return nil
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// The stored text without the board marker. Other features that read
    /// `topic` as notes (the hook prompt) use this so the internal marker never
    /// leaks into their context.
    static func strippingMarker(from stored: String) -> String {
        removingMarkerLine(from: stored)
    }

    static func hasEscaletaNotes(_ stored: String) -> Bool {
        !EscaletaProjectNotes.decode(stored).isEmpty
    }

    private static func removingMarkerLine(from stored: String) -> String {
        stored
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(marker) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
