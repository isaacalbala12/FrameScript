import Foundation
@testable import FrameScript
import XCTest

final class SpanishLocalizationTests: XCTestCase {
    func testSpanishIsSelectableAndKeepsExistingRawValues() {
        XCTAssertEqual(AppLanguage.english.rawValue, "english")
        XCTAssertEqual(AppLanguage.russian.rawValue, "russian")
        XCTAssertEqual(AppLanguage.spanish.rawValue, "spanish")
        XCTAssertEqual(AppLanguage.spanish.displayName, "Español")
        XCTAssertTrue(AppLanguage.allCases.contains(.spanish))
    }

    func testSystemLanguageLabelFollowsTheInterfaceLanguage() {
        XCTAssertEqual(AppLanguage.system.displayName(in: .english), "System")
        XCTAssertEqual(AppLanguage.system.displayName(in: .spanish), "Sistema")
        XCTAssertEqual(AppLanguage.system.displayName(in: .russian), "Системный")
        XCTAssertEqual(AppLanguage.spanish.displayName(in: .english), "Español")
    }

    func testSpanishTableCoversEveryEnglishBaseKey() throws {
        let english = L10n.baseTable(for: .english)
        let spanish = L10n.baseTable(for: .spanish)

        XCTAssertEqual(Set(spanish.keys), Set(english.keys))
        for (key, englishValue) in english {
            let spanishValue = try XCTUnwrap(spanish[key], "Missing Spanish value for \(key)")
            if !englishValue.isEmpty {
                XCTAssertFalse(
                    spanishValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Empty Spanish value for \(key)"
                )
            }
        }
    }

    /// Every feature table (and every `[.spanish: …]` counterpart) is registered
    /// and carries the same keys in Spanish as in English.
    func testEveryFeatureTableIsRegisteredAndKeepsSpanishKeyParity() {
        let expectedSampleKeys = [
            "template.Simracing Update Analysis",
            "dialog.externalChange.title",
            "backups.menu",
            "menu.teleprompter",
            "menu.generateHook",
            "menu.importEscaleta",
            "aiProvider.T3 Code (suscripción)",
            "settings.markupRhythm",
            "duration.real",
            "recording.menu.togglePanel",
            "voiceFollow.toggle"
        ]

        let fullTables = L10n.featureTables.compactMap { $0[.english] }
        let englishFeatureKeys = Set(fullTables.flatMap(\.keys))
        let spanishCounterpartKeys = Set(
            L10n.featureTables
                .filter { $0[.english] == nil }
                .compactMap { $0[.spanish] }
                .flatMap(\.keys)
        )
        for key in expectedSampleKeys {
            XCTAssertTrue(
                englishFeatureKeys.contains(key),
                "feature table containing \(key) is not registered in Localization+Features.swift"
            )
        }

        for (index, table) in L10n.featureTables.enumerated() {
            XCTAssertFalse(table.isEmpty, "feature table \(index) is empty")
            guard let english = table[.english] else {
                // A `[.spanish: …]` counterpart table: its keys must exist in a
                // registered English table, otherwise it overrides nothing.
                let spanish = table[.spanish] ?? [:]
                XCTAssertFalse(spanish.isEmpty, "counterpart table \(index) has no Spanish strings")
                XCTAssertTrue(
                    Set(spanish.keys).isSubset(of: englishFeatureKeys),
                    "counterpart table \(index) has keys no English table defines: \(Set(spanish.keys).subtracting(englishFeatureKeys).sorted())"
                )
                continue
            }
            if let spanish = table[.spanish] {
                XCTAssertEqual(
                    Set(spanish.keys),
                    Set(english.keys),
                    "table \(index) Spanish keys drifted from English"
                )
            } else {
                // Tables written before Spanish existed may ship Spanish as a
                // separate `[.spanish: …]` entry; every key still needs one.
                XCTAssertTrue(
                    Set(english.keys).isSubset(of: spanishCounterpartKeys),
                    "table \(index) has keys without a Spanish counterpart: \(Set(english.keys).subtracting(spanishCounterpartKeys).sorted())"
                )
            }
        }

        // The registered tables, taken together, must translate the same keys.
        let spanishFeatureKeys = Set(
            L10n.featureTables.compactMap { $0[.spanish] }.flatMap(\.keys)
        )
        XCTAssertEqual(englishFeatureKeys, spanishFeatureKeys)
    }

    func testSpanishPlaceholdersMatchEnglishForEveryKey() {        let english = L10n.baseTable(for: .english)
        let spanish = L10n.baseTable(for: .spanish)

        for (key, englishValue) in english {
            guard let spanishValue = spanish[key] else {
                XCTFail("Missing Spanish value for \(key)")
                continue
            }
            XCTAssertEqual(
                Self.placeholders(in: englishValue),
                Self.placeholders(in: spanishValue),
                "Placeholder mismatch for \(key)"
            )
        }
    }

    func testSpanishUsesGlossaryTerms() {
        XCTAssertEqual(L10n.tr("mode.script", language: .spanish), "Guion")
        XCTAssertEqual(L10n.tr("mode.bRoll", language: .spanish), "Visuales")
        XCTAssertEqual(L10n.tr("mode.editing", language: .spanish), "Edición")
        XCTAssertEqual(L10n.tr("scene.kind", language: .spanish), "Escena")
        XCTAssertEqual(L10n.tr("shortcuts.title", language: .spanish), "Atajos")
        XCTAssertEqual(L10n.tr("settings.autosave", language: .spanish), "Guardado automático al cambiar")
        XCTAssertEqual(L10n.tr("settings.language", language: .spanish), "Idioma")
        XCTAssertEqual(L10n.tr("settings.export", language: .spanish), "Exportación")
        XCTAssertEqual(L10n.tr("brollSource.Talking head", language: .spanish), "Plano a cámara")
    }

    func testResolvePrefersTheFirstSupportedSystemLanguage() {
        XCTAssertEqual(L10n.resolve(.system, preferredLanguages: ["es-ES"]), .spanish)
        // Latin American Spanish is served by the only Spanish table (Spain).
        XCTAssertEqual(L10n.resolve(.system, preferredLanguages: ["es-419", "en-US"]), .spanish)
        XCTAssertEqual(L10n.resolve(.system, preferredLanguages: ["ca-ES", "es-ES"]), .spanish)
        XCTAssertEqual(L10n.resolve(.system, preferredLanguages: ["en-US", "es-ES"]), .english)
        XCTAssertEqual(L10n.resolve(.system, preferredLanguages: ["fr-FR", "ru-RU"]), .russian)
        XCTAssertEqual(L10n.resolve(.system, preferredLanguages: ["fr-FR", "ca-ES"]), .english)
        XCTAssertEqual(L10n.resolve(.system, preferredLanguages: ["ru-RU"]), .russian)
        XCTAssertEqual(L10n.resolve(.system, preferredLanguages: ["en-GB"]), .english)
        XCTAssertEqual(L10n.resolve(.english, preferredLanguages: ["es-ES"]), .english)
        XCTAssertEqual(L10n.resolve(.spanish, preferredLanguages: ["en-US"]), .spanish)
    }

    func testPromptLanguageFollowsTheScriptLanguage() {
        let prompts = PromptBuilder()

        XCTAssertEqual(
            prompts.responseLanguage(
                for: "Hoy vamos a analizar la nueva actualización del simulador y cómo cambia el comportamiento del coche en las curvas rápidas.",
                fallback: .english
            ),
            .spanish
        )
        XCTAssertEqual(
            prompts.responseLanguage(
                for: "El nuevo Porsche 911 GT3 R en Spa-Francorchamps",
                fallback: .english
            ),
            .spanish
        )
        XCTAssertEqual(
            prompts.responseLanguage(
                for: "Today we are going to review the new simulator update and how it changes the car's behavior in fast corners.",
                fallback: .spanish
            ),
            .english
        )
        XCTAssertEqual(
            prompts.responseLanguage(
                for: "Это достаточно длинный русский текст для определения языка.",
                fallback: .english
            ),
            .russian
        )
    }

    func testUnsupportedScriptLanguagesFallBackToTheInterfaceLanguage() {
        let prompts = PromptBuilder()

        XCTAssertEqual(
            prompts.responseLanguage(
                for: "Nous allons analyser la nouvelle mise à jour du simulateur et son comportement dans les virages rapides.",
                fallback: .spanish
            ),
            .spanish
        )
        XCTAssertEqual(
            prompts.responseLanguage(
                for: "Avui analitzarem l'actualització del simulador i com canvia el comportament del cotxe als revolts ràpids.",
                fallback: .english
            ),
            .english
        )
        XCTAssertEqual(
            prompts.responseLanguage(
                for: "Hoje vamos analisar a nova atualização do simulador e como muda o comportamento do carro nas curvas rápidas.",
                fallback: .russian
            ),
            .russian
        )
    }

    func testShortScriptTextFallsBackToInterfaceLanguage() {
        let prompts = PromptBuilder()

        XCTAssertEqual(prompts.responseLanguage(for: "Hola", fallback: .english), .english)
        XCTAssertEqual(prompts.responseLanguage(for: "Buenos días", fallback: .spanish), .spanish)
        XCTAssertEqual(prompts.responseLanguage(for: "1234 !!! ...", fallback: .russian), .russian)
        XCTAssertEqual(
            prompts.responseLanguage(for: "", fallback: .system, preferredLanguages: ["es-ES"]),
            .spanish
        )
    }

    func testStructuredReviewPromptAsksForSpanishValues() {
        let prompt = PromptBuilder().systemPrompt(for: .analyze, language: .spanish)

        XCTAssertTrue(prompt.contains("Respond only in Spanish."))
        XCTAssertTrue(prompt.contains("title, message, and suggestion values must be written in Spanish"))
        XCTAssertTrue(prompt.contains("Severity must be note, suggestion, or important."))
        XCTAssertTrue(PromptBuilder().systemPrompt(for: .analyze, language: .russian).contains("Russian"))
    }

    private static func placeholders(in value: String) -> [String] {
        value.matches(of: #/%(?:lld|ld|d|@|f|s)/#).map { String($0.output) }.sorted()
    }
}
