import AppKit
import Foundation
import Observation
import QuartzCore

struct TeleprompterDisplay: Identifiable, Equatable {
    let id: UInt32
    let name: String
}

@MainActor
enum TeleprompterDisplays {
    static func available() -> [TeleprompterDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return TeleprompterDisplay(id: number.uint32Value, name: screen.localizedName)
        }
    }

    static func screen(for displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return number.uint32Value == displayID
        }
    }

    static func mainDisplayID() -> UInt32? {
        guard let number = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return number.uint32Value
    }
}

/// Observable playback surface for the teleprompter window. All mutation is
/// main-actor bound; scrolling is driven by a real-time tick and the pure
/// `TeleprompterScrollEngine`.
@MainActor
@Observable
final class TeleprompterModel {
    static let contentTopInset: Double = 64

    let sections: [TeleprompterSection]
    let language: AppLanguage

    var settings: TeleprompterSettings {
        didSet { scheduleSettingsSave() }
    }

    var offset: Double = 0
    var isPlaying = false
    var currentSectionIndex: Int
    var controlsVisible = true
    var countdown: Int?
    var viewportHeight: Double = 0
    var contentHeight: Double = 0
    var sectionHeights: [Int: Double] = [:]

    /// External target offset hook for the future speech follower. When set,
    /// the engine eases towards it instead of scrolling at the WPM rate.
    var voiceTargetOffset: Double? {
        didSet { engine.setTargetOffset(voiceTargetOffset) }
    }

    var onClose: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
    var onMoveToDisplay: ((UInt32) -> Void)?

    private let settingsStore: TeleprompterSettingsStore
    private var engine = TeleprompterScrollEngine()
    private var tickTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var hideControlsTask: Task<Void, Never>?
    private var settingsSaveTask: Task<Void, Never>?
    private var hasStartedOnce = false
    private var hasAppliedInitialSection: Bool
    private let pendingInitialSectionIndex: Int

    init(
        sections: [TeleprompterSection],
        startingSectionIndex: Int,
        language: AppLanguage,
        settingsStore: TeleprompterSettingsStore
    ) {
        let clampedStart = min(max(0, startingSectionIndex), max(0, sections.count - 1))
        self.sections = sections
        self.language = language
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
        self.currentSectionIndex = clampedStart
        self.pendingInitialSectionIndex = clampedStart
        self.hasAppliedInitialSection = clampedStart == 0
        startTicking()
    }

    var readingLineY: Double {
        viewportHeight * settings.readingLineFraction
    }

    var maxOffset: Double {
        max(0, contentHeight - viewportHeight)
    }

    var sceneStarts: [Double] {
        TeleprompterLayout.sectionStarts(
            heights: (0..<sections.count).map { sectionHeights[$0] ?? 0 },
            topInset: Self.contentTopInset
        )
    }

    var pointsPerSecond: Double {
        TeleprompterSpeed.pointsPerSecond(
            wordsPerMinute: settings.wordsPerMinute,
            fontSize: settings.fontSize,
            columnWidth: settings.columnWidth
        )
    }

    var totalEstimatedDuration: TimeInterval {
        TeleprompterTiming.estimatedDuration(for: sections, wordsPerMinute: settings.wordsPerMinute)
    }

    var elapsedEstimate: TimeInterval {
        guard maxOffset > 0 else { return 0 }
        return totalEstimatedDuration * min(1, max(0, offset / maxOffset))
    }

    var remainingEstimate: TimeInterval {
        max(0, totalEstimatedDuration - elapsedEstimate)
    }

    var progress: Double {
        guard maxOffset > 0 else { return 0 }
        return min(1, max(0, offset / maxOffset))
    }

    var availableDisplays: [TeleprompterDisplay] {
        TeleprompterDisplays.available()
    }

    var selectedDisplayID: UInt32? {
        settings.preferredDisplayID ?? TeleprompterDisplays.mainDisplayID()
    }

    var selectedDisplayName: String {
        guard let selectedDisplayID,
              let display = availableDisplays.first(where: { $0.id == selectedDisplayID }) else {
            return availableDisplays.first?.name ?? ""
        }
        return display.name
    }

    var currentSectionTitle: String {
        guard sections.indices.contains(currentSectionIndex) else { return "" }
        return sections[currentSectionIndex].title
    }

    func localized(_ key: String) -> String {
        L10n.tr(key, language: language)
    }

    // MARK: Geometry

    func updateViewport(height: Double) {
        guard abs(viewportHeight - height) > 0.5 else { return }
        viewportHeight = height
    }

    func updateContentHeight(_ height: Double) {
        contentHeight = height
    }

    func updateSectionHeights(_ heights: [Int: Double]) {
        sectionHeights = heights
    }

    // MARK: Transport

    func togglePlayback() {
        if countdown != nil {
            cancelCountdown()
            beginPlayback()
            return
        }
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard !sections.isEmpty else { return }
        cancelCountdown()
        if maxOffset > 0, offset >= maxOffset - 0.5 {
            jump(to: currentSectionIndex)
        }
        if settings.countdownEnabled && !hasStartedOnce {
            startCountdown()
        } else {
            beginPlayback()
        }
    }

    func pause() {
        cancelCountdown()
        isPlaying = false
        engine.isPlaying = false
        engine.resetTimestamp()
        controlsVisible = true
        hideControlsTask?.cancel()
    }

    func startPlaybackImmediately() {
        cancelCountdown()
        hasStartedOnce = true
        beginPlayback()
    }

    func nextSection() {
        guard !sections.isEmpty else { return }
        jump(to: min(sections.count - 1, currentSectionIndex + 1))
    }

    func previousSection() {
        guard !sections.isEmpty else { return }
        jump(to: max(0, currentSectionIndex - 1))
    }

    func restartSection() {
        jump(to: currentSectionIndex)
    }

    func jump(to index: Int) {
        guard sections.indices.contains(index) else { return }
        let target = TeleprompterLayout.offsetForSection(
            index,
            starts: sceneStarts,
            readingLineY: readingLineY
        )
        currentSectionIndex = index
        engine.maxOffset = maxOffset
        engine.seek(to: target)
        offset = engine.offset
        engine.resetTimestamp()
    }

    // MARK: Settings adjustments

    func adjustWordsPerMinute(by delta: Double) {
        settings.wordsPerMinute = min(
            TeleprompterSettings.Limits.wordsPerMinute.upperBound,
            max(TeleprompterSettings.Limits.wordsPerMinute.lowerBound, settings.wordsPerMinute + delta)
        )
    }

    func adjustFontSize(by delta: Double) {
        settings.fontSize = min(
            TeleprompterSettings.Limits.fontSize.upperBound,
            max(TeleprompterSettings.Limits.fontSize.lowerBound, settings.fontSize + delta)
        )
    }

    func adjustColumnWidth(by delta: Double) {
        settings.columnWidth = min(
            TeleprompterSettings.Limits.columnWidth.upperBound,
            max(TeleprompterSettings.Limits.columnWidth.lowerBound, settings.columnWidth + delta)
        )
    }

    func toggleMirrorHorizontal() {
        settings.mirrorHorizontal.toggle()
    }

    func toggleMirrorVertical() {
        settings.mirrorVertical.toggle()
    }

    func toggleCountdown() {
        settings.countdownEnabled.toggle()
    }

    func selectDisplay(_ displayID: UInt32) {
        settings.preferredDisplayID = displayID
        onMoveToDisplay?(displayID)
    }

    func toggleFullScreen() {
        onToggleFullScreen?()
    }

    func close() {
        onClose?()
    }

    // MARK: Overlay visibility

    func showControlsTemporarily() {
        controlsVisible = true
        hideControlsTask?.cancel()
        guard isPlaying else { return }
        hideControlsTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.8))
            guard !Task.isCancelled, let self, self.isPlaying else { return }
            self.controlsVisible = false
        }
    }

    // MARK: Lifecycle

    func stop() {
        tickTask?.cancel()
        countdownTask?.cancel()
        hideControlsTask?.cancel()
        settingsSaveTask?.cancel()
        tickTask = nil
        countdownTask = nil
        hideControlsTask = nil
        settingsSaveTask = nil
        settingsStore.save(settings)
    }

    // MARK: Tick

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        applyInitialSectionIfNeeded()
        engine.maxOffset = maxOffset
        if engine.offset > maxOffset {
            engine.seek(to: maxOffset)
        }
        engine.pointsPerSecond = pointsPerSecond
        engine.isPlaying = isPlaying
        engine.advance(to: CACurrentMediaTime())

        if abs(offset - engine.offset) > 0.01 {
            offset = engine.offset
        }
        if isPlaying != engine.isPlaying {
            isPlaying = engine.isPlaying
            if !isPlaying {
                controlsVisible = true
            }
        }

        guard !sceneStarts.isEmpty else { return }
        let index = TeleprompterLayout.currentSectionIndex(
            offset: offset,
            readingLineY: readingLineY,
            starts: sceneStarts
        )
        if index != currentSectionIndex {
            currentSectionIndex = index
        }
    }

    /// The window opens at the scene selected in the editor, but section heights
    /// and the viewport are only known after the first layout pass.
    private func applyInitialSectionIfNeeded() {
        guard !hasAppliedInitialSection,
              viewportHeight > 0,
              contentHeight > 0,
              sections.indices.contains(pendingInitialSectionIndex),
              sectionHeights.count >= sections.count else {
            return
        }
        hasAppliedInitialSection = true
        jump(to: pendingInitialSectionIndex)
    }

    // MARK: Countdown

    private func startCountdown() {
        countdownTask?.cancel()
        countdown = 3
        countdownTask = Task { @MainActor [weak self] in
            for value in stride(from: 3, through: 1, by: -1) {
                guard !Task.isCancelled, let self else { return }
                self.countdown = value
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, let self else { return }
            self.countdown = nil
            self.beginPlayback()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    private func beginPlayback() {
        guard !sections.isEmpty else { return }
        hasStartedOnce = true
        isPlaying = true
        engine.isPlaying = true
        engine.resetTimestamp()
        showControlsTemporarily()
    }

    // MARK: Save debounce

    private func scheduleSettingsSave() {
        settingsSaveTask?.cancel()
        settingsSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            self.settingsStore.save(self.settings)
        }
    }
}
