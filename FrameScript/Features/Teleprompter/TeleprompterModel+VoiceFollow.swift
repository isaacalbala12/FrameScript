import AppKit
import Foundation
import FrameScriptCore

// MARK: - Alerts

struct VoiceFollowAlert: Identifiable {
    enum Kind {
        case explanation
        case denied
        case failure(VoiceFollowFailure)
        case noText
    }

    let id = UUID()
    let kind: Kind
}

// MARK: - Model integration

extension TeleprompterModel {
    // MARK: Toggle and permissions

    func toggleVoiceFollow() {
        if voiceFollow.isEnabled {
            stopVoiceFollowing(pausePlayback: true)
        } else {
            Task { @MainActor [weak self] in
                await self?.beginVoiceFollowFlow()
            }
        }
    }

    func beginVoiceFollowFlow() async {
        guard !voiceFollow.isEnabled else { return }
        guard speechLanguage != nil else {
            voiceFollowAlert = VoiceFollowAlert(kind: .failure(.unsupportedLanguage))
            return
        }
        guard !sections.isEmpty else {
            voiceFollowAlert = VoiceFollowAlert(kind: .noText)
            return
        }
        refreshVoiceInputDevices()

        let permissions = await voiceFollow.permissions()
        if permissions.speech == .denied
            || permissions.speech == .restricted
            || permissions.microphone == .denied
            || permissions.microphone == .restricted {
            voiceFollowAlert = VoiceFollowAlert(kind: .denied)
        } else if permissions.speech == .notDetermined || permissions.microphone == .notDetermined {
            // Explain what the microphone is for before macOS shows its own
            // permission dialog.
            voiceFollowAlert = VoiceFollowAlert(kind: .explanation)
        } else {
            await startVoiceFollowing()
        }
    }

    func confirmVoiceFollowPermissions() {
        guard !voiceFollow.isEnabled else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let permissions = await self.voiceFollow.requestPermissions()
            guard permissions.isGranted else {
                self.voiceFollowAlert = VoiceFollowAlert(kind: .denied)
                return
            }
            await self.startVoiceFollowing()
        }
    }

    func startVoiceFollowing() async {
        guard !voiceFollow.isEnabled, let speechLanguage else { return }
        refreshVoiceInputDevices()
        let document = VoiceFollowDocument(sections: sections, language: speechLanguage)
        do {
            try await voiceFollow.start(
                document: document,
                language: speechLanguage,
                startPosition: currentVoicePosition(),
                inputDeviceUID: settings.preferredAudioInputUID
            )
            startPlaybackImmediately()
            voiceTargetOffset = offset
            voiceSmoother.reset(at: offset)
            voiceLastTick = nil
            lastVoicePhase = .listening
            showControlsTemporarily()
        } catch {
            voiceFollowAlert = VoiceFollowAlert(kind: .failure(VoiceFollowFailure.from(error)))
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

    // MARK: Microphone

    func refreshVoiceInputDevices() {
        voiceFollow.refreshInputDevices()
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
        guard voiceFollow.isEnabled else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.voiceFollow.restart(inputDeviceUID: uid)
            } catch {
                self.voiceFollowAlert = VoiceFollowAlert(
                    kind: .failure(VoiceFollowFailure.from(error))
                )
                self.stopVoiceFollowing(pausePlayback: true)
            }
        }
    }

    // MARK: Failures

    func handleVoiceFollowFailure(_ failure: VoiceFollowFailure) {
        voiceFollowAlert = VoiceFollowAlert(kind: .failure(failure))
        showControlsTemporarily()
    }

    func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
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
        return VoiceFollowPosition(sceneID: anchor.sceneID, characterOffset: anchor.characterOffset)
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
        voiceFollow.tick(now: now)
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
                // Re-anchor at what is actually on screen so a long silent
                // stretch does not leave the follower far behind.
                voiceFollow.rebase(to: currentVoicePosition())
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
    /// path the live stream uses.
    func ingestVoiceHypothesis(
        _ text: String,
        at timestamp: TimeInterval,
        segment: Int? = nil
    ) {
        voiceFollow.ingest(text: text, at: timestamp, segment: segment)
    }
}
