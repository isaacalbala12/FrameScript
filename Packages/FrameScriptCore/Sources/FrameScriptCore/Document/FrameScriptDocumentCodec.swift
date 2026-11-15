import Foundation
#if canImport(Darwin)
import Darwin
#endif

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
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.iso8601String(from: date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = Self.date(fromISO8601: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date: \(value)"
                )
            }
            return date
        }
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
    ///
    /// A symlinked destination is resolved first: the target is replaced and the
    /// link itself stays a link. When the destination exists, the old file is
    /// replaced via `FileManager.replaceItemAt` after copying extended
    /// attributes. This keeps Finder tags and other xattrs attached to the
    /// project file. POSIX mode is preserved by the replace operation. If
    /// replacing is not possible, the writer falls back to Foundation's atomic
    /// write and re-applies the extended attributes by hand.
    public static func write(_ document: FrameScriptDocument, to url: URL) throws {
        let data = try encode(document)
        try writeEncoded(data, to: url)
    }

    /// Writes bytes that were already produced by `encode(_:)`.
    ///
    /// Callers use this to remember the exact bytes they wrote as their
    /// external-change fingerprint instead of re-reading the file (a newer
    /// external write between the two would be adopted silently).
    public static func writeEncoded(_ data: Data, to url: URL) throws {
        try writeAtomically(data, to: url)
    }

    // MARK: Dates

    /// ISO-8601 with fractional seconds. Existing plain ISO-8601 files remain
    /// readable through the decoder fallbacks.
    public static func iso8601String(from date: Date) -> String {
        let formatter = makeDateFormatter(format: "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX")
        return formatter.string(from: date)
    }

    public static func date(fromISO8601 value: String) -> Date? {
        let fractional = makeDateFormatter(format: "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX")
        if let date = fractional.date(from: value) { return date }
        let milliseconds = makeDateFormatter(format: "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX")
        if let date = milliseconds.date(from: value) { return date }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let fractionalISO = ISO8601DateFormatter()
        fractionalISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalISO.date(from: value)
    }

    private static func makeDateFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    // MARK: Atomic write

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        // Save through a symlink must update the target and keep the link.
        let target = writeTarget(for: url)
        guard fileManager.fileExists(atPath: target.path) else {
            try data.write(to: target, options: .atomic)
            return
        }

        let directory = target.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".\(target.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporaryURL, options: [])
            copyExtendedAttributes(from: target, to: temporaryURL)
            _ = try fileManager.replaceItemAt(target, withItemAt: temporaryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            // The atomic fallback replaces the file, which drops its extended
            // attributes, so carry them across explicitly.
            let attributes = readExtendedAttributes(at: target)
            try data.write(to: target, options: .atomic)
            applyExtendedAttributes(attributes, to: target)
        }
    }

    // MARK: Extended attributes

    /// Resolves a symlink chain by hand when the final component is a link whose
    /// target does not exist yet (`resolvingSymlinksInPath()` stops at the
    /// dangling link). Parent-directory symlinks are still resolved by
    /// `resolvingSymlinksInPath()` on the final target.
    private static func writeTarget(for url: URL, depth: Int = 0) -> URL {
        let standardized = url.standardizedFileURL
        guard depth < 8,
              let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: standardized.path)
        else {
            return standardized.resolvingSymlinksInPath()
        }
        let base = standardized.deletingLastPathComponent()
        let next = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : base.appendingPathComponent(destination)
        return writeTarget(for: next, depth: depth + 1)
    }

    private static func readExtendedAttributes(at url: URL) -> [String: Data] {
        #if canImport(Darwin)
        let nameSize = url.path.withCString { listxattr($0, nil, 0, XATTR_NOFOLLOW) }
        guard nameSize > 0 else { return [:] }

        var names = [CChar](repeating: 0, count: nameSize)
        let readSize = url.path.withCString { path in
            names.withUnsafeMutableBufferPointer { buffer in
                listxattr(path, buffer.baseAddress, nameSize, XATTR_NOFOLLOW)
            }
        }
        guard readSize > 0 else { return [:] }

        var attributes: [String: Data] = [:]
        var offset = 0
        while offset < readSize {
            let name = names.withUnsafeBufferPointer { buffer -> String in
                String(cString: buffer.baseAddress!.advanced(by: offset))
            }
            offset += name.utf8.count + 1

            let valueSize = url.path.withCString { path in
                name.withCString { namePointer in
                    getxattr(path, namePointer, nil, 0, 0, XATTR_NOFOLLOW)
                }
            }
            guard valueSize > 0 else { continue }

            var value = [UInt8](repeating: 0, count: valueSize)
            let copied = url.path.withCString { path in
                name.withCString { namePointer in
                    value.withUnsafeMutableBytes { buffer in
                        getxattr(path, namePointer, buffer.baseAddress, valueSize, 0, XATTR_NOFOLLOW)
                    }
                }
            }
            guard copied == valueSize else { continue }
            attributes[name] = Data(value)
        }
        return attributes
        #else
        return [:]
        #endif
    }

    private static func applyExtendedAttributes(_ attributes: [String: Data], to url: URL) {
        #if canImport(Darwin)
        for (name, value) in attributes {
            _ = url.path.withCString { path in
                name.withCString { namePointer in
                    value.withUnsafeBytes { buffer in
                        setxattr(path, namePointer, buffer.baseAddress, value.count, 0, XATTR_NOFOLLOW)
                    }
                }
            }
        }
        #endif
    }

    private static func copyExtendedAttributes(from source: URL, to destination: URL) {
        #if canImport(Darwin)
        let nameSize = source.path.withCString { listxattr($0, nil, 0, XATTR_NOFOLLOW) }
        guard nameSize > 0 else { return }

        var names = [CChar](repeating: 0, count: nameSize)
        let readSize = source.path.withCString { path in
            names.withUnsafeMutableBufferPointer { buffer in
                listxattr(path, buffer.baseAddress, nameSize, XATTR_NOFOLLOW)
            }
        }
        guard readSize > 0 else { return }

        var offset = 0
        while offset < readSize {
            let name = names.withUnsafeBufferPointer { buffer -> String in
                String(cString: buffer.baseAddress!.advanced(by: offset))
            }
            let next = offset + name.utf8.count + 1
            defer { offset = next }

            let valueSize = source.path.withCString { path in
                name.withCString { namePointer in
                    getxattr(path, namePointer, nil, 0, 0, XATTR_NOFOLLOW)
                }
            }
            guard valueSize > 0 else { continue }

            var value = [UInt8](repeating: 0, count: valueSize)
            let copied = source.path.withCString { path in
                name.withCString { namePointer in
                    value.withUnsafeMutableBytes { buffer in
                        getxattr(path, namePointer, buffer.baseAddress, valueSize, 0, XATTR_NOFOLLOW)
                    }
                }
            }
            guard copied == valueSize else { continue }

            _ = destination.path.withCString { path in
                name.withCString { namePointer in
                    value.withUnsafeBytes { buffer in
                        setxattr(path, namePointer, buffer.baseAddress, valueSize, 0, XATTR_NOFOLLOW)
                    }
                }
            }
        }
        #endif
    }
}
