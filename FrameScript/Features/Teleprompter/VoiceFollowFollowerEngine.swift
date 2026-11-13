import Foundation
import FrameScriptCore

/// Result of one speech-follower update.
struct VoiceFollowUpdate: Sendable, Equatable {
    let state: SpeechFollowState
    let location: VoiceFollowLocation?
}

/// Owns the tokenized document and the `SpeechFollower` off the MainActor.
///
/// `SpeechFollower.process` is a dynamic-programming alignment; at 5–20
/// partial transcripts per second it must not run on the thread that draws the
/// teleprompter. The controller awaits this actor and only applies the small
/// resulting state on the MainActor.
actor VoiceFollowFollowerEngine {
    private(set) var document: VoiceFollowDocument
    private let configuration: SpeechFollowConfiguration
    private var follower: SpeechFollower

    init(
        document: VoiceFollowDocument,
        configuration: SpeechFollowConfiguration = SpeechFollowConfiguration()
    ) {
        self.document = document
        self.configuration = configuration
        self.follower = SpeechFollower(script: document.script, configuration: configuration)
    }

    func seek(to position: VoiceFollowPosition?) -> VoiceFollowLocation? {
        let token = position.flatMap { document.tokenIndex(for: $0) } ?? 0
        follower.seek(toToken: token)
        return document.location(forTokenIndex: token)
    }

    func process(
        text: String,
        at timestamp: TimeInterval,
        segment: Int?,
        reanchor: VoiceFollowPosition? = nil
    ) -> VoiceFollowUpdate {
        if let reanchor, let token = document.tokenIndex(for: reanchor) {
            var fresh = SpeechFollower(script: document.script, configuration: configuration)
            fresh.seek(toToken: token)
            let state = fresh.process(text: text, at: timestamp, segment: segment)
            follower = fresh
            return VoiceFollowUpdate(state: state, location: location(for: state))
        }
        let state = follower.process(text: text, at: timestamp, segment: segment)
        return VoiceFollowUpdate(state: state, location: location(for: state))
    }

    func tick(at timestamp: TimeInterval, reanchor: VoiceFollowPosition? = nil) -> VoiceFollowUpdate {
        seekIfNeeded(reanchor)
        let state = follower.tick(at: timestamp)
        return VoiceFollowUpdate(state: state, location: location(for: state))
    }

    @discardableResult
    private func seekIfNeeded(_ position: VoiceFollowPosition?) -> Int? {
        guard let position, let token = document.tokenIndex(for: position) else { return nil }
        // A rebase deliberately starts from a pristine follower: the old one
        // may carry fallback/lost state accumulated while the screen scrolled
        // away, and only the anchor is meaningful after a re-anchor.
        follower = SpeechFollower(script: document.script, configuration: configuration)
        follower.seek(toToken: token)
        return token
    }

    func updateDocument(
        _ newDocument: VoiceFollowDocument,
        oldLocation: VoiceFollowLocation?,
        position: VoiceFollowPosition?
    ) -> VoiceFollowLocation? {
        let token = newDocument.migratedTokenIndex(
            from: document,
            location: oldLocation,
            fallback: position
        )
        document = newDocument
        follower = SpeechFollower(script: newDocument.script, configuration: configuration)
        let resolved = token ?? newDocument.tokenIndex(for: position ?? VoiceFollowPosition(
            sceneID: newDocument.sections.first?.sceneID ?? UUID(),
            characterOffset: 0
        )) ?? 0
        follower.seek(toToken: resolved)
        return newDocument.location(forTokenIndex: resolved)
    }

    func currentLocation(forTokenIndex index: Int) -> VoiceFollowLocation? {
        document.location(forTokenIndex: index)
    }

    private func location(for state: SpeechFollowState) -> VoiceFollowLocation? {
        guard let tokenIndex = state.tokenIndex else { return nil }
        return document.location(forTokenIndex: tokenIndex)
    }
}
