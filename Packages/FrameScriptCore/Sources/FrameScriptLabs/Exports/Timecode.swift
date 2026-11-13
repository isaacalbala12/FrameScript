import Foundation

/// A rational frame rate.
///
/// NTSC rates are stored exactly as `30000/1001` and friends so that frame
/// arithmetic never drifts. The nominal integer rate (24, 30, 60…) is what
/// timecode labels are counted with.
public struct FrameRate: Sendable, Hashable, Codable, CustomStringConvertible {
    public let numerator: Int
    public let denominator: Int

    public init(numerator: Int, denominator: Int) {
        precondition(numerator > 0 && denominator > 0, "Frame rate must be positive")
        let divisor = Self.greatestCommonDivisor(numerator, denominator)
        self.numerator = numerator / divisor
        self.denominator = denominator / divisor
    }

    private enum CodingKeys: String, CodingKey {
        case numerator
        case denominator
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let numerator = try container.decode(Int.self, forKey: .numerator)
        let denominator = try container.decode(Int.self, forKey: .denominator)
        guard numerator > 0, denominator > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .denominator,
                in: container,
                debugDescription: "Frame rate must be positive"
            )
        }
        self.init(numerator: numerator, denominator: denominator)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(numerator, forKey: .numerator)
        try container.encode(denominator, forKey: .denominator)
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            (x, y) = (y, x % y)
        }
        return x == 0 ? 1 : x
    }

    public static let fps23_976 = FrameRate(numerator: 24_000, denominator: 1_001)
    public static let fps24 = FrameRate(numerator: 24, denominator: 1)
    public static let fps25 = FrameRate(numerator: 25, denominator: 1)
    public static let fps29_97 = FrameRate(numerator: 30_000, denominator: 1_001)
    public static let fps30 = FrameRate(numerator: 30, denominator: 1)
    public static let fps50 = FrameRate(numerator: 50, denominator: 1)
    public static let fps59_94 = FrameRate(numerator: 60_000, denominator: 1_001)
    public static let fps60 = FrameRate(numerator: 60, denominator: 1)

    public static let all: [FrameRate] = [
        .fps23_976, .fps24, .fps25, .fps29_97, .fps30, .fps50, .fps59_94, .fps60,
    ]

    /// Integer rate used for timecode labels: 24, 25, 30, 50 or 60.
    public var nominalFPS: Int {
        Int((Double(numerator) / Double(denominator)).rounded())
    }

    /// Real frames per second, e.g. 29.97002997.
    public var framesPerSecond: Double {
        Double(numerator) / Double(denominator)
    }

    /// Only 29.97 and 59.94 support SMPTE drop-frame numbering.
    public var supportsDropFrame: Bool {
        self == .fps29_97 || self == .fps59_94
    }

    public var isNTSC: Bool { denominator == 1_001 }

    /// Two dropped frame numbers per minute (four at 59.94).
    public var droppedFrameNumbersPerMinute: Int {
        self == .fps59_94 ? 4 : 2
    }

    /// "23.976", "29.97", "25"…
    public var description: String {
        switch self {
        case .fps23_976: "23.976"
        case .fps29_97: "29.97"
        case .fps59_94: "59.94"
        default: "\(nominalFPS)"
        }
    }
}

/// An absolute frame count on a timeline.
///
/// `Timecode` deliberately stores frames only. Whether the label is drop-frame
/// is a property of the format being written, passed to `string(rate:dropFrame:)`.
public struct Timecode: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let frames: Int

    public init(frames: Int) {
        precondition(frames >= 0, "Timecode cannot be negative")
        self.frames = frames
    }

    public static let zero = Timecode(frames: 0)

    /// Rounds to the nearest frame, clamped at zero.
    ///
    /// Non-finite or out-of-range input (for example `.infinity`) becomes zero
    /// instead of trapping.
    public init(seconds: TimeInterval, rate: FrameRate) {
        let value = seconds * rate.framesPerSecond
        guard value.isFinite, value >= 0, let rounded = Int(exactly: value.rounded()) else {
            self.frames = 0
            return
        }
        self.frames = max(0, rounded)
    }

    private enum CodingKeys: String, CodingKey {
        case frames
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let frames = try container.decode(Int.self, forKey: .frames)
        guard frames >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .frames,
                in: container,
                debugDescription: "Timecode cannot be negative"
            )
        }
        self.init(frames: frames)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frames, forKey: .frames)
    }

    /// 01:00:00:00 as Resolve starts new timelines (01:00:00;00 at 29.97 DF).
    public static func oneHour(rate: FrameRate, dropFrame: Bool) -> Timecode {
        var frames = 3_600 * rate.nominalFPS
        if dropFrame && rate.supportsDropFrame {
            // 60 minutes minus the six tenth minutes that are not dropped.
            frames -= rate.droppedFrameNumbersPerMinute * (60 - 60 / 10)
        }
        return Timecode(frames: frames)
    }

    public func seconds(rate: FrameRate) -> TimeInterval {
        Double(frames) * Double(rate.denominator) / Double(rate.numerator)
    }

    public func advanced(by count: Int) -> Timecode {
        Timecode(frames: frames + count)
    }

    public static func + (lhs: Timecode, rhs: Int) -> Timecode {
        lhs.advanced(by: rhs)
    }

    public static func < (lhs: Timecode, rhs: Timecode) -> Bool {
        lhs.frames < rhs.frames
    }

    public var description: String {
        String(format: "%d", frames)
    }

    /// Formats the frame count as `HH:MM:SS:FF` (NDF) or `HH:MM:SS;FF` (DF).
    public func string(rate: FrameRate, dropFrame: Bool) -> String {
        let effectiveDrop = dropFrame && rate.supportsDropFrame
        let labelled = labelledFrameNumber(rate: rate, dropFrame: effectiveDrop)
        let nominal = rate.nominalFPS
        let framePart = labelled % nominal
        let totalSeconds = labelled / nominal
        let secondPart = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutePart = totalMinutes % 60
        let hourPart = totalMinutes / 60
        let separator = effectiveDrop ? ";" : ":"
        return String(
            format: "%02d:%02d:%02d%@%02d",
            hourPart, minutePart, secondPart, separator, framePart
        )
    }

    /// Parses `HH:MM:SS:FF` or `HH:MM:SS;FF`.
    ///
    /// A semicolon implies drop frame. When `dropFrame` is passed explicitly it
    /// wins. Invalid or skipped labels (00:01:00;00 at 29.97) return `nil`.
    public init?(string: String, rate: FrameRate, dropFrame: Bool? = nil) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let inferredDrop = trimmed.contains(";")
        let isDrop = dropFrame ?? inferredDrop
        guard !isDrop || rate.supportsDropFrame else { return nil }

        let normalized = trimmed.replacingOccurrences(of: ";", with: ":")
        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        guard parts.allSatisfy({ $0.count == 2 }) else { return nil }

        guard
            let hours = Int(parts[0]),
            let minutes = Int(parts[1]),
            let seconds = Int(parts[2]),
            let framePart = Int(parts[3])
        else { return nil }

        guard (0...23).contains(hours),
              (0...59).contains(minutes),
              (0...59).contains(seconds),
              (0..<rate.nominalFPS).contains(framePart)
        else { return nil }

        var total = ((hours * 3_600 + minutes * 60 + seconds) * rate.nominalFPS) + framePart
        if isDrop {
            let totalMinutes = hours * 60 + minutes
            total -= rate.droppedFrameNumbersPerMinute * (totalMinutes - totalMinutes / 10)
        }
        guard total >= 0 else { return nil }

        let parsed = Timecode(frames: total)
        let separator = isDrop ? ";" : ":"
        let canonical = String(
            format: "%02d:%02d:%02d%@%02d",
            hours, minutes, seconds, separator, framePart
        )
        // Round-tripping rejects labels that drop-frame numbering skips.
        guard parsed.string(rate: rate, dropFrame: isDrop) == canonical else { return nil }
        self = parsed
    }

    /// Converts a frame count to the label number, dropping the right labels.
    private func labelledFrameNumber(rate: FrameRate, dropFrame: Bool) -> Int {
        guard dropFrame else { return frames }
        let nominal = rate.nominalFPS
        let drop = rate.droppedFrameNumbersPerMinute
        let framesPerMinute = nominal * 60 - drop
        let framesPerTenMinutes = nominal * 600 - drop * 9

        let tenMinuteBlocks = frames / framesPerTenMinutes
        let remainder = frames % framesPerTenMinutes
        var labelled = frames + drop * 9 * tenMinuteBlocks
        if remainder > drop {
            labelled += drop * ((remainder - drop) / framesPerMinute)
        }
        return labelled
    }
}

/// Human-readable `m:ss` / `h:mm:ss` timestamps used by chapters and notes.
public enum DurationFormat {
    public static func clock(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let secondPart = clamped % 60
        let totalMinutes = clamped / 60
        let minutePart = totalMinutes % 60
        let hourPart = totalMinutes / 60
        if hourPart > 0 {
            return String(format: "%d:%02d:%02d", hourPart, minutePart, secondPart)
        }
        return String(format: "%d:%02d", minutePart, secondPart)
    }

    public static func clock(frames: Int, rate: FrameRate) -> String {
        // Display timestamps round to the nearest second: 35964 frames at
        // 29.97 is 1199.9994 s and must print 20:00, not 19:59.
        let seconds = Int((Double(frames) * Double(rate.denominator) / Double(rate.numerator)).rounded())
        return clock(seconds: seconds)
    }

    public static func clock(seconds: TimeInterval, rate: FrameRate) -> String {
        // Durations are display-only; round to the nearest second. Chapter
        // starts use the frame-accurate, floor-based overload above.
        clock(seconds: Int(max(0, seconds).rounded()))
    }
}
