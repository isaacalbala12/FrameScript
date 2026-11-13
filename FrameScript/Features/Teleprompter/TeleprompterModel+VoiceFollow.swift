import AppKit
import Foundation
import FrameScriptCore

// MARK: - Alerts

struct VoiceFollowAlert: Identifiable {
    enum Kind {
        case explanation
        case denied(speechDenied: Bool)
        case failure(VoiceFollowFailure)
        case noText
    }

    let id = UUID()
    let kind: Kind
}

// MARK: - Model integration

extension TeleprompterModel {
    // MARK: Toggle and permissions

    /// A single synchronous transition flag makes the keyboard shortcut and the
    /// button reentrant-safe: a second V while the first start is still
    /// awaiting permissions is ignored instead of starting a second session.
    func toggleVoiceFollow() {
        guard !voiceTransitionInProgress else { return }
        voiceTransitionInProgress = true
        voiceStartCancelled = false
        voiceTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.voiceTransitionInProgress = false }
            if self.voiceFollow.isEnabled {
                await self.stopVoiceFollowingAndWait(pausePlayback: true)
            } else {
                await self.beginVoiceFollowFlow()
            }
        }
    }

    func beginVoiceFollowFlow() async {
        guard !voiceFollow.isEnabled, !voiceStartCancelled else { return }
        guard speechLanguage != nil else {
            voiceFollowAlert = VoiceFollowAlert(kind: .failure(.unsupportedLanguage))
            return
        }
        guard !sections.isEmpty else {
            voiceFollowAlert = VoiceFollowAlert(kind: .noText)
            return
        }
        await voiceFollow.refreshInputDevices()
        guard !voiceStartCancelled else { return }

        let permissions = await voiceFollow.permissions()
        guard !voiceStartCancelled else { return }
        if permissions.speech == .denied
            || permissions.speech == .restricted
            || permissions.microphone == .denied
            || permissions.microphone == .restricted {
            let speechDenied = permissions.speech == .denied || permissions.speech == .restricted
            voiceFollowAlert = VoiceFollowAlert(kind: .denied(speechDenied: speechDenied))
        } else if permissions.speech == .notDetermined || permissions.microphone == .notDetermined {
            // Explain what the microphone is for before macOS shows its own
            // permission dialog.
            voiceFollowAlert = VoiceFollowAlert(kind: .explanation)
        } else {
            await startVoiceFollowing()
        }
    }

    func confirmVoiceFollowPermissions() {
        guard !voiceFollow.isEnabled, !voiceTransitionInProgress else { return }
        voiceTransitionInProgress = true
        voiceStartCancelled = false
        voiceTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.voiceTransitionInProgress = false }
            let permissions = await self.voiceFollow.requestPermissions()
            guard !self.voiceStartCancelled else { return }
            guard permissions.isGranted else {
                self.voiceFollowAlert = VoiceFollowAlert(
                    kind: .denied(speechDenied: permissions.speech != .authorized)
                )
                return
            }
            await self.startVoiceFollowing()
        }
    }

    func startVoiceFollowing() async {
        guard !voiceFollow.isEnabled, !voiceStartCancelled, let speechLanguage else { return }
        voiceFollow.fallbackPositionProvider = { [weak self] in
            self?.currentVoicePosition()
        }
        await voiceFollow.refreshInputDevices()
        // Tokenizing the whole document is expensive; never do it on the
        // MainActor while the teleprompter is drawing.
        let sectionsSnapshot = sections
        let document = await Task.detached {
            VoiceFollowDocument(sections: sectionsSnapshot, language: speechLanguage)
        }.value
        guard !voiceStartCancelled else { return }

        do {
            try await voiceFollow.start(
                document: document,
                language: speechLanguage,
                startPosition: currentVoicePosition(),
                inputDeviceUID: settings.preferredAudioInputUID
            )
            guard !voiceStartCancelled else {
                await voiceFollow.stopAndWait(
                    now: ProcessInfo.processInfo.systemUptime,
                    emitSession: false
                )
                return
            }
            startPlaybackImmediately()
            voiceTargetOffset = offset
            voiceSmoother.reset(at: offset)
            voiceLastTick = nil
            lastVoicePhase = .listening
            showControlsTemporarily()
        } catch {
            let failure = VoiceFollowFailure.from(error)
            guard failure != .cancelled else { return }
            voiceFollowAlert = VoiceFollowAlert(kind: .failure(failure))
            stopVoiceFollowing(pausePlayback: true)
        }
    }

    func stopVoiceFollowing(
        pausePlayback: Bool,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard voiceFollow.isEnabled || voiceFollow.phase != .off else { return }
        voiceFollow.stop(now: now, emitSession: true)
        voiceTargetOffset = nil
        voiceLastTick = nil
        lastVoicePhase = .off
        voiceSmoother.reset(at: offset)
        if pausePlayback {
            isPlaying = false
            engine.isPlaying = false
            engine.resetTimestamp()
            controlsVisible = true
            hideControlsTask?.cancel()
        }
    }

    func stopVoiceFollowingAndWait(
        pausePlayback: Bool,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) async {
        stopVoiceFollowing(pausePlayback: pausePlayback, now: now)
        await voiceFollow.waitForStop()
    }

    func waitForVoiceTransition() async {
        await voiceTransitionTask?.value
    }

    func waitForVoiceFollowDocumentUpdate() async {
        await voiceFollow.waitForDocumentUpdate()
    }

    func waitForVoiceFollowStop() async {
        await voiceFollow.waitForStop()
    }

    // MARK: Microphone

    func refreshVoiceInputDevices() {
        Task { @MainActor [weak self] in
            await self?.voiceFollow.refreshInputDevices()
        }
    }

    var selectedAudioInputName: String {
        guard let uid = settings.preferredAudioInputUID,
              let device = voiceFollow.availableInputDevices.first(where: { $0.uid == uid }) else {
            return localized("voiceFollow.systemMicrophone")
        }
        return device.name
    }

    func selectAudioInput(uid: String?) {
        settings.preferredAudioInputUID = uid
        guard voiceFollow.isEnabled, !voiceTransitionInProgress else { return }
        voiceTransitionInProgress = true
        voiceTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.voiceTransitionInProgress = false }
            do {
                try await self.voiceFollow.restart(inputDeviceUID: uid)
            } catch {
                let failure = VoiceFollowFailure.from(error)
                guard failure != .cancelled else { return }
                self.voiceFollowAlert = VoiceFollowAlert(kind: .failure(failure))
                await self.stopVoiceFollowingAndWait(pausePlayback: true)
            }
        }
    }

    // MARK: Project language

    func updateSpeechLanguage(_ language: SpeechLanguage?) async {
        guard language != speechLanguage, !voiceTransitionInProgress else { return }
        voiceTransitionInProgress = true
        defer { voiceTransitionInProgress = false }
        speechLanguage = language
        guard voiceFollow.isEnabled else { return }
        guard let language else {
            voiceFollowAlert = VoiceFollowAlert(kind: .failure(.unsupportedLanguage))
            await stopVoiceFollowingAndWait(pausePlayback: true)
            return
        }

        let sectionsSnapshot = sections
        let document = await Task.detached {
            VoiceFollowDocument(sections: sectionsSnapshot, language: language)
        }.value
        do {
            try await voiceFollow.restart(
                language: language,
                document: document,
                inputDeviceUID: settings.preferredAudioInputUID
            )
        } catch {
            let failure = VoiceFollowFailure.from(error)
            guard failure != .cancelled else { return }
            voiceFollowAlert = VoiceFollowAlert(kind: .failure(failure))
            await stopVoiceFollowingAndWait(pausePlayback: true)
        }
    }

    // MARK: Failures

    func handleVoiceFollowFailure(_ failure: VoiceFollowFailure) {
        guard failure != .cancelled else { return }
        voiceFollowAlert = VoiceFollowAlert(kind: .failure(failure))
        showControlsTemporarily()
    }

    func openPrivacySettings(speechDenied: Bool) {
        let pane = speechDenied ? "Privacy_SpeechRecognition" : "Privacy_Microphone"
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Geometry

    func currentVoicePosition() -> VoiceFollowPosition? {
        guard let anchor = readingAnchor(
            mirrorVertical: settings.mirrorVertical,
            readingLineFraction: settings.readingLineFraction
        ) else {
            return nil
        }
        return VoiceFollowPosition(
            sceneID: anchor.sceneID,
            characterOffset: anchor.characterOffset
        )
    }

    var voiceFallbackWordsPerMinute: Double {
        if let learned = fallbackWordsPerMinuteProvider?(), learned.isFinite, learned > 0 {
            return learned
        }
        return settings.wordsPerMinute
    }

    var voiceFallbackPointsPerSecond: Double {
        TeleprompterSpeed.pointsPerSecond(
            wordsPerMinute: voiceFallbackWordsPerMinute,
            fontSize: settings.fontSize,
            columnWidth: effectiveColumnWidth
        )
    }

    func voiceTargetOffsetForCurrentLocation() -> Double? {
        guard let location = voiceFollow.currentLocation,
              sections.indices.contains(location.sectionIndex),
              sectionStarts.indices.contains(location.sectionIndex),
              sectionHeights.indices.contains(location.sectionIndex),
              visibleCharacterCounts.indices.contains(location.sectionIndex) else {
            return nil
        }
        let contentY = TeleprompterLayout.contentY(
            forCharacterOffset: location.characterOffset,
            characterCount: visibleCharacterCounts[location.sectionIndex],
            start: sectionStarts[location.sectionIndex],
            height: sectionHeights[location.sectionIndex]
        )
        return contentY - readingContentY
    }

    // MARK: Per-frame update

    func voiceFollowTick(now: TimeInterval) {
        guard voiceFollow.isEnabled else {
            if lastVoicePhase != .off {
                lastVoicePhase = .off
                voiceLastTick = nil
                voiceTargetOffset = nil
                voiceSmoother.reset(at: offset)
            }
            return
        }

        let delta = voiceLastTick.map { min(max(now - $0, 0), 0.25) } ?? 0
        voiceLastTick = now
        let phase = voiceFollow.phase

        switch phase {
        case .following:
            if lastVoicePhase != .following {
                voiceSmoother.reset(at: offset)
            }
            if let target = voiceTargetOffsetForCurrentLocation() {
                voiceSmoother.setTarget(target)
                voiceTargetOffset = voiceSmoother.advance(by: delta)
            }
        case .timedFallback:
            if lastVoicePhase != .timedFallback {
                voiceTargetOffset = nil
            }
            engine.isPlaying = true
            engine.pointsPerSecond = voiceFallbackPointsPerSecond
            if engine.offset >= maxOffset - 0.5 {
                engine.isPlaying = false
            }
        case .listening, .preparing:
            if lastVoicePhase == .off || lastVoicePhase == .timedFallback {
                voiceSmoother.reset(at: offset)
                voiceTargetOffset = offset
            }
        case .off:
            voiceTargetOffset = nil
        }
        lastVoicePhase = phase
    }

    /// Test/debug entry point: inject a recognizer hypothesis through the same
    /// path the live stream uses. The alignment itself runs off-main.
    func ingestVoiceHypothesis(
        _ text: String,
        at timestamp: TimeInterval,
        segment: Int? = nil
    ) async {
        await voiceFollow.ingest(text: text, at: timestamp, segment: segment)
    }

    /// Deterministic liveness advance for tests; production has a 4 Hz
    /// liveness task inside the voice controller.
    func advanceVoiceFollow(to timestamp: TimeInterval) async {
        await voiceFollow.tick(now: timestamp)
        tick(now: timestamp)
    }
}
