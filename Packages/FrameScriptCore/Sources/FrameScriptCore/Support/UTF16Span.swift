import Foundation

/// A half-open range measured in UTF-16 code units.
///
/// The app stores text anchors and editor selections as UTF-16 offsets because
/// `NSTextView` and the `.fscr` format use them. Diff operations and rhythm
/// warnings expose the same coordinates so the UI can underline or highlight
/// without converting between index systems.
public struct UTF16Span: Sendable, Hashable, Codable, CustomStringConvertible {
    /// Offset from the start of the string, in UTF-16 code units.
    public let location: Int
    /// Number of UTF-16 code units covered. Always `>= 0` for ranges produced by
    /// this package.
    public let length: Int

    public init(location: Int, length: Int = 0) {
        self.location = location
        self.length = length
    }

    public init(_ range: Range<Int>) {
        self.location = range.lowerBound
        self.length = range.upperBound - range.lowerBound
    }

    public var range: Range<Int> { location..<(location + length) }

    public var end: Int { location + length }

    public var isEmpty: Bool { length == 0 }

    public static let zero = UTF16Span(location: 0)

    public func contains(_ offset: Int) -> Bool {
        offset >= location && offset < end
    }

    public var description: String { "\(location)..<\(end)" }
}
