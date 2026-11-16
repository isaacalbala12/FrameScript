import Foundation
import FrameScriptCore

/// Localized text for the chapter warnings produced by `YouTubeChapters`.
///
/// The Core generator keeps a Spanish fallback message for the CLI and older
/// callers, but the app must never show Spanish to an English or Russian user.
extension ChapterWarning {
    func localizedMessage(language: AppLanguage) -> String {
        switch kind {
        case .noScenes:
            return L10n.tr("publishing.chapterWarning.noScenes", language: language)
        case .tooFewChapters:
            if let count = chapterCount, count > 0 {
                return String(
                    format: L10n.tr("publishing.chapterWarning.tooFew", language: language),
                    count
                )
            }
            return L10n.tr("publishing.chapterWarning.none", language: language)
        case .firstSceneNotAtZero:
            return L10n.tr("publishing.chapterWarning.firstSceneNotAtZero", language: language)
        case .unsortedScenes:
            return L10n.tr("publishing.chapterWarning.unsortedScenes", language: language)
        case .duplicateStart:
            return String(
                format: L10n.tr("publishing.chapterWarning.duplicateStart", language: language),
                title ?? "",
                otherTitle ?? ""
            )
        case .duplicateTimestamp:
            return String(
                format: L10n.tr("publishing.chapterWarning.duplicateTimestamp", language: language),
                title ?? "",
                timestamp ?? ""
            )
        case .shortSceneMerged:
            if isFirstChapterMerge {
                return String(
                    format: L10n.tr(
                        "publishing.chapterWarning.shortSceneMergedFirst",
                        language: language
                    ),
                    title ?? "",
                    otherTitle ?? ""
                )
            }
            return String(
                format: L10n.tr(
                    "publishing.chapterWarning.shortSceneMergedPrevious",
                    language: language
                ),
                title ?? "",
                otherTitle ?? "",
                timestamp ?? ""
            )
        case .emptyTitle:
            return String(
                format: L10n.tr("publishing.chapterWarning.emptyTitle", language: language),
                title ?? ""
            )
        case .titleTruncated:
            return String(
                format: L10n.tr("publishing.chapterWarning.titleTruncated", language: language),
                title ?? ""
            )
        case .sceneOutsideVideo:
            return String(
                format: L10n.tr("publishing.chapterWarning.sceneOutsideVideo", language: language),
                title ?? ""
            )
        }
    }
}
