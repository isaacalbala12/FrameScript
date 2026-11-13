import AppKit
import Foundation
import FrameScriptCore
@testable import FrameScript
import SwiftUI
import Vision

/// One isolated environment for every board test: its own UserDefaults suite,
/// temporary library, fake Keychain and an AppState that never touches the
/// real app preferences.
@MainActor
final class BoardTestHarness {
    let suiteName: String
    let defaults: UserDefaults
    let tempRoot: URL
    let libraryRoot: URL
    let settingsStore: SettingsStore
    let appState: AppState
    let board: BoardStore
    let catalog: BoardCatalogStore
    let plane: PlaneSettingsStore
    let ledger: BoardPlaneLedgerStore
    let keychain: BoardFakeKeychain
    let externalChange: BoardExternalChangeBox

    init() throws {
        suiteName = "FrameScript.BoardTests.\(UUID().uuidString)"
        defaults = BoardMemoryDefaults()

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameScriptBoardTests-\(UUID().uuidString)", isDirectory: true)
        libraryRoot = tempRoot.appendingPathComponent("Biblioteca", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)

        let fakeKeychain = BoardFakeKeychain()
        keychain = fakeKeychain
        let externalChange = BoardExternalChangeBox()
        self.externalChange = externalChange

        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        settings.theme = .light
        settings.generalPreferences.autosaveEnabled = false
        settingsStore = SettingsStore(
            settings: settings,
            userDefaults: defaults,
            key: "test.settings"
        )

        let recent = RecentProjectStore(
            userDefaults: defaults,
            storageKey: "test.recents",
            legacyPathsKey: "test.legacyPaths",
            bookmarkCreator: { url in Data(url.path.utf8) },
            bookmarkResolver: { data, _ in URL(fileURLWithPath: String(decoding: data, as: UTF8.self)) },
            securityScope: BoardTestHarness.noSecurityScope
        )

        let recording = RecordingController(
            preferences: OBSPreferencesStore(
                defaults: defaults,
                secretStore: BoardFakeOBSSecretStore()
            ),
            defaults: defaults
        )

        appState = AppState(
            projectStore: ProjectStore(project: BoardTestHarness.makeProject(named: "Proyecto abierto")),
            recentProjectStore: recent,
            settingsStore: settingsStore,
            recording: recording,
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults),
            securityScope: BoardTestHarness.noSecurityScope,
            externalChangeConfirmation: { externalChange.resolution },
            customTemplates: []
        )

        board = BoardStore(
            userDefaults: defaults,
            foldersStorageKey: "test.board.folders",
            bookmarkCreator: { url in Data(url.path.utf8) },
            bookmarkResolver: { data, _ in URL(fileURLWithPath: String(decoding: data, as: UTF8.self)) },
            securityScope: BoardTestHarness.noSecurityScope
        )
        board.loadFolders()

        catalog = BoardCatalogStore(userDefaults: defaults, storageKey: "test.board.catalog")
        plane = PlaneSettingsStore(
            userDefaults: defaults,
            storageKey: "test.plane.settings",
            readToken: { fakeKeychain.token },
            writeToken: { fakeKeychain.token = $0 },
            deleteToken: { fakeKeychain.token = nil }
        )
        ledger = BoardPlaneLedgerStore(userDefaults: defaults, storageKey: "test.plane.ledger")
    }

    func tearDown() {
        appState.resetProjectFileTracking()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    static let noSecurityScope = SecurityScopedResourceAccess(
        start: { _ in false },
        stop: { _ in }
    )

    // MARK: Files

    @discardableResult
    func writeProject(_ document: FrameScriptDocument, fileName: String) throws -> URL {
        let url = libraryRoot.appendingPathComponent(fileName)
        try FrameScriptDocumentCodec.write(document, to: url)
        return url
    }

    func refresh() async {
        await board.refresh(
            folderURLs: [libraryRoot],
            extraFileURLs: [],
            securityScope: BoardTestHarness.noSecurityScope
        )
    }

    /// Adds the temporary library as a real board folder and scans it through
    /// the app state, exactly like opening the board window.
    func prepareSampleBoard() async throws {
        try board.addFolder(at: libraryRoot)
        try writeSampleLibrary()
        await board.refresh(appState: appState)
    }

    // MARK: Synthetic projects

    static func makeProject(named title: String) -> FrameProject {
        FrameProject(
            title: title,
            scenes: [
                Scene(
                    id: UUID(),
                    order: 0,
                    sectionType: .hook,
                    title: "Entrada",
                    scriptText: "Una frase sintética para la prueba.",
                    textSegments: []
                )
            ]
        )
    }

    /// Six synthetic Spanish projects that exercise every column, both real and
    /// estimated durations, dates, pending kinds and the unclassified state.
    @discardableResult
    func writeSampleLibrary() throws -> [URL] {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = now.addingTimeInterval(5 * 86_400)
        let past = now.addingTimeInterval(-2 * 86_400)

        let accentScene = FrameScriptDocument.Scene(
            order: 0,
            sectionType: .hook,
            title: "Presentación",
            scriptText: "Hoy analizamos la actualización con datos de prueba.",
            estimatedDuration: 42,
            bRollItems: [
                FrameScriptDocument.BRollItem(descriptionText: "Plano del coche en boxes", status: .idea),
                FrameScriptDocument.BRollItem(descriptionText: "Captura del menú", status: .planned)
            ],
            editingItems: [
                FrameScriptDocument.EditingItem(cutStyle: "Corte seco", status: .pending)
            ]
        )
        let recordedScene = FrameScriptDocument.Scene(
            order: 1,
            sectionType: .example,
            title: "Vuelta rápida",
            scriptText: "Una vuelta de prueba en el circuito sintético.",
            estimatedDuration: 31,
            takes: [
                FrameScriptDocument.Take(
                    number: 1,
                    startedAt: now,
                    duration: 28,
                    rating: .good,
                    sceneTextHash: FrameScriptDocument.TextHash.hash("Una vuelta de prueba en el circuito sintético.")
                )
            ]
        )

        let documents: [(String, FrameScriptDocument)] = [
            (
                "analisis-actualizacion.fscr",
                BoardTestHarness.makeDocument(
                    title: "Análisis de la actualización 1.9 de Assetto Corsa Competizione",
                    topic: "Assetto Corsa Competizione",
                    videoType: "análisis",
                    status: .script,
                    targetDate: future,
                    scenes: [accentScene, recordedScene],
                    checklist: [
                        FrameScriptDocument.ChecklistTask(text: "Verificar los datos de la actualización", kind: .research)
                    ],
                    updatedAt: now
                )
            ),
            (
                "review-porsche-spa.fscr",
                BoardTestHarness.makeDocument(
                    title: "Review del Porsche 911 GT3 R en Spa",
                    topic: "iRacing",
                    videoType: "review de mod/coche",
                    status: .edited,
                    targetDate: now.addingTimeInterval(2 * 86_400),
                    scenes: [accentScene],
                    updatedAt: now.addingTimeInterval(-3_600)
                )
            ),
            (
                "comparativa-frenos.fscr",
                BoardTestHarness.makeDocument(
                    title: "Comparativa de frenos: GT3 contra GT4",
                    topic: "Assetto Corsa Competizione",
                    videoType: "comparativa",
                    status: .recorded,
                    scenes: [recordedScene],
                    updatedAt: now.addingTimeInterval(-7_200)
                )
            ),
            (
                "cronica-watkins-glen.fscr",
                BoardTestHarness.makeDocument(
                    title: "Crónica de las 6 Horas de Watkins Glen",
                    topic: "iRacing",
                    videoType: "crónica",
                    status: .published,
                    targetDate: past,
                    publishDate: past,
                    scenes: [recordedScene],
                    updatedAt: now.addingTimeInterval(-10_800)
                )
            ),
            (
                "primeras-impresiones-lmu.fscr",
                BoardTestHarness.makeDocument(
                    title: "Primeras impresiones de Le Mans Ultimate",
                    topic: "Le Mans Ultimate",
                    videoType: "gameplay",
                    status: .idea,
                    scenes: [],
                    updatedAt: now.addingTimeInterval(-14_400)
                )
            ),
            (
                "vantare-stint.fscr",
                BoardTestHarness.makeDocument(
                    title: "Vantare: cómo preparamos un stint de 45 minutos",
                    topic: "Vantare",
                    videoType: "Vantare",
                    status: .outline,
                    scenes: [],
                    updatedAt: now.addingTimeInterval(-18_000)
                )
            ),
            (
                "sin-clasificar.fscr",
                BoardTestHarness.makeDocument(
                    title: "Proyecto sin clasificar",
                    topic: "",
                    videoType: "",
                    status: .idea,
                    scenes: [],
                    updatedAt: now.addingTimeInterval(-25_200)
                )
            )
        ]

        return try documents.map { fileName, document in
            try writeProject(document, fileName: fileName)
        }
    }

    static func makeDocument(
        title: String,
        topic: String,
        videoType: String,
        status: FrameScriptDocument.ProductionStatus,
        targetDate: Date? = nil,
        publishDate: Date? = nil,
        scenes: [FrameScriptDocument.Scene],
        checklist: [FrameScriptDocument.ChecklistTask] = [],
        updatedAt: Date
    ) -> FrameScriptDocument {
        FrameScriptDocument(
            project: FrameScriptDocument.Project(
                title: title,
                updatedAt: updatedAt,
                scenes: scenes,
                primaryLanguage: "es",
                topic: topic,
                videoType: videoType,
                productionStatus: status,
                targetDate: targetDate,
                publishDate: publishDate,
                checklistTasks: checklist
            )
        )
    }
}

/// In-memory `UserDefaults` used by the board tests. It never touches the real
/// preference domain and cannot leave a suite plist behind.
final class BoardMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? {
        locked { storage[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        locked {
            if let value {
                storage[defaultName] = value
            } else {
                storage.removeValue(forKey: defaultName)
            }
        }
    }

    override func removeObject(forKey defaultName: String) {
        locked { storage.removeValue(forKey: defaultName) }
    }

    override func data(forKey defaultName: String) -> Data? {
        object(forKey: defaultName) as? Data
    }

    override func string(forKey defaultName: String) -> String? {
        object(forKey: defaultName) as? String
    }

    override func bool(forKey defaultName: String) -> Bool {
        if let value = object(forKey: defaultName) as? Bool { return value }
        if let value = object(forKey: defaultName) as? NSNumber { return value.boolValue }
        return false
    }

    override func integer(forKey defaultName: String) -> Int {
        if let value = object(forKey: defaultName) as? Int { return value }
        if let value = object(forKey: defaultName) as? NSNumber { return value.intValue }
        return 0
    }

    override func dictionary(forKey defaultName: String) -> [String: Any]? {
        object(forKey: defaultName) as? [String: Any]
    }

    override func dictionaryRepresentation() -> [String: Any] {
        locked { storage }
    }

    override func synchronize() -> Bool { true }

    override func removePersistentDomain(forName domainName: String) {
        locked { storage.removeAll() }
    }

    override func removeSuite(named suiteName: String) {
        locked { storage.removeAll() }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class BoardFakeKeychain: @unchecked Sendable {
    var token: String?
}

@MainActor
final class BoardExternalChangeBox {
    var resolution: ExternalProjectChangeResolution = .cancel
}

struct BoardFakeOBSSecretStore: OBSSecretStoring {
    func readPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
}

// MARK: - Snapshot rendering

struct BoardSnapshotRenderer {
    enum Appearance: String {
        case light
        case dark

        var colorScheme: ColorScheme {
            self == .dark ? .dark : .light
        }

        var nsAppearance: NSAppearance.Name {
            self == .dark ? .darkAqua : .aqua
        }
    }

    struct Result {
        let pngData: Data?
        let pixelWidth: Int
        let pixelHeight: Int
        let labels: [String]
        let controlFrames: [CGRect]
        let containerSize: CGSize
    }

    static let outputRoot = URL(fileURLWithPath: "/tmp/fs-snapshots/w3-g-board", isDirectory: true)

    /// Renders `view` in an offscreen window that is never ordered front. With
    /// `FS_SNAPSHOTS=1` the PNG is written under `/tmp/fs-snapshots/w3-g-board`;
    /// otherwise the caller asserts layout invariants on the returned data.
    @MainActor
    static func render<V: View>(
        _ view: V,
        size: CGSize,
        appearance: Appearance,
        name: String,
        theme: FrameTheme,
        inspectText: Bool = true
    ) throws -> Result {
        let hosting = NSHostingView(
            rootView: view
                .frame(width: size.width, height: size.height)
                .environment(\.frameTheme, theme)
                .preferredColorScheme(appearance.colorScheme)
        )
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance.nsAppearance)
        window.contentView = hosting
        window.setContentSize(size)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        hosting.display()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw BoardSnapshotError.cannotCreateBitmap
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let data = rep.representation(using: .png, properties: [:])

        // The offscreen accessibility tree is empty because no window is
        // ordered front. Vision OCR verifies the text that is actually
        // rendered, in Spanish, and provides line frames for the layout checks.
        let observations = inspectText ? (data.flatMap { BoardSnapshotOCR.observe($0) } ?? []) : []
        let labels = observations.map(\.text)
        let frames = observations.map { $0.frame(for: size) }

        if ProcessInfo.processInfo.environment["FS_SNAPSHOTS"] == "1", let data {
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
            let file = outputRoot.appendingPathComponent(
                "\(name)-\(appearance.rawValue)-\(Int(size.width))x\(Int(size.height)).png"
            )
            try data.write(to: file, options: .atomic)
        }

        return Result(
            pngData: data,
            pixelWidth: rep.pixelsWide,
            pixelHeight: rep.pixelsHigh,
            labels: labels,
            controlFrames: frames,
            containerSize: size
        )
    }

    // OCR-based inspection lives in BoardSnapshotOCR below.
}

enum BoardSnapshotError: Error {
    case cannotCreateBitmap
}


/// Minimal on-device OCR used by the offscreen renderer. No network and no
/// accessibility permission is involved.
enum BoardSnapshotOCR {
    struct Observation {
        let text: String
        /// Normalized Vision box (0...1, origin bottom-left).
        let box: CGRect

        func frame(for size: CGSize) -> CGRect {
            CGRect(
                x: box.minX * size.width,
                y: (1 - box.maxY) * size.height,
                width: box.width * size.width,
                height: box.height * size.height
            )
        }
    }

    static func observe(_ data: Data) -> [Observation] {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["es-ES", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Observation(text: text, box: observation.boundingBox)
        }
    }
}
