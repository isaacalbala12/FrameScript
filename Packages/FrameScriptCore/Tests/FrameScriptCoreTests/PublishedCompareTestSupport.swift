import Foundation
import Testing
@testable import FrameScriptCore

enum PublishedCompareFixtures {
    static func text(_ name: String, extension ext: String) throws -> String {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: ext,
                subdirectory: "Fixtures/PublishedCompare"
            ),
            "Missing fixture \(name).\(ext)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }
}

func approximatelyEqual(_ lhs: Double?, _ rhs: Double, tolerance: Double = 0.001) -> Bool {
    guard let lhs else { return false }
    return abs(lhs - rhs) <= tolerance
}
