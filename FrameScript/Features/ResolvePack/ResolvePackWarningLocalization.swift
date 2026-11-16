import Foundation
import FrameScriptCore

/// Localized text for the Resolve delivery sheet warnings.
///
/// `ResolvePackWarning.message` is the Spanish fallback the README and CLI use;
/// the sheet renders `kind` so the interface language always wins.
extension ResolvePackWarning {
    func localizedMessage(language: AppLanguage) -> String {
        switch kind {
        case let .missingLanguageText(sceneTitle, languageCode):
            return String(
                format: L10n.tr("resolvePack.warning.missingLanguageText", language: language),
                sceneTitle,
                languageCode
            )
        case let .unestimableDuration(sceneTitle):
            return String(
                format: L10n.tr("resolvePack.warning.unestimableDuration", language: language),
                sceneTitle
            )
        case let .unanchoredBRoll(sceneTitle, item):
            return String(
                format: L10n.tr("resolvePack.warning.unanchoredBRoll", language: language),
                sceneTitle,
                item
            )
        case let .claimNeedsVerification(sceneTitle, status, text):
            return String(
                format: L10n.tr("resolvePack.warning.claim", language: language),
                status,
                text,
                sceneTitle
            )
        case let .unlinkedClaim(status, text):
            return String(
                format: L10n.tr("resolvePack.warning.unlinkedClaim", language: language),
                status,
                text
            )
        case let .dropFrameUnsupported(fps):
            return String(
                format: L10n.tr("resolvePack.warning.dropFrameUnsupported", language: language),
                fps
            )
        case .emptyProjectName:
            return L10n.tr("resolvePack.warning.emptyProjectName", language: language)
        case let .markerCollision(name, otherName, frame):
            return String(
                format: L10n.tr("resolvePack.warning.markerCollision", language: language),
                name,
                frame,
                otherName
            )
        case let .tooManyEvents(count):
            return String(
                format: L10n.tr("resolvePack.warning.tooManyEvents", language: language),
                count
            )
        case let .chapter(warning):
            return warning.localizedMessage(language: language)
        case let .markerNameTruncated(name, fullName):
            return String(
                format: L10n.tr("resolvePack.warning.markerNameTruncated", language: language),
                name,
                fullName
            )
        case let .moreNamesTruncated(count):
            return String(
                format: L10n.tr("resolvePack.warning.moreNamesTruncated", language: language),
                count
            )
        case let .chaptersOmitted(chapterCount):
            return String(
                format: L10n.tr("resolvePack.warning.chaptersOmitted", language: language),
                chapterCount
            )
        }
    }
}
