import Foundation
import Testing
@testable import FrameScriptCore

@Suite("SnapshotCodec")
struct SnapshotCodecTests {
    @Test func roundTripsSmallPayloads() throws {
        let payloads: [Data] = [
            Data(),
            Data([0]),
            Data("hola mundo".utf8),
            Data(repeating: 0, count: 10_000),
            Data("El niño comió piña 🎬".utf8)
        ]
        for payload in payloads {
            let compressed = try SnapshotCodec.compress(payload)
            #expect(compressed.count >= SnapshotCodec.headerSize)
            let restored = try SnapshotCodec.decompress(compressed)
            #expect(restored == payload)
        }
    }

    @Test func roundTripsLargePayloads() throws {
        var generator = LCG(state: 42)
        var random = Data()
        random.reserveCapacity(1_000_000)
        for _ in 0..<1_000_000 {
            random.append(UInt8(truncatingIfNeeded: generator.next()))
        }
        let compressed = try SnapshotCodec.compress(random)
        let restored = try SnapshotCodec.decompress(compressed)
        #expect(restored == random)
    }

    @Test func compressibleDataGetsSmaller() throws {
        let text = String(repeating: "El coche gira en la curva. ", count: 5_000)
        let payload = Data(text.utf8)
        let compressed = try SnapshotCodec.compress(payload)
        #expect(compressed.count < payload.count)
    }

    @Test func base64RoundTrip() throws {
        let payload = Data("instantánea con acentos y emoji 🎥".utf8)
        let encoded = try SnapshotCodec.compressToBase64(payload)
        #expect(!encoded.isEmpty)
        let restored = try SnapshotCodec.decompress(base64: encoded)
        #expect(restored == payload)
    }

    @Test func invalidBase64Throws() {
        #expect(throws: SnapshotCodecError.invalidBase64) {
            try SnapshotCodec.decompress(base64: "@@@not base64@@@")
        }
    }

    @Test func rejectsWrongMagic() throws {
        var data = try SnapshotCodec.compress(Data("hola".utf8))
        data[0] = 0
        #expect(throws: SnapshotCodecError.notASnapshot) {
            try SnapshotCodec.decompress(data)
        }
    }

    @Test func rejectsUnsupportedVersion() throws {
        var data = try SnapshotCodec.compress(Data("hola".utf8))
        data[4] = 99
        #expect(throws: SnapshotCodecError.unsupportedVersion(99)) {
            try SnapshotCodec.decompress(data)
        }
    }

    @Test func rejectsUnsupportedFlags() throws {
        var data = try SnapshotCodec.compress(Data("hola".utf8))
        data[5] = 7
        #expect(throws: SnapshotCodecError.unsupportedFlags(7)) {
            try SnapshotCodec.decompress(data)
        }
    }

    @Test func rejectsMalformedReservedBytes() throws {
        var data = try SnapshotCodec.compress(Data("hola".utf8))
        data[6] = 1
        #expect(throws: SnapshotCodecError.malformedHeader) {
            try SnapshotCodec.decompress(data)
        }
    }

    @Test func rejectsShortHeader() {
        #expect(throws: SnapshotCodecError.truncated(expected: 28, actual: 10)) {
            try SnapshotCodec.decompress(Data(repeating: 0, count: 10))
        }
    }

    @Test func rejectsTruncatedPayload() throws {
        var data = try SnapshotCodec.compress(Data("hola mundo".utf8))
        data.removeLast()
        do {
            _ = try SnapshotCodec.decompress(data)
            Issue.record("Decompressing truncated data should throw")
        } catch let error as SnapshotCodecError {
            switch error {
            case .truncated:
                break
            default:
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func detectsLengthMismatch() throws {
        var data = try SnapshotCodec.compress(Data("hola mundo".utf8))
        // Inflate the declared raw length by one.
        var rawLength: UInt64 = 0
        for index in 0..<8 {
            rawLength |= UInt64(data[8 + index]) << UInt64(index * 8)
        }
        let bumped = rawLength + 1
        for index in 0..<8 {
            data[8 + index] = UInt8(truncatingIfNeeded: bumped >> UInt64(index * 8))
        }
        #expect(throws: SnapshotCodecError.lengthMismatch(expected: Int(bumped), actual: Int(rawLength))) {
            try SnapshotCodec.decompress(data)
        }
    }

    @Test func detectsChecksumMismatch() throws {
        var data = try SnapshotCodec.compress(Data("hola mundo".utf8))
        data[24] ^= 0xFF
        do {
            _ = try SnapshotCodec.decompress(data)
            Issue.record("A checksum mismatch should throw")
        } catch let error as SnapshotCodecError {
            switch error {
            case .checksumMismatch:
                break
            default:
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func detectsCorruptedPayload() throws {
        let compressed = try SnapshotCodec.compress(Data("El niño comió piña y acción".utf8))
        var corrupted = compressed
        corrupted[corrupted.count - 1] ^= 0xFF
        do {
            _ = try SnapshotCodec.decompress(corrupted)
            Issue.record("Corrupted payload should throw")
        } catch let error as SnapshotCodecError {
            switch error {
            case .decompressionFailed, .checksumMismatch, .lengthMismatch:
                break
            default:
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func acceptsSlicedData() throws {
        let compressed = try SnapshotCodec.compress(Data("datos".utf8))
        var padded = Data([0x00, 0x01])
        padded.append(compressed)
        let slice = padded[2...]
        let restored = try SnapshotCodec.decompress(slice)
        #expect(restored == Data("datos".utf8))
    }
}

@Suite("SnapshotPolicy")
struct SnapshotPolicyTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func firstAutomaticSnapshotIsTaken() {
        let decision = SnapshotPolicy().decide(
            kind: .automatic,
            contentHash: 1,
            existing: [],
            now: base
        )
        #expect(decision.shouldTake)
        #expect(decision.evictedIDs.isEmpty)
    }

    @Test func unchangedContentIsSkipped() {
        let record = makeRecord(.automatic, at: 0, hash: 7)
        let decision = SnapshotPolicy().decide(
            kind: .automatic,
            contentHash: 7,
            existing: [record],
            now: base + 3_600
        )
        #expect(decision.action == .skip(.unchanged))
    }

    @Test func automaticSnapshotsAreThrottledToFiveMinutes() {
        let policy = SnapshotPolicy()
        let record = makeRecord(.automatic, at: 0, hash: 1)

        let tooSoon = policy.decide(
            kind: .automatic,
            contentHash: 2,
            existing: [record],
            now: base + 299
        )
        #expect(tooSoon.action == .skip(.throttled))

        let atLimit = policy.decide(
            kind: .automatic,
            contentHash: 2,
            existing: [record],
            now: base + 300
        )
        #expect(atLimit.shouldTake)
    }

    @Test func automaticSnapshotComparesAgainstMostRecentSnapshotOfAnyKind() {
        let named = makeRecord(.named, at: 100, hash: 42)
        let decision = SnapshotPolicy().decide(
            kind: .automatic,
            contentHash: 42,
            existing: [named],
            now: base + 101
        )
        #expect(decision.action == .skip(.unchanged))
    }

    @Test func namedSnapshotsAreAlwaysTaken() {
        let record = makeRecord(.automatic, at: 0, hash: 5)
        let decision = SnapshotPolicy().decide(
            kind: .named,
            contentHash: 5,
            existing: [record],
            now: base + 1
        )
        #expect(decision.shouldTake)
        #expect(decision.evictedIDs.isEmpty)
    }

    @Test func externalChangeSnapshotsAreAlwaysTaken() {
        let policy = SnapshotPolicy()
        let record = makeRecord(.automatic, at: 0, hash: 5)
        let sameHash = policy.decide(
            kind: .externalChange,
            contentHash: 5,
            existing: [record],
            now: base + 1
        )
        #expect(sameHash.shouldTake)

        let differentHash = policy.decide(
            kind: .externalChange,
            contentHash: 9,
            existing: [record],
            now: base + 2
        )
        #expect(differentHash.shouldTake)
    }

    @Test func capEvictsOldestAutomaticSnapshot() {
        let policy = SnapshotPolicy(automaticInterval: 0, maximumAutomaticSnapshots: 50)
        var records: [SnapshotRecord] = []
        for index in 0..<50 {
            records.append(makeRecord(.automatic, at: TimeInterval(index), hash: UInt64(index)))
        }
        let oldest = records[0].id
        let decision = policy.decide(
            kind: .automatic,
            contentHash: 999,
            existing: records,
            now: base + 10_000
        )
        #expect(decision.shouldTake)
        #expect(decision.evictedIDs == [oldest])
    }

    @Test func capEvictsMultipleOldestFirst() {
        let policy = SnapshotPolicy(automaticInterval: 0, maximumAutomaticSnapshots: 50)
        var records: [SnapshotRecord] = []
        for index in 0..<53 {
            records.append(makeRecord(.automatic, at: TimeInterval(index), hash: UInt64(index)))
        }
        let expected = Array(records.prefix(4)).map(\.id)
        let decision = policy.decide(
            kind: .automatic,
            contentHash: 999,
            existing: records,
            now: base + 10_000
        )
        #expect(decision.evictedIDs == expected)
    }

    @Test func namedSnapshotsAreNeverEvicted() {
        let policy = SnapshotPolicy(automaticInterval: 0, maximumAutomaticSnapshots: 2)
        let named = makeRecord(.named, at: -100, hash: 111)
        let first = makeRecord(.automatic, at: 0, hash: 1)
        let second = makeRecord(.automatic, at: 1, hash: 2)
        let decision = policy.decide(
            kind: .automatic,
            contentHash: 3,
            existing: [named, first, second],
            now: base + 10
        )
        #expect(decision.evictedIDs == [first.id])
        #expect(!decision.evictedIDs.contains(named.id))
    }

    @Test func belowCapDoesNotEvict() {
        let policy = SnapshotPolicy(automaticInterval: 0, maximumAutomaticSnapshots: 50)
        let records = (0..<49).map { makeRecord(.automatic, at: TimeInterval($0), hash: UInt64($0)) }
        let decision = policy.decide(
            kind: .automatic,
            contentHash: 123,
            existing: records,
            now: base + 1_000
        )
        #expect(decision.shouldTake)
        #expect(decision.evictedIDs.isEmpty)
    }

    @Test func externalSnapshotsDoNotConsumeAutomaticBudget() {
        let policy = SnapshotPolicy(automaticInterval: 0, maximumAutomaticSnapshots: 1)
        let auto = makeRecord(.automatic, at: 0, hash: 1)
        let external = makeRecord(.externalChange, at: 1, hash: 2)
        let decision = policy.decide(
            kind: .automatic,
            contentHash: 3,
            existing: [auto, external],
            now: base + 10
        )
        #expect(decision.shouldTake)
        #expect(decision.evictedIDs == [auto.id])
    }

    @Test func contentHashIsStable() {
        #expect(SnapshotHash.fnv1a64("") == 0xcbf2_9ce4_8422_2325)
        #expect(SnapshotHash.fnv1a64("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(SnapshotHash.fnv1a64("hola") == SnapshotHash.fnv1a64(Data("hola".utf8)))
        #expect(SnapshotHash.fnv1a64("hola") != SnapshotHash.fnv1a64("hola "))
    }

    private func makeRecord(
        _ kind: SnapshotKind,
        at seconds: TimeInterval,
        hash: UInt64
    ) -> SnapshotRecord {
        SnapshotRecord(kind: kind, createdAt: base + seconds, contentHash: hash)
    }
}
