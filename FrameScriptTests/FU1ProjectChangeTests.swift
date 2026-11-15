import AppKit
import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

/// FU1 fix-up regressions:
/// - a project open that fails must not announce `.frameScriptProjectWillChange`
///   (or drop the open project's AI/editor state) before the file was read;
/// - an unreadable project file must go through the external-change prompt
///   instead of the missing-file path;
/// - deleting a scene with no scene selected must not ask for confirmation;
/// - the marker column tooltip must actually reach AppKit;
/// - the default project/scene titles must follow the interface language.
@MainActor
final class FU1ProjectChangeTests: FrameScriptTestCase {
    private let externalChanges = FU1ExternalChangeRecorder()
    private let prompts = FU1PromptRecorder()

    // MARK: - Project change notification

    /// Fails before the fix: `prepareForProjectReplacement` posted the
    /// notification and reset the AI/editor state before the new file was read,
    /// so a corrupt file left the old project open with its teleprompter closed
    /// and its AI run cancelled.
    func testAFailedOpenLeavesTheOpenProjectAndItsRuntimeStateUntouched() throws {
        let openURL = try makeProjectFile(title: "Open project", text: "alpha target omega")
        let brokenURL = try makeBrokenProjectFile(named: "Broken open")
        let appState = makeAppState()
        appState.openProject(at: openURL)
        XCTAssertTrue(appState.hasOpenProject)
        let openTitle = appState.project.title
        let sceneID = try XCTUnwrap(appState.project.scenes.first?.id)
        let identity = UUID()
        let restoration = ScriptEditorRestorationState(
            selectedRange: NSRange(location: 3, length: 0),
            visibleOrigin: NSPoint(x: 0, y: 12)
        )
        appState.editorState.setScriptEditorState(restoration, sceneID: sceneID, editorIdentity: identity)
        appState.aiState.isAnalyzing = true

        let counter = FU1NotificationCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .frameScriptProjectWillChange,
            object: appState,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        appState.openProject(at: brokenURL)

        XCTAssertEqual(counter.count, 0, "A failed open must not announce a project change")
        XCTAssertEqual(appState.project.title, openTitle, "The old project must stay open")
        XCTAssertTrue(appState.hasOpenProject)
        XCTAssertEqual(
            appState.editorState.scriptEditorState(sceneID: sceneID, editorIdentity: identity),
            restoration,
            "A failed open must not drop the editor restoration state"
        )
        XCTAssertTrue(
            appState.aiState.isAnalyzing,
            "A failed open must not cancel the AI run of the project that stays open"
        )
        XCTAssertEqual(appState.failedOpenProjectFileURL, brokenURL)
        XCTAssertEqual(appState.errorCenter.presentedError?.kind, .corruptedProject)
    }

    /// Over-fix guard: a real replacement still announces exactly once, after
    /// the new document was read.
    func testASuccessfulOpenAnnouncesTheProjectChangeOnce() throws {
        let firstURL = try makeProjectFile(title: "First", text: "one")
        let secondURL = try makeProjectFile(title: "Second", text: "two")
        let appState = makeAppState()
        appState.openProject(at: firstURL)

        let counter = FU1NotificationCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .frameScriptProjectWillChange,
            object: appState,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        appState.openProject(at: secondURL)

        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(appState.project.title, "Second")
        XCTAssertNil(appState.failedOpenProjectFileURL)
    }

    // MARK: - Unreadable file

    /// Fails before the fix: every read error was treated as `.missing`, so an
    /// unreadable file produced a "file is missing" alert and the save went
    /// ahead with no conflict prompt.
    func testSavingAnUnreadableFileAsksInsteadOfReportingItMissing() throws {
        let url = try makeProjectFile(title: "Locked", text: "keep me")
        let appState = makeAppState()
        appState.openProject(at: url)
        let sceneID = try XCTUnwrap(appState.project.scenes.first?.id)
        appState.commitScriptTextChange(sceneID: sceneID, text: "local edit")
        try makeUnreadable(url)

        externalChanges.resolution = .cancel
        XCTAssertFalse(appState.saveProject())

        XCTAssertEqual(externalChanges.count, 1, "An unreadable file must go through the conflict prompt")
        XCTAssertNil(appState.errorCenter.presentedError, "It is not a missing file")
        XCTAssertTrue(appState.projectStore.hasUnsavedFileChanges, "The local edits must be kept")

        try makeReadable(url)
        XCTAssertEqual(
            try FrameScriptFileStore.read(from: url).scenes.first?.scriptText,
            "keep me",
            "Cancel must leave the file exactly as it was"
        )
    }

    /// Fails before the fix: the file monitor reported an unreadable file as
    /// missing, which marked the project dirty and never asked what to do.
    func testAnUnreadableFileDetectedExternallyAsksBeforeSaving() throws {
        let url = try makeProjectFile(title: "Locked externally", text: "keep me")
        let appState = makeAppState()
        appState.openProject(at: url)
        let sceneID = try XCTUnwrap(appState.project.scenes.first?.id)
        appState.commitScriptTextChange(sceneID: sceneID, text: "local edit")
        try makeUnreadable(url)

        appState.checkForExternalProjectChanges()

        XCTAssertEqual(externalChanges.count, 1, "An unreadable file is an external change, not a missing file")
        XCTAssertNil(appState.errorCenter.presentedError)
    }

    /// A cancelled unreadable prompt must not re-open on every autosave, but a
    /// manual Save must ask again.
    func testACancelledUnreadablePromptIsNotRepeatedByAutosave() throws {
        let url = try makeProjectFile(title: "Locked background", text: "keep me")
        let appState = makeAppState()
        appState.openProject(at: url)
        let sceneID = try XCTUnwrap(appState.project.scenes.first?.id)
        appState.commitScriptTextChange(sceneID: sceneID, text: "local edit")
        try makeUnreadable(url)

        externalChanges.resolution = .cancel
        XCTAssertFalse(appState.saveProject())
        XCTAssertEqual(externalChanges.count, 1)

        let backgroundAuthorization = appState.prepareProjectFileForWrite(honoringDeclinedConflict: true)
        guard case .declined = backgroundAuthorization else {
            XCTFail("Background autosave must honour the cancelled prompt, got \(backgroundAuthorization)")
            return
        }
        XCTAssertEqual(externalChanges.count, 1)

        XCTAssertFalse(appState.saveProject(), "A manual save asks again")
        XCTAssertEqual(externalChanges.count, 2)
    }

    // MARK: - Delete scene guard

    /// Fails before the fix: the `selectedSceneIndex` guard sat after the
    /// confirmation, so deleting in an empty project asked first.
    func testDeletingWithNoSceneSelectedDoesNotAskForConfirmation() throws {
        let emptyProject = FrameProject(title: "Empty", scenes: [])
        let appState = makeAppState(project: emptyProject)
        appState.projectStore.openProject(
            emptyProject,
            fileURL: nil,
            wordsPerMinute: 150,
            markUnsaved: true
        )
        XCTAssertNil(appState.selectedSceneIndex)

        appState.deleteSelectedScene()

        XCTAssertEqual(prompts.count, 0, "A no-op delete must not interrupt the user")
    }

    // MARK: - Marker tooltip

    /// Fails before the fix: `view(_:stringForToolTip:point:userData:)` was not
    /// part of `NSViewToolTipOwner` and not `@objc`, so AppKit never called it
    /// and did not even respond to the selector.
    func testTheMarkerTooltipReachesAppKitWithAnExistingMarkerLabel() throws {
        let text = "alpha target omega"
        let anchor = try XCTUnwrap(
            TextAnchorRepair.anchor(in: text, range: (text as NSString).range(of: "target"))
        )
        let container = MarkerTextContainerView()
        container.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        container.textView.string = text
        container.textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        container.addBRollLabel = "Add Visual for Selection"
        container.bRollMarkerLabel = "Visual linked to this text"
        container.editingMarkerLabel = "Editing note for this text"
        container.markers = [ProductionTextMarker(itemID: UUID(), mode: .bRoll, anchor: anchor)]
        container.layoutSubtreeIfNeeded()

        let strip = container.markerStripView
        XCTAssertTrue(
            strip.responds(to: NSSelectorFromString("view:stringForToolTip:point:userData:")),
            "AppKit only asks an NSViewToolTipOwner for the tooltip text"
        )

        let rect = try XCTUnwrap(container.markerRects().first?.rect)
        let midpoint = NSPoint(x: rect.midX, y: rect.midY)
        XCTAssertEqual(
            strip.view(strip, stringForToolTip: 0, point: midpoint, userData: nil),
            "Visual linked to this text",
            "An existing marker must describe itself, not offer to add a new one"
        )
        XCTAssertEqual(
            strip.view(strip, stringForToolTip: 0, point: NSPoint(x: -50, y: -50), userData: nil),
            "",
            "Empty space in the marker column has no tooltip"
        )
    }

    // MARK: - Default titles follow the language (V10)

    /// Fails before the fix: `SampleData` hard-coded "Untitled Script" and
    /// "New scene", so a Spanish interface showed English titles.
    func testDefaultProjectTitlesFollowTheLocalizedKeys() {
        let spanish = SampleData.defaultProject(language: .spanish)
        XCTAssertEqual(spanish.title, "Guion sin título")
        XCTAssertEqual(spanish.title, L10n.tr("project.untitled", language: .spanish))
        XCTAssertEqual(spanish.scenes.map(\.title), ["Escena nueva"])

        let russian = SampleData.defaultProject(language: .russian)
        XCTAssertEqual(russian.title, "Новый сценарий")
        XCTAssertEqual(russian.scenes.map(\.title), ["Новая сцена"])

        let english = SampleData.defaultProject(language: .english)
        XCTAssertEqual(english.title, "Untitled Script")
        XCTAssertEqual(english.scenes.map(\.title), ["New scene"])
    }

    func testAProjectBuiltWithoutExplicitNamesUsesTheLanguageDefaults() {
        let spanish = SampleData.project(
            named: L10n.tr("project.untitled", language: .spanish),
            template: SampleData.templates.first { $0.isBlank },
            language: .spanish
        )
        XCTAssertEqual(spanish.scenes.map(\.title), ["Escena nueva"])
        XCTAssertEqual(spanish.exportPresets.map(\.name), ["Entrega al editor"])
    }

    /// Over-fix guard: the New Project command already localized its titles; it
    /// must keep doing so now that `SampleData` has language-defaulted names.
    func testANewProjectUsesTheCurrentLanguageTitles() {
        let appState = makeAppState(language: .spanish)

        appState.newProject()

        XCTAssertEqual(appState.project.title, "Guion sin título")
        XCTAssertEqual(appState.project.scenes.map(\.title), ["Escena nueva"])
    }

    // MARK: - Helpers

    private func makeAppState(
        project: FrameProject = SampleData.defaultProject,
        language: AppLanguage = .english
    ) -> AppState {
        let suite = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.language = language
        settings.generalPreferences.autosaveEnabled = false
        settings.generalPreferences.confirmBeforeDeleting = true
        settings.generalPreferences.defaultNewProjectTemplate = "Blank"
        settings.generalPreferences.blankProjectStart = .oneEmptyScene
        let recorder = externalChanges
        let prompts = prompts
        return AppState(
            projectStore: ProjectStore(project: project),
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: settings, userDefaults: suite, key: "settings"),
            externalChangeConfirmation: {
                recorder.count += 1
                return recorder.resolution
            },
            confirmationHandler: { _, _ in
                prompts.count += 1
                return prompts.answer
            }
        )
    }

    private func makeProject(title: String, text: String) -> FrameProject {
        FrameProject(
            title: title,
            scenes: [Scene(id: UUID(), order: 0, sectionType: .custom, title: "Scene", scriptText: text)]
        )
    }

    private func makeProjectFile(title: String, text: String) throws -> URL {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("\(title.replacingOccurrences(of: " ", with: "-")).fscr")
        try FrameScriptFileStore.write(project: makeProject(title: title, text: text), to: url)
        return url
    }

    private func makeBrokenProjectFile(named name: String) throws -> URL {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("\(name.replacingOccurrences(of: " ", with: "-")).fscr")
        try Data("{ not a project".utf8).write(to: url)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameScriptFU1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    /// Simulates a file the app exists but cannot read (permission denied, an
    /// undownloaded iCloud placeholder, a locked volume). Skips when the test
    /// user ignores file permissions, because then nothing is unreadable.
    private func makeUnreadable(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        guard (try? Data(contentsOf: url)) == nil else {
            try makeReadable(url)
            throw XCTSkip("File permissions are not enforced for this user")
        }
    }

    private func makeReadable(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }
}

private final class FU1ExternalChangeRecorder {
    var count = 0
    var resolution: ExternalProjectChangeResolution = .cancel
}

private final class FU1PromptRecorder {
    var count = 0
    var answer = false
}

private final class FU1NotificationCounter: @unchecked Sendable {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
