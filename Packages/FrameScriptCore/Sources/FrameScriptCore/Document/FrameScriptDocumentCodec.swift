import Foundation

public enum FrameScriptDocumentError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedVersion(Int)
    case duplicateSceneID(UUID)
    case invalidAnchor

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            if version > FrameScriptFormat.currentFileVersion {
                return "This project was saved by a newer version of FrameScript (file version \(version)). Update FrameScript to open it."
            }
            return "Unsupported FrameScript project file version \(version)."
        case .duplicateSceneID:
            return "The project file contains duplicate scene identifiers."
        case .invalidAnchor:
            return "The project file contains an invalid text anchor."
        }
    }
}

/// Reads and writes `.fscr` documents.
///
/// Readers accept versions 1 through 4 and migrate in memory. Writers always
/// emit version 4. Files with a newer version fail with a clear error instead
/// of being silently downgraded.
public enum FrameScriptDocumentCodec {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Encodes a document, forcing the current schema version.
    public static func encode(_ document: FrameScriptDocument) throws -> Data {
        var document = document
        document.fileVersion = FrameScriptFormat.currentFileVersion
        return try makeEncoder().encode(document)
    }

    /// Decodes a document and migrates it to the current schema version.
    public static func decode(_ data: Data) throws -> FrameScriptDocument {
        let document = try makeDecoder().decode(FrameScriptDocument.self, from: data)
        return try document.migrated()
    }

    public static func read(from url: URL) throws -> FrameScriptDocument {
        try decode(Data(contentsOf: url))
    }

    /// Atomically writes a document next to its destination.
    public static func write(_ document: FrameScriptDocument, to url: URL) throws {
        let data = try encode(document)
        try data.write(to: url, options: .atomic)
    }
}
