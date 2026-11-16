import Foundation

/// A field of the publishing pack. The cases match the order the escaleta
/// contract uses, so copy actions and the Markdown export agree.
public enum PublishingField: String, Sendable, CaseIterable, Identifiable {
    case promise
    case thesis
    case title
    case titleCandidates
    case thumbnailConcept
    case description
    case chapters
    case tags
    case hashtags
    case pinnedComment
    case communityPost

    public var id: String { rawValue }
}

/// Hard and soft limits enforced by YouTube and by the house publishing rules.
public enum PublishingLimits {
    public static let titleMaximum = 100
    public static let titleRecommended = 70
    public static let descriptionMaximum = 5_000
    public static let descriptionRecommended = 4_500
    public static let tagsCharactersMaximum = 500
    public static let tagsRecommendedCount = 20
    public static let hashtagsRecommendedCount = 3
    public static let thumbnailTextWordsRecommended = 3
    public static let pinnedCommentMaximum = 10_000
    public static let pinnedCommentRecommended = 500
    public static let chapterTitleMaximum = 60
    public static let minimumChapters = 3
    public static let minimumChapterSeconds = 10
}

public enum PublishingIssueSeverity: String, Sendable, Hashable, CaseIterable {
    /// Publishing still works, but the result is weaker or likely to be cut.
    case warning
    /// YouTube rejects the value.
    case error
}

public enum PublishingValidationRule: String, Sendable, Hashable {
    case titleMissing
    case titleTooLong
    case titleNearLimit
    case titleInvalidCharacters
    case descriptionMissing
    case descriptionTooLong
    case descriptionNearLimit
    case descriptionInvalidCharacters
    case studioDescriptionTooLong
    case tagsTooLong
    case tooManyTags
    case tooManyHashtags
    case thumbnailTextTooLong
    case pinnedCommentTooLong
    case pinnedCommentNearLimit
}

public struct PublishingValidationIssue: Sendable, Hashable, Identifiable {
    public let field: PublishingField
    public let rule: PublishingValidationRule
    public let severity: PublishingIssueSeverity
    public let count: Int
    public let limit: Int

    public var id: String {
        "\(field.rawValue).\(rule.rawValue)"
    }

    public init(
        field: PublishingField,
        rule: PublishingValidationRule,
        severity: PublishingIssueSeverity,
        count: Int,
        limit: Int
    ) {
        self.field = field
        self.rule = rule
        self.severity = severity
        self.count = count
        self.limit = limit
    }
}

/// Everything the metadata validator needs. Thumbnail concepts are passed as
/// their on-screen text only: that is the part YouTube shows at 320 px wide.
public struct PublishingValidationInput: Sendable, Equatable {
    public var title: String
    public var description: String
    /// Final description after chapters and sources are appended. YouTube
    /// receives this string, so the 5,000-character limit must be checked here
    /// as well as on the editable `description`.
    public var studioDescription: String
    public var tags: [String]
    public var hashtags: [String]
    public var pinnedComment: String
    public var thumbnailTexts: [String]

    public init(
        title: String = "",
        description: String = "",
        studioDescription: String = "",
        tags: [String] = [],
        hashtags: [String] = [],
        pinnedComment: String = "",
        thumbnailTexts: [String] = []
    ) {
        self.title = title
        self.description = description
        self.studioDescription = studioDescription
        self.tags = tags
        self.hashtags = hashtags
        self.pinnedComment = pinnedComment
        self.thumbnailTexts = thumbnailTexts
    }
}

/// One of the eight fixed checks in the Publishing panel. The token is stored
/// in `ChecklistTask.text`, so the checklist survives project saves without
/// adding a field to `PublishingPack`.
public enum PublishingChecklistItem: String, Sendable, CaseIterable, Identifiable {
    case chosenTitle
    case thumbnailExported
    case descriptionWithChaptersAndSources
    case tags
    case pinnedComment
    case endScreen
    case communityPost
    case subtitlesReviewed

    public var id: String { rawValue }

    /// Stable, language-independent token persisted inside `ChecklistTask.text`.
    public var taskToken: String { "publishing.checklist.\(rawValue)" }

    /// Localization key for the human label.
    public var titleKey: String { "publishing.checklist.\(rawValue)" }

    public static func item(forTaskText text: String) -> PublishingChecklistItem? {
        allCases.first { $0.taskToken == text }
    }
}

public struct PublishingSource: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var url: String
    public var note: String

    public init(id: UUID = UUID(), title: String = "", url: String = "", note: String = "") {
        self.id = id
        self.title = title
        self.url = url
        self.note = note
    }

    /// One line for the description and the escaleta sources section. The note
    /// is the importer's verbatim line and wins when present, matching
    /// `EscaletaProjectExporter`.
    public var displayLine: String {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { return note }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty {
            return title.isEmpty ? url : "\(title) — \(url)"
        }
        return title
    }
}

/// Small text helpers shared by the app and the Core tests.
public enum PublishingText {
    public static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func wordCount(_ value: String) -> Int {
        value.split(whereSeparator: \.isWhitespace).count
    }

    /// Parses a comma or newline separated tag field. Duplicates are removed
    /// case-insensitively while keeping the first spelling.
    public static func tags(from value: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in value.components(separatedBy: CharacterSet(charactersIn: ",\n")) {
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { continue }
            let key = tag.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(tag)
        }
        return result
    }

    /// Parses hashtags separated by commas, spaces or newlines. A leading `#`
    /// is added when the user wrote the word without it.
    public static func hashtags(from value: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let pieces = value.components(
            separatedBy: CharacterSet(charactersIn: ", \n\t")
        )
        for raw in pieces {
            var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { continue }
            if !tag.hasPrefix("#") { tag = "#" + tag }
            guard tag.count > 1 else { continue }
            let key = tag.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(tag)
        }
        return result
    }

    /// YouTube counts a multi-word tag as if it were wrapped in quotes, so
    /// `assetto corsa` costs two extra characters. Ignoring them made the
    /// counter accept 498/500 values that YouTube then rejected.
    public static func tagCharacterCount(_ tags: [String]) -> Int {
        guard !tags.isEmpty else { return 0 }
        let characters = tags.reduce(0) { partial, tag in
            partial + tag.count + (tag.contains(where: \.isWhitespace) ? 2 : 0)
        }
        return characters + tags.count - 1
    }

    /// Number of words in the longest thumbnail text.
    public static func longestThumbnailWordCount(_ texts: [String]) -> Int {
        texts.map(wordCount).max() ?? 0
    }
}
