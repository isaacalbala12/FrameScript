import Compression
import Foundation

/// Errors thrown while encoding or decoding a compressed snapshot.
public enum SnapshotCodecError: Error, Equatable, Sendable {
    case compressionFailed
    case decompressionFailed
    case notASnapshot
    case unsupportedVersion(UInt8)
    case unsupportedFlags(UInt8)
    case malformedHeader
    case truncated(expected: Int, actual: Int)
    case lengthMismatch(expected: Int, actual: Int)
    case checksumMismatch(expected: UInt32, actual: UInt32)
    case sizeLimitExceeded(limit: Int)
    case invalidBase64
}

/// Compresses snapshot payloads with zlib and a small self-describing header.
///
/// Layout (little endian):
///
///     magic      4 bytes  "FSSC"
///     version    1 byte   currently 1
///     flags      1 byte   0 = zlib
///     reserved   2 bytes  must be 0
///     rawLength  8 bytes  uncompressed byte count
///     zipLength  8 bytes  compressed byte count
///     crc32      4 bytes  CRC-32 (IEEE) of the uncompressed bytes
///     payload    zipLength bytes
///
/// The header makes a corrupted or truncated payload detectable before the app
/// tries to decode JSON, and the CRC-32 catches zlib streams that happen to
/// inflate successfully after bit rot.
///
/// Decompression enforces an output-size limit (64 MiB by default) both before
/// allocating and while inflating, so a malicious compressed snapshot cannot
/// expand into an arbitrarily large buffer.
public enum SnapshotCodec {
    public static let magic: [UInt8] = [0x46, 0x53, 0x53, 0x43] // "FSSC"
    public static let currentVersion: UInt8 = 1
    public static let headerSize = 28

    /// Default guard against decompression bombs. A snapshot of a script is far
    /// smaller than this; callers can pass a different limit to `decompress`.
    public static let defaultMaximumUncompressedSize = 64 * 1024 * 1024

    // MARK: - Data API

    public static func compress(_ data: Data) throws -> Data {
        let payload: Data
        do {
            payload = try (data as NSData).compressed(using: .zlib) as Data
        } catch {
            throw SnapshotCodecError.compressionFailed
        }

        var output = Data()
        output.reserveCapacity(headerSize + payload.count)
        output.append(contentsOf: magic)
        output.append(currentVersion)
        output.append(0) // flags: zlib
        output.append(0) // reserved
        output.append(0) // reserved
        appendUInt64(UInt64(data.count), to: &output)
        appendUInt64(UInt64(payload.count), to: &output)
        appendUInt32(CRC32.checksum(data), to: &output)
        output.append(payload)
        return output
    }

    public static func decompress(
        _ data: Data,
        maximumUncompressedSize: Int = SnapshotCodec.defaultMaximumUncompressedSize
    ) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize else {
            throw SnapshotCodecError.truncated(expected: headerSize, actual: bytes.count)
        }
        guard Array(bytes[0..<4]) == magic else {
            throw SnapshotCodecError.notASnapshot
        }
        let version = bytes[4]
        guard version == currentVersion else {
            throw SnapshotCodecError.unsupportedVersion(version)
        }
        let flags = bytes[5]
        guard flags == 0 else {
            throw SnapshotCodecError.unsupportedFlags(flags)
        }
        guard bytes[6] == 0, bytes[7] == 0 else {
            throw SnapshotCodecError.malformedHeader
        }

        let rawLengthValue = readUInt64(bytes, at: 8)
        let zipLengthValue = readUInt64(bytes, at: 16)
        let checksum = readUInt32(bytes, at: 24)

        guard rawLengthValue <= UInt64(Int.max),
              zipLengthValue <= UInt64(Int.max - headerSize) else {
            throw SnapshotCodecError.malformedHeader
        }
        let rawLength = Int(rawLengthValue)
        let zipLength = Int(zipLengthValue)
        let limit = max(0, maximumUncompressedSize)
        guard rawLength <= limit else {
            throw SnapshotCodecError.sizeLimitExceeded(limit: limit)
        }
        let payloadCount = bytes.count - headerSize
        guard payloadCount == zipLength else {
            throw SnapshotCodecError.truncated(
                expected: headerSize + zipLength,
                actual: bytes.count
            )
        }

        let payload = data.subdata(in: (data.startIndex + headerSize)..<data.endIndex)
        let inflated = try inflate(payload, expectedLength: rawLength)

        let computed = CRC32.checksum(inflated)
        guard computed == checksum else {
            throw SnapshotCodecError.checksumMismatch(expected: checksum, actual: computed)
        }
        return inflated
    }

    // MARK: - Base64 helpers (D4 stores snapshots as base64 inside .fscr)

    public static func compressToBase64(_ data: Data) throws -> String {
        try compress(data).base64EncodedString()
    }

    public static func decompress(
        base64 string: String,
        maximumUncompressedSize: Int = SnapshotCodec.defaultMaximumUncompressedSize
    ) throws -> Data {
        guard let encoded = Data(base64Encoded: string) else {
            throw SnapshotCodecError.invalidBase64
        }
        return try decompress(encoded, maximumUncompressedSize: maximumUncompressedSize)
    }

    // MARK: - Streaming inflate with a hard output cap

    /// Inflates a zlib payload, refusing to allocate more than the declared
    /// uncompressed length. A lying header therefore stops after roughly
    /// `expectedLength + 64 KiB` instead of expanding a decompression bomb.
    private static func inflate(_ payload: Data, expectedLength: Int) throws -> Data {
        guard !payload.isEmpty else {
            if expectedLength == 0 { return Data() }
            throw SnapshotCodecError.decompressionFailed
        }

        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { placeholder.deallocate() }
        var stream = compression_stream(
            dst_ptr: placeholder,
            dst_size: 0,
            src_ptr: UnsafePointer(placeholder),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(
            &stream,
            COMPRESSION_STREAM_DECODE,
            COMPRESSION_ZLIB
        ) == COMPRESSION_STATUS_OK else {
            throw SnapshotCodecError.decompressionFailed
        }
        defer { compression_stream_destroy(&stream) }

        return try payload.withUnsafeBytes { rawBuffer -> Data in
            guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw SnapshotCodecError.decompressionFailed
            }
            stream.src_ptr = source
            stream.src_size = rawBuffer.count

            var output = Data()
            output.reserveCapacity(min(expectedLength, 1 << 20))
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var previousSourceSize = -1

            while true {
                let (status, produced) = buffer.withUnsafeMutableBufferPointer {
                    destination -> (compression_status, Int) in
                    guard let base = destination.baseAddress else {
                        return (COMPRESSION_STATUS_ERROR, 0)
                    }
                    stream.dst_ptr = base
                    stream.dst_size = destination.count
                    let status = compression_stream_process(
                        &stream,
                        Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                    )
                    let produced = destination.count - stream.dst_size
                    if produced > 0 {
                        output.append(base, count: produced)
                    }
                    return (status, produced)
                }

                if output.count > expectedLength {
                    throw SnapshotCodecError.lengthMismatch(
                        expected: expectedLength,
                        actual: output.count
                    )
                }

                switch status {
                case COMPRESSION_STATUS_END:
                    guard output.count == expectedLength else {
                        throw SnapshotCodecError.lengthMismatch(
                            expected: expectedLength,
                            actual: output.count
                        )
                    }
                    return output
                case COMPRESSION_STATUS_OK:
                    if produced == 0, stream.src_size == previousSourceSize {
                        throw SnapshotCodecError.decompressionFailed
                    }
                    previousSourceSize = stream.src_size
                    continue
                default:
                    throw SnapshotCodecError.decompressionFailed
                }
            }
        }
    }

    // MARK: - Byte helpers

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 0, through: 56, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
        }
        return value
    }
}

/// CRC-32 (IEEE 802.3, polynomial 0xEDB88320), used as the snapshot integrity
/// check. Implemented locally so the core package keeps depending only on
/// Foundation.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { rawBuffer in
            for byte in rawBuffer {
                let index = Int((crc ^ UInt32(byte)) & 0xFF)
                crc = table[index] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
