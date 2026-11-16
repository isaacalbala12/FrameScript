import Foundation

/// Validates the metadata limits YouTube enforces and the softer house limits
/// that keep a title readable and a description scannable.
///
/// The validator never truncates: the panel shows the counter and the writer
/// decides. Exporters use the same limits so a warning cannot silently become
/// a broken upload.
public enum PublishingValidator {
    public static func issues(for input: PublishingValidationInput) -> [PublishingValidationIssue] {
        var issues: [PublishingValidationIssue] = []

        let trimmedTitle = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleCount = input.title.count
        if trimmedTitle.isEmpty {
            issues.append(
                PublishingValidationIssue(
                    field: .title,
                    rule: .titleMissing,
                    severity: .warning,
                    count: 0,
                    limit: PublishingLimits.titleMaximum
                )
            )
        } else if titleCount > PublishingLimits.titleMaximum {
            issues.append(
                PublishingValidationIssue(
                    field: .title,
                    rule: .titleTooLong,
                    severity: .error,
                    count: titleCount,
                    limit: PublishingLimits.titleMaximum
                )
            )
        } else if titleCount > PublishingLimits.titleRecommended {
            issues.append(
                PublishingValidationIssue(
                    field: .title,
                    rule: .titleNearLimit,
                    severity: .warning,
                    count: titleCount,
                    limit: PublishingLimits.titleRecommended
                )
            )
        }
        if let invalid = invalidCharacterCount(input.title), invalid > 0 {
            issues.append(
                PublishingValidationIssue(
                    field: .title,
                    rule: .titleInvalidCharacters,
                    severity: .error,
                    count: invalid,
                    limit: 0
                )
            )
        }

        let trimmedDescription = input.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptionCount = input.description.count
        if trimmedDescription.isEmpty {
            issues.append(
                PublishingValidationIssue(
                    field: .description,
                    rule: .descriptionMissing,
                    severity: .warning,
                    count: 0,
                    limit: PublishingLimits.descriptionMaximum
                )
            )
        } else if descriptionCount > PublishingLimits.descriptionMaximum {
            issues.append(
                PublishingValidationIssue(
                    field: .description,
                    rule: .descriptionTooLong,
                    severity: .error,
                    count: descriptionCount,
                    limit: PublishingLimits.descriptionMaximum
                )
            )
        } else if descriptionCount > PublishingLimits.descriptionRecommended {
            issues.append(
                PublishingValidationIssue(
                    field: .description,
                    rule: .descriptionNearLimit,
                    severity: .warning,
                    count: descriptionCount,
                    limit: PublishingLimits.descriptionRecommended
                )
            )
        }
        if let invalid = invalidCharacterCount(input.description), invalid > 0 {
            issues.append(
                PublishingValidationIssue(
                    field: .description,
                    rule: .descriptionInvalidCharacters,
                    severity: .error,
                    count: invalid,
                    limit: 0
                )
            )
        }

        let studioCount = input.studioDescription.count
        if studioCount > PublishingLimits.descriptionMaximum {
            issues.append(
                PublishingValidationIssue(
                    field: .description,
                    rule: .studioDescriptionTooLong,
                    severity: .error,
                    count: studioCount,
                    limit: PublishingLimits.descriptionMaximum
                )
            )
        }

        let tagCharacters = PublishingText.tagCharacterCount(input.tags)
        if tagCharacters > PublishingLimits.tagsCharactersMaximum {
            issues.append(
                PublishingValidationIssue(
                    field: .tags,
                    rule: .tagsTooLong,
                    severity: .error,
                    count: tagCharacters,
                    limit: PublishingLimits.tagsCharactersMaximum
                )
            )
        }
        if input.tags.count > PublishingLimits.tagsRecommendedCount {
            issues.append(
                PublishingValidationIssue(
                    field: .tags,
                    rule: .tooManyTags,
                    severity: .warning,
                    count: input.tags.count,
                    limit: PublishingLimits.tagsRecommendedCount
                )
            )
        }

        if input.hashtags.count > PublishingLimits.hashtagsRecommendedCount {
            issues.append(
                PublishingValidationIssue(
                    field: .hashtags,
                    rule: .tooManyHashtags,
                    severity: .warning,
                    count: input.hashtags.count,
                    limit: PublishingLimits.hashtagsRecommendedCount
                )
            )
        }

        let thumbnailWords = PublishingText.longestThumbnailWordCount(input.thumbnailTexts)
        if thumbnailWords > PublishingLimits.thumbnailTextWordsRecommended {
            issues.append(
                PublishingValidationIssue(
                    field: .thumbnailConcept,
                    rule: .thumbnailTextTooLong,
                    severity: .warning,
                    count: thumbnailWords,
                    limit: PublishingLimits.thumbnailTextWordsRecommended
                )
            )
        }

        let pinnedCount = input.pinnedComment.count
        if pinnedCount > PublishingLimits.pinnedCommentMaximum {
            issues.append(
                PublishingValidationIssue(
                    field: .pinnedComment,
                    rule: .pinnedCommentTooLong,
                    severity: .error,
                    count: pinnedCount,
                    limit: PublishingLimits.pinnedCommentMaximum
                )
            )
        } else if pinnedCount > PublishingLimits.pinnedCommentRecommended {
            issues.append(
                PublishingValidationIssue(
                    field: .pinnedComment,
                    rule: .pinnedCommentNearLimit,
                    severity: .warning,
                    count: pinnedCount,
                    limit: PublishingLimits.pinnedCommentRecommended
                )
            )
        }

        return issues
    }

    public static func hasErrors(_ issues: [PublishingValidationIssue]) -> Bool {
        issues.contains { $0.severity == .error }
    }

    /// YouTube rejects angle brackets in the title and description; tag and
    /// hashtag rules do not matter when the whole upload is refused.
    private static func invalidCharacterCount(_ value: String) -> Int? {
        let count = value.unicodeScalars.filter { $0.value == 0x3C || $0.value == 0x3E }.count
        return count > 0 ? count : nil
    }
}
