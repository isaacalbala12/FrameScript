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

    func testSpanishPlaceholdersMatchEnglishForEveryKey() {
        let english = L10n.baseTable(for: .english)
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
        XCTAssertEqual(L10n.tr("settings.autosave", language: .spanish), "Autoguardado al cambiar")
        XCTAssertEqual(L10n.tr("settings.language", language: .spanish), "Idioma")
    }

    func testResolvePrefersSpanishSystemLanguage() {
        XCTAssertEqual(L10n.resolve(.system, preferredLanguages: ["es-ES"]), .spanish)
        XCTAssertEqual(L10n.resolve(.system, preferredLanguages: ["es-419", "en-US"]), .spanish)
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
