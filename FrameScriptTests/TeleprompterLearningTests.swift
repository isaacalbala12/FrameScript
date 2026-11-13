import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

@MainActor
final class TeleprompterLearningTests: XCTestCase {
    func testReadingSessionTeachesLearnedWPMAndRefreshesEstimates() throws {
        let text = Array(repeating: "palabra", count: 40).joined(separator: " ")
        let scene = Scene(order: 0, sectionType: .hook, title: "Hook", scriptText: text)
        let project = FrameProject(title: "Learning", scenes: [scene], primaryLanguage: "es")
        let appState = makeAppState(project: project)

        // 40 words in 20 s = 120 wpm.
        let recorded = appState.recordTeleprompterReadingSession(
            TeleprompterReadingSession(spokenWords: 40, duration: 20, language: .spanish)
        )

        XCTAssertTrue(recorded)
        XCTAssertEqual(try XCTUnwrap(project.learnedWordsPerMinuteByLanguage["es"]), 120, accuracy: 0.001)
        XCTAssertEqual(appState.effectiveWPM(language: "es"), 120, accuracy: 0.001)
        XCTAssertEqual(appState.currentDurationWordsPerMinute, 120)
        // The stored estimate now uses the new pace: 40 words at 120 wpm = 20 s.
        XCTAssertEqual(scene.estimatedDuration, 20, accuracy: 0.001)
    }

    func testDuplicateAndTooShortSessionsAreIgnored() {
        let scene = Scene(order: 0, sectionType: .hook, title: "Hook", scriptText: "uno dos tres")
        let project = FrameProject(title: "Learning", scenes: [scene], primaryLanguage: "es")
        let appState = makeAppState(project: project)

        let session = TeleprompterReadingSession(spokenWords: 40, duration: 20, language: .spanish)
        XCTAssertTrue(appState.recordTeleprompterReadingSession(session))
        XCTAssertFalse(appState.recordTeleprompterReadingSession(session))
        XCTAssertEqual(project.learnedWordsPerMinuteByLanguage["es"] ?? 0, 120, accuracy: 0.001)

        // Under the 20-word / 10-second minimum: no sample, no change.
        XCTAssertFalse(appState.recordTeleprompterReadingSession(
            TeleprompterReadingSession(spokenWords: 19, duration: 30, language: .spanish)
        ))
        XCTAssertFalse(appState.recordTeleprompterReadingSession(
            TeleprompterReadingSession(spokenWords: 60, duration: 9, language: .spanish)
        ))
        XCTAssertEqual(project.learnedWordsPerMinuteByLanguage["es"] ?? 0, 120, accuracy: 0.001)
    }

    func testResetCutoffStopsSessionsFromTeaching() {
        let scene = Scene(order: 0, sectionType: .hook, title: "Hook", scriptText: "uno dos tres")
        let project = FrameProject(title: "Learning", scenes: [scene], primaryLanguage: "es")
        project.learnedWordsPerMinuteByLanguage["es"] = 120
        let appState = makeAppState(project: project)
        let cutoff = Date().addingTimeInterval(60)
        project.learnedWordsPerMinuteResetAtByLanguage["es"] = cutoff

        XCTAssertFalse(appState.recordTeleprompterReadingSession(
            TeleprompterReadingSession(spokenWords: 60, duration: 20, language: .spanish),
            now: cutoff.addingTimeInterval(-1)
        ))
        XCTAssertEqual(project.learnedWordsPerMinuteByLanguage["es"] ?? 0, 120, accuracy: 0.001)

        // A session after the cutoff teaches again.
        XCTAssertTrue(appState.recordTeleprompterReadingSession(
            TeleprompterReadingSession(spokenWords: 60, duration: 20, language: .spanish),
            now: cutoff.addingTimeInterval(1)
        ))
        XCTAssertGreaterThan(project.learnedWordsPerMinuteByLanguage["es"] ?? 0, 120)
    }

    func testSessionTeachesTheLanguageItWasReadInNotTheProjectLanguage() {
        let scene = Scene(order: 0, sectionType: .hook, title: "Hook", scriptText: "один два три")
        let project = FrameProject(title: "Learning", scenes: [scene], primaryLanguage: "ru")
        let appState = makeAppState(project: project)

        // The report carries the recognition language. A reading in English
        // teaches English even in a Russian project; the unsupported Russian
        // bucket is never invented.
        XCTAssertTrue(appState.recordTeleprompterReadingSession(
            TeleprompterReadingSession(spokenWords: 40, duration: 20, language: .english)
        ))
        XCTAssertEqual(project.learnedWordsPerMinuteByLanguage["en"] ?? 0, 120, accuracy: 0.001)
        XCTAssertNil(project.learnedWordsPerMinuteByLanguage["ru"])
    }

    // MARK: - Helpers

    private func makeAppState(project: FrameProject) -> AppState {
        let suite = UserDefaults(suiteName: "TeleprompterLearningTests-\(UUID().uuidString)")!
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        return AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: .defaults, userDefaults: suite, key: "settings")
        )
    }
}
