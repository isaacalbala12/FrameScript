import CoreGraphics
import Foundation
import FrameScriptCore
import Observation

/// The eight rates the delivery sheet offers, including drop-frame variants.
enum ResolvePackFrameRate: String, CaseIterable, Identifiable, Sendable {
    case fps23_976
    case fps24
    case fps25
    case fps29_97
    case fps30
    case fps50
    case fps59_94
    case fps60

    var id: String { rawValue }

    var frameRate: FrameRate {
        switch self {
        case .fps23_976: .fps23_976
        case .fps24: .fps24
        case .fps25: .fps25
        case .fps29_97: .fps29_97
        case .fps30: .fps30
        case .fps50: .fps50
        case .fps59_94: .fps59_94
        case .fps60: .fps60
        }
    }

    var dropFrame: Bool {
        self == .fps29_97 || self == .fps59_94
    }

    var label: String {
        switch self {
        case .fps23_976: "23.976"
        case .fps24: "24"
        case .fps25: "25"
        case .fps29_97: "29.97 DF"
        case .fps30: "30"
        case .fps50: "50"
        case .fps59_94: "59.94 DF"
        case .fps60: "60"
        }
    }

    static let `default`: ResolvePackFrameRate = .fps25

    static func matching(fps: FrameRate, dropFrame: Bool) -> ResolvePackFrameRate {
        allCases.first { $0.frameRate == fps && $0.dropFrame == (dropFrame && fps.supportsDropFrame) }
            ?? `default`
    }
}

/// Where each scene's timeline duration comes from.
enum ResolvePackDurationSource: String, CaseIterable, Identifiable, Sendable {
    /// The selected good/safe take for the pack language, falling back to the
    /// learned-pace estimate.
    case realTakes
    /// Always the markup-aware estimate at the learned words per minute.
    case estimates

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .realTakes: "resolvePack.duration.real"
        case .estimates: "resolvePack.duration.estimate"
        }
    }
}

/// A language the pack can be generated in: the project original plus any
/// translated variant that exists in at least one scene.
struct ResolvePackLanguageOption: Identifiable, Hashable, Sendable {
    let code: String
    let isOriginal: Bool

    var id: String { code }

    func displayName(interfaceLanguage: AppLanguage) -> String {
        let name: String
        switch code {
        case "es": name = "Español"
        case "en": name = "English"
        case "ru": name = "Русский"
        default: name = code.uppercased()
        }
        guard isOriginal else { return name }
        return String(
            format: L10n.tr("resolvePack.language.originalFormat", language: interfaceLanguage),
            name
        )
    }
}

/// Parses the sheet's start-timecode field, accepting either `:` or `;` before
/// the frames and normalising it to the selected rate. A DF label such as
/// `01:00:00:00` is accepted and becomes `01:00:00;00`; skipped DF labels stay
/// invalid.
enum ResolvePackTimecodeField {
    static func parse(_ text: String, rate: FrameRate, dropFrame: Bool) -> Timecode? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let lastSeparator = trimmed.lastIndex(where: { $0 == ":" || $0 == ";" }) else {
            return nil
        }
        let drop = dropFrame && rate.supportsDropFrame
        let normalized = String(trimmed[..<lastSeparator])
            + (drop ? ";" : ":")
            + String(trimmed[trimmed.index(after: lastSeparator)...])
        return Timecode(string: normalized, rate: rate, dropFrame: drop)
    }

    static func defaultText(rate: FrameRate, dropFrame: Bool) -> String {
        let drop = dropFrame && rate.supportsDropFrame
        return Timecode.oneHour(rate: rate, dropFrame: drop)
            .string(rate: rate, dropFrame: drop)
    }
}

/// Everything the sheet edits. Pure and testable: no AppState, no file system.
struct ResolvePackConfiguration: Equatable, Sendable {
    var rate: ResolvePackFrameRate
    var startTimecodeText: String
    var asciiSafeNames: Bool
    var durationSource: ResolvePackDurationSource
    var languageCode: String
    var includeMarkerEDL: Bool
    var includeFCPXML: Bool
    var includeShotList: Bool
    var includeEditingNotes: Bool
    var includeChapters: Bool
    var includeChapterMarkersInFCPXML: Bool
    var includeReadme: Bool
    /// Explicit opt-in for a chapter list YouTube will ignore (fewer than 3).
    var writeInvalidChapters: Bool

    static func defaults(languageCode: String) -> ResolvePackConfiguration {
        let rate = ResolvePackFrameRate.default
        return ResolvePackConfiguration(
            rate: rate,
            startTimecodeText: ResolvePackTimecodeField.defaultText(
                rate: rate.frameRate,
                dropFrame: rate.dropFrame
            ),
            asciiSafeNames: true,
            durationSource: .realTakes,
            languageCode: languageCode,
            includeMarkerEDL: true,
            includeFCPXML: true,
            includeShotList: true,
            includeEditingNotes: true,
            includeChapters: true,
            includeChapterMarkersInFCPXML: true,
            includeReadme: true,
            writeInvalidChapters: false
        )
    }

    var parsedStartTimecode: Timecode? {
        ResolvePackTimecodeField.parse(
            startTimecodeText,
            rate: rate.frameRate,
            dropFrame: rate.dropFrame
        )
    }

    var hasAnyFile: Bool {
        includeMarkerEDL || includeFCPXML || includeShotList
            || includeEditingNotes || includeChapters || includeReadme
    }

    /// Changing the rate resets the field to that rate's one-hour default, so
    /// a 25 fps frame count can never be relabelled as 29.97 DF and shift an
    /// hour.
    mutating func setRate(_ newRate: ResolvePackFrameRate) {
        guard newRate != rate else { return }
        rate = newRate
        startTimecodeText = ResolvePackTimecodeField.defaultText(
            rate: newRate.frameRate,
            dropFrame: newRate.dropFrame
        )
    }

    func options() -> ResolvePackOptions? {
        guard hasAnyFile, let startTimecode = parsedStartTimecode else { return nil }
        return ResolvePackOptions(
            fps: rate.frameRate,
            dropFrame: rate.dropFrame,
            startTimecode: startTimecode,
            asciiSafeNames: asciiSafeNames,
            includeMarkerEDL: includeMarkerEDL,
            includeFCPXML: includeFCPXML,
            includeShotList: includeShotList,
            includeEditingNotes: includeEditingNotes,
            includeChapters: includeChapters,
            includeChapterMarkersInFCPXML: includeChapterMarkersInFCPXML && includeFCPXML,
            includeReadme: includeReadme,
            writeInvalidChapters: writeInvalidChapters
        )
    }
}

/// What the sheet's file checkboxes actually write, which can differ from the
/// raw booleans when a chapter list cannot be used by YouTube.
enum ResolvePackFileSelection {
    static func chaptersWillBeWritten(
        configuration: ResolvePackConfiguration,
        plan: ResolvePackPlan?
    ) -> Bool {
        guard configuration.includeChapters else { return false }
        guard let plan else { return true }
        return plan.chapters.isValidForYouTube || configuration.writeInvalidChapters
    }

    static func selectedFileCount(
        configuration: ResolvePackConfiguration,
        plan: ResolvePackPlan?
    ) -> Int {
        var count = [
            configuration.includeMarkerEDL,
            configuration.includeFCPXML,
            configuration.includeShotList,
            configuration.includeEditingNotes,
            configuration.includeChapters,
            configuration.includeReadme
        ].filter { $0 }.count
        if configuration.includeChapters,
           !chaptersWillBeWritten(configuration: configuration, plan: plan) {
            count -= 1
        }
        return max(0, count)
    }
}

// MARK: - Presentation

/// Coalesces Resolve-plan rebuilds without ever letting Export write an older
/// plan than the configuration on screen.
///
/// Option changes schedule a rebuild after a short delay (typing in the
/// timecode field must not re-parse the script per keystroke). Export calls
/// `flushForExport`, which cancels the pending task and rebuilds synchronously
/// from the current configuration.
@MainActor
@Observable
final class ResolvePackPlanRefreshController {
    private(set) var plan: ResolvePackPlan?
    private var refreshTask: Task<Void, Never>?

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refreshNow(
        appState: AppState,
        configuration: ResolvePackConfiguration
    ) {
        cancel()
        plan = appState.makeResolvePackPlan(configuration: configuration)
    }

    func schedule(
        appState: AppState,
        configuration: ResolvePackConfiguration
    ) {
        cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.plan = appState.makeResolvePackPlan(configuration: configuration)
            self.refreshTask = nil
        }
    }

    /// Rebuilds synchronously and returns the plan Export must write.
    @discardableResult
    func flushForExport(
        appState: AppState,
        configuration: ResolvePackConfiguration
    ) -> ResolvePackPlan? {
        cancel()
        let fresh = appState.makeResolvePackPlan(configuration: configuration)
        plan = fresh
        return fresh
    }
}

struct ResolvePackRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let languageCode: String
}

/// Presentation coordinator, mirroring `HookSheetPresenter` so the menu opens
/// immediately and the command palette waits for its own sheet to close.
@MainActor
@Observable
final class ResolvePackPresenter {
    static let shared = ResolvePackPresenter()

    var request: ResolvePackRequest?
    private var pendingRequest: ResolvePackRequest?

    func present(languageCode: String) {
        request = ResolvePackRequest(languageCode: languageCode)
    }

    func presentAfterPaletteDismissal(languageCode: String) {
        pendingRequest = ResolvePackRequest(languageCode: languageCode)
    }

    func presentPendingRequest() {
        guard let pendingRequest else { return }
        self.pendingRequest = nil
        request = pendingRequest
    }
}

// MARK: - Layout

/// Fixed layout contract shared by the view and the offscreen layout tests.
enum ResolvePackSheetLayout {
    static let minimumWindowSize = CGSize(width: 980, height: 712)
    static let minimumSheetSize = CGSize(width: 860, height: 620)
    static let idealSheetSize = CGSize(width: 880, height: 640)
    static let optionsColumnWidth: CGFloat = 320
    static let dividerWidth: CGFloat = 1
    static let headerHeight: CGFloat = 66
    static let footerHeight: CGFloat = 62

    struct Frames: Equatable {
        var header: CGRect
        var body: CGRect
        var footer: CGRect
        var options: CGRect
        var divider: CGRect
        var preview: CGRect
    }

    static func frames(in size: CGSize) -> Frames {
        let width = max(size.width, minimumSheetSize.width)
        let height = max(size.height, minimumSheetSize.height)
        let bodyY = headerHeight + dividerWidth
        let bodyHeight = max(0, height - bodyY - footerHeight - dividerWidth)
        let previewX = optionsColumnWidth + dividerWidth
        return Frames(
            header: CGRect(x: 0, y: 0, width: width, height: headerHeight),
            body: CGRect(x: 0, y: bodyY, width: width, height: bodyHeight),
            footer: CGRect(x: 0, y: bodyY + bodyHeight + dividerWidth, width: width, height: footerHeight),
            options: CGRect(x: 0, y: bodyY, width: optionsColumnWidth, height: bodyHeight),
            divider: CGRect(x: optionsColumnWidth, y: bodyY, width: dividerWidth, height: bodyHeight),
            preview: CGRect(x: previewX, y: bodyY, width: max(0, width - previewX), height: bodyHeight)
        )
    }
}
