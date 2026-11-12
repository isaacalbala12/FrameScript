import Foundation
import FrameScriptCore

// MARK: - Positions

/// A reading position expressed the same way as `TeleprompterReadingAnchor`:
/// a scene and a character offset into that scene's *visible* text.
struct VoiceFollowPosition: Equatable, Sendable {
    let sceneID: UUID
    let characterOffset: Int
}

/// A resolved position in the rendered teleprompter document.
struct VoiceFollowLocation: Equatable, Sendable {
    let sectionIndex: Int
    let sceneID: UUID
    let characterOffset: Int
    /// Index into the combined, re-indexed speech script.
    let tokenIndex: Int
}

// MARK: - Visible text

/// Reproduces the character counting used by `TeleprompterAttributedStringBuilder`
/// without building an attributed string.
///
/// The renderer counts only the characters of `.text` and `.emphasis` runs and
/// strips one leading line break after a header, cue or pause. Speech offsets
/// must use exactly the same convention or the reading anchor would drift.
enum TeleprompterVisibleText {
    static func texts(for sections: [TeleprompterSection]) -> [String] {
        sections.map(text(for:))
    }

    static func text(for section: TeleprompterSection) -> String {
        var result = ""
        // The section header is followed by a newline and starts a new block.
        var pendingBlockBreak = true

        for run in section.runs {
            switch run {
            case .text(let value), .emphasis(let value, _):
                guard !value.isEmpty else { continue }
                var text = value
                if pendingBlockBreak {
                    stripOneLeadingLineBreak(from: &text)
                    pendingBlockBreak = false
                }
                guard !text.isEmpty else { continue }
                result += text
            case .pause, .cue:
                pendingBlockBreak = true
            }
        }
        return result
    }

    private static func stripOneLeadingLineBreak(from text: inout String) {
        if text.hasPrefix("\r\n") {
            text.removeFirst(2)
        } else if text.hasPrefix("\n") || text.hasPrefix("\r") {
            text.removeFirst()
        }
    }
}

// MARK: - Document

/// One scene's visible text plus the information needed to translate between
/// UTF-16 offsets (used by the tokenizer) and Character offsets (used by the
/// teleprompter reading anchor).
struct VoiceFollowSection: Equatable, Sendable {
    let sceneID: UUID
    let text: String
    let characterCount: Int
    /// UTF-16 offset of every Character in `text`.
    let characterUTF16Offsets: [Int]
    let utf16Length: Int

    init(sceneID: UUID, text: String) {
        self.sceneID = sceneID
        self.text = text
        self.characterCount = text.count
        var offsets: [Int] = []
        offsets.reserveCapacity(text.count)
        var offset = 0
        for character in text {
            offsets.append(offset)
            offset += String(character).utf16.count
        }
        self.characterUTF16Offsets = offsets
        self.utf16Length = offset
    }

    func characterOffset(forUTF16Offset value: Int) -> Int {
        guard !characterUTF16Offsets.isEmpty else { return 0 }
        var low = 0
        var high = characterUTF16Offsets.count
        while low < high {
            let middle = (low + high) / 2
            if characterUTF16Offsets[middle] <= value {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return min(characterCount, max(0, low - 1))
    }
}

/// The whole rendered document prepared for the speech follower.
///
/// Every scene is tokenized on its own and the tokens are re-indexed into one
/// script, so the follower can walk from the last word of a scene into the
/// first word of the next without knowing about scene boundaries.
struct VoiceFollowDocument: Equatable, Sendable {
    let sections: [VoiceFollowSection]
    /// One combined script for the follower. Token ranges are section-local
    /// UTF-16 offsets (that is what `VoiceFollowSection` maps); `source` is
    /// only a readable join of the visible text for debugging.
    let script: TokenizedScript
    /// Section index of every token in `script.tokens`.
    let tokenSectionIndices: [Int]
    /// Token-index range of every section (possibly empty).
    let sectionTokenRanges: [Range<Int>]

    init(sections: [TeleprompterSection], language: SpeechLanguage) {
        let visible = TeleprompterVisibleText.texts(for: sections)
        let voiceSections = zip(sections, visible).map { section, text in
            VoiceFollowSection(sceneID: section.sceneID, text: text)
        }
        self.sections = voiceSections

        var tokens: [ScriptToken] = []
        var tokenSections: [Int] = []
        var ranges: [Range<Int>] = []
        var sentenceBase = 0

        for (sectionIndex, section) in voiceSections.enumerated() {
            let start = tokens.count
            let tokenized = ScriptTokenizer.tokenize(section.text, language: language)
            for token in tokenized.tokens {
                tokens.append(
                    ScriptToken(
                        index: tokens.count,
                        normalized: token.normalized,
                        source: token.source,
                        range: token.range,
                        sentenceIndex: token.sentenceIndex + sentenceBase
                    )
                )
                tokenSections.append(sectionIndex)
            }
            ranges.append(start..<tokens.count)
            // A scene boundary is always a sentence boundary, even when the
            // previous scene ended without terminal punctuation.
            sentenceBase += tokenized.sentenceCount
        }

        let combinedSource = voiceSections.map(\.text).joined(separator: "\n\n")
        self.script = TokenizedScript(
            source: combinedSource,
            language: language,
            tokens: tokens,
            sentenceRanges: Self.sentenceRanges(for: tokens)
        )
        self.tokenSectionIndices = tokenSections
        self.sectionTokenRanges = ranges
    }

    // MARK: Queries

    func sectionIndex(forSceneID sceneID: UUID) -> Int? {
        sections.firstIndex { $0.sceneID == sceneID }
    }

    func tokenIndex(for position: VoiceFollowPosition) -> Int? {
        guard let sectionIndex = sectionIndex(forSceneID: position.sceneID) else {
            return nil
        }
        let section = sections[sectionIndex]
        let characterOffset = min(max(0, position.characterOffset), section.characterCount)
        let utf16Offset: Int
        if characterOffset < section.characterUTF16Offsets.count {
            utf16Offset = section.characterUTF16Offsets[characterOffset]
        } else {
            utf16Offset = section.utf16Length
        }

        let range = sectionTokenRanges[sectionIndex]
        guard !range.isEmpty else {
            if sectionIndex + 1 < sectionTokenRanges.count {
                for nextIndex in (sectionIndex + 1)..<sectionTokenRanges.count {
                    let next = sectionTokenRanges[nextIndex]
                    if !next.isEmpty { return next.lowerBound }
                }
            }
            if sectionIndex > 0 {
                for index in stride(from: sectionIndex - 1, through: 0, by: -1) {
                    let previous = sectionTokenRanges[index]
                    if !previous.isEmpty {
                        return previous.upperBound - 1
                    }
                }
            }
            return nil
        }

        // Last token whose start is at or before the target.
        var low = range.lowerBound
        var high = range.upperBound
        while low < high {
            let middle = (low + high) / 2
            if script.tokens[middle].range.lowerBound <= utf16Offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let candidate = low - 1
        if candidate >= range.lowerBound,
           utf16Offset < script.tokens[candidate].range.upperBound {
            return candidate
        }
        if low < range.upperBound {
            return low
        }
        return range.upperBound - 1
    }

    func location(forTokenIndex index: Int) -> VoiceFollowLocation? {
        guard script.tokens.indices.contains(index),
              tokenSectionIndices.indices.contains(index) else {
            return nil
        }
        let sectionIndex = tokenSectionIndices[index]
        guard sections.indices.contains(sectionIndex) else { return nil }
        let section = sections[sectionIndex]
        let token = script.tokens[index]
        let characterOffset = section.characterOffset(forUTF16Offset: token.range.lowerBound)
        return VoiceFollowLocation(
            sectionIndex: sectionIndex,
            sceneID: section.sceneID,
            characterOffset: characterOffset,
            tokenIndex: index
        )
    }

    func position(atTokenIndex index: Int) -> VoiceFollowPosition? {
        guard let location = location(forTokenIndex: index) else { return nil }
        return VoiceFollowPosition(
            sceneID: location.sceneID,
            characterOffset: location.characterOffset
        )
    }

    /// Suffix of the script starting at `index`, with tokens and sentences
    /// re-indexed from zero. The speech follower has no public seek API, so a
    /// fresh follower is anchored by slicing the script at the current word.
    func followerScript(startingAtToken index: Int) -> (script: TokenizedScript, baseTokenIndex: Int) {
        guard !script.tokens.isEmpty else {
            return (
                TokenizedScript(
                    source: script.source,
                    language: script.language,
                    tokens: [],
                    sentenceRanges: []
                ),
                0
            )
        }
        let start = min(max(0, index), script.tokens.count - 1)
        let slice = script.tokens[start...]
        let sentenceBase = slice.first?.sentenceIndex ?? 0
        let tokens = slice.enumerated().map { offset, token in
            ScriptToken(
                index: offset,
                normalized: token.normalized,
                source: token.source,
                range: token.range,
                sentenceIndex: token.sentenceIndex - sentenceBase
            )
        }
        return (
            TokenizedScript(
                source: script.source,
                language: script.language,
                tokens: tokens,
                sentenceRanges: Self.sentenceRanges(for: tokens)
            ),
            start
        )
    }

    private static func sentenceRanges(for tokens: [ScriptToken]) -> [Range<Int>] {
        guard let first = tokens.first else { return [] }
        var ranges: [Range<Int>] = []
        var sentence = first.sentenceIndex
        var start = 0
        for (index, token) in tokens.enumerated() where token.sentenceIndex != sentence {
            ranges.append(start..<index)
            sentence = token.sentenceIndex
            start = index
        }
        ranges.append(start..<tokens.count)
        return ranges
    }
}

// MARK: - Project language

extension SpeechLanguage {
    /// Maps the project's primary language code (`es`, `es-ES`, `en`, ...) to
    /// one of the two recognition locales F9 supports.
    init?(projectLanguageCode: String) {
        let code = projectLanguageCode.lowercased()
        if code.hasPrefix("en") {
            self = .english
        } else if code.hasPrefix("es") {
            self = .spanish
        } else {
            return nil
        }
    }
}
