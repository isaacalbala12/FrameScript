import Foundation

extension L10n {
    /// Strings owned by fix package WP7. Every key needs .english, .russian and .spanish.
    static let wp7Strings: [AppLanguage: [String: String]] = [
        .english: [
            // Stable video-type identifiers. The rhythm threshold table is keyed
            // by these ASCII ids, never by the label the user reads.
            "videoType.analysis": "Analysis",
            "videoType.gameplay": "Gameplay",
            "videoType.review": "Review",
            "videoType.comparison": "Comparison",
            "videoType.news": "News",
            "videoType.chronicle": "Chronicle",
            "videoType.tutorial": "Tutorial",
            "videoType.update": "Update",
            "videoType.vantare": "Vantare",

            // Plural forms for the sidebar rhythm badge (`L10n.plural`).
            "rhythm.badgeAccessibility.one": "%d rhythm warning",
            "rhythm.badgeAccessibility.other": "%d rhythm warnings"
        ],
        .russian: [
            "videoType.analysis": "Анализ",
            "videoType.gameplay": "Геймплей",
            "videoType.review": "Обзор",
            "videoType.comparison": "Сравнение",
            "videoType.news": "Новости",
            "videoType.chronicle": "Хроника",
            "videoType.tutorial": "Туториал",
            "videoType.update": "Обновление",
            "videoType.vantare": "Vantare",

            "rhythm.badgeAccessibility.one": "%d предупреждение ритма",
            "rhythm.badgeAccessibility.few": "%d предупреждения ритма",
            "rhythm.badgeAccessibility.many": "%d предупреждений ритма"
        ],
        .spanish: [
            "videoType.analysis": "Análisis",
            "videoType.gameplay": "Gameplay",
            "videoType.review": "Review",
            "videoType.comparison": "Comparativa",
            "videoType.news": "Noticia",
            "videoType.chronicle": "Crónica",
            "videoType.tutorial": "Tutorial",
            "videoType.update": "Actualización",
            "videoType.vantare": "Vantare",

            "rhythm.badgeAccessibility.one": "%d aviso de ritmo",
            "rhythm.badgeAccessibility.other": "%d avisos de ritmo"
        ]
    ]
}

extension AppLanguage {
    /// Project script language for newly created content, resolved against an
    /// explicit preference list.
    ///
    /// `contentLanguageCode` (`DurationModels.swift`) resolves the same value
    /// with `Locale.preferredLanguages`. This overload lets a test pin the
    /// `.system` rule on any Mac instead of shipping a check that can only agree
    /// with itself.
    func contentLanguageCode(preferredLanguages: [String]) -> String {
        switch L10n.resolve(self, preferredLanguages: preferredLanguages) {
        case .system, .english: "en"
        case .spanish: "es"
        case .russian: "ru"
        }
    }
}
