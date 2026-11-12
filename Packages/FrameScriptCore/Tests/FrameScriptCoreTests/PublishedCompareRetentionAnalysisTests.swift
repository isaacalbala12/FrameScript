import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Published compare – retention analysis")
struct PublishedCompareRetentionAnalysisTests {
    private func sample(_ position: Double, _ retention: Double) -> RetentionSample {
        RetentionSample(position: position, retention: retention)
    }

    @Test func mapsCurveOntoScenesWithAverages() {
        let samples = [
            sample(0, 1.0), sample(10, 0.9), sample(20, 0.8), sample(30, 0.7),
            sample(40, 0.6), sample(50, 0.5), sample(60, 0.4)
        ]
        let scenes = [
            RetentionScene(id: "s1", start: 0, end: 30),
            RetentionScene(id: "s2", start: 30, end: 60)
        ]

        let result = RetentionAnalysis.analyze(samples: samples, scenes: scenes)

        #expect(result.scenes.count == 2)
        #expect(approximatelyEqual(result.scenes[0].averageRetention, 0.85))
        #expect(approximatelyEqual(result.scenes[0].startRetention, 1.0))
        #expect(approximatelyEqual(result.scenes[0].endRetention, 0.7))
        #expect(approximatelyEqual(result.scenes[0].delta, -0.3))
        #expect(result.scenes[0].sampleCount == 3)
        #expect(approximatelyEqual(result.scenes[1].averageRetention, 0.55))
        #expect(approximatelyEqual(result.scenes[1].delta, -0.3))
        #expect(result.scenes[1].sampleCount == 3)
        #expect(approximatelyEqual(result.overallStartRetention, 1.0))
        #expect(approximatelyEqual(result.overallEndRetention, 0.4))
    }

    @Test func interpolatesSparseCurve() {
        let samples = [sample(0, 1.0), sample(60, 0.4)]
        let scenes = [RetentionScene(id: "s1", start: 20, end: 40)]
        let configuration = RetentionAnalysisConfiguration(separateHookLoss: false)

        let result = RetentionAnalysis.analyze(samples: samples, scenes: scenes, configuration: configuration)
        let scene = result.scenes[0]

        #expect(approximatelyEqual(scene.startRetention, 0.8))
        #expect(approximatelyEqual(scene.endRetention, 0.6))
        #expect(approximatelyEqual(scene.averageRetention, 0.7))
        #expect(approximatelyEqual(scene.delta, -0.2))
        #expect(scene.sampleCount == 0)
    }

    @Test func reportsHookLossSeparately() {
        let samples = [
            sample(0, 1.0), sample(10, 0.9), sample(20, 0.8), sample(30, 0.7),
            sample(40, 0.65), sample(50, 0.6), sample(60, 0.55)
        ]
        let scenes = [RetentionScene(id: "s1", start: 0, end: 60)]

        let result = RetentionAnalysis.analyze(samples: samples, scenes: scenes)
        let hook = result.hookLoss

        #expect(hook != nil)
        #expect(hook?.kind == .hookLoss)
        #expect(hook?.sceneID == "s1")
        #expect(approximatelyEqual(hook?.magnitude, 0.3))
        #expect(approximatelyEqual(hook?.end, 30))
        #expect(result.insights.contains { $0.kind == .hookLoss })

        let sceneDrop = result.insights.first { $0.kind == .sceneDrop }
        #expect(approximatelyEqual(sceneDrop?.start, 30))
        #expect(approximatelyEqual(sceneDrop?.magnitude, 0.15))
    }

    @Test func doesNotSeparateHookWhenDisabled() {
        let samples = [sample(0, 1.0), sample(30, 0.7), sample(60, 0.55)]
        let scenes = [RetentionScene(id: "s1", start: 0, end: 60)]
        let configuration = RetentionAnalysisConfiguration(separateHookLoss: false)

        let result = RetentionAnalysis.analyze(samples: samples, scenes: scenes, configuration: configuration)

        #expect(result.hookLoss == nil)
        #expect(!result.insights.contains { $0.kind == .hookLoss })
        let drop = result.insights.first { $0.kind == .sceneDrop }
        #expect(approximatelyEqual(drop?.magnitude, 0.45))
        #expect(approximatelyEqual(drop?.start, 0))
    }

    @Test func detectsTemporaryLocalDropWhenSceneRecovers() {
        let samples = [
            sample(0, 1.0), sample(10, 0.8), sample(20, 0.6),
            sample(30, 0.8), sample(40, 0.9), sample(50, 1.0)
        ]
        let scenes = [RetentionScene(id: "s1", start: 0, end: 50)]
        let configuration = RetentionAnalysisConfiguration(separateHookLoss: false)

        let result = RetentionAnalysis.analyze(samples: samples, scenes: scenes, configuration: configuration)

        #expect(approximatelyEqual(result.scenes[0].delta, 0))
        let drop = result.insights.first { $0.kind == .localDrop }
        #expect(drop != nil)
        #expect((drop?.magnitude ?? 0) >= 0.19)
        #expect(drop?.magnitude ?? 0 <= 0.21)
    }

    @Test func detectsReplaySpike() {
        let samples = [sample(0, 0.8), sample(10, 0.9), sample(20, 0.95), sample(30, 0.8), sample(40, 0.8)]
        let scenes = [RetentionScene(id: "s1", start: 0, end: 40)]
        let configuration = RetentionAnalysisConfiguration(
            dropThreshold: 0.2,
            relativeDropThreshold: 1.0,
            spikeThreshold: 0.05,
            separateHookLoss: false
        )

        let result = RetentionAnalysis.analyze(samples: samples, scenes: scenes, configuration: configuration)

        let spike = result.insights.first { $0.kind == .spike }
        #expect(spike != nil)
        #expect(approximatelyEqual(spike?.magnitude, 0.10))
        #expect(!result.insights.contains { $0.kind == .sceneDrop || $0.kind == .localDrop })
    }

    @Test func ranksInsightsByMagnitude() {
        let samples = [sample(0, 1.0), sample(30, 0.8), sample(60, 0.5)]
        let scenes = [
            RetentionScene(id: "s1", start: 0, end: 30),
            RetentionScene(id: "s2", start: 30, end: 60)
        ]

        let result = RetentionAnalysis.analyze(samples: samples, scenes: scenes)

        #expect(result.insights.count >= 2)
        #expect(result.insights[0].magnitude >= result.insights[1].magnitude)
        #expect(result.insights[0].kind == .sceneDrop)
        #expect(result.insights[0].sceneID == "s2")
    }

    @Test func respectsConfigurableThreshold() {
        let samples = [sample(0, 1.0), sample(30, 0.7), sample(60, 0.4)]
        let scenes = [RetentionScene(id: "s1", start: 30, end: 60)]
        let strict = RetentionAnalysisConfiguration(
            dropThreshold: 0.35,
            relativeDropThreshold: 0.0,
            separateHookLoss: false
        )
        let loose = RetentionAnalysisConfiguration(
            dropThreshold: 0.05,
            relativeDropThreshold: 0.0,
            separateHookLoss: false
        )

        let strictResult = RetentionAnalysis.analyze(samples: samples, scenes: scenes, configuration: strict)
        let looseResult = RetentionAnalysis.analyze(samples: samples, scenes: scenes, configuration: loose)

        #expect(!strictResult.insights.contains { $0.kind == .sceneDrop || $0.kind == .localDrop })
        #expect(looseResult.insights.contains { $0.kind == .sceneDrop })
    }

    @Test func appliesRelativeThreshold() {
        let samples = [sample(0, 0.9), sample(30, 0.82)]
        let scenes = [RetentionScene(id: "s1", start: 0, end: 30)]
        let strict = RetentionAnalysisConfiguration(
            dropThreshold: 0.05,
            relativeDropThreshold: 0.10,
            separateHookLoss: false
        )
        let loose = RetentionAnalysisConfiguration(
            dropThreshold: 0.05,
            relativeDropThreshold: 0.05,
            separateHookLoss: false
        )

        let strictResult = RetentionAnalysis.analyze(samples: samples, scenes: scenes, configuration: strict)
        let looseResult = RetentionAnalysis.analyze(samples: samples, scenes: scenes, configuration: loose)

        #expect(strictResult.insights.isEmpty)
        #expect(looseResult.insights.contains { $0.kind == .sceneDrop })
    }

    @Test func sampleAtBoundaryBelongsToNextScene() {
        let samples = [sample(0, 1.0), sample(30, 0.7), sample(60, 0.4)]
        let scenes = [
            RetentionScene(id: "s1", start: 0, end: 30),
            RetentionScene(id: "s2", start: 30, end: 60)
        ]

        let result = RetentionAnalysis.analyze(samples: samples, scenes: scenes)

        #expect(result.scenes[0].sampleCount == 1)
        #expect(result.scenes[1].sampleCount == 1)
        #expect(approximatelyEqual(result.scenes[0].endRetention, 0.7))
        #expect(approximatelyEqual(result.scenes[1].startRetention, 0.7))
    }

    @Test func shortVideoHookUsesLastSample() {
        let samples = [sample(0, 1.0), sample(10, 0.8), sample(20, 0.7)]
        let scenes = [RetentionScene(id: "s1", start: 0, end: 20)]

        let result = RetentionAnalysis.analyze(samples: samples, scenes: scenes)

        #expect(approximatelyEqual(result.hookLoss?.end, 20))
        #expect(approximatelyEqual(result.hookLoss?.magnitude, 0.3))
    }

    @Test func mergesDuplicateSamples() {
        let samples = [sample(0, 1.0), sample(0, 0.9), sample(10, 0.8), sample(20, 0.6)]
        let scenes = [RetentionScene(id: "s1", start: 0, end: 20)]

        let result = RetentionAnalysis.analyze(samples: samples, scenes: scenes)

        #expect(approximatelyEqual(result.overallStartRetention, 0.95))
        #expect(approximatelyEqual(result.scenes[0].startRetention, 0.95))
    }

    @Test func handlesEmptyInputs() {
        #expect(RetentionAnalysis.analyze(samples: [], scenes: []).insights.isEmpty)
        #expect(RetentionAnalysis.analyze(
            samples: [],
            scenes: [RetentionScene(id: "s1", start: 0, end: 10)]
        ).scenes.isEmpty)
        #expect(RetentionAnalysis.analyze(
            samples: [sample(0, 1.0)],
            scenes: []
        ).insights.isEmpty)
    }
}
