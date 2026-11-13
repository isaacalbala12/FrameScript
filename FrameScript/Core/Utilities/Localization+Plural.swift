import Foundation

extension L10n {
    enum PluralCategory: String {
        case one, few, many, other
    }

    /// CLDR-style plural category for the languages the app ships.
    static func pluralCategory(for count: Int, language: AppLanguage) -> PluralCategory {
        let n = abs(count)
        switch resolve(language) {
        case .russian:
            if n % 10 == 1 && n % 100 != 11 { return .one }
            if (2...4).contains(n % 10) && !(12...14).contains(n % 100) { return .few }
            return .many
        default:
            return n == 1 ? .one : .other
        }
    }

    /// Looks up `"<baseKey>.<category>"`, falling back to `baseKey`, and formats it with `count`.
    static func plural(_ baseKey: String, count: Int, language: AppLanguage) -> String {
        let resolved = resolve(language)
        let key = "\(baseKey).\(pluralCategory(for: count, language: resolved).rawValue)"
        var format = tr(key, language: resolved)
        if format == key { format = tr(baseKey, language: resolved) }
        return String(format: format, locale: Locale(identifier: resolved.localeIdentifierForPlurals), count)
    }
}

private extension AppLanguage {
    var localeIdentifierForPlurals: String {
        switch self {
        case .spanish: "es_ES"
        case .russian: "ru_RU"
        default: "en_US"
        }
    }
}
