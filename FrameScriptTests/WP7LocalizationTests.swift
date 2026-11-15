import Foundation
@testable import FrameScript
import XCTest

/// Regression tests for fix package WP7: localization tables, content
/// language resolution and the Spanish copy.
final class WP7LocalizationTests: FrameScriptTestCase {
    // MARK: - Item 1: `.system` resolution

    func testSimracingCopyResolvesSystemLanguageLikeTheInterface() {
        XCTAssertEqual(
            SimracingCopy.resolvedLanguage(.system, preferredLanguages: ["ca-ES", "es-ES"]),
            .spanish
        )
        XCTAssertEqual(
            SimracingCopy.resolvedLanguage(.system, preferredLanguages: ["fr-FR", "ru-RU"]),
            .russian
        )
        XCTAssertEqual(
            SimracingCopy.resolvedLanguage(.system, preferredLanguages: ["fr-FR", "ca-ES"]),
            .english
        )
        XCTAssertEqual(
            SimracingCopy.resolvedLanguage(.spanish, preferredLanguages: ["en-US"]),
            .spanish
        )
    }

    func testDemoBuiltFromTheSystemLanguageUsesTheResolvedContentLanguage() {
        let spanish = SampleData.demoProject(
            language: .system,
            preferredLanguages: ["ca-ES", "es-ES"]
        )
        XCTAssertEqual(spanish.primaryLanguage, "es")
        XCTAssertEqual(spanish.title, SampleData.demoProject(language: .spanish).title)

        let russian = SampleData.demoProject(
            language: .system,
            preferredLanguages: ["fr-FR", "ru-RU"]
        )
        XCTAssertEqual(russian.primaryLanguage, "ru")
        XCTAssertEqual(russian.title, SampleData.demoProject(language: .russian).title)
    }

    func testSystemContentCodeUsesTheSameResolverAsTheInterface() {
        // The tautology this replaces compared `code` with
        // `contentLanguageCode`, which are the same property. Resolve `.system`
        // against explicit preference lists instead, so the expectation does not
        // depend on this Mac's locale.
        XCTAssertEqual(
            AppLanguage.system.contentLanguageCode(preferredLanguages: ["fr-FR"]),
            "en",
            "an unsupported system language must fall back to English content"
        )
        XCTAssertEqual(
            AppLanguage.system.contentLanguageCode(preferredLanguages: ["ca-ES", "es-ES"]),
            "es"
        )
        XCTAssertEqual(
            AppLanguage.system.contentLanguageCode(preferredLanguages: ["fr-FR", "ru-RU"]),
            "ru"
        )
        // Non-system languages never consult the preference list.
        XCTAssertEqual(AppLanguage.spanish.contentLanguageCode(preferredLanguages: ["en-US"]), "es")
        XCTAssertEqual(AppLanguage.english.contentLanguageCode(preferredLanguages: ["es-ES"]), "en")

        // The production property and the new-project language agree with the
        // resolver on this machine's real preferences.
        let resolved = L10n.resolve(.system)
        XCTAssertEqual(AppLanguage.system.code, resolved.contentLanguageCode)
        XCTAssertEqual(
            AppLanguage.system.contentLanguageCode,
            AppLanguage.system.contentLanguageCode(preferredLanguages: Locale.preferredLanguages)
        )
        XCTAssertTrue(
            ["en", "es", "ru"].contains(AppLanguage.system.code),
            "an unsupported system language must not leak \(AppLanguage.system.code) into project content"
        )
        XCTAssertEqual(SampleData.project(named: "Nuevo", template: nil, language: .system).primaryLanguage,
                       resolved.contentLanguageCode)
    }

    // MARK: - Item 2: video types

    func testLegacySpanishThresholdKeyAppliesToTheCanonicalVideoType() {
        var settings = AppSettings.defaults
        settings.rhythmThresholdsByVideoType["Análisis"] = AppRhythmThresholds(
            longSentenceWordLimit: 42,
            uncoveredSecondsLimit: 3
        )
        let project = FrameProject(title: "Análisis", videoType: "analysis")
        let calibration = RhythmReview.effectiveThresholds(project: project, settings: settings)
        XCTAssertEqual(calibration.maxSentenceWords, 42)
        XCTAssertEqual(calibration.maxSecondsWithoutVisualChange, 3)
    }

    func testVideoTypeAliasesShareOneCanonicalID() {
        XCTAssertEqual(VideoTypeID.canonicalID(for: "Análisis"), "analysis")
        XCTAssertEqual(VideoTypeID.canonicalID(for: "ANÁLISIS"), "analysis")
        XCTAssertEqual(VideoTypeID.canonicalID(for: " analysis "), "analysis")
        XCTAssertEqual(VideoTypeID.canonicalID(for: "Comparativa"), "comparison")
        XCTAssertEqual(VideoTypeID.canonicalID(for: "comparison"), "comparison")
        XCTAssertEqual(VideoTypeID.canonicalID(for: "Noticia"), "news")
        XCTAssertEqual(VideoTypeID.canonicalID(for: "Crónica"), "chronicle")
        XCTAssertEqual(VideoTypeID.canonicalID(for: "cronica"), "chronicle")
        XCTAssertEqual(VideoTypeID.canonicalID(for: "Actualización"), "update")
        XCTAssertEqual(VideoTypeID.canonicalID(for: "Review"), "review")
        XCTAssertEqual(VideoTypeID.canonicalID(for: "Vantare"), "vantare")
        XCTAssertEqual(VideoTypeID.canonicalID(for: "Vlog de viajes"), "Vlog de viajes")
        XCTAssertEqual(VideoTypeID.canonicalID(for: "   "), "")
    }

    func testWritesReuseTheLegacyKeyAndRemovalClearsEverySpelling() {
        var settings = AppSettings.defaults
        settings.rhythmThresholdsByVideoType["Análisis"] = AppRhythmThresholds(longSentenceWordLimit: 10)

        RhythmReview.setVideoTypeThresholds(
            AppRhythmThresholds(longSentenceWordLimit: 20),
            for: "analysis",
            in: &settings
        )
        XCTAssertEqual(settings.rhythmThresholdsByVideoType.count, 1)
        XCTAssertEqual(settings.rhythmThresholdsByVideoType["Análisis"]?.longSentenceWordLimit, 20)

        settings.rhythmThresholdsByVideoType["analysis"] = AppRhythmThresholds(longSentenceWordLimit: 30)
        RhythmReview.removeVideoTypeThresholds(for: "Análisis", in: &settings)
        XCTAssertTrue(settings.rhythmThresholdsByVideoType.isEmpty)
    }

    func testThresholdRowsUseStableIDsWithLocalizedLabels() {
        var settings = AppSettings.defaults
        settings.rhythmThresholdsByVideoType["Crónica"] = AppRhythmThresholds(longSentenceWordLimit: 12)
        let ids = RhythmReview.videoTypeIDs(
            projectVideoType: "analysis",
            settings: settings,
            language: .spanish
        )
        XCTAssertEqual(Set(ids), Set(VideoTypeID.builtIn))
        XCTAssertTrue(ids.contains("chronicle"))
        XCTAssertEqual(VideoTypeID.displayName("chronicle", language: .spanish), "Crónica")
        XCTAssertEqual(VideoTypeID.displayName("update", language: .spanish), "Actualización")
        XCTAssertEqual(VideoTypeID.displayName("analysis", language: .russian), "Анализ")
        XCTAssertEqual(VideoTypeID.displayName("analysis", language: .english), "Analysis")
        XCTAssertEqual(VideoTypeID.displayName("Vlog de viajes", language: .spanish), "Vlog de viajes")
    }

    // MARK: - Items 3 and 5: copy

    func testDeleteProjectMessageIsHonestAboutUnsavedChanges() {
        XCTAssertEqual(
            L10n.tr("dialog.deleteProject.message", language: .english),
            "This closes the project and discards changes that have not been saved. The .fscr file stays on disk."
        )
        XCTAssertEqual(
            L10n.tr("dialog.deleteProject.message", language: .spanish),
            "Se cerrará el proyecto y se descartarán los cambios sin guardar. El archivo .fscr se conserva en el disco."
        )
        let russian = L10n.tr("dialog.deleteProject.message", language: .russian)
        XCTAssertTrue(russian.contains(".fscr"), russian)
        XCTAssertFalse(russian.contains("локальной библиотеки"), russian)
    }

    func testSpanishCopyEditsAreApplied() {
        XCTAssertEqual(L10n.tr("project.reveal", language: .spanish), "Mostrar en Finder")
        XCTAssertEqual(L10n.tr("settings.readingSpeed.reset", language: .spanish), "Restablecer")
        XCTAssertEqual(
            L10n.tr("settings.sidebarDefault", language: .spanish),
            "Mostrar el panel de contenido al iniciar"
        )
        XCTAssertEqual(
            L10n.tr("escaleta.import.metric.cues", language: .spanish),
            "Marcas"
        )
        XCTAssertEqual(
            L10n.tr("hooks.empty", language: .spanish),
            "No se ha recibido ningún gancho utilizable. Regenera o prueba otro proveedor."
        )
        XCTAssertEqual(
            L10n.tr("hooks.emptyRehooks", language: .spanish),
            "No se ha recibido ningún puente utilizable. Regenera o prueba otro proveedor."
        )
        XCTAssertEqual(
            L10n.tr("settings.ai.subscription.elapsed", language: .spanish),
            "Tiempo transcurrido: %@"
        )
    }

    func testSpanishAICopySaysComandoInsteadOfOrden() {
        let table = L10n.baseTable(for: .spanish)
            .merging(Self.spanishFeatureValues()) { existing, _ in existing }
        let offenders = table
            .filter { $0.key.hasPrefix("aiError.") || $0.key.hasPrefix("settings.ai.") }
            .filter { _, value in
                // Whole words only: «ordenador» or «ordenar» are not the
                // command-sense mistake this test is about.
                let words = value
                    .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "es_ES"))
                    .lowercased()
                    .split { !$0.isLetter }
                    .map(String.init)
                return words.contains("orden")
            }
        XCTAssertTrue(offenders.isEmpty, "command-sense copy still says orden: \(offenders.keys.sorted())")
        XCTAssertEqual(
            L10n.tr("aiError.emptyReply", language: .spanish),
            "El comando de IA devolvió una respuesta vacía."
        )
        XCTAssertEqual(
            L10n.tr("aiError.noProviderAvailable", language: .spanish),
            "No hay ningún comando de IA disponible. Instala t3, claude o codex, o indica sus rutas en Ajustes."
        )
    }

    /// Spain Spanish only: neutral, never Latin-American forms.
    func testSpanishTablesStaySpainSpanish() {
        var values = L10n.baseTable(for: .spanish)
        values.merge(Self.spanishFeatureValues()) { existing, _ in existing }
        // Stems that only appear in Latin-American Spanish.
        let forbiddenPrefixes = ["computadora", "celular", "ustedes", "agreg"]
        for (key, value) in values {
            let folded = value
                .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "es_ES"))
                .lowercased()
            let tokens = folded.split { !$0.isLetter }.map(String.init)
            for prefix in forbiddenPrefixes {
                XCTAssertFalse(
                    tokens.contains { $0.hasPrefix(prefix) },
                    "\(key) uses a Latin-American form: \(value)"
                )
            }
            // «acá» folds to «aca», which must not be confused with «acabar».
            XCTAssertFalse(
                tokens.contains("aca"),
                "\(key) uses a Latin-American form: \(value)"
            )
        }
        XCTAssertTrue(
            values.contains { $0.value.localizedCaseInsensitiveContains("vídeo") },
            "Spanish copy should keep using «vídeo»"
        )
    }

    // MARK: - Item 4: plurals and rhythm strings

    func testRhythmBadgeUsesPluralForms() {
        XCTAssertEqual(
            L10n.plural("rhythm.badgeAccessibility", count: 1, language: .spanish),
            "1 aviso de ritmo"
        )
        XCTAssertEqual(
            L10n.plural("rhythm.badgeAccessibility", count: 3, language: .spanish),
            "3 avisos de ritmo"
        )
        XCTAssertEqual(
            L10n.plural("rhythm.badgeAccessibility", count: 1, language: .english),
            "1 rhythm warning"
        )
        XCTAssertEqual(
            L10n.plural("rhythm.badgeAccessibility", count: 2, language: .english),
            "2 rhythm warnings"
        )
        XCTAssertEqual(
            L10n.plural("rhythm.badgeAccessibility", count: 1, language: .russian),
            "1 предупреждение ритма"
        )
        XCTAssertEqual(
            L10n.plural("rhythm.badgeAccessibility", count: 2, language: .russian),
            "2 предупреждения ритма"
        )
        XCTAssertEqual(
            L10n.plural("rhythm.badgeAccessibility", count: 5, language: .russian),
            "5 предупреждений ритма"
        )
        XCTAssertEqual(
            L10n.plural("rhythm.badgeAccessibility", count: 21, language: .russian),
            "21 предупреждение ритма"
        )
    }

    func testUnusedRhythmSceneCountKeyIsGone() {
        for language in [AppLanguage.english, .russian, .spanish] {
            XCTAssertEqual(
                L10n.tr("rhythm.sceneCount", language: language),
                "rhythm.sceneCount",
                "rhythm.sceneCount has no display site and must not linger in the tables"
            )
        }
    }

    func testReadingSpeedUnitUsesTheLocalizedKey() {
        XCTAssertEqual(L10n.tr("hooks.wpm", language: .spanish), "ppm")
        XCTAssertEqual(L10n.tr("hooks.wpm", language: .russian), "слов/мин")
        XCTAssertEqual(L10n.tr("hooks.wpm", language: .english), "wpm")
    }

    func testRhythmWarningFormatterUsesTheAppLanguageLocale() {
        XCTAssertEqual(
            String(format: "%.1f", locale: RhythmWarningFormatter.locale(for: .spanish), 0.5),
            "0,5"
        )
        XCTAssertEqual(
            String(format: "%.1f", locale: RhythmWarningFormatter.locale(for: .english), 0.5),
            "0.5"
        )
        XCTAssertEqual(
            String(format: "%.1f", locale: RhythmWarningFormatter.locale(for: .russian), 0.5),
            "0,5"
        )
    }

    // MARK: - Item 7: table hygiene

    func testNoFeatureTableShadowsABaseKey() {
        let base: [AppLanguage: Set<String>] = Dictionary(
            uniqueKeysWithValues: [AppLanguage.english, .russian, .spanish].map { language in
                (language, Set(L10n.baseTable(for: language).keys))
            }
        )
        var duplicates: [String] = []
        for (index, table) in L10n.featureTables.enumerated() {
            for (language, entries) in table {
                for key in entries.keys where base[language]?.contains(key) == true {
                    duplicates.append("table \(index) [\(language.rawValue)]: \(key)")
                }
            }
        }
        XCTAssertTrue(
            duplicates.isEmpty,
            "feature tables define keys the base table already owns (the base value wins silently): \(duplicates.sorted())"
        )
    }

    /// Two feature tables that define the same key silently drop one of them:
    /// `L10n.mergedStrings` keeps the first table that registered the key. The
    /// WP1 × WP5 `dialog.revertToSaved.*` collision was found by hand, so this
    /// checks every feature table against every other one.
    func testNoTwoFeatureTablesDefineTheSameKey() {
        var owners: [AppLanguage: [String: [Int]]] = [:]
        for (index, table) in L10n.featureTables.enumerated() {
            for (language, entries) in table {
                for key in entries.keys {
                    owners[language, default: [:]][key, default: []].append(index)
                }
            }
        }

        var duplicates: [String] = []
        for language in [AppLanguage.english, .russian, .spanish] {
            for (key, indices) in owners[language] ?? [:] {
                let tables = Set(indices)
                guard tables.count > 1 else { continue }
                duplicates.append(
                    "[\(language.rawValue)] \(key) is defined by feature tables \(tables.sorted())"
                )
            }
        }

        XCTAssertTrue(
            duplicates.isEmpty,
            "feature tables define the same key more than once (the first table wins silently): \(duplicates.sorted())"
        )
    }

    // MARK: - Item 8: Russian guidance disclosure

    func testRussianSimracingDescriptionsDiscloseEnglishGuidance() {
        let keys = [
            "template.Simracing Update Analysis.description",
            "template.Simracing Mod or Car Review.description",
            "template.Simracing Comparison.description",
            "template.Simracing News and Reaction.description",
            "template.Simracing Race Chronicle.description"
        ]
        for key in keys {
            let value = L10n.tr(key, language: .russian)
            XCTAssertTrue(value.contains("на английском"), "\(key) does not disclose English guidance: \(value)")
            XCTAssertFalse(
                L10n.tr(key, language: .english).contains("на английском"),
                "\(key) leaked the Russian note into English"
            )
        }
    }

    // MARK: - Item 9: demo anchor fallback

    func testMissingDemoAnchorFallsBackToTheWholeText() {
        let anchor = SampleData.anchor("frase que no existe", in: "Hola mundo")
        XCTAssertEqual(anchor.startUTF16, 0)
        XCTAssertEqual(anchor.lengthUTF16, ("Hola mundo" as NSString).length)
        XCTAssertEqual(anchor.selectedText, "Hola mundo")
        XCTAssertEqual(anchor.prefixContext, "")
        XCTAssertEqual(anchor.suffixContext, "")
    }

    func testExistingDemoAnchorStillPointsAtThePhrase() {
        let text = "Una introducción larga. La frase clave aparece aquí."
        let anchor = SampleData.anchor("La frase clave", in: text)
        XCTAssertEqual(anchor.selectedText, "La frase clave")
        XCTAssertEqual(anchor.startUTF16, (text as NSString).range(of: "La frase clave").location)
    }

    // MARK: - Item 6: Info.plist and regions

    func testBaseInfoPlistUsesEnglishPermissionText() throws {
        // `Bundle.object(forInfoDictionaryKey:)` already applies InfoPlist.strings,
        // so read the built base plist itself.
        let plistURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let microphone = try XCTUnwrap(plist["NSMicrophoneUsageDescription"] as? String)
        XCTAssertTrue(microphone.hasPrefix("FrameScript uses the microphone"), microphone)
        let speech = try XCTUnwrap(plist["NSSpeechRecognitionUsageDescription"] as? String)
        XCTAssertTrue(speech.hasPrefix("FrameScript uses on-device"), speech)
    }

    func testLocalizedInfoPlistNamesTheDocumentTypes() throws {
        for (language, expected) in [("es", "Proyecto de FrameScript"), ("ru", "Проект FrameScript")] {
            let path = try XCTUnwrap(
                Bundle.main.path(
                    forResource: "InfoPlist",
                    ofType: "strings",
                    inDirectory: nil,
                    forLocalization: language
                ),
                "missing \(language).lproj/InfoPlist.strings in the app bundle"
            )
            // Xcode compiles .strings as UTF-16, so decode it as a property list.
            let strings = try XCTUnwrap(
                NSDictionary(contentsOfFile: path) as? [String: String],
                "\(language).lproj/InfoPlist.strings is not a readable strings file"
            )
            XCTAssertEqual(strings["FrameScript Project"], expected)
            XCTAssertFalse(strings["Legacy FrameScript Project"]?.isEmpty ?? true)
        }
    }

    func testProjectRegionsIncludeSpanishAndRussian() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectFile = repositoryRoot.appendingPathComponent("FrameScript.xcodeproj/project.pbxproj")
        let contents = try String(contentsOf: projectFile, encoding: .utf8)
        let regionBlock = try XCTUnwrap(
            contents.range(of: "knownRegions = (").map { range in
                String(contents[range.lowerBound...].prefix(200))
            }
        )
        XCTAssertTrue(regionBlock.contains("es,"), regionBlock)
        XCTAssertTrue(regionBlock.contains("ru,"), regionBlock)
    }

    // MARK: - Helpers

    private static func spanishFeatureValues() -> [String: String] {
        var merged: [String: String] = [:]
        for table in L10n.featureTables {
            for (key, value) in table[.spanish] ?? [:] {
                merged[key] = value
            }
        }
        return merged
    }
}
