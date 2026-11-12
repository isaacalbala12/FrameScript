import Foundation
import Testing

import FrameScriptCore

// MARK: - Helpers

private enum MarkupTestSupport {
    static func pauses(
        _ text: String,
        defaults: PauseDefaults = .standard
    ) -> [(seconds: TimeInterval, explicit: Bool, token: MarkupToken)] {
        ScriptMarkup.parse(text, defaults: defaults).compactMap { token in
            guard case .pause(let seconds, let explicit) = token.kind else { return nil }
            return (seconds, explicit, token)
        }
    }

    static func emphases(
        _ text: String
    ) -> [(level: EmphasisLevel, text: String, token: MarkupToken)] {
        ScriptMarkup.parse(text).compactMap { token in
            guard case .emphasis(let level) = token.kind else { return nil }
            return (level, token.text, token)
        }
    }

    static func cues(
        _ text: String
    ) -> [(label: String, payload: String, token: MarkupToken)] {
        ScriptMarkup.parse(text).compactMap { token in
            guard case .cue(let label, let payload) = token.kind else { return nil }
            return (label, payload, token)
        }
    }

    static func raw(_ text: String, _ range: NSRange) -> String {
        (text as NSString).substring(with: range)
    }

    static func utf16Length(_ text: String) -> Int {
        (text as NSString).length
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1e15
    }
}

// MARK: - Slash pauses

@Suite("ScriptMarkup slash pauses")
struct ScriptMarkupSlashPauseTests {
    @Test func singleSlashBetweenSpacesIsShortPause() throws {
        let text = "Hola / mundo"
        let result = MarkupTestSupport.pauses(text)
        #expect(result.count == 1)
        let pause = try #require(result.first)
        #expect(pause.seconds == 0.5)
        #expect(pause.explicit == false)
        #expect(pause.token.range == NSRange(location: 5, length: 1))
        #expect(pause.token.markerRanges == [NSRange(location: 5, length: 1)])
        #expect(MarkupTestSupport.raw(text, pause.token.range) == "/")
        #expect(ScriptMarkup.parse(text).count == 3)
    }

    @Test func doubleSlashBetweenSpacesIsLongPause() throws {
        let text = "Hola // mundo"
        let result = MarkupTestSupport.pauses(text)
        #expect(result.count == 1)
        let pause = try #require(result.first)
        #expect(pause.seconds == 1.0)
        #expect(pause.explicit == false)
        #expect(MarkupTestSupport.raw(text, pause.token.range) == "//")
    }

    @Test func slashAtLineStartIsPause() throws {
        let text = "/ Hola"
        let pause = try #require(MarkupTestSupport.pauses(text).first)
        #expect(pause.token.range == NSRange(location: 0, length: 1))
        #expect(pause.seconds == 0.5)
    }

    @Test func slashAtLineEndIsPause() throws {
        let text = "Hola /"
        let pause = try #require(MarkupTestSupport.pauses(text).first)
        #expect(pause.token.range == NSRange(location: 5, length: 1))
    }

    @Test func slashAloneIsPause() {
        #expect(MarkupTestSupport.pauses("/").count == 1)
        #expect(MarkupTestSupport.pauses("//").count == 1)
        #expect(MarkupTestSupport.pauses("///").isEmpty)
    }

    @Test func slashOnItsOwnLineIsPause() throws {
        let text = "Uno\n/\nDos"
        let pause = try #require(MarkupTestSupport.pauses(text).first)
        #expect(pause.token.range == NSRange(location: 4, length: 1))
        #expect(ScriptMarkup.parse(text).count == 3)
    }

    @Test func slashSurroundedByTabsIsPause() {
        #expect(MarkupTestSupport.pauses("a\t/\tb").count == 1)
        #expect(MarkupTestSupport.pauses("a\t//\tb").count == 1)
    }

    @Test func slashBeforeNewlineIsPause() {
        #expect(MarkupTestSupport.pauses("Hola /\nmundo").count == 1)
        #expect(MarkupTestSupport.pauses("Hola //\nmundo").count == 1)
    }

    @Test func slashesInsideTokensAreNotPauses() {
        let samples = [
            "km/h",
            "1/4",
            "and/or",
            "https://example.com",
            "https://example.com/a/b?x=1",
            "12/11/2026",
            "A/B testing",
            "50/50",
        ]
        for sample in samples {
            #expect(MarkupTestSupport.pauses(sample).isEmpty, "\(sample) must not be a pause")
            #expect(ScriptMarkup.parse(sample).count == 1, "\(sample) must stay one text token")
        }
    }

    @Test func slashNeedsWhitespaceOnBothSides() {
        #expect(MarkupTestSupport.pauses("Hola /mundo").isEmpty)
        #expect(MarkupTestSupport.pauses("Hola/ mundo").isEmpty)
        #expect(MarkupTestSupport.pauses("Hola//mundo").isEmpty)
        #expect(MarkupTestSupport.pauses("Hola //mundo").isEmpty)
        #expect(MarkupTestSupport.pauses("Hola// mundo").isEmpty)
        #expect(MarkupTestSupport.pauses("/Hola").isEmpty)
        #expect(MarkupTestSupport.pauses("Hola/").isEmpty)
    }

    @Test func threeOrMoreSlashesAreLiteral() {
        #expect(MarkupTestSupport.pauses("Hola /// mundo").isEmpty)
        #expect(MarkupTestSupport.pauses("Hola //// mundo").isEmpty)
        #expect(ScriptMarkup.parse("Hola /// mundo").count == 1)
    }

    @Test func escapedSlashIsLiteral() {
        let text = "Hola \\/ mundo"
        #expect(MarkupTestSupport.pauses(text).isEmpty)
        let tokens = ScriptMarkup.parse(text)
        #expect(tokens.count == 1)
        #expect(tokens.first?.text == "Hola / mundo")
        #expect(ScriptMarkup.spokenText(text) == "Hola / mundo")
    }

    @Test func customDefaultsAreUsed() throws {
        let defaults = PauseDefaults(short: 0.25, long: 3.0)
        let short = try #require(MarkupTestSupport.pauses("a / b", defaults: defaults).first)
        let long = try #require(MarkupTestSupport.pauses("a // b", defaults: defaults).first)
        #expect(short.seconds == 0.25)
        #expect(long.seconds == 3.0)
    }

    @Test func negativeDefaultsAreClampedToZero() {
        let defaults = PauseDefaults(short: -1, long: -2)
        #expect(defaults.short == 0)
        #expect(defaults.long == 0)
        #expect(MarkupTestSupport.pauses("a / b", defaults: defaults).first?.seconds == 0)
        #expect(MarkupTestSupport.pauses("a // b", defaults: defaults).first?.seconds == 0)
    }

    @Test func durationsClampToSaneMaximum() {
        let defaults = PauseDefaults(short: 999, long: 61)
        #expect(PauseDefaults.maximumDuration == 60)
        #expect(defaults.short == 60)
        #expect(defaults.long == 60)
        #expect(MarkupTestSupport.pauses("a / b", defaults: defaults).first?.seconds == 60)
        #expect(MarkupTestSupport.pauses("a // b", defaults: defaults).first?.seconds == 60)
    }

    @Test func nonFiniteDurationsFallBackToStandardValues() {
        let defaults = PauseDefaults(short: .nan, long: .infinity)
        #expect(defaults.short == 0.5)
        #expect(defaults.long == 1.0)
        let mixed = PauseDefaults(short: -Double.infinity, long: Double.nan)
        #expect(mixed.short == 0.5)
        #expect(mixed.long == 1.0)
    }

    @Test func mutationIsSanitised() {
        var defaults = PauseDefaults()
        defaults.short = 999
        defaults.long = .nan
        #expect(defaults.short == 60)
        #expect(defaults.long == 1.0)

        defaults.short = -3
        defaults.long = 100
        #expect(defaults.short == 0)
        #expect(defaults.long == 60)
    }

    @Test func decodedDurationsAreSanitised() throws {
        let clamped = try JSONDecoder().decode(
            PauseDefaults.self,
            from: Data(#"{"short":-5,"long":1000}"#.utf8)
        )
        #expect(clamped.short == 0)
        #expect(clamped.long == 60)

        let missing = try JSONDecoder().decode(PauseDefaults.self, from: Data("{}".utf8))
        #expect(missing == .standard)
    }

    @Test func explicitPauseDurationsAreNotCapped() {
        // The 60 s cap applies to configurable defaults, not to a writer who
        // explicitly asks for a longer pause in the script.
        #expect(MarkupTestSupport.pauses("[pausa 120s]").first?.seconds == 120)
    }

    @Test func slashPauseBetweenAccentedWords() throws {
        let text = "canción / ñandú"
        let pause = try #require(MarkupTestSupport.pauses(text).first)
        #expect(pause.token.range == NSRange(location: 8, length: 1))
    }

    @Test func slashPauseAfterEmojiUsesUTF16Offsets() throws {
        let text = "🏎️ Hola / mundo"
        let pause = try #require(MarkupTestSupport.pauses(text).first)
        let slashLocation = (text as NSString).range(of: "/").location
        #expect(pause.token.range == NSRange(location: slashLocation, length: 1))
        #expect(slashLocation == 9) // 🏎️ is 3 UTF-16 units + space + "Hola" + space
    }
}

// MARK: - Bracket pauses

@Suite("ScriptMarkup explicit pauses")
struct ScriptMarkupExplicitPauseTests {
    @Test func bareSpanishPauseUsesLongDefault() throws {
        let text = "Antes [pausa] después"
        let pause = try #require(MarkupTestSupport.pauses(text).first)
        #expect(pause.seconds == 1.0)
        #expect(pause.explicit)
        #expect(pause.token.range == NSRange(location: 6, length: 7))
        #expect(MarkupTestSupport.raw(text, pause.token.range) == "[pausa]")
        #expect(pause.token.markerRanges.map { MarkupTestSupport.raw(text, $0) } == ["[", "]"])
    }

    @Test func bareSpanishPauseIsCaseInsensitive() {
        #expect(MarkupTestSupport.pauses("[PAUSA]").first?.seconds == 1.0)
        #expect(MarkupTestSupport.pauses("[Pausa]").first?.seconds == 1.0)
    }

    @Test func bareEnglishPauseUsesLongDefault() {
        let pause = MarkupTestSupport.pauses("[pause]").first
        #expect(pause?.seconds == 1.0)
        #expect(pause?.explicit == true)
        #expect(MarkupTestSupport.pauses("[pause 2s]").first?.seconds == 2.0)
    }

    @Test func spanishPauseWithDuration() throws {
        let pause = try #require(MarkupTestSupport.pauses("[pausa 2s]").first)
        #expect(pause.seconds == 2.0)
        #expect(pause.explicit)
    }

    @Test func decimalCommaDuration() {
        #expect(MarkupTestSupport.pauses("[pausa 1,5s]").first?.seconds == 1.5)
        #expect(MarkupTestSupport.pauses("[pausa 1,5 s]").first?.seconds == 1.5)
        #expect(MarkupTestSupport.pauses("[1,5s]").first?.seconds == 1.5)
        #expect(MarkupTestSupport.pauses("[pausa 2,5 s]").first?.seconds == 2.5)
    }

    @Test func decimalPointDuration() {
        #expect(MarkupTestSupport.pauses("[pausa 1.5s]").first?.seconds == 1.5)
        #expect(MarkupTestSupport.pauses("[pausa 1.5 s]").first?.seconds == 1.5)
        #expect(MarkupTestSupport.pauses("[pausa 0.25s]").first?.seconds == 0.25)
    }

    @Test func durationOnlyBrackets() {
        #expect(MarkupTestSupport.pauses("[2s]").first?.seconds == 2.0)
        #expect(MarkupTestSupport.pauses("[0.5s]").first?.seconds == 0.5)
        #expect(MarkupTestSupport.pauses("[0,5s]").first?.seconds == 0.5)
        #expect(MarkupTestSupport.pauses("[1.5 s]").first?.seconds == 1.5)
    }

    @Test func uppercaseUnitsAndKeywords() {
        #expect(MarkupTestSupport.pauses("[Pausa 2S]").first?.seconds == 2.0)
        #expect(MarkupTestSupport.pauses("[PAUSE 3S]").first?.seconds == 3.0)
        #expect(MarkupTestSupport.pauses("[2S]").first?.seconds == 2.0)
    }

    @Test func zeroSecondPauseIsAllowed() throws {
        let pause = try #require(MarkupTestSupport.pauses("[pausa 0s]").first)
        #expect(pause.seconds == 0)
        #expect(pause.explicit)
    }

    @Test func barePauseUsesConfiguredLongValue() {
        let defaults = PauseDefaults(short: 0.25, long: 2.75)
        #expect(MarkupTestSupport.pauses("[pausa]", defaults: defaults).first?.seconds == 2.75)
        #expect(MarkupTestSupport.pauses("[pause]", defaults: defaults).first?.seconds == 2.75)
    }

    @Test func explicitDurationIgnoresDefaults() {
        let defaults = PauseDefaults(short: 5, long: 9)
        #expect(MarkupTestSupport.pauses("[pausa 1,5s]", defaults: defaults).first?.seconds == 1.5)
        #expect(MarkupTestSupport.pauses("[2s]", defaults: defaults).first?.seconds == 2.0)
    }

    @Test func multipleExplicitPauses() {
        let text = "Uno [pausa] dos [2s] tres [pausa 1,5s]"
        let seconds = MarkupTestSupport.pauses(text).map(\.seconds)
        #expect(seconds == [1.0, 2.0, 1.5])
    }

    @Test func malformedPauseIsReportedAsCue() throws {
        let cue = try #require(MarkupTestSupport.cues("[pausa dos segundos]").first)
        #expect(cue.label == "PAUSA")
        #expect(cue.payload == "dos segundos")
        #expect(MarkupTestSupport.pauses("[pausa dos segundos]").isEmpty)
    }

    @Test func numberWithoutUnitIsACueNotAPause() throws {
        let cue = try #require(MarkupTestSupport.cues("[2]").first)
        #expect(cue.label == "2")
        #expect(cue.payload == "")
        #expect(MarkupTestSupport.pauses("[2]").isEmpty)
    }

    @Test func negativeDurationIsNotAPause() {
        #expect(MarkupTestSupport.pauses("[pausa -2s]").isEmpty)
        #expect(MarkupTestSupport.cues("[pausa -2s]").first?.label == "PAUSA")
    }

    @Test func invalidNumberIsNotAPause() {
        #expect(MarkupTestSupport.pauses("[pausa 1.5.2s]").isEmpty)
        #expect(MarkupTestSupport.pauses("[pausa 2m]").isEmpty)
        #expect(MarkupTestSupport.pauses("[pausa s]").isEmpty)
        #expect(MarkupTestSupport.pauses("[pausa 2]").isEmpty)
    }

    @Test func pauseInsideSentenceKeepsSurroundingText() {
        let text = "Antes [pausa 2s] después"
        let tokens = ScriptMarkup.parse(text)
        #expect(tokens.count == 3)
        #expect(tokens[0].text == "Antes ")
        #expect(tokens[2].text == " después")
    }
}

// MARK: - Cues

@Suite("ScriptMarkup cues")
struct ScriptMarkupCueTests {
    @Test func imageCueIsNotAPause() throws {
        let text = "[IMAGEN: un coche rojo]"
        let cue = try #require(MarkupTestSupport.cues(text).first)
        #expect(cue.label == "IMAGEN")
        #expect(cue.payload == "un coche rojo")
        #expect(MarkupTestSupport.pauses(text).isEmpty)
        #expect(cue.token.range == NSRange(location: 0, length: MarkupTestSupport.utf16Length(text)))
        #expect(cue.token.markerRanges.map { MarkupTestSupport.raw(text, $0) } == ["[", "]"])
    }

    @Test func cueLabelsAreUppercasedButPayloadPreservesCase() throws {
        let cue = try #require(MarkupTestSupport.cues("[imagen: Coche de Vantare]").first)
        #expect(cue.label == "IMAGEN")
        #expect(cue.payload == "Coche de Vantare")
    }

    @Test func cueWithoutPayload() throws {
        let cue = try #require(MarkupTestSupport.cues("[RE-HOOK]").first)
        #expect(cue.label == "RE-HOOK")
        #expect(cue.payload == "")
    }

    @Test func otherProductionCues() {
        let samples: [(String, String, String)] = [
            ("[B-ROLL: gameplay]", "B-ROLL", "gameplay"),
            ("[B-ROLL]", "B-ROLL", ""),
            ("[RÓTULO: curva de ñandú]", "RÓTULO", "curva de ñandú"),
            ("[rótulo: miniatura]", "RÓTULO", "miniatura"),
            ("[PRUEBA: telemetría]", "PRUEBA", "telemetría"),
            ("[CAPTURA]", "CAPTURA", ""),
        ]
        for (text, label, payload) in samples {
            let cue = MarkupTestSupport.cues(text).first
            #expect(cue?.label == label)
            #expect(cue?.payload == payload)
            #expect(MarkupTestSupport.pauses(text).isEmpty)
        }
    }

    @Test func cuePayloadKeepsAdditionalColons() throws {
        let cue = try #require(MarkupTestSupport.cues("[IMAGEN: telemetría: vuelta 3]").first)
        #expect(cue.label == "IMAGEN")
        #expect(cue.payload == "telemetría: vuelta 3")
    }

    @Test func emptyBracketsAreLiteralText() {
        #expect(MarkupTestSupport.cues("[]").isEmpty)
        #expect(MarkupTestSupport.cues("[   ]").isEmpty)
        #expect(ScriptMarkup.parse("[]").count == 1)
        #expect(ScriptMarkup.parse("[]").first?.kind == .text)
    }

    @Test func colonWithoutLabelIsLiteralText() {
        #expect(MarkupTestSupport.cues("[: foo]").isEmpty)
        #expect(ScriptMarkup.spokenText("[: foo]") == "[: foo]")
    }

    @Test func unclosedBracketIsLiteralText() {
        #expect(MarkupTestSupport.cues("[IMAGEN").isEmpty)
        #expect(ScriptMarkup.parse("[IMAGEN").first?.text == "[IMAGEN")
    }

    @Test func bracketCueCannotCrossALine() {
        let text = "[IMAGEN\n]"
        #expect(MarkupTestSupport.cues(text).isEmpty)
        #expect(ScriptMarkup.parse(text).count == 1)
    }

    @Test func cueDoesNotParseEmphasisInside() {
        let text = "[IMAGEN: *coche*]"
        #expect(MarkupTestSupport.emphases(text).isEmpty)
        #expect(MarkupTestSupport.cues(text).first?.payload == "*coche*")
    }

    @Test func urlInsideBracketsIsACueNotAPause() {
        let text = "[FUENTE: https://example.com/a/b]"
        #expect(MarkupTestSupport.pauses(text).isEmpty)
        #expect(MarkupTestSupport.cues(text).first?.label == "FUENTE")
    }

    @Test func cueMarkersAreDimmedSeparately() throws {
        let text = "Antes [IMAGEN: coche] después"
        let cue = try #require(MarkupTestSupport.cues(text).first)
        #expect(cue.token.markerRanges.count == 2)
        #expect(MarkupTestSupport.raw(text, cue.token.markerRanges[0]) == "[")
        #expect(MarkupTestSupport.raw(text, cue.token.markerRanges[1]) == "]")
        #expect(cue.token.range == NSRange(location: 6, length: 15))
    }
}

// MARK: - Emphasis

@Suite("ScriptMarkup emphasis")
struct ScriptMarkupEmphasisTests {
    @Test func singleWordEmphasis() throws {
        let text = "*palabra*"
        let emphasis = try #require(MarkupTestSupport.emphases(text).first)
        #expect(emphasis.level == .emphasis)
        #expect(emphasis.text == "palabra")
        #expect(emphasis.token.range == NSRange(location: 0, length: 9))
        #expect(emphasis.token.markerRanges.map { MarkupTestSupport.raw(text, $0) } == ["*", "*"])
        #expect(ScriptMarkup.parse(text).count == 1)
    }

    @Test func multipleWordEmphasis() throws {
        let emphasis = try #require(MarkupTestSupport.emphases("*varias palabras*").first)
        #expect(emphasis.text == "varias palabras")
        #expect(emphasis.level == .emphasis)
    }

    @Test func strongEmphasis() throws {
        let text = "**fuerte**"
        let emphasis = try #require(MarkupTestSupport.emphases(text).first)
        #expect(emphasis.level == .strong)
        #expect(emphasis.text == "fuerte")
        #expect(emphasis.token.markerRanges.map { MarkupTestSupport.raw(text, $0) } == ["**", "**"])
    }

    @Test func emphasisCanSpanASingleLineBreak() throws {
        let emphasis = try #require(MarkupTestSupport.emphases("*una\ndos*").first)
        #expect(emphasis.text == "una\ndos")
    }

    @Test func emphasisCannotCrossABlankLine() {
        #expect(MarkupTestSupport.emphases("*una\n\ndos*").isEmpty)
        #expect(ScriptMarkup.parse("*una\n\ndos*").count == 1)
    }

    @Test func loneAsteriskIsLiteral() {
        #expect(MarkupTestSupport.emphases("*").isEmpty)
        #expect(MarkupTestSupport.emphases("a * b").isEmpty)
        #expect(MarkupTestSupport.emphases("5 * 3").isEmpty)
        #expect(MarkupTestSupport.emphases("5 * 3 * 2").isEmpty)
    }

    @Test func unclosedEmphasisIsLiteral() {
        #expect(MarkupTestSupport.emphases("*palabra").isEmpty)
        #expect(MarkupTestSupport.emphases("*varias palabras").isEmpty)
        #expect(MarkupTestSupport.emphases("**palabra*").isEmpty)
        #expect(MarkupTestSupport.emphases("**palabra").isEmpty)
    }

    @Test func tripleAsterisksAreLiteral() {
        #expect(MarkupTestSupport.emphases("***triple***").isEmpty)
        #expect(ScriptMarkup.parse("***triple***").count == 1)
    }

    @Test func doubleAsterisksInsideSingleEmphasisAreLiteral() throws {
        // The `**` run cannot close a single-star span, so it stays inside the
        // outer emphasis as literal content.
        let text = "*a**b*"
        let emphases = MarkupTestSupport.emphases(text)
        #expect(emphases.count == 1)
        let emphasis = try #require(emphases.first)
        #expect(emphasis.level == .emphasis)
        #expect(emphasis.text == "a**b")
        #expect(emphasis.token.range == NSRange(location: 0, length: 6))
        #expect(emphasis.token.markerRanges.map { MarkupTestSupport.raw(text, $0) } == ["*", "*"])
    }

    @Test func emptyEmphasisIsLiteral() {
        #expect(MarkupTestSupport.emphases("**").isEmpty)
        #expect(MarkupTestSupport.emphases("* *").isEmpty)
    }

    @Test func emphasisRequiresHuggingContent() {
        #expect(MarkupTestSupport.emphases("* palabras *").isEmpty)
        #expect(MarkupTestSupport.emphases("*palabras *").isEmpty)
        #expect(MarkupTestSupport.emphases("* palabras*").isEmpty)
    }

    @Test func emphasisRequiresAWordBoundary() {
        #expect(MarkupTestSupport.emphases("a*b*").isEmpty)
        #expect(MarkupTestSupport.emphases("2*3*4").isEmpty)
        #expect(MarkupTestSupport.emphases("*palabra*ñ").isEmpty)
    }

    @Test func twoEmphasesInOneLine() {
        let emphases = MarkupTestSupport.emphases("*palabra* y **otra**")
        #expect(emphases.count == 2)
        #expect(emphases[0].text == "palabra")
        #expect(emphases[0].level == .emphasis)
        #expect(emphases[1].text == "otra")
        #expect(emphases[1].level == .strong)
    }

    @Test func emphasisAfterSpanishPunctuation() throws {
        let emphasis = try #require(MarkupTestSupport.emphases("¿*ñandú*?").first)
        #expect(emphasis.text == "ñandú")
        #expect(emphasis.token.range == NSRange(location: 1, length: 7))
    }

    @Test func emphasisBeforePunctuation() {
        #expect(MarkupTestSupport.emphases("*palabra*.").count == 1)
        #expect(MarkupTestSupport.emphases("*palabra*,").count == 1)
        #expect(MarkupTestSupport.emphases("*palabra*—otra").count == 1)
    }

    @Test func emphasisWithEmoji() throws {
        let text = "*coche 🏎️ rápido*"
        let emphasis = try #require(MarkupTestSupport.emphases(text).first)
        #expect(emphasis.text == "coche 🏎️ rápido")
        #expect(emphasis.token.range.length == MarkupTestSupport.utf16Length(text))
        #expect(emphasis.token.markerRanges.map { MarkupTestSupport.raw(text, $0) } == ["*", "*"])
    }

    @Test func emphasisWithAccentsAndEnye() throws {
        let text = "*canción de ñandú*"
        let emphasis = try #require(MarkupTestSupport.emphases(text).first)
        #expect(emphasis.text == "canción de ñandú")
    }

    @Test func escapedAsterisksAreLiteral() {
        let text = "\\*no es énfasis\\*"
        #expect(MarkupTestSupport.emphases(text).isEmpty)
        #expect(ScriptMarkup.parse(text).count == 1)
        #expect(ScriptMarkup.parse(text).first?.text == "*no es énfasis*")
        #expect(ScriptMarkup.spokenText(text) == "*no es énfasis*")
    }

    @Test func escapedAsteriskInsideEmphasisIsLiteral() throws {
        let text = "*a \\* b*"
        let emphasis = try #require(MarkupTestSupport.emphases(text).first)
        #expect(emphasis.text == "a * b")
        #expect(emphasis.token.markerRanges.count == 2)
    }

    @Test func strongAndEmphasisAreDisjoint() {
        let text = "**a** *b* **c**"
        let emphases = MarkupTestSupport.emphases(text)
        #expect(emphases.map(\.level) == [.strong, .emphasis, .strong])
        #expect(emphases.map(\.text) == ["a", "b", "c"])
    }

    @Test func emphasisMarkersAreOnlyTheAsterisks() throws {
        let text = "Hola *mundo* cruel"
        let emphasis = try #require(MarkupTestSupport.emphases(text).first)
        #expect(MarkupTestSupport.raw(text, emphasis.token.markerRanges[0]) == "*")
        #expect(MarkupTestSupport.raw(text, emphasis.token.markerRanges[1]) == "*")
        #expect(emphasis.token.text == "mundo")
    }
}

// MARK: - Emphasis with inner markers

@Suite("ScriptMarkup emphasis with inner markers")
struct ScriptMarkupEmphasisInnerMarkerTests {
    @Test func pauseInsideEmphasisIsEmittedAndSplitsTheSpan() throws {
        let text = "*Hola [pausa] mundo*"
        let tokens = ScriptMarkup.parse(text)
        #expect(tokens.count == 3)

        let first = try #require(tokens.first)
        #expect(first.kind == .emphasis(.emphasis))
        #expect(first.text == "Hola ")
        #expect(first.range == NSRange(location: 0, length: 6))
        #expect(first.markerRanges.map { MarkupTestSupport.raw(text, $0) } == ["*"])
        #expect(first.escapeRanges.isEmpty)

        let pause = try #require(tokens.dropFirst().first)
        #expect(pause.kind == .pause(seconds: 1.0, explicit: true))
        #expect(pause.range == NSRange(location: 6, length: 7))

        let last = try #require(tokens.last)
        #expect(last.kind == .emphasis(.emphasis))
        #expect(last.text == " mundo")
        #expect(last.range == NSRange(location: 13, length: 7))
        #expect(last.markerRanges.map { MarkupTestSupport.raw(text, $0) } == ["*"])

        #expect(ScriptMarkup.spokenText(text) == "Hola mundo")
        #expect(ScriptMarkup.spokenWordCount(text) == 2)
        #expect(abs(ScriptMarkup.estimateDuration(text, wordsPerMinute: 60) - 3) < 0.0001)
    }

    @Test func slashPauseInsideEmphasisIsEmitted() {
        let text = "*Hola / mundo*"
        let tokens = ScriptMarkup.parse(text)
        #expect(tokens.count == 3)
        #expect(tokens.dropFirst().first?.kind == .pause(seconds: 0.5, explicit: false))
        #expect(ScriptMarkup.spokenText(text) == "Hola mundo")
        #expect(ScriptMarkup.spokenWordCount(text) == 2)
        #expect(abs(ScriptMarkup.estimateDuration(text, wordsPerMinute: 60) - 2.5) < 0.0001)
        #expect(ScriptMarkup.runs(text) == [
            .emphasis("Hola ", level: .emphasis),
            .pause(0.5),
            .emphasis(" mundo", level: .emphasis),
        ])
    }

    @Test func cueInsideEmphasisIsEmitted() throws {
        let text = "*Hola [IMAGEN: coche] mundo*"
        let tokens = ScriptMarkup.parse(text)
        #expect(tokens.count == 3)

        let cue = try #require(tokens.dropFirst().first)
        #expect(cue.kind == .cue(label: "IMAGEN", payload: "coche"))

        #expect(ScriptMarkup.spokenText(text) == "Hola mundo")
        #expect(ScriptMarkup.spokenWordCount(text) == 2)
        #expect(abs(ScriptMarkup.estimateDuration(text, wordsPerMinute: 60) - 2) < 0.0001)
        #expect(ScriptMarkup.runs(text) == [
            .emphasis("Hola ", level: .emphasis),
            .cue("IMAGEN"),
            .emphasis(" mundo", level: .emphasis),
        ])
    }

    @Test func cueWithoutSpacesInsideEmphasisKeepsWordsApart() {
        let text = "*Hola[IMAGEN]mundo*"
        #expect(ScriptMarkup.spokenText(text) == "Hola mundo")
        #expect(ScriptMarkup.spokenWordCount(text) == 2)
    }

    @Test func punctuationAfterInnerMarkerIsTightened() {
        #expect(ScriptMarkup.spokenText("*Hola [pausa], mundo*") == "Hola, mundo")
        #expect(ScriptMarkup.spokenText("*Hola [IMAGEN: x]. Adiós.*") == "Hola. Adiós.")
        #expect(ScriptMarkup.spokenText("¡Hola [pausa]!") == "¡Hola!")
        #expect(ScriptMarkup.spokenText("Hola [pausa] [IMAGEN: x], mundo") == "Hola, mundo")
        #expect(ScriptMarkup.spokenText("*Hola [pausa]*, mundo") == "Hola, mundo")
    }

    @Test func strongEmphasisSplitsAroundAnInnerCue() {
        let text = "**Hola [IMAGEN: coche] mundo**"
        let tokens = ScriptMarkup.parse(text)
        #expect(tokens.count == 3)
        #expect(tokens.first?.kind == .emphasis(.strong))
        #expect(tokens.first?.text == "Hola ")
        #expect(tokens.last?.kind == .emphasis(.strong))
        #expect(tokens.last?.text == " mundo")
        #expect(ScriptMarkup.spokenText(text) == "Hola mundo")
    }

    @Test func pauseDirectlyInsideEmphasisProducesEmptySegments() {
        let text = "*[pausa]*"
        let tokens = ScriptMarkup.parse(text)
        #expect(tokens.count == 3)
        #expect(tokens.first?.kind == .emphasis(.emphasis))
        #expect(tokens.first?.text == "")
        #expect(tokens.last?.kind == .emphasis(.emphasis))
        #expect(tokens.last?.text == "")
        #expect(ScriptMarkup.spokenText(text) == "")
        #expect(ScriptMarkup.spokenWordCount(text) == 0)
        #expect(ScriptMarkup.runs(text) == [.pause(1.0)])
        #expect(abs(ScriptMarkup.estimateDuration(text, wordsPerMinute: 60) - 1) < 0.0001)
    }

    @Test func emphasisWithInnerMarkersKeepsSurroundingText() {
        let text = "Antes *Hola [pausa] mundo* después"
        #expect(ScriptMarkup.spokenText(text) == "Antes Hola mundo después")
        #expect(ScriptMarkup.spokenWordCount(text) == 4)
    }

    @Test func consecutiveInnerPausesSplitEmphasisIntoSegments() {
        let text = "*a[pausa]b[pausa]c*"
        let tokens = ScriptMarkup.parse(text)
        let pauses = tokens.compactMap { token -> TimeInterval? in
            guard case .pause(let seconds, _) = token.kind else { return nil }
            return seconds
        }
        #expect(pauses.count == 2)
        let emphasisTexts = tokens.compactMap { token -> String? in
            guard case .emphasis = token.kind else { return nil }
            return token.text
        }
        #expect(emphasisTexts == ["a", "b", "c"])
        #expect(ScriptMarkup.spokenText(text) == "a b c")
    }

    @Test func adjacentInnerMarkersDoNotEmitEmptyMiddleSegments() {
        let text = "*a[pausa][pausa]b*"
        let tokens = ScriptMarkup.parse(text)
        #expect(tokens.allSatisfy { $0.range.length > 0 })

        let emphasisTexts = tokens.compactMap { token -> String? in
            guard case .emphasis = token.kind else { return nil }
            return token.text
        }
        #expect(emphasisTexts == ["a", "b"])
        #expect(ScriptMarkup.spokenText(text) == "a b")
        #expect(ScriptMarkup.runs(text) == [
            .emphasis("a", level: .emphasis),
            .pause(1.0),
            .pause(1.0),
            .emphasis("b", level: .emphasis),
        ])
    }
}

// MARK: - Escapes

@Suite("ScriptMarkup escapes")
struct ScriptMarkupEscapeTests {
    @Test func escapedSlashAndAsteriskStayLiteral() {
        let text = "Hola \\* mundo \\/ fin"
        #expect(MarkupTestSupport.pauses(text).isEmpty)
        #expect(MarkupTestSupport.emphases(text).isEmpty)
        #expect(ScriptMarkup.parse(text).count == 1)
        #expect(ScriptMarkup.parse(text).first?.text == "Hola * mundo / fin")
    }

    @Test func textTokenExposesEscapeBackslashRanges() throws {
        let text = "Hola \\* mundo \\/ fin"
        let token = try #require(ScriptMarkup.parse(text).first)
        #expect(token.kind == .text)
        #expect(token.escapeRanges == [
            NSRange(location: 5, length: 1),
            NSRange(location: 14, length: 1),
        ])
        #expect(token.escapeRanges.map { MarkupTestSupport.raw(text, $0) } == ["\\", "\\"])
        #expect(token.markerRanges.isEmpty)
        #expect(token.text == "Hola * mundo / fin")
    }

    @Test func emphasisTokenExposesEscapeBackslashRanges() throws {
        let text = "*a \\* b*"
        let emphasis = try #require(MarkupTestSupport.emphases(text).first)
        #expect(emphasis.text == "a * b")
        #expect(emphasis.token.escapeRanges == [NSRange(location: 3, length: 1)])
        #expect(emphasis.token.escapeRanges.map { MarkupTestSupport.raw(text, $0) } == ["\\"])
    }

    @Test func splitEmphasisSegmentExposesItsOwnEscapes() {
        let text = "*a \\* [pausa] b*"
        let tokens = ScriptMarkup.parse(text)
        #expect(tokens.count == 3)
        #expect(tokens.first?.escapeRanges == [NSRange(location: 3, length: 1)])
        #expect(tokens.last?.escapeRanges.isEmpty == true)
    }

    @Test func escapeRangesNeverOverlapMarkerRanges() {
        let text = "A \\* *b \\/ c* [IMAGEN: d]"
        for token in ScriptMarkup.parse(text) {
            for escape in token.escapeRanges {
                for marker in token.markerRanges {
                    #expect(NSIntersectionRange(escape, marker).length == 0)
                }
            }
        }
    }

    @Test func backslashesBeforeOtherCharactersArePreserved() {
        let text = "C:\\Users\\coche"
        #expect(ScriptMarkup.parse(text).first?.text == text)
        #expect(ScriptMarkup.spokenText(text) == text)
    }

    @Test func escapedMarkerRangesStillCoverTheOriginal() {
        let text = "\\*literal\\*"
        let token = ScriptMarkup.parse(text).first
        #expect(token?.range == NSRange(location: 0, length: MarkupTestSupport.utf16Length(text)))
        #expect(token?.markerRanges.isEmpty == true)
        #expect(token?.text == "*literal*")
    }

    @Test func escapeAtEndOfStringStaysLiteralBackslash() {
        let text = "Hola \\"
        #expect(ScriptMarkup.parse(text).first?.text == "Hola \\")
    }

    @Test func escapedSlashDoesNotCreatePauseAtLineEdge() {
        #expect(MarkupTestSupport.pauses("\\/").isEmpty)
        #expect(ScriptMarkup.spokenText("\\/") == "/")
    }
}

// MARK: - Spoken text

@Suite("ScriptMarkup spoken text")
struct ScriptMarkupSpokenTextTests {
    @Test func removesPausesAndTidiesSpaces() {
        let text = "Hola   /   mundo. [IMAGEN: telemetría]"
        #expect(ScriptMarkup.spokenText(text) == "Hola mundo.")
    }

    @Test func removesEmphasisMarkersOnly() {
        #expect(ScriptMarkup.spokenText("*Muy* **fuerte**.") == "Muy fuerte.")
        #expect(ScriptMarkup.spokenText("Hola *mundo* cruel") == "Hola mundo cruel")
    }

    @Test func keepsOneBlankLineBetweenParagraphs() {
        let text = "Uno / dos.\n\n[pausa 2s]\n\nTres."
        #expect(ScriptMarkup.spokenText(text) == "Uno dos.\n\nTres.")
    }

    @Test func normalisesCRLF() {
        let text = "Hola / mundo\r\n// fin"
        #expect(ScriptMarkup.spokenText(text) == "Hola mundo\nfin")
    }

    @Test func cueBetweenWordsLeavesAWordBreak() {
        #expect(ScriptMarkup.spokenText("Hola[IMAGEN]mundo") == "Hola mundo")
        #expect(ScriptMarkup.spokenText("Hola[pausa]mundo") == "Hola mundo")
    }

    @Test func removedMarkersDoNotLeaveSpaceBeforeTightPunctuation() {
        #expect(ScriptMarkup.spokenText("Hola [pausa], mundo") == "Hola, mundo")
        #expect(ScriptMarkup.spokenText("Hola [IMAGEN: x]. Adiós.") == "Hola. Adiós.")
        #expect(ScriptMarkup.spokenText("Hola [pausa]?") == "Hola?")
        #expect(ScriptMarkup.spokenText("Hola [pausa] ; mundo") == "Hola; mundo")
        #expect(ScriptMarkup.spokenText("(Hola [pausa])") == "(Hola)")
        #expect(ScriptMarkup.spokenText("«Hola [pausa]»") == "«Hola»")
        #expect(ScriptMarkup.spokenText("Hola [pausa] : mundo") == "Hola: mundo")
    }

    @Test func openingPunctuationKeepsItsSpace() {
        #expect(ScriptMarkup.spokenText("Hola [pausa] ¿qué tal?") == "Hola ¿qué tal?")
        #expect(ScriptMarkup.spokenText("Hola [pausa] —adios") == "Hola —adios")
    }

    @Test func emphasisRemovalKeepsDirectPunctuationAttached() {
        #expect(ScriptMarkup.spokenText("*Hola*, mundo") == "Hola, mundo")
        #expect(ScriptMarkup.spokenText("*Hola*. Adiós.") == "Hola. Adiós.")
        #expect(ScriptMarkup.spokenText("*Hola*-mundo") == "Hola-mundo")
    }

    @Test func markerFreePunctuationSpacingIsPreserved() {
        #expect(ScriptMarkup.spokenText("Hola , mundo") == "Hola , mundo")
    }

    @Test func emptyAndMarkerOnlyScriptsBecomeEmpty() {
        #expect(ScriptMarkup.spokenText("") == "")
        #expect(ScriptMarkup.spokenText("   \n\t ") == "")
        #expect(ScriptMarkup.spokenText("/ // [pausa] [IMAGEN: x]") == "")
    }

    @Test func plainTextRoundTrips() {
        let samples = [
            "Hola mundo",
            "Línea uno\nLínea dos",
            "Párrafo uno.\n\nPárrafo dos.",
            "¿Qué tal, ñandú?",
            "Emoji 🏎️ y más.",
            "km/h y 1/4",
            "https://example.com/a/b",
            "12/11/2026",
        ]
        for sample in samples {
            #expect(ScriptMarkup.spokenText(sample) == sample, "round-trip failed for \(sample)")
        }
    }

    @Test func collapsesWhitespaceLikeAnExport() {
        let text = "  Hola\t\tmundo  \n\n\n  Otra   línea  "
        #expect(ScriptMarkup.spokenText(text) == "Hola mundo\n\nOtra línea")
    }

    @Test func spanishScriptWithEveryMarker() {
        let text = "¡Hola a todos! / Hoy *probamos* el **nuevo** coche.\r\n\r\n[pausa 2s]\r\n[IMAGEN: telemetría]\r\n// Vamos allá."
        let expected = "¡Hola a todos! Hoy probamos el nuevo coche.\n\nVamos allá."
        #expect(ScriptMarkup.spokenText(text) == expected)
    }

    @Test func spokenTextResolvesEscapes() {
        #expect(ScriptMarkup.spokenText("5 \\* 3") == "5 * 3")
        #expect(ScriptMarkup.spokenText("km\\/h") == "km/h")
    }

    @Test func italicPunctuationIsKept() {
        let text = "—¿*En serio*? —preguntó."
        #expect(ScriptMarkup.spokenText(text) == "—¿En serio? —preguntó.")
    }
}

// MARK: - Word count

@Suite("ScriptMarkup word count")
struct ScriptMarkupWordCountTests {
    @Test func countsPlainWords() {
        #expect(ScriptMarkup.spokenWordCount("Hola mundo") == 2)
        #expect(ScriptMarkup.spokenWordCount("Uno dos tres cuatro") == 4)
    }

    @Test func markersDoNotCount() {
        let text = "Hola / mundo // cruel [pausa 2s] [IMAGEN: x] *extra*"
        #expect(ScriptMarkup.spokenWordCount(text) == 4)
    }

    @Test func accentedWordsCountOnce() {
        #expect(ScriptMarkup.spokenWordCount("¡Hola, ñandú!") == 2)
        #expect(ScriptMarkup.spokenWordCount("canción de suspensión") == 3)
    }

    @Test func slashesInsideWordsKeepOneWord() {
        #expect(ScriptMarkup.spokenWordCount("km/h y 1/4") == 3)
        #expect(ScriptMarkup.spokenWordCount("and/or 50/50") == 2)
    }

    @Test func emptyTextHasNoWords() {
        #expect(ScriptMarkup.spokenWordCount("") == 0)
        #expect(ScriptMarkup.spokenWordCount("  \n\t ") == 0)
        #expect(ScriptMarkup.spokenWordCount("/ / [pausa]") == 0)
    }

    @Test func punctuationAndEmojiOnlyRunsAreNotWords() {
        #expect(ScriptMarkup.spokenWordCount("— ¿ ?") == 0)
        #expect(ScriptMarkup.spokenWordCount("🏎️") == 0)
        #expect(ScriptMarkup.spokenWordCount("🏎️ Hola 🏁") == 1)
    }

    @Test func numbersCountAsWords() {
        #expect(ScriptMarkup.spokenWordCount("Vuelta 3 en 1:24.5") == 4)
    }
}

// MARK: - Duration

@Suite("ScriptMarkup duration")
struct ScriptMarkupDurationTests {
    @Test func wordsOnly() {
        let text = String(repeating: "palabra ", count: 150)
        let duration = ScriptMarkup.estimateDuration(text, wordsPerMinute: 150)
        #expect(abs(duration - 60) < 0.0001)
    }

    @Test func wordsPlusPauses() {
        let text = "palabra / palabra // palabra [pausa 2s] palabra"
        let duration = ScriptMarkup.estimateDuration(text, wordsPerMinute: 120)
        #expect(abs(duration - 5.5) < 0.0001)
    }

    @Test func cuesDoNotCount() {
        let text = "Hola [IMAGEN: x] [RE-HOOK]"
        #expect(abs(ScriptMarkup.estimateDuration(text, wordsPerMinute: 60) - 1) < 0.0001)
    }

    @Test func customDefaultsAreSummed() {
        let defaults = PauseDefaults(short: 0.25, long: 0.75)
        let text = "a / b // c [pausa]"
        let duration = ScriptMarkup.estimateDuration(
            text,
            wordsPerMinute: 60,
            defaults: defaults
        )
        #expect(abs(duration - 4.75) < 0.0001)
    }

    @Test func zeroWordsPerMinuteCountsOnlyPauses() {
        let text = "Hola / mundo [2s]"
        #expect(abs(ScriptMarkup.estimateDuration(text, wordsPerMinute: 0) - 2.5) < 0.0001)
    }

    @Test func negativeWordsPerMinuteCountsOnlyPauses() {
        let text = "Hola / mundo"
        #expect(abs(ScriptMarkup.estimateDuration(text, wordsPerMinute: -100) - 0.5) < 0.0001)
    }

    @Test func emptyTextIsZero() {
        #expect(ScriptMarkup.estimateDuration("", wordsPerMinute: 150) == 0)
        #expect(ScriptMarkup.estimateDuration("/ [pausa]", wordsPerMinute: 150) == 1.5)
    }

    @Test func decimalCommaPause() {
        let text = "Hola [pausa 1,5s]"
        #expect(abs(ScriptMarkup.estimateDuration(text, wordsPerMinute: 60) - 2.5) < 0.0001)
    }

    @Test func emojiIsNotAWord() {
        let text = "🏎️ Hola"
        #expect(abs(ScriptMarkup.estimateDuration(text, wordsPerMinute: 60) - 1) < 0.0001)
    }

    @Test func threeHundredWordsAtOneHundredFifty() {
        let text = String(repeating: "vuelta rápida ", count: 150)
        let duration = ScriptMarkup.estimateDuration(text, wordsPerMinute: 150)
        #expect(abs(duration - 120) < 0.0001)
    }
}

// MARK: - Runs

@Suite("ScriptMarkup runs")
struct ScriptMarkupRunTests {
    @Test func mixedScriptProducesDisplayRuns() {
        let text = "Hola / *mundo* **fuerte** [IMAGEN: x]"
        let expected: [MarkupRun] = [
            .text("Hola "),
            .pause(0.5),
            .text(" "),
            .emphasis("mundo", level: .emphasis),
            .text(" "),
            .emphasis("fuerte", level: .strong),
            .text(" "),
            .cue("IMAGEN"),
        ]
        #expect(ScriptMarkup.runs(text) == expected)
    }

    @Test func emptyScriptHasNoRuns() {
        #expect(ScriptMarkup.runs("").isEmpty)
    }

    @Test func plainTextIsOneRun() {
        #expect(ScriptMarkup.runs("Hola mundo") == [.text("Hola mundo")])
    }

    @Test func cueKeepsOnlyLabel() {
        #expect(ScriptMarkup.runs("[IMAGEN: un coche]") == [.cue("IMAGEN")])
        #expect(ScriptMarkup.runs("[RE-HOOK]") == [.cue("RE-HOOK")])
    }

    @Test func customPauseDefaultsFlowIntoRuns() {
        let defaults = PauseDefaults(short: 0.2, long: 1.4)
        #expect(ScriptMarkup.runs("a / b // c", defaults: defaults) == [
            .text("a "),
            .pause(0.2),
            .text(" b "),
            .pause(1.4),
            .text(" c"),
        ])
    }

    @Test func escapesAreResolvedInRuns() {
        #expect(ScriptMarkup.runs("Hola \\* mundo") == [.text("Hola * mundo")])
    }

    @Test func runsPreserveLineBreaksInText() {
        #expect(ScriptMarkup.runs("Uno\ndos") == [.text("Uno\ndos")])
    }
}

// MARK: - Ranges

@Suite("ScriptMarkup ranges")
struct ScriptMarkupRangeTests {
    @Test func tokensCoverTheWholeOriginalText() {
        let text = "🏎️ ¡Hola! / *mundo* **fuerte**\r\n[pausa 1,5 s]\n[IMAGEN: coche]\n// fin \t"
        let tokens = ScriptMarkup.parse(text)
        var cursor = 0
        for token in tokens {
            #expect(token.range.location == cursor)
            cursor += token.range.length
        }
        #expect(cursor == MarkupTestSupport.utf16Length(text))
    }

    @Test func tokensCoverTextWithInnerMarkersInsideEmphasis() {
        let text = "A *Hola / mundo [IMAGEN: coche] fin* B"
        let tokens = ScriptMarkup.parse(text)
        var cursor = 0
        for token in tokens {
            #expect(token.range.location == cursor)
            cursor += token.range.length
        }
        #expect(cursor == MarkupTestSupport.utf16Length(text))
    }

    @Test func everyMarkerRangeIsInsideItsToken() {
        let text = "A / B *c* **d** [pausa] [E: f]"
        for token in ScriptMarkup.parse(text) {
            for marker in token.markerRanges {
                #expect(marker.location >= token.range.location)
                #expect(NSMaxRange(marker) <= NSMaxRange(token.range))
            }
        }
    }

    @Test func textTokenTextMatchesRawSourceWhenThereAreNoEscapes() {
        let text = "Hola / mundo *cruel* [IMAGEN: x]"
        for token in ScriptMarkup.parse(text) where token.kind == .text {
            #expect(token.text == MarkupTestSupport.raw(text, token.range))
        }
    }

    @Test func rangesUseUTF16ForEmoji() throws {
        let text = "🏎️ rápido / lento"
        let pause = try #require(MarkupTestSupport.pauses(text).first)
        let slashLocation = (text as NSString).range(of: "/").location
        #expect(pause.token.range.location == slashLocation)
        #expect(MarkupTestSupport.raw(text, pause.token.range) == "/")
    }

    @Test func rangesUseUTF16ForCRLF() throws {
        let text = "Uno\r\n// Dos"
        let pause = try #require(MarkupTestSupport.pauses(text).first)
        #expect(pause.token.range == NSRange(location: 5, length: 2))
        #expect(MarkupTestSupport.raw(text, pause.token.range) == "//")
    }

    @Test func markerRangesAreOrdered() {
        let text = "**a** [pausa 2s] [IMAGEN: b]"
        for token in ScriptMarkup.parse(text) {
            for (left, right) in zip(token.markerRanges, token.markerRanges.dropFirst()) {
                #expect(NSMaxRange(left) <= right.location)
            }
        }
    }

    @Test func utf16LengthMatchesNSStringForAccentsAndEmoji() {
        let text = "canción 🏎️ ñandú 🏁"
        #expect(text.utf16.count == MarkupTestSupport.utf16Length(text))
        let textTokens = ScriptMarkup.parse(text).filter { $0.kind == .text }
        #expect(textTokens.count == 1)
        #expect(textTokens.first?.text == text)
    }

    @Test func allTokensHaveNonEmptyRanges() {
        let text = "/ *a* **b** [pausa] [C: d] texto"
        for token in ScriptMarkup.parse(text) {
            #expect(token.range.length > 0)
        }
    }

    @Test func pauseMarkerEqualsTokenRange() throws {
        let text = "a // b"
        let pause = try #require(MarkupTestSupport.pauses(text).first)
        #expect(pause.token.markerRanges == [pause.token.range])
    }
}

// MARK: - Defaults and Codable

@Suite("ScriptMarkup defaults")
struct ScriptMarkupDefaultsTests {
    @Test func standardsAreHalfSecondAndOneSecond() {
        #expect(PauseDefaults.standard.short == 0.5)
        #expect(PauseDefaults.standard.long == 1.0)
    }

    @Test func codableRoundTrip() throws {
        let defaults = PauseDefaults(short: 0.4, long: 1.25)
        let data = try JSONEncoder().encode(defaults)
        let decoded = try JSONDecoder().decode(PauseDefaults.self, from: data)
        #expect(decoded == defaults)
    }

    @Test func defaultsAreHashable() {
        let set: Set<PauseDefaults> = [.standard, PauseDefaults(short: 0.5, long: 1.0)]
        #expect(set.count == 1)
    }

    @Test func emphasisLevelsAreOrdered() {
        #expect(EmphasisLevel.emphasis < EmphasisLevel.strong)
        #expect(EmphasisLevel.allCases == [.emphasis, .strong])
    }
}

// MARK: - Performance

@Suite("ScriptMarkup performance", .serialized)
struct ScriptMarkupPerformanceTests {
    @Test func twentyThousandWordsParseUnderFiftyMilliseconds() {
        let vocabulary = [
            "coche", "pista", "vuelta", "motor", "freno", "curva",
            "recta", "box", "neumático", "suspensión", "Vantare", "simracing",
        ]
        var pieces: [String] = []
        pieces.reserveCapacity(20_000)
        for index in 0 ..< 20_000 {
            var piece = vocabulary[index % vocabulary.count]
            if index.isMultiple(of: 89) { piece = "*" + piece + "*" }
            if index.isMultiple(of: 97) { piece += " /" }
            pieces.append(piece)
        }
        let script = pieces.joined(separator: " ")

        let clock = ContinuousClock()
        var best = Duration.seconds(60)
        var tokenCount = 0
        for _ in 0 ..< 3 {
            let start = clock.now
            tokenCount = ScriptMarkup.parse(script).count
            let elapsed = clock.now - start
            best = min(best, elapsed)
        }

        let milliseconds = MarkupTestSupport.milliseconds(best)
        print("parse 20k words: \(String(format: "%.2f", milliseconds)) ms, \(tokenCount) tokens")

        #expect(tokenCount > 500)
        #expect(ScriptMarkup.spokenWordCount(script) == 20_000)
        #expect(best < .milliseconds(50))
    }

    @Test func twentyThousandUnmatchedEmphasisOpenersStayLinear() {
        // The previous implementation rescanned to the end of the paragraph for
        // every opener, which was quadratic on this input.
        let script = (0 ..< 20_000).map { "*palabra\($0)" }.joined(separator: " ")

        let clock = ContinuousClock()
        var best = Duration.seconds(60)
        var tokenCount = 0
        for _ in 0 ..< 3 {
            let start = clock.now
            tokenCount = ScriptMarkup.parse(script).count
            let elapsed = clock.now - start
            best = min(best, elapsed)
        }

        #if DEBUG
        let configuration = "debug"
        let limit = Duration.milliseconds(250)
        #else
        let configuration = "release"
        let limit = Duration.milliseconds(50)
        #endif

        let milliseconds = MarkupTestSupport.milliseconds(best)
        print(
            "parse 20k unmatched openers (\(configuration)): "
                + "\(String(format: "%.2f", milliseconds)) ms, \(tokenCount) tokens"
        )

        #expect(tokenCount == 1) // every opener is literal and merges into one text token
        #expect(ScriptMarkup.spokenWordCount(script) == 20_000)
        #expect(best < limit)
    }
}
