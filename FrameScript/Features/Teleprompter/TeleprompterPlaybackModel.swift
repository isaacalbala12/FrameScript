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

/// Observable playback surface for the teleprompter window. Geometry comes
/// from the AppKit text renderer; scrolling drives that renderer directly so a
/// 60 Hz tick never rebuilds a SwiftUI text tree.
@MainActor
@Observable
final class TeleprompterModel {
    let language: AppLanguage

    var sections: [TeleprompterSection]
    var settings: TeleprompterSettings {
        didSet { handleSettingsChange(from: oldValue) }
    }

    /// Bumped whenever the text must be rebuilt by the renderer.
    private(set) var layoutRevision = 0

    /// Status-bar offset, throttled to 10 Hz so the overlay does not re-render
    /// at the scroll cadence.
    private(set) var displayOffset: Double = 0
    private(set) var isPlaying = false
    private(set) var currentSectionIndex: Int
    private(set) var controlsVisible = true
    private(set) var countdown: Int?
    private(set) var isAwaitingLayout = true
    private var isWindowVisible = true

    private(set) var viewportWidth: Double = 0
    private(set) var viewportHeight: Double = 0
    private(set) var contentHeight: Double = 0
    private(set) var sectionStarts: [Double] = []
    private(set) var sectionHeights: [Double] = []
    private(set) var visibleCharacterCounts: [Int] = []

    private(set) var offset: Double = 0

    /// External target offset hook for the future speech follower. When set,
    /// the engine eases towards it instead of scrolling at the WPM rate.
    var voiceTargetOffset: Double? {
        didSet { engine.setTargetOffset(voiceTargetOffset) }
    }

    var onClose: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
    var onMoveToDisplay: ((UInt32) -> Void)?

    private let settingsStore: TeleprompterSettingsStore
    private let sceneProvider: TeleprompterSceneProvider?
    private weak var textRenderer: TeleprompterTextRendering?
    private var sourceSnapshot: [TeleprompterSceneText] = []
    private var engine = TeleprompterScrollEngine()
    private var tickTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var hideControlsTask: Task<Void, Never>?
    private var settingsSaveTask: Task<Void, Never>?
    private var hasStartedOnce = false
    private var hasAppliedInitialSection = false
    private let pendingInitialSectionIndex: Int
    private let initialAnchor: TeleprompterReadingAnchor?
    private var pendingReadingAnchor: TeleprompterReadingAnchor?
    private var pendingJumpIndex: Int?
    private var lastDisplayUpdate: TimeInterval = 0
    private var lastAppliedMetricsGeneration = -1

    init(
        sections: [TeleprompterSection],
        startingSectionIndex: Int,
        language: AppLanguage,
        settingsStore: TeleprompterSettingsStore,
        sceneProvider: TeleprompterSceneProvider? = nil,
        resumeAnchor: TeleprompterReadingAnchor? = nil
    ) {
        let resolvedStart: Int
        if let resumeAnchor,
           let index = sections.firstIndex(where: { $0.sceneID == resumeAnchor.sceneID }) {
            resolvedStart = index
            self.initialAnchor = resumeAnchor
        } else {
            resolvedStart = min(max(0, startingSectionIndex), max(0, sections.count - 1))
            self.initialAnchor = nil
        }

        self.sections = sections
        self.language = language
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
        self.currentSectionIndex = resolvedStart
        self.pendingInitialSectionIndex = resolvedStart
        self.sceneProvider = sceneProvider
        startTicking()
        startRefreshing()
    }

    // MARK: Geometry

    static func effectiveColumnWidth(settingsWidth: Double, viewportWidth: Double) -> Double {
        guard viewportWidth > 0 else { return settingsWidth }
        return min(settingsWidth, max(260, viewportWidth - 96))
    }

    var effectiveColumnWidth: Double {
        Self.effectiveColumnWidth(settingsWidth: settings.columnWidth, viewportWidth: viewportWidth)
    }

    var visualReadingLineY: Double {
        viewportHeight * settings.readingLineFraction
    }

    var readingContentY: Double {
        TeleprompterLayout.readingContentY(
            viewportHeight: viewportHeight,
            fraction: settings.readingLineFraction,
            mirrorVertical: settings.mirrorVertical
        )
    }

    var maxOffset: Double {
        max(0, contentHeight - viewportHeight)
    }

    var pointsPerSecond: Double {
        TeleprompterSpeed.pointsPerSecond(
            wordsPerMinute: settings.wordsPerMinute,
            fontSize: settings.fontSize,
            columnWidth: effectiveColumnWidth
        )
    }

    var totalEstimatedDuration: TimeInterval {
        TeleprompterTiming.estimatedDuration(for: sections, wordsPerMinute: settings.wordsPerMinute)
    }

    var elapsedEstimate: TimeInterval {
        guard maxOffset > 0 else { return 0 }
        return totalEstimatedDuration * min(1, max(0, displayOffset / maxOffset))
    }

    var remainingEstimate: TimeInterval {
        max(0, totalEstimatedDuration - elapsedEstimate)
    }

    var currentSectionTitle: String {
        guard sections.indices.contains(currentSectionIndex) else { return "" }
        return sections[currentSectionIndex].title
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

    func localized(_ key: String) -> String {
        L10n.tr(key, language: language)
    }

    // MARK: Renderer plumbing

    func attachRenderer(_ renderer: TeleprompterTextRendering) {
        textRenderer = renderer
        renderer.setScrollOffset(offset)
    }

    func detachRenderer(_ renderer: TeleprompterTextRendering) {
        guard let current = textRenderer, current === renderer else { return }
        textRenderer = nil
    }

    func updateTextMetrics(_ metrics: TeleprompterTextMetrics) {
        guard metrics.generation >= lastAppliedMetricsGeneration else { return }
        lastAppliedMetricsGeneration = metrics.generation
        contentHeight = metrics.contentHeight
        sectionStarts = metrics.sectionStarts
        sectionHeights = metrics.sectionHeights
        visibleCharacterCounts = metrics.visibleCharacterCounts
        if let voiceTargetOffset {
            engine.setTargetOffset(voiceTargetOffset)
        }

        guard isAwaitingLayout else { return }
        isAwaitingLayout = false

        if !hasAppliedInitialSection {
            hasAppliedInitialSection = true
            if let pendingJumpIndex {
                self.pendingJumpIndex = nil
                jump(to: pendingJumpIndex)
            } else if let initialAnchor {
                restore(anchor: initialAnchor)
            } else {
                jump(to: pendingInitialSectionIndex)
            }
        } else if let pendingJumpIndex {
            self.pendingJumpIndex = nil
            jump(to: pendingJumpIndex)
        } else if let pendingReadingAnchor {
            restore(anchor: pendingReadingAnchor)
        }
        pendingReadingAnchor = nil
        updateDisplayOffset(force: true)
    }

    func setWindowVisible(_ isVisible: Bool) {
        isWindowVisible = isVisible
        engine.resetTimestamp()
    }

    func updateViewport(width: Double, height: Double) {
        let oldWidth = viewportWidth
        let oldHeight = viewportHeight
        guard abs(oldWidth - width) > 0.5 || abs(oldHeight - height) > 0.5 else { return }

        let hadMetrics = !sectionStarts.isEmpty
        let oldEffective = Self.effectiveColumnWidth(settingsWidth: settings.columnWidth, viewportWidth: oldWidth)
        let anchor = hadMetrics
            ? readingAnchor(mirrorVertical: settings.mirrorVertical, readingLineFraction: settings.readingLineFraction)
            : nil

        viewportWidth = width
        viewportHeight = height

        guard hadMetrics else { return }
        let newEffective = effectiveColumnWidth
        if abs(oldEffective - newEffective) > 0.5 {
            pendingReadingAnchor = anchor ?? pendingReadingAnchor
            isAwaitingLayout = true
            layoutRevision += 1
        } else if let anchor {
            restore(anchor: anchor)
        }
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
        voiceTargetOffset = nil
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
        guard !isAwaitingLayout else {
            pendingJumpIndex = index
            return
        }
        let target = TeleprompterLayout.offsetForSection(
            index,
            starts: sectionStarts,
            readingContentY: readingContentY,
            mirrorVertical: settings.mirrorVertical
        )
        currentSectionIndex = index
        applyOffset(target)
        voiceTargetOffset = nil
    }

    // MARK: Reading anchors

    func readingAnchor(
        mirrorVertical: Bool,
        readingLineFraction: Double
    ) -> TeleprompterReadingAnchor? {
        guard !sections.isEmpty, !sectionStarts.isEmpty else { return nil }
        let guide = TeleprompterLayout.readingContentY(
            viewportHeight: viewportHeight,
            fraction: readingLineFraction,
            mirrorVertical: mirrorVertical
        )
        let index = TeleprompterLayout.currentSectionIndex(
            offset: offset,
            readingContentY: guide,
            starts: sectionStarts
        )
        guard sections.indices.contains(index) else { return nil }

        let count = visibleCharacterCounts.indices.contains(index)
            ? visibleCharacterCounts[index]
            : 0
        let progress = TeleprompterLayout.sceneProgress(
            offset: offset,
            readingContentY: guide,
            start: sectionStarts[index],
            height: sectionHeights.indices.contains(index) ? sectionHeights[index] : 0
        )
        let characterOffset = min(count, max(0, Int((progress * Double(count)).rounded())))
        return TeleprompterReadingAnchor(sceneID: sections[index].sceneID, characterOffset: characterOffset)
    }

    func restore(anchor: TeleprompterReadingAnchor) {
        guard let index = sections.firstIndex(where: { $0.sceneID == anchor.sceneID }) else {
            jump(to: min(max(0, currentSectionIndex), max(0, sections.count - 1)))
            return
        }
        let count = visibleCharacterCounts.indices.contains(index) ? visibleCharacterCounts[index] : 0
        let start = sectionStarts.indices.contains(index) ? sectionStarts[index] : 0
        let height = sectionHeights.indices.contains(index) ? sectionHeights[index] : 0
        let contentY = TeleprompterLayout.contentY(
            forCharacterOffset: anchor.characterOffset,
            characterCount: count,
            start: start,
            height: height
        )
        currentSectionIndex = index
        applyOffset(contentY - readingContentY)
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
        refreshTask?.cancel()
        countdownTask?.cancel()
        hideControlsTask?.cancel()
        settingsSaveTask?.cancel()
        tickTask = nil
        refreshTask = nil
        countdownTask = nil
        hideControlsTask = nil
        settingsSaveTask = nil
        settingsStore.save(settings)
    }

    // MARK: Live source

    func refreshFromProvider() {
        guard let sceneProvider else { return }
        let scenes = sceneProvider()
        guard !scenes.isEmpty, scenes != sourceSnapshot else { return }
        sourceSnapshot = scenes

        let newSections = TeleprompterContentBuilder.sections(from: scenes)
        guard newSections != sections else { return }

        let anchor = isAwaitingLayout
            ? pendingReadingAnchor
            : readingAnchor(mirrorVertical: settings.mirrorVertical, readingLineFraction: settings.readingLineFraction)

        sections = newSections
        pendingReadingAnchor = anchor
        isAwaitingLayout = true
        layoutRevision += 1
    }

    // MARK: Tick

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Very long scripts are expensive to redraw with Core Text. At
                // 30 Hz a slow teleprompter still moves in sub-2-point steps,
                // while the main thread keeps up with the scroll instead of
                // dropping most of the frames.
                let interval = (self?.totalVisibleCharacters ?? 0) > 80_000 ? 33 : 16
                try? await Task.sleep(for: .milliseconds(interval))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private var totalVisibleCharacters: Int {
        visibleCharacterCounts.reduce(0, +)
    }

    private func startRefreshing() {
        guard sceneProvider != nil else { return }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                self.refreshFromProvider()
            }
        }
    }

    private func tick() {
        guard isWindowVisible, !isAwaitingLayout else { return }
        engine.maxOffset = maxOffset
        if engine.offset > maxOffset {
            engine.seek(to: maxOffset)
        }
        engine.pointsPerSecond = pointsPerSecond
        engine.isPlaying = isPlaying
        engine.advance(to: CACurrentMediaTime())

        if abs(offset - engine.offset) > 0.001 {
            offset = engine.offset
            textRenderer?.setScrollOffset(offset)
        }
        if isPlaying != engine.isPlaying {
            isPlaying = engine.isPlaying
            if !isPlaying {
                controlsVisible = true
            }
        }

        guard !sectionStarts.isEmpty else { return }
        let index = TeleprompterLayout.currentSectionIndex(
            offset: offset,
            readingContentY: readingContentY,
            starts: sectionStarts
        )
        if index != currentSectionIndex {
            currentSectionIndex = index
        }

        let now = CACurrentMediaTime()
        if now - lastDisplayUpdate >= 0.1 {
            lastDisplayUpdate = now
            displayOffset = offset
        }
    }

    private func applyOffset(_ value: Double) {
        engine.maxOffset = maxOffset
        engine.seek(to: value)
        offset = engine.offset
        displayOffset = offset
        lastDisplayUpdate = CACurrentMediaTime()
        textRenderer?.setScrollOffset(offset)
    }

    private func updateDisplayOffset(force: Bool) {
        guard force || abs(displayOffset - offset) > 0.1 else { return }
        displayOffset = offset
        lastDisplayUpdate = CACurrentMediaTime()
    }

    private func handleSettingsChange(from oldValue: TeleprompterSettings) {
        let oldEffective = Self.effectiveColumnWidth(
            settingsWidth: oldValue.columnWidth,
            viewportWidth: viewportWidth
        )
        let needsRelayout = oldValue.fontSize != settings.fontSize
            || abs(oldEffective - effectiveColumnWidth) > 0.5
        let readingChanged = oldValue.readingLineFraction != settings.readingLineFraction
            || oldValue.mirrorVertical != settings.mirrorVertical

        if needsRelayout || readingChanged {
            let anchor = readingAnchor(
                mirrorVertical: oldValue.mirrorVertical,
                readingLineFraction: oldValue.readingLineFraction
            )
            if needsRelayout {
                if pendingReadingAnchor == nil {
                    pendingReadingAnchor = anchor
                }
                isAwaitingLayout = true
                layoutRevision += 1
            } else if !isAwaitingLayout, let anchor {
                restore(anchor: anchor)
            }
        }

        scheduleSettingsSave()
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
