import Foundation
import Testing
import FrameScriptCore

@Suite("W3FixCDH timeline anchoring")
struct W3FixCDHTimelineAnchoringTests {
    @Test("W3FixCDH the batch anchor API matches the single-offset API")
    func batchMatchesSingle() {
        let text = """
        Hoy probamos el coche en mojado. [RE-HOOK] La presión importa *mucho* más que la marca.
        / Un segundo de pausa // y otro más. Después comparamos tres neumáticos con telemetría real.
        RÓTULO: presión 2.1 bares
        """

        var generator = W3FixCDHGenerator(seed: 0xC0FFEE)
        let offsets = (0..<50).map { _ in
            Int.random(in: 0...((text as NSString).length), using: &generator)
        }
        let batch = TimelineAnchoring.seconds(
            text: text,
            utf16Offsets: offsets,
            wordsPerMinute: 150,
            defaults: .standard
        )
        let single = offsets.map { offset in
            TimelineAnchoring.seconds(
                text: text,
                utf16Offset: offset,
                wordsPerMinute: 150,
                defaults: .standard
            )
        }

        #expect(batch.count == single.count)
        for (index, pair) in zip(batch, single).enumerated() {
            #expect(
                abs(pair.0 - pair.1) < 0.000_001,
                "offset \(offsets[index]) differs: \(pair.0) vs \(pair.1)"
            )
        }
    }
}

/// Deterministic generator so a failure can be reproduced.
private struct W3FixCDHGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
