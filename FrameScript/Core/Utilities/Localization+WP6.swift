import Foundation

extension L10n {
    /// Strings owned by fix package WP6. Every key needs .english, .russian and .spanish.
    static let wp6Strings: [AppLanguage: [String: String]] = [
        .english: [
            "settings.autosaveIntervalValue": "%d s",
            "production.goToScript": "Go to Script",
            "recording.takes.count.one": "%d take",
            "recording.takes.count.other": "%d takes"
        ],
        .russian: [
            "settings.autosaveIntervalValue": "%d с",
            "production.goToScript": "Перейти к сценарию",
            "recording.takes.count.one": "%d дубль",
            "recording.takes.count.few": "%d дубля",
            "recording.takes.count.many": "%d дублей"
        ],
        .spanish: [
            "settings.autosaveIntervalValue": "%d s",
            "production.goToScript": "Ir al guion",
            "recording.takes.count.one": "%d toma",
            "recording.takes.count.other": "%d tomas"
        ]
    ]
}
