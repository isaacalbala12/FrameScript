import CoreAudio
import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

@MainActor
final class VoiceFollowTests: XCTestCase {
    // MARK: - Visible text and document mapping

    func testVisibleTextMatchesRendererCharacterCounts() {
        let sections = [
            TeleprompterSection(
                sceneID: UUID(),
                title: "One",
                runs: [
                    .text("\nuno"),
                    .pause(1),
                    .text("\n\ndos"),
                    .cue("CAM"),
                    .emphasis("tres", level: .strong)
                ]
            ),
            TeleprompterSection(
                sceneID: UUID(),
                title: "Two",
                runs: [
                    .text("cuatro"),
                    .text(" cinco"),
                    .pause(0.5),
                    .emphasis("seis", level: .emphasis)
                ]
            )
        ]

        let rendered = TeleprompterAttributedStringBuilder.build(sections: sections, fontSize: 64)
        let visible = TeleprompterVisibleText.texts(for: sections)

        XCTAssertEqual(visible.map(\.count), rendered.visibleCharacterCounts)
        XCTAssertEqual(visible[0], "uno\ndostres")
        XCTAssertEqual(visible[1], "cuatro cincoseis")
    }

    func testDocumentMapsTokensAcrossSceneBoundaries() {
        let first = sceneSection(title: "One", text: "uno dos tres")
        let second = sceneSection(title: "Two", text: "cuatro cinco seis")
        let document = VoiceFollowDocument(sections: [first, second], language: .spanish)

        XCTAssertEqual(
            document.script.tokens.map(\.normalized),
            ["1", "2", "3", "4", "5", "6"]
        )
        XCTAssertEqual(document.location(forTokenIndex: 3)?.sectionIndex, 1)
        XCTAssertEqual(document.location(forTokenIndex: 3)?.characterOffset, 0)
        XCTAssertEqual(
            document.tokenIndex(for: VoiceFollowPosition(sceneID: second.sceneID, characterOffset: 0)),
            3
        )
        XCTAssertEqual(
            document.tokenIndex(for: VoiceFollowPosition(sceneID: second.sceneID, characterOffset: 13)),
            5
        )
        XCTAssertEqual(
            document.location(forTokenIndex: 5)?.characterOffset,
            13
        )
    }

    func testFollowerScriptSlicesAndRebasesTokensAndSentences() {
        let first = sceneSection(title: "One", text: "uno dos tres")
        let second = sceneSection(title: "Two", text: "cuatro cinco seis")
        let document = VoiceFollowDocument(sections: [first, second], language: .spanish)

        let sliced = document.followerScript(startingAtToken: 3)
        XCTAssertEqual(sliced.baseTokenIndex, 3)
        XCTAssertEqual(sliced.script.tokens.count, 3)
        XCTAssertEqual(sliced.script.tokens.first?.normalized, "4")
        XCTAssertEqual(sliced.script.tokens.first?.index, 0)
        XCTAssertEqual(sliced.script.tokens.first?.sentenceIndex, 0)
        XCTAssertEqual(sliced.script.sentenceRanges, [0..<3])
    }

    func testRetokenizationPreservesSceneAndCharacter() {
        let first = sceneSection(title: "One", text: "uno dos tres")
        let second = sceneSection(title: "Two", text: "cuatro cinco seis")
        let document = VoiceFollowDocument(sections: [first, second], language: .spanish)
        let position = VoiceFollowPosition(sceneID: second.sceneID, characterOffset: 13)

        let editedFirst = sceneSection(title: "One", text: "cero uno dos tres")
        let edited = VoiceFollowDocument(sections: [editedFirst, second], language: .spanish)
        let token = edited.tokenIndex(for: position)

        XCTAssertEqual(token, 6)
        XCTAssertEqual(edited.location(forTokenIndex: 6)?.sceneID, second.sceneID)
        XCTAssertEqual(edited.location(forTokenIndex: 6)?.characterOffset, 13)
        XCTAssertEqual(document.tokenIndex(for: position), 5)
    }

    func testSceneBoundaryStartsANewSentenceEvenWithoutPunctuation() {
        let first = sceneSection(title: "One", text: "sin puntuacion")
        let second = sceneSection(title: "Two", text: "otra escena")
        let document = VoiceFollowDocument(sections: [first, second], language: .spanish)

        XCTAssertEqual(document.script.tokens.map(\.sentenceIndex), [0, 0, 1, 1])
        XCTAssertEqual(document.script.sentenceRanges, [0..<2, 2..<4])
    }

    // MARK: - Fallback state machine

    func testModeTrackerFallsBackImmediatelyAndResumesAfterSustainedConfidence() {
        var tracker = VoiceFollowModeTracker()
        XCTAssertEqual(
            tracker.update(confidence: 0, isLost: false, hasPosition: false, at: 0),
            .waiting
        )
        XCTAssertEqual(
            tracker.update(confidence: 0.6, isLost: false, hasPosition: true, at: 1),
            .following
        )
        XCTAssertEqual(
            tracker.update(confidence: 0, isLost: true, hasPosition: true, at: 2),
            .timedFallback
        )
        XCTAssertEqual(
            tracker.update(confidence: 0.6, isLost: false, hasPosition: true, at: 3),
            .timedFallback
        )
        XCTAssertEqual(
            tracker.update(confidence: 0.6, isLost: false, hasPosition: true, at: 3.5),
            .following
        )
    }

    func testModeTrackerDoesNotResumeAfterABriefConfidenceBlip() {
        var tracker = VoiceFollowModeTracker()
        _ = tracker.update(confidence: 0.6, isLost: false, hasPosition: true, at: 0)
        _ = tracker.update(confidence: 0, isLost: true, hasPosition: true, at: 1)
        _ = tracker.update(confidence: 0.6, isLost: false, hasPosition: true, at: 2)
        _ = tracker.update(confidence: 0, isLost: false, hasPosition: true, at: 2.2)
        _ = tracker.update(confidence: 0.6, isLost: false, hasPosition: true, at: 2.3)
        XCTAssertEqual(
            tracker.update(confidence: 0.6, isLost: false, hasPosition: true, at: 2.6),
            .timedFallback
        )
        XCTAssertEqual(
            tracker.update(confidence: 0.6, isLost: false, hasPosition: true, at: 2.8),
            .following
        )
    }

    func testModeTrackerKeepsFollowingThroughAShortConfidenceDip() {
        var tracker = VoiceFollowModeTracker()
        _ = tracker.update(confidence: 0.7, isLost: false, hasPosition: true, at: 0)
        XCTAssertEqual(
            tracker.update(confidence: 0.1, isLost: false, hasPosition: true, at: 1),
            .following
        )
    }

    // MARK: - Damping

    func testSmootherConvergesWithoutOvershoot() {
        var smoother = TeleprompterVoiceSmoother()
        smoother.reset(at: 0)
        smoother.setTarget(500)

        var previous = -1.0
        for _ in 0..<300 {
            let value = smoother.advance(by: 1.0 / 60.0)
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertLessThanOrEqual(value, 500.000_001)
            previous = value
        }
        XCTAssertEqual(smoother.value, 500, accuracy: 0.001)
    }

    func testSmootherIsFrameRateIndependent() {
        var singleStep = TeleprompterVoiceSmoother()
        singleStep.maximumSpeed = 1_000_000
        singleStep.reset(at: 0)
        singleStep.setTarget(300)
        _ = singleStep.advance(by: 0.25)

        var manySteps = singleStep
        manySteps.reset(at: 0)
        manySteps.setTarget(300)
        for _ in 0..<15 {
            _ = manySteps.advance(by: 1.0 / 60.0)
        }

        XCTAssertEqual(singleStep.value, manySteps.value, accuracy: 0.01)
    }

    func testSmootherIgnoresSubLineTargetJitter() {
        var smoother = TeleprompterVoiceSmoother()
        smoother.reset(at: 100)
        smoother.setTarget(104)
        _ = smoother.advance(by: 1)

        XCTAssertEqual(smoother.target, 100)
        XCTAssertEqual(smoother.value, 100)
    }

    func testSmootherCapsSpeedOnLargeJumps() {
        var smoother = TeleprompterVoiceSmoother()
        smoother.maximumSpeed = 100
        smoother.reset(at: 0)
        smoother.setTarget(1_000)

        let value = smoother.advance(by: 0.1)
        XCTAssertLessThanOrEqual(abs(value), 10.000_001)
    }

    // MARK: - Simulated transcript

    func testSimulatedHypothesisFileParsesTimestampsAndText() {
        let contents = """
        # synthetic transcript
        0.5 hola
        00:01.5 esto es una prueba
        1:02:03,5 final

        bad line
        """
        let hypotheses = SimulatedHypothesisFile.parse(contents)

        XCTAssertEqual(hypotheses.count, 3)
        XCTAssertEqual(hypotheses[0].timestamp, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(hypotheses[0].text, "hola")
        XCTAssertEqual(hypotheses[1].timestamp, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(hypotheses[1].text, "esto es una prueba")
        XCTAssertEqual(hypotheses[2].timestamp, 3_723.5, accuracy: 0.000_001)
        XCTAssertEqual(hypotheses[2].text, "final")
    }

    // MARK: - Model integration

    func testVoiceFollowFollowsAcrossScenesAndMovesTheScroll() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let scenes = [
            TeleprompterSceneText(id: firstID, title: "One", text: "uno dos tres"),
            TeleprompterSceneText(id: secondID, title: "Two", text: "cuatro cinco seis")
        ]
        let model = try makeModel(scenes: scenes)
        prepare(model, counts: [12, 17])

        await model.startVoiceFollowing()
        XCTAssertTrue(model.voiceFollow.isEnabled)

        model.ingestVoiceHypothesis("uno dos tres", at: 100)
        XCTAssertEqual(model.voiceFollow.phase, .following)
        XCTAssertEqual(model.voiceFollow.currentLocation?.sectionIndex, 0)

        model.ingestVoiceHypothesis("cuatro cinco seis", at: 100.5)
        XCTAssertEqual(model.voiceFollow.currentLocation?.sectionIndex, 1)
        XCTAssertEqual(model.voiceFollow.currentLocation?.sceneID, secondID)

        for index in 0..<120 {
            model.tick(now: 100.6 + Double(index) / 60.0)
        }

        XCTAssertGreaterThan(model.offset, 300)
        XCTAssertEqual(model.currentSectionIndex, 1)
        XCTAssertNotNil(model.voiceTargetOffset)
    }

    func testVoiceFollowFallsBackToTimedScrollingAndResumes() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let scenes = [
            TeleprompterSceneText(id: firstID, title: "One", text: "uno dos tres"),
            TeleprompterSceneText(id: secondID, title: "Two", text: "cuatro cinco seis")
        ]
        let model = try makeModel(scenes: scenes)
        prepare(model, counts: [12, 17])

        await model.startVoiceFollowing()
        model.ingestVoiceHypothesis("uno dos tres", at: 200)
        model.tick(now: 200.1)
        XCTAssertEqual(model.voiceFollow.phase, .following)

        model.tick(now: 203.3)
        XCTAssertEqual(model.voiceFollow.phase, .timedFallback)
        XCTAssertNil(model.voiceTargetOffset)
        XCTAssertTrue(model.isPlaying)

        let beforeFallbackScroll = model.offset
        model.tick(now: 204.1)
        XCTAssertGreaterThan(model.offset, beforeFallbackScroll)

        model.ingestVoiceHypothesis("uno dos tres", at: 204.2)
        model.tick(now: 204.7)
        XCTAssertEqual(model.voiceFollow.phase, .following)
        XCTAssertNotNil(model.voiceTargetOffset)
    }

    func testLiveScriptEditKeepsVoicePosition() async throws {
        let firstID = UUID()
        let secondID = UUID()
        var scenes = [
            TeleprompterSceneText(id: firstID, title: "One", text: "uno dos tres"),
            TeleprompterSceneText(id: secondID, title: "Two", text: "cuatro cinco seis")
        ]
        let provider: TeleprompterSceneProvider = { scenes }
        let model = try makeModel(scenes: scenes, provider: provider)
        prepare(model, counts: [12, 17])

        await model.startVoiceFollowing()
        model.ingestVoiceHypothesis("uno dos tres", at: 300)
        let before = try XCTUnwrap(model.voiceFollow.currentLocation)

        scenes[0] = TeleprompterSceneText(
            id: firstID,
            title: "One",
            text: "cero uno dos tres"
        )
        model.refreshFromProvider()

        let after = try XCTUnwrap(model.voiceFollow.currentLocation)
        XCTAssertEqual(after.sceneID, before.sceneID)
        XCTAssertGreaterThanOrEqual(after.characterOffset, before.characterOffset - 1)
        XCTAssertLessThanOrEqual(after.characterOffset, before.characterOffset + 1)
        XCTAssertEqual(model.voiceFollow.phase, .following)
    }

    func testReadingSessionReportsSpokenWordsDurationAndLanguage() async throws {
        let scenes = [
            TeleprompterSceneText(id: UUID(), title: "One", text: "uno dos tres")
        ]
        let model = try makeModel(scenes: scenes)
        prepare(model, counts: [12])
        model.restore(
            anchor: TeleprompterReadingAnchor(sceneID: scenes[0].id, characterOffset: 0)
        )

        var reported: TeleprompterReadingSession?
        model.onReadingSessionFinished = { reported = $0 }

        await model.startVoiceFollowing()
        model.ingestVoiceHypothesis("uno dos tres", at: 400)
        model.stopVoiceFollowing(pausePlayback: true, now: 405)

        let session = try XCTUnwrap(reported)
        XCTAssertEqual(session.spokenWords, 2)
        XCTAssertEqual(session.duration, 5, accuracy: 0.000_001)
        XCTAssertEqual(session.language, .spanish)
    }

    func testSimulatedTranscriptDrivesThePlaybackModel() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let scenes = [
            TeleprompterSceneText(id: firstID, title: "One", text: "uno dos tres"),
            TeleprompterSceneText(id: secondID, title: "Two", text: "cuatro cinco seis")
        ]
        let model = try makeModel(scenes: scenes)
        prepare(model, counts: [12, 17])

        let transcript = """
        0.5 uno dos tres
        1.5 cuatro cinco seis
        """
        let hypotheses = SimulatedHypothesisFile.parse(transcript)
        XCTAssertEqual(hypotheses.count, 2)

        await model.startVoiceFollowing()
        for hypothesis in hypotheses {
            model.ingestVoiceHypothesis(hypothesis.text, at: hypothesis.timestamp)
            model.tick(now: hypothesis.timestamp + 0.05)
        }

        XCTAssertEqual(model.voiceFollow.currentLocation?.sceneID, secondID)
        XCTAssertEqual(model.voiceFollow.phase, .following)
    }

    // MARK: - Permissions and settings

    func testNotDeterminedPermissionsExplainBeforeAsking() async throws {
        let scenes = [
            TeleprompterSceneText(id: UUID(), title: "One", text: "uno dos tres")
        ]
        let model = try makeModel(scenes: scenes, recognizer: UndeterminedSpeechRecognizer())
        prepare(model, counts: [12])

        await model.beginVoiceFollowFlow()

        guard case .explanation = model.voiceFollowAlert?.kind else {
            return XCTFail("Expected the Spanish permission explanation alert")
        }
        XCTAssertFalse(model.voiceFollow.isEnabled)
    }

    func testDeniedPermissionTurnsVoiceFollowOffWithAMessage() async throws {
        let scenes = [
            TeleprompterSceneText(id: UUID(), title: "One", text: "uno dos tres")
        ]
        let model = try makeModel(scenes: scenes, recognizer: DeniedSpeechRecognizer())
        prepare(model, counts: [12])

        await model.startVoiceFollowing()

        XCTAssertFalse(model.voiceFollow.isEnabled)
        XCTAssertEqual(model.voiceFollow.phase, .off)
        guard case .failure(.permissionsDenied) = model.voiceFollowAlert?.kind else {
            return XCTFail("Expected a permissions failure alert")
        }
    }

    func testMicrophoneChoiceRoundTripsInTeleprompterSettings() throws {
        var settings = TeleprompterSettings.defaults
        settings.preferredAudioInputUID = "synthetic-mic-uid"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(TeleprompterSettings.self, from: data)
        XCTAssertEqual(decoded.preferredAudioInputUID, "synthetic-mic-uid")
        XCTAssertEqual(decoded, settings)
    }

    func testVoiceFollowLocalizationCoversEveryLanguage() throws {
        let english = try XCTUnwrap(L10n.voiceFollowStrings[.english])
        let russian = try XCTUnwrap(L10n.voiceFollowStrings[.russian])
        let spanish = try XCTUnwrap(L10n.voiceFollowStrings[.spanish])
        XCTAssertEqual(Set(english.keys), Set(russian.keys))
        XCTAssertEqual(Set(english.keys), Set(spanish.keys))
        XCTAssertEqual(L10n.tr("voiceFollow.toggle", language: .spanish), "Seguir mi voz")
        XCTAssertEqual(L10n.tr("voiceFollow.toggle", language: .english), "Follow my voice")
    }

    func testProjectLanguageMapsToRecognitionLocale() {
        XCTAssertEqual(SpeechLanguage(projectLanguageCode: "es")?.rawValue, "es")
        XCTAssertEqual(SpeechLanguage(projectLanguageCode: "es-ES")?.rawValue, "es")
        XCTAssertEqual(SpeechLanguage(projectLanguageCode: "en-US")?.rawValue, "en")
        XCTAssertNil(SpeechLanguage(projectLanguageCode: "ru"))
    }

    // MARK: - Helpers

    private func sceneSection(title: String, text: String) -> TeleprompterSection {
        TeleprompterSection(
            sceneID: UUID(),
            title: title,
            runs: ScriptMarkup.runs(text)
        )
    }

    private func makeModel(
        scenes: [TeleprompterSceneText],
        provider: TeleprompterSceneProvider? = nil,
        recognizer: any SpeechRecognizing = FakeSpeechRecognizer()
    ) throws -> TeleprompterModel {
        let suiteName = "VoiceFollowTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let model = TeleprompterModel(
            sections: TeleprompterContentBuilder.sections(from: scenes),
            startingSectionIndex: 0,
            language: .spanish,
            settingsStore: TeleprompterSettingsStore(userDefaults: defaults),
            sceneProvider: provider,
            speechLanguage: .spanish,
            speechRecognizer: recognizer,
            fallbackWordsPerMinuteProvider: { 120.0 }
        )
        addTeardownBlock {
            model.stop()
        }
        return model
    }

    private func prepare(_ model: TeleprompterModel, counts: [Int]) {
        model.updateViewport(width: 1200, height: 600)
        model.updateTextMetrics(
            TeleprompterTextMetrics(
                contentHeight: 1600,
                sectionStarts: counts.indices.map { 64 + Double($0) * 500 },
                sectionHeights: counts.map { _ in 500 },
                visibleCharacterCounts: counts
            )
        )
    }
}

private actor FakeSpeechRecognizer: SpeechRecognizing {
    private var continuation: AsyncThrowingStream<SpeechRecognitionEvent, Error>.Continuation?

    func permissions() async -> SpeechRecognitionPermissions {
        SpeechRecognitionPermissions(speech: .authorized, microphone: .authorized)
    }

    func requestPermissions() async -> SpeechRecognitionPermissions {
        await permissions()
    }

    func start(
        language: SpeechLanguage,
        inputDeviceID: AudioDeviceID?
    ) async throws -> AsyncThrowingStream<SpeechRecognitionEvent, Error> {
        let pair = AsyncThrowingStream<SpeechRecognitionEvent, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }
}

private actor UndeterminedSpeechRecognizer: SpeechRecognizing {
    func permissions() async -> SpeechRecognitionPermissions {
        SpeechRecognitionPermissions(speech: .notDetermined, microphone: .notDetermined)
    }

    func requestPermissions() async -> SpeechRecognitionPermissions {
        SpeechRecognitionPermissions(speech: .denied, microphone: .denied)
    }

    func start(
        language: SpeechLanguage,
        inputDeviceID: AudioDeviceID?
    ) async throws -> AsyncThrowingStream<SpeechRecognitionEvent, Error> {
        throw SpeechRecognitionError.speechPermissionDenied
    }

    func stop() async {}
}

private actor DeniedSpeechRecognizer: SpeechRecognizing {
    func permissions() async -> SpeechRecognitionPermissions {
        SpeechRecognitionPermissions(speech: .denied, microphone: .denied)
    }

    func requestPermissions() async -> SpeechRecognitionPermissions {
        await permissions()
    }

    func start(
        language: SpeechLanguage,
        inputDeviceID: AudioDeviceID?
    ) async throws -> AsyncThrowingStream<SpeechRecognitionEvent, Error> {
        throw SpeechRecognitionError.speechPermissionDenied
    }

    func stop() async {}
}
