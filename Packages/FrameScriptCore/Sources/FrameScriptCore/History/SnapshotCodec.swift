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
public enum SnapshotCodec {
    public static let magic: [UInt8] = [0x46, 0x53, 0x53, 0x43] // "FSSC"
    public static let currentVersion: UInt8 = 1
    public static let headerSize = 28

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

    public static func decompress(_ data: Data) throws -> Data {
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
        let payloadCount = bytes.count - headerSize
        guard payloadCount == zipLength else {
            throw SnapshotCodecError.truncated(
                expected: headerSize + zipLength,
                actual: bytes.count
            )
        }

        let payload = data.subdata(in: (data.startIndex + headerSize)..<data.endIndex)
        let inflated: Data
        do {
            inflated = try (payload as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw SnapshotCodecError.decompressionFailed
        }

        guard inflated.count == rawLength else {
            throw SnapshotCodecError.lengthMismatch(expected: rawLength, actual: inflated.count)
        }
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

    public static func decompress(base64 string: String) throws -> Data {
        guard let encoded = Data(base64Encoded: string) else {
            throw SnapshotCodecError.invalidBase64
        }
        return try decompress(encoded)
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
