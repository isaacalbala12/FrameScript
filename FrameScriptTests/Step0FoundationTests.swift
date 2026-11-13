import AppKit
import SwiftUI
import XCTest
@testable import FrameScript

final class Step0FoundationTests: XCTestCase {
    func testRussianPluralCategories() {
        let expected: [Int: L10n.PluralCategory] = [1: .one, 2: .few, 5: .many, 11: .many, 21: .one, 22: .few, 12: .many, 104: .few]
        for (count, category) in expected {
            XCTAssertEqual(L10n.pluralCategory(for: count, language: .russian), category, "count \(count)")
        }
    }

    func testSpanishAndEnglishPluralCategories() {
        for language in [AppLanguage.spanish, .english] {
            XCTAssertEqual(L10n.pluralCategory(for: 1, language: language), .one)
            for count in [0, 2, 5, 11, 21, 22] {
                XCTAssertEqual(L10n.pluralCategory(for: count, language: language), .other, "\(language) \(count)")
            }
        }
    }

    func testPluralFallsBackToBaseKeyWhenMissing() {
        XCTAssertEqual(L10n.plural("step0.missing.key", count: 3, language: .spanish), "step0.missing.key")
    }

    func testFixPackageTablesAreRegistered() {
        XCTAssertGreaterThanOrEqual(L10n.featureTables.count, 22)
    }

    func testAccentTokensMeetContrast() {
        for scheme in [ColorScheme.light, .dark] {
            for accent in AccentPalette.allCases {
                let theme = FrameTheme(colorScheme: scheme, accent: accent)
                let strong = NSColor(theme.accentStrong)
                let text = NSColor(theme.accentText)
                XCTAssertGreaterThanOrEqual(MarkupEditorPalette.contrastRatio(strong, .white), 4.5, "\(accent) strong \(scheme)")
                XCTAssertGreaterThanOrEqual(
                    MarkupEditorPalette.contrastRatio(text, NSColor(theme.appBackground)), 4.5,
                    "\(accent) text \(scheme)"
                )
            }
        }
    }
}
