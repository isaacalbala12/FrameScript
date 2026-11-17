import AppKit
import Darwin
import Foundation
import FrameScriptCore
import SwiftUI
import XCTest
@testable import FrameScript

/// Synthetic project sizes used by the wave-3 performance review. The text is
/// generated from a fixed Spanish word list, so it never contains real scripts.
enum PerfFixtureSize: String, CaseIterable {
    /// A typical imported escaleta: 9 scenes, ~4,500 words.
    case typical
    /// A long project: 30 scenes, ~21,000 words.
    case large

    var sceneCount: Int {
        switch self {
        case .typical: 9
        case .large: 30
        }
    }

    var wordsPerScene: Int {
        switch self {
        case .typical: 500
        case .large: 700
        }
    }

    var label: String { "\(sceneCount)×\(wordsPerScene)" }
}

/// Builds a realistic project: scene text with markup (pauses, B-roll and
/// image cues), anchored B-roll and editing items, claims, checklist tasks,
/// takes, clips, sources, assets and a publishing pack.
@MainActor
enum PerfFixture {
    private static let words = [
        "cuando", "la", "curva", "llega", "el", "piloto", "frena", "tarde", "y",
        "el", "coche", "gira", "sobre", "el", "piano", "mientras", "la", "pista",
        "se", "enfría", "con", "cada", "vuelta", "que", "damos", "en", "el",
        "simulador", "volante", "pedal", "neumático", "trazada", "ritmo", "sector"
    ]

    static func sceneText(sceneIndex: Int, words count: Int) -> String {
        var parts: [String] = []
        parts.reserveCapacity(count + count / 10)
        var sentenceLength = 0
        for index in 0..<count {
            var word = words[(sceneIndex * 7 + index * 5 + index / 11) % words.count]
            if sentenceLength == 0 {
                word = word.prefix(1).uppercased() + word.dropFirst()
            }
            sentenceLength += 1
            if sentenceLength >= 14 {
                word += "."
                sentenceLength = 0
                if index % 5 == 0 { word += " [pausa]" }
                if index % 9 == 0 { word += " / *énfasis* sigue" }
                if index % 13 == 0 { word += "\n\n[B-ROLL: vuelta de clasificación]" }
                if index % 17 == 0 { word += " [IMAGEN: telemetría]" }
            }
            parts.append(word)
        }
        return parts.joined(separator: " ") + "."
    }

    static func makeProject(_ size: PerfFixtureSize) -> FrameProject {
        let scenes: [FrameScript.Scene] = (0..<size.sceneCount).map { index in
            let text = sceneText(sceneIndex: index, words: size.wordsPerScene)
            let scene = Scene(
                order: index,
                sectionType: index == 0 ? .hook : .custom,
                title: "Escena \(index + 1)",
                scriptText: text,
                notes: "Notas de la escena \(index + 1)",
                targetDuration: index % 3 == 0 ? 120 : nil
            )
            let nsText = text as NSString
            scene.bRollItems = (0..<4).map { item in
                let start = min(nsText.length - 10, 40 + item * 300)
                return BRollItem(
                    textAnchor: TextAnchorRepair.anchor(in: text, range: NSRange(location: start, length: 8)),
                    templateType: "",
                    sourceType: .screenRecording,
                    descriptionText: "Plano \(item) de la escena \(index + 1)"
                )
            }
            scene.editingItems = (0..<3).map { item in
                let start = min(nsText.length - 10, 120 + item * 350)
                return EditingItem(
                    textAnchor: TextAnchorRepair.anchor(in: text, range: NSRange(location: start, length: 6)),
                    templateType: "",
                    cutStyle: "Corte \(item)",
                    transition: "",
                    subtitleStyle: ""
                )
            }
            scene.takes = (0..<2).map { take in
                Take(
                    number: take + 1,
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 100 + take)),
                    duration: 95 + Double(take * 4),
                    rating: take == 0 ? .good : .unrated,
                    readText: text,
                    sceneTextHash: FrameScriptDocument.TextHash.hash(text)
                )
            }
            return scene
        }
        let sources = (0..<12).map { index in
            ProjectSource(title: "Fuente \(index)", url: "https://example.com/\(index)")
        }
        var claims: [ProjectClaim] = []
        for index in 0..<(size.sceneCount * 3) {
            let scene = scenes[index % scenes.count]
            let sourceIDs: [UUID] = index % 2 == 0 ? [sources[index % sources.count].id] : []
            let range = NSRange(location: 10 + index, length: 5)
            let anchor = TextAnchorRepair.anchor(in: scene.scriptText, range: range)
            let status: ClaimStatus = index % 4 == 0 ? .confirmed : .probable
            claims.append(ProjectClaim(
                text: "Afirmación \(index)",
                status: status,
                sourceIDs: sourceIDs,
                sceneIDs: [scene.id],
                anchorSceneID: scene.id,
                anchor: anchor,
                needsVerification: index % 3 != 0
            ))
        }
        let tasks: [ChecklistTask] = (0..<(size.sceneCount * 2)).map { index in
            ChecklistTask(
                text: "Tarea \(index)",
                kind: ChecklistTaskKind.allCases[index % ChecklistTaskKind.allCases.count],
                isDone: index % 3 == 0,
                sceneID: scenes[index % scenes.count].id
            )
        }
        let clips: [ShortClip] = (0..<6).map { index in
            let scene = scenes[index % scenes.count]
            return ShortClip(
                title: "Clip \(index)",
                sourceSceneIDs: [scene.id],
                anchorSceneID: scene.id,
                anchor: TextAnchorRepair.anchor(in: scene.scriptText, range: NSRange(location: 200, length: 40)),
                hook: "Gancho del clip \(index)",
                adaptedText: String(scene.scriptText.prefix(300))
            )
        }
        let assets: [ProjectAsset] = (0..<8).map { index in
            ProjectAsset(
                path: "/nonexistent/perf-fixture/asset-\(index).mov",
                kind: .web,
                linkedSceneIDs: [scenes[index % scenes.count].id]
            )
        }
        let pack = PublishingPack(
            titleCandidates: ["Título A", "Título B", "Título C"],
            chosenTitle: "Título A",
            description: "Descripción sintética del vídeo.",
            tags: ["simracing", "telemetría"],
            hashtags: ["#simracing"],
            chapterOverrides: scenes.prefix(4).map { ChapterOverride(sceneID: $0.id, title: $0.title) }
        )
        return FrameProject(
            title: "Proyecto de rendimiento \(size.label)",
            scenes: scenes,
            primaryLanguage: "es",
            topic: "Simracing",
            videoType: "Tutorial",
            targetDuration: Double(size.sceneCount) * 150,
            assets: assets,
            publishingPacks: ["es": pack],
            checklistTasks: tasks,
            sources: sources,
            claims: claims,
            clips: clips
        )
    }
}

/// Thread CPU time of the calling thread. Unlike wall time it ignores the idle
/// waits of a run-loop pump, so it measures the work the main thread did.
enum PerfClock {
    static func threadCPUNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }

    static func wallNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }
}

struct PerfSample {
    var wallMilliseconds: Double
    var cpuMilliseconds: Double
}

extension Array where Element == PerfSample {
    func median(_ keyPath: KeyPath<PerfSample, Double>) -> Double {
        let values = map { $0[keyPath: keyPath] }.sorted()
        guard !values.isEmpty else { return 0 }
        return values[values.count / 2]
    }

    func percentile(_ p: Double, _ keyPath: KeyPath<PerfSample, Double>) -> Double {
        let values = map { $0[keyPath: keyPath] }.sorted()
        guard !values.isEmpty else { return 0 }
        let index = Swift.min(values.count - 1, Int((Double(values.count - 1) * p).rounded()))
        return values[index]
    }
}

/// Hosts the real `AppShellView` in an offscreen borderless window. The
/// window is never ordered front, so the user's focus is untouched.
@MainActor
final class PerfMainWindowHost {
    let appState: AppState
    let inspectorState: UXInspectorState
    let window: NSWindow
    let hosting: NSView

    init(appState: AppState, inspectorState: UXInspectorState, size: CGSize = CGSize(width: 1320, height: 860)) {
        self.appState = appState
        self.inspectorState = inspectorState
        let theme = FrameTheme(colorScheme: .light, accent: appState.settings.accentColor)
        let root = AppShellView(inspectorState: inspectorState)
            .environment(appState)
            .environment(EscaletaImportCoordinator())
            .environment(\.frameTheme, theme)
            .preferredColorScheme(.light)
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        self.hosting = hosting
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
    }

    /// One update pass: SwiftUI observation flush, layout and display.
    func flush() {
        RunLoop.current.run(until: Date())
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        RunLoop.current.run(until: Date())
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    /// Lets debounced work (metrics, rhythm, checklist, segment rebuild) run.
    func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
        }
    }

    /// Measures `work` plus the update pass it triggers.
    func measure(_ work: () -> Void) -> PerfSample {
        let wall0 = PerfClock.wallNanoseconds()
        let cpu0 = PerfClock.threadCPUNanoseconds()
        work()
        flush()
        let cpu1 = PerfClock.threadCPUNanoseconds()
        let wall1 = PerfClock.wallNanoseconds()
        return PerfSample(
            wallMilliseconds: Double(wall1 - wall0) / 1_000_000,
            cpuMilliseconds: Double(cpu1 - cpu0) / 1_000_000
        )
    }

    /// Main-thread CPU spent while the run loop idles for `seconds`.
    func measureSettle(_ seconds: TimeInterval) -> Double {
        let cpu0 = PerfClock.threadCPUNanoseconds()
        pump(seconds)
        return Double(PerfClock.threadCPUNanoseconds() - cpu0) / 1_000_000
    }

    func allSubviews() -> [NSView] {
        func collect(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(collect) }
        return collect(hosting)
    }

    var singleSceneTextView: PlaceholderTextView? {
        allSubviews().compactMap { $0 as? PlaceholderTextView }
            .first { !($0 is FullScriptEditableTextView) && $0.isEditable }
    }

    var fullScriptTextView: FullScriptEditableTextView? {
        allSubviews().compactMap { $0 as? FullScriptEditableTextView }.first
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}

/// In-memory OBS credentials: never touches the Keychain.
struct PerfSecretStore: OBSSecretStoring {
    func readPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
}

@MainActor
enum PerfAppStateFactory {
    static func make(
        project: FrameProject,
        defaults: UserDefaults,
        fileURL: URL? = nil,
        autosaveEnabled: Bool = false
    ) -> AppState {
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        settings.generalPreferences.autosaveEnabled = autosaveEnabled
        settings.generalPreferences.autosaveIntervalSeconds = 3_600
        settings.editorPreferences.showAIReviewPanel = true
        settings.aiPreferences.provider = .disabled
        let store = ProjectStore(project: SampleData.defaultProject)
        let appState = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            recording: RecordingController(
                preferences: OBSPreferencesStore(defaults: defaults, secretStore: PerfSecretStore()),
                defaults: defaults
            ),
            subscriptionRuntime: SubscriptionAIRuntime(
                store: SubscriptionAISettingsStore(userDefaults: defaults)
            ),
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults),
            closeConfirmation: { .discard },
            externalChangeConfirmation: { .keepMine },
            templates: SampleData.templates,
            customTemplates: []
        )
        if let fileURL {
            _ = appState.openProject(at: fileURL)
        } else {
            store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
            appState.editorState.selectedSceneID = project.scenes.sortedByOrder.first?.id
        }
        return appState
    }
}
