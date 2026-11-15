import Foundation

extension L10n {
    /// Feature-owned string tables. Each feature declares its own table in
    /// `Localization+<Feature>.swift` as `static let <feature>Strings: [AppLanguage: [String: String]]`
    /// and appends it here (one line per feature) so parallel work never edits the base tables.
    static let featureTables: [[AppLanguage: [String: String]]] = [
        simracingTemplateStrings,
        autosaveStrings,
        [.spanish: autosaveSpanish],
        backupsStrings,
        [.spanish: backupsSpanish],
        teleprompterStrings,
        [.spanish: teleprompterSpanish],
        hooksStrings,
        markdownImportStrings,
        aiProvidersStrings,
        editorMarkupStrings,
        durationStrings,
        recordingStrings,
        voiceFollowStrings,
        wp1Strings,
        wp2Strings,
        wp3Strings,
        wp4Strings,
        wp5Strings,
        wp6Strings,
        wp7Strings,
        wp8Strings,
        productionStrings,
        clipsStrings,
        timelineStrings,
        avScriptStrings
    ]
}
