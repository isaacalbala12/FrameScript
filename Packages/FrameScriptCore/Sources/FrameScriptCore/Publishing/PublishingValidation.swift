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

        let titleCount = input.title.count
        if titleCount > PublishingLimits.titleMaximum {
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

        let descriptionCount = input.description.count
        if descriptionCount > PublishingLimits.descriptionMaximum {
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
}
