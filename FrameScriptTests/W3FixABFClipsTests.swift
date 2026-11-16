import AppKit
import Foundation
import FrameScriptCore
import SwiftUI
import XCTest

@testable import FrameScript

/// F-1..F-7, N-1, N-3..N-6 and the clips visual fixes.
@MainActor
final class W3FixABFClipsTests: XCTestCase {
    private var isolatedDefaults: TestDefaults?
    private var appState: AppState?
    private var project: FrameProject?
    private var scene: FrameScript.Scene?

    override func setUp() async throws {
        try await super.setUp()
        TestBundleCleanup.register()
        isolatedDefaults = W3FixABFSupport.makeDefaults()
        project = W3FixABFSupport.makeProject(sceneText: "Hoy probamos el coche en mojado y el resultado sorprende.")
        scene = project?.scenes[0]
        appState = W3FixABFSupport.makeAppState(
            project: project!,
            defaults: isolatedDefaults!.defaults
        )
        appState?.editorState.selectedSceneID = scene?.id
    }

    override func tearDown() async throws {
        appState = nil
        project = nil
        scene = nil
        isolatedDefaults?.cleanup()
        isolatedDefaults = nil
        try await super.tearDown()
    }

    // MARK: - F-2

    func testW3FixABFClipMarkersUseTheSelectedFrameRate() throws {
        let applicationState = try XCTUnwrap(appState)
        let scene = try XCTUnwrap(scene)
        applicationState.project.learnedWordsPerMinuteByLanguage["es"] = 120
        var clip = try XCTUnwrap(applicationState.createClip(sceneIDs: [scene.id]))
        clip.hook = "one two three four five six"
        clip.adaptedText = ""
        clip.languageCode = "es"
        applicationState.updateClip(clip)

        let edl = try XCTUnwrap(
            applicationState.clipMarkerContent(id: clip.id, format: .edl, rate: .fps60)
        )
        XCTAssertTrue(edl.contains("|D:180"), "3 s at 60 fps must be 180 frames: \(edl)")

        let fcpxml = try XCTUnwrap(
            applicationState.clipMarkerContent(id: clip.id, format: .fcpxml, rate: .fps60)
        )
        XCTAssertTrue(fcpxml.contains("frameDuration=\"1/60s\""), fcpxml)
        XCTAssertTrue(fcpxml.contains("duration=\"3s\""), fcpxml)

        let edl25 = try XCTUnwrap(
            applicationState.clipMarkerContent(id: clip.id, format: .edl, rate: .fps25)
        )
        XCTAssertTrue(edl25.contains("|D:75"), edl25)
    }

    // MARK: - F-3

    func testW3FixABFClipsSummaryUsesEachClipLanguageRate() throws {
        let applicationState = try XCTUnwrap(appState)
        let scene = try XCTUnwrap(scene)
        applicationState.project.learnedWordsPerMinuteByLanguage["es"] = 120
        applicationState.project.learnedWordsPerMinuteByLanguage["en"] = 240
        var spanish = try XCTUnwrap(applicationState.createClip(sceneIDs: [scene.id]))
        spanish.hook = ""
        spanish.adaptedText = Array(repeating: "palabra", count: 40).joined(separator: " ")
        spanish.languageCode = "es"
        applicationState.updateClip(spanish)
        var english = try XCTUnwrap(applicationState.createClip(sceneIDs: [scene.id]))
        english.hook = ""
        english.adaptedText = Array(repeating: "word", count: 40).joined(separator: " ")
        english.languageCode = "en"
        applicationState.updateClip(english)

        let summary = applicationState.clipsSummary
        let expected = [spanish, english].reduce(0.0) { partial, clip in
            partial + applicationState.clipEstimate(for: applicationState.clip(id: clip.id)!).seconds
        }

        XCTAssertEqual(summary.estimatedTotalSeconds, expected, accuracy: 0.01)
        XCTAssertEqual(summary.estimatedTotalSeconds, 30, accuracy: 0.01)
    }

    // MARK: - F-1 / N-6

    func testW3FixABFStaleSurfacesAgreeAndAcceptPrecomputedScenes() throws {
        let applicationState = try XCTUnwrap(appState)
        let scene = try XCTUnwrap(scene)
        let clip = try XCTUnwrap(applicationState.createClip(sceneIDs: [scene.id]))

        let scenes = applicationState.clipSourceScenes
        XCTAssertEqual(
            applicationState.clipIsStale(clip, scenes: scenes),
            applicationState.clipIsStale(clip)
        )
        XCTAssertEqual(
            applicationState.clipsSummary(scenes: scenes),
            applicationState.clipsSummary
        )

        scene.scriptText = scene.scriptText + " Texto nuevo."
        let updatedScenes = applicationState.clipSourceScenes
        XCTAssertTrue(applicationState.clipIsStale(clip, scenes: updatedScenes))
        XCTAssertTrue(applicationState.clipStaleness(for: clip, scenes: updatedScenes).isStale)
    }

    // MARK: - F-4

    func testW3FixABFEmptyStateHasOneCreateAction() throws {
        let emptyProject = W3FixABFSupport.makeProject(sceneText: "Escena sin clips.")
        let emptyState = W3FixABFSupport.makeAppState(
            project: emptyProject,
            defaults: isolatedDefaults!.defaults
        )
        emptyState.editorState.selectedSceneID = emptyProject.scenes[0].id

        let result = SnapshotRenderer.render(
            ClipsPanel(),
            name: "clips-empty-state-980",
            suite: "w3-fix-abf",
            size: CGSize(width: 980, height: 712),
            appearance: .light,
            language: .spanish,
            appState: emptyState
        )

        XCTAssertTrue(
            result.textFragments.contains { $0.contains("Nuevo clip") },
            "the primary empty-state action must stay: \(result.textFragments)"
        )
        XCTAssertFalse(
            result.textFragments.contains {
                $0.contains(L10n.tr("clips.command.create", language: .spanish))
            },
            "the duplicate Create Clip button must be gone: \(result.textFragments)"
        )
    }

    // MARK: - F-5

    func testW3FixABFSelectionNeverShowsAFilteredOutClip() throws {
        let applicationState = try XCTUnwrap(appState)
        let scene = try XCTUnwrap(scene)
        var draft = try XCTUnwrap(applicationState.createClip(sceneIDs: [scene.id]))
        draft.status = .draft
        applicationState.updateClip(draft)
        var ready = try XCTUnwrap(applicationState.createClip(sceneIDs: [scene.id]))
        ready.status = .ready
        applicationState.updateClip(ready)

        let published = [applicationState.clip(id: ready.id)!]
        XCTAssertEqual(
            ClipListSelection.resolvedID(selectedID: draft.id, clips: published),
            ready.id
        )
        XCTAssertNil(ClipListSelection.resolvedID(selectedID: draft.id, clips: []))
        XCTAssertEqual(
            ClipListSelection.resolvedID(selectedID: ready.id, clips: published),
            ready.id
        )
    }

    // MARK: - F-6

    func testW3FixABFExportTextWritesTheMarkdownDocument() throws {
        let applicationState = try XCTUnwrap(appState)
        let scene = try XCTUnwrap(scene)
        var clip = try XCTUnwrap(applicationState.createClip(sceneIDs: [scene.id]))
        clip.title = "Clip con acentos"
        clip.hook = "Gancho"
        applicationState.updateClip(clip)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("w3fix-abf-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let written = try applicationState.writeClipText(id: clip.id, to: url)
        let expected = try XCTUnwrap(applicationState.clipTextExportContent(id: clip.id))

        XCTAssertEqual(written, expected)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), expected)
        XCTAssertTrue(written.hasPrefix("# Clip con acentos"))
    }

    // MARK: - F-7

    func testW3FixABFDeleteClipCanBeCancelledAndUndone() throws {
        var confirmations = 0
        let applicationState = W3FixABFSupport.makeAppState(
            project: try XCTUnwrap(project),
            defaults: isolatedDefaults!.defaults,
            confirmationHandler: { _, _ in
                confirmations += 1
                return true
            }
        )
        let scene = try XCTUnwrap(scene)
        let first = try XCTUnwrap(applicationState.createClip(sceneIDs: [scene.id]))
        let second = try XCTUnwrap(applicationState.createClip(sceneIDs: [scene.id]))
        let undoManager = UndoManager()

        XCTAssertTrue(applicationState.deleteClip(id: first.id, undoManager: undoManager))
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(applicationState.project.clips.map(\.id), [second.id])

        undoManager.undo()
        XCTAssertEqual(applicationState.project.clips.map(\.id), [first.id, second.id])
        XCTAssertEqual(applicationState.clip(id: first.id), first)
    }

    func testW3FixABFDeleteClipRespectsTheConfirmationPreference() throws {
        var confirmations = 0
        let applicationState = W3FixABFSupport.makeAppState(
            project: try XCTUnwrap(project),
            defaults: isolatedDefaults!.defaults,
            confirmationHandler: { _, _ in
                confirmations += 1
                return false
            }
        )
        let clip = try XCTUnwrap(applicationState.createClip(sceneIDs: [try XCTUnwrap(scene).id]))

        XCTAssertFalse(applicationState.deleteClip(id: clip.id))
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(applicationState.project.clips.map(\.id), [clip.id])
    }

    // MARK: - N-1

    func testW3FixABFGenerateKeepsEditsTypedWhileTheRequestRunsAndUndoRestores() async throws {
        let provider = W3FixABFGatedProvider(
            response: """
            {"hook":"Gancho generado","adaptedText":"Texto generado","onScreenText":"Texto en pantalla","description":"Descripción generada","hashtags":["simracing"]}
            """
        )
        var confirmations = 0
        let applicationState = W3FixABFSupport.makeAppState(
            project: try XCTUnwrap(project),
            defaults: isolatedDefaults!.defaults,
            provider: provider,
            confirmationHandler: { _, _ in
                confirmations += 1
                return true
            }
        )
        let scene = try XCTUnwrap(scene)
        var clip = try XCTUnwrap(applicationState.createClip(sceneIDs: [scene.id]))
        clip.hook = "Gancho escrito a mano"
        clip.adaptedText = "Texto escrito a mano"
        clip.onScreenText = ""
        clip.description = ""
        applicationState.updateClip(clip)

        let undoManager = UndoManager()
        let task = Task {
            await applicationState.generateClipAdaptation(
                id: clip.id,
                undoManager: undoManager
            )
        }
        await provider.waitUntilCalled()
        XCTAssertEqual(confirmations, 1)

        // The user keeps writing while the request is in flight.
        var typed = try XCTUnwrap(applicationState.clip(id: clip.id))
        typed.adaptedText = "Mi texto mientras genera"
        applicationState.updateClip(typed)

        provider.release()
        await task.value

        let result = try XCTUnwrap(applicationState.clip(id: clip.id))
        XCTAssertEqual(result.adaptedText, "Mi texto mientras genera")
        XCTAssertEqual(result.hook, "Gancho generado")
        XCTAssertEqual(result.onScreenText, "Texto en pantalla")
        XCTAssertEqual(result.description, "Descripción generada")
        XCTAssertEqual(result.hashtags, ["#simracing"])

        undoManager.undo()
        XCTAssertEqual(applicationState.clip(id: clip.id)?.hook, "Gancho escrito a mano")
        XCTAssertEqual(applicationState.clip(id: clip.id)?.adaptedText, "Mi texto mientras genera")
    }

    func testW3FixABFGenerateAsksBeforeReplacingWrittenFields() async throws {
        let provider = W3FixABFGatedProvider(
            response: #"{"hook":"Nuevo","adaptedText":"Nuevo","onScreenText":"","description":"","hashtags":[]}"#
        )
        let applicationState = W3FixABFSupport.makeAppState(
            project: try XCTUnwrap(project),
            defaults: isolatedDefaults!.defaults,
            provider: provider,
            confirmationHandler: { _, _ in false }
        )
        let scene = try XCTUnwrap(scene)
        var clip = try XCTUnwrap(applicationState.createClip(sceneIDs: [scene.id]))
        clip.hook = "Gancho escrito a mano"
        applicationState.updateClip(clip)

        await applicationState.generateClipAdaptation(id: clip.id)

        XCTAssertEqual(provider.calls, 0, "a declined confirmation must not call the provider")
        XCTAssertEqual(applicationState.clip(id: clip.id)?.hook, "Gancho escrito a mano")
    }

    func testW3FixABFGenerateUndoKeepsLaterManualEdits() async throws {
        let provider = W3FixABFGatedProvider(
            response: #"{"hook":"Gancho IA","adaptedText":"Texto IA","onScreenText":"","description":"","hashtags":[]}"#
        )
        let applicationState = W3FixABFSupport.makeAppState(
            project: try XCTUnwrap(project),
            defaults: isolatedDefaults!.defaults,
            provider: provider,
            confirmationHandler: { _, _ in true }
        )
        let scene = try XCTUnwrap(scene)
        var clip = try XCTUnwrap(applicationState.createClip(sceneIDs: [scene.id]))
        clip.hook = "Gancho escrito a mano"
        clip.adaptedText = "Texto escrito a mano"
        applicationState.updateClip(clip)
        let undoManager = UndoManager()

        let task = Task {
            await applicationState.generateClipAdaptation(id: clip.id, undoManager: undoManager)
        }
        await provider.waitUntilCalled()
        provider.release()
        await task.value

        var later = try XCTUnwrap(applicationState.clip(id: clip.id))
        later.hook = "Gancho posterior"
        later.title = "Título posterior"
        applicationState.updateClip(later)

        undoManager.undo()
        let afterUndo = try XCTUnwrap(applicationState.clip(id: clip.id))
        XCTAssertEqual(afterUndo.hook, "Gancho posterior")
        XCTAssertEqual(afterUndo.title, "Título posterior")
        XCTAssertEqual(afterUndo.adaptedText, "Texto escrito a mano")
    }

    func testW3FixABFUseSourceTextIsConfirmedAndUndoable() throws {
        var confirmations = 0
        let applicationState = W3FixABFSupport.makeAppState(
            project: try XCTUnwrap(project),
            defaults: isolatedDefaults!.defaults,
            confirmationHandler: { _, _ in
                confirmations += 1
                return true
            }
        )
        let scene = try XCTUnwrap(scene)
        var clip = try XCTUnwrap(applicationState.createClip(sceneIDs: [scene.id]))
        clip.adaptedText = "Texto escrito a mano"
        applicationState.updateClip(clip)
        let undoManager = UndoManager()

        XCTAssertTrue(applicationState.useSourceTextForClip(id: clip.id, undoManager: undoManager))
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(applicationState.clip(id: clip.id)?.adaptedText, scene.scriptText)

        undoManager.undo()
        XCTAssertEqual(applicationState.clip(id: clip.id)?.adaptedText, "Texto escrito a mano")
    }

    func testW3FixABFUndoOnlyRevertsTheFieldTheActionChanged() throws {
        let applicationState = W3FixABFSupport.makeAppState(
            project: try XCTUnwrap(project),
            defaults: isolatedDefaults!.defaults,
            confirmationHandler: { _, _ in true }
        )
        let scene = try XCTUnwrap(scene)
        var clip = try XCTUnwrap(applicationState.createClip(sceneIDs: [scene.id]))
        clip.adaptedText = "Texto escrito a mano"
        applicationState.updateClip(clip)

        let undoManager = UndoManager()
        XCTAssertTrue(applicationState.useSourceTextForClip(id: clip.id, undoManager: undoManager))

        var later = try XCTUnwrap(applicationState.clip(id: clip.id))
        later.hook = "Gancho escrito después"
        later.title = "Título nuevo"
        applicationState.updateClip(later)

        undoManager.undo()
        let afterUndo = try XCTUnwrap(applicationState.clip(id: clip.id))
        XCTAssertEqual(afterUndo.hook, "Gancho escrito después")
        XCTAssertEqual(afterUndo.title, "Título nuevo")
        XCTAssertEqual(afterUndo.adaptedText, "Texto escrito a mano")

        undoManager.redo()
        let afterRedo = try XCTUnwrap(applicationState.clip(id: clip.id))
        XCTAssertEqual(afterRedo.hook, "Gancho escrito después")
        XCTAssertEqual(afterRedo.title, "Título nuevo")
        XCTAssertEqual(afterRedo.adaptedText, scene.scriptText)
    }

    // MARK: - N-3

    func testW3FixABFSafeFileNameFallbacks() {
        XCTAssertEqual(SafeFileName.fileName("", fallback: "clip", extension: "edl"), "clip.edl")
        XCTAssertEqual(SafeFileName.fileName("a/b:c", fallback: "clip", extension: "edl"), "a-b-c.edl")
        XCTAssertEqual(SafeFileName.fileName("  ", fallback: "clip", extension: "md"), "clip.md")
        XCTAssertEqual(SafeFileName.fileName("Título", fallback: "clip", extension: "fcpxml"), "Título.fcpxml")
    }

    // MARK: - N-4

    func testW3FixABFRecheckingTheAnchorSceneRestoresTheFragment() {
        let sceneID = UUID()
        let anchor = TextAnchor(
            startUTF16: 4,
            lengthUTF16: 5,
            selectedText: "mojado",
            prefixContext: "en ",
            suffixContext: " y"
        )
        let dropped = ClipDroppedAnchor(sceneID: sceneID, anchor: anchor, anchorSceneID: sceneID)

        XCTAssertEqual(dropped.restoredAnchor(for: sceneID)?.anchor, anchor)
        XCTAssertEqual(dropped.restoredAnchor(for: sceneID)?.anchorSceneID, sceneID)
        XCTAssertNil(dropped.restoredAnchor(for: UUID()))
        XCTAssertNil(
            ClipDroppedAnchor(sceneID: sceneID, anchor: nil, anchorSceneID: nil)
                .restoredAnchor(for: sceneID)
        )
    }

    // MARK: - N-5 / N-6 / VW9

    func testW3FixABFExportSheetUsesCloseAndTextLabels() {
        XCTAssertEqual(L10n.tr("clips.export.close", language: .spanish), "Cerrar")
        XCTAssertEqual(L10n.tr("clips.export.saveText", language: .spanish), "Guardar texto…")
        XCTAssertEqual(L10n.tr("clips.export.frameRate", language: .spanish), "Velocidad de fotogramas")
        XCTAssertEqual(
            L10n.plural("clips.summary.count", count: 1, language: .spanish),
            "1 clip"
        )
    }

    func testW3FixABFExportSheetSnapshotHasButtonsAndFrameRate() throws {
        let applicationState = try XCTUnwrap(appState)
        let scene = try XCTUnwrap(scene)
        var clip = try XCTUnwrap(applicationState.createClip(sceneIDs: [scene.id]))
        clip.title = "Clip de prueba"
        clip.hook = "Gancho"
        applicationState.updateClip(clip)

        let result = SnapshotRenderer.render(
            ClipExportSheet(clip: clip),
            name: "clip-export-sheet-980",
            suite: "w3-fix-abf",
            size: CGSize(width: 620, height: 520),
            appearance: .light,
            language: .spanish,
            appState: applicationState
        )

        XCTAssertGreaterThan(result.pixelSize.width, 0)
        XCTAssertTrue(
            result.textFragments.contains { $0.contains("Cerrar") },
            "the dismiss button must say Cerrar: \(result.textFragments)"
        )
        XCTAssertTrue(
            result.textFragments.contains { $0.contains("Velocidad de fotogramas") },
            "the export sheet must offer the fps picker: \(result.textFragments)"
        )
        XCTAssertTrue(
            result.textFragments.contains { $0.contains("Guardar texto") },
            "the export sheet must offer the markdown save: \(result.textFragments)"
        )
    }
}

// MARK: - Gated provider

@MainActor
private final class W3FixABFGatedProvider: LLMProviderProtocol {
    private let response: String
    private(set) var calls = 0
    private var callContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(response: String) {
        self.response = response
    }

    func complete(request: LLMRequest, apiKey: String) async throws -> LLMResponse {
        calls += 1
        callContinuation?.resume()
        callContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return LLMResponse(text: response)
    }

    func waitUntilCalled() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { continuation in
            callContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
