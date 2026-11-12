import Foundation

/// A scene's position in the final, published video.
public struct RetentionScene: Sendable, Equatable, Hashable, Identifiable, Codable {
    public var id: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(id: String, start: TimeInterval, end: TimeInterval) {
        self.id = id
        self.start = start
        self.end = end
    }
}

public struct RetentionAnalysisConfiguration: Sendable, Equatable, Codable {
    /// Absolute drop that counts as significant, as a fraction (0.05 = 5 points).
    public var dropThreshold: Double
    /// Relative drop that counts as significant (0.10 = 10 % of the retention
    /// before the drop). The effective threshold is the larger of the two.
    public var relativeDropThreshold: Double
    /// Absolute rise that counts as a replay spike (0.05 = 5 points).
    public var spikeThreshold: Double
    /// The natural opening loss is reported separately for this many seconds.
    public var hookDuration: TimeInterval
    /// When true, drops inside the hook window are not reported as scene drops.
    public var separateHookLoss: Bool
    /// Widest span searched for a local drop/spike inside one scene.
    public var localWindow: TimeInterval

    public init(
        dropThreshold: Double = 0.05,
        relativeDropThreshold: Double = 0.10,
        spikeThreshold: Double = 0.05,
        hookDuration: TimeInterval = 30,
        separateHookLoss: Bool = true,
        localWindow: TimeInterval = 15
    ) {
        self.dropThreshold = dropThreshold
        self.relativeDropThreshold = relativeDropThreshold
        self.spikeThreshold = spikeThreshold
        self.hookDuration = hookDuration
        self.separateHookLoss = separateHookLoss
        self.localWindow = localWindow
    }
}

public enum RetentionInsightKind: String, Sendable, Equatable, Codable, CaseIterable {
    /// The natural opening loss, reported separately from scene drops.
    case hookLoss
    /// The scene ended materially lower than it started.
    case sceneDrop
    /// A temporary dip inside a scene that recovered before the scene ended.
    case localDrop
    /// A replay/rewind spike.
    case spike
}

public struct RetentionInsight: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var sceneID: String
    public var kind: RetentionInsightKind
    public var start: TimeInterval
    public var end: TimeInterval
    /// Absolute magnitude as a fraction: 0.07 means 7 percentage points.
    public var magnitude: Double
    public var retentionBefore: Double
    public var retentionAfter: Double
    /// Short diagnostic message in English. UI code should localize from
    /// `kind`, `magnitude` and the scene instead of displaying this verbatim.
    public var message: String

    public init(
        id: String,
        sceneID: String,
        kind: RetentionInsightKind,
        start: TimeInterval,
        end: TimeInterval,
        magnitude: Double,
        retentionBefore: Double,
        retentionAfter: Double,
        message: String
    ) {
        self.id = id
        self.sceneID = sceneID
        self.kind = kind
        self.start = start
        self.end = end
        self.magnitude = magnitude
        self.retentionBefore = retentionBefore
        self.retentionAfter = retentionAfter
        self.message = message
    }
}

public struct SceneRetention: Sendable, Equatable, Identifiable, Codable {
    public var sceneID: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var averageRetention: Double?
    public var startRetention: Double?
    public var endRetention: Double?
    /// End minus start. Negative means viewers were lost.
    public var delta: Double?
    public var minimumRetention: Double?
    public var maximumRetention: Double?
    public var sampleCount: Int

    public var id: String { sceneID }

    public init(
        sceneID: String,
        start: TimeInterval,
        end: TimeInterval,
        averageRetention: Double? = nil,
        startRetention: Double? = nil,
        endRetention: Double? = nil,
        delta: Double? = nil,
        minimumRetention: Double? = nil,
        maximumRetention: Double? = nil,
        sampleCount: Int = 0
    ) {
        self.sceneID = sceneID
        self.start = start
        self.end = end
        self.averageRetention = averageRetention
        self.startRetention = startRetention
        self.endRetention = endRetention
        self.delta = delta
        self.minimumRetention = minimumRetention
        self.maximumRetention = maximumRetention
        self.sampleCount = sampleCount
    }

    public var duration: TimeInterval { max(0, end - start) }
}

public struct RetentionAnalysisResult: Sendable, Equatable, Codable {
    public var scenes: [SceneRetention]
    /// Ranked by `magnitude`, descending. Includes the hook-loss insight;
    /// `hookLoss` is a convenience reference to the same value.
    public var insights: [RetentionInsight]
    public var hookLoss: RetentionInsight?
    public var overallStartRetention: Double?
    public var overallEndRetention: Double?

    public init(
        scenes: [SceneRetention],
        insights: [RetentionInsight],
        hookLoss: RetentionInsight? = nil,
        overallStartRetention: Double? = nil,
        overallEndRetention: Double? = nil
    ) {
        self.scenes = scenes
        self.insights = insights
        self.hookLoss = hookLoss
        self.overallStartRetention = overallStartRetention
        self.overallEndRetention = overallEndRetention
    }
}

/// Maps a retention curve onto scene boundaries, averages it per scene and
/// ranks the significant moments.
///
/// At most one drop insight is emitted per scene: the scene-wide start→end
/// delta when significant, otherwise the strongest temporary dip that recovered
/// before the scene ended. Spikes are reported separately.
public enum RetentionAnalysis {
    public static func analyze(
        samples: [RetentionSample],
        scenes: [RetentionScene],
        configuration: RetentionAnalysisConfiguration = RetentionAnalysisConfiguration()
    ) -> RetentionAnalysisResult {
        let curve = sanitize(samples)
        guard !curve.isEmpty, !scenes.isEmpty else {
            return RetentionAnalysisResult(scenes: [], insights: [])
        }

        let hookEnd = configuration.separateHookLoss
            ? min(configuration.hookDuration, max(curve.last?.position ?? 0, curve.first?.position ?? 0))
            : nil

        var sceneResults: [SceneRetention] = []
        sceneResults.reserveCapacity(scenes.count)
        var dropInsights: [RetentionInsight] = []
        var spikeInsights: [RetentionInsight] = []

        for scene in scenes {
            let result = analyzeScene(scene: scene, curve: curve, hookEnd: hookEnd, configuration: configuration)
            sceneResults.append(result.scene)
            if let insight = result.dropInsight { dropInsights.append(insight) }
            if let insight = result.spikeInsight { spikeInsights.append(insight) }
        }

        var hookInsight: RetentionInsight?
        if let hookEnd, hookEnd > 0, let first = curve.first, let last = curve.last {
            let startValue = first.retention
            let endValue = interpolate(curve, at: hookEnd) ?? last.retention
            let magnitude = startValue - endValue
            if magnitude >= configuration.dropThreshold, magnitude > 0 {
                let scene = scenes.first(where: { $0.start <= hookEnd && hookEnd <= $0.end })
                    ?? scenes.min(by: { abs($0.start - hookEnd) < abs($1.start - hookEnd) })
                    ?? scenes[0]
                hookInsight = RetentionInsight(
                    id: insightID(sceneID: scene.id, kind: .hookLoss, start: 0),
                    sceneID: scene.id,
                    kind: .hookLoss,
                    start: 0,
                    end: hookEnd,
                    magnitude: magnitude,
                    retentionBefore: startValue,
                    retentionAfter: endValue,
                    message: "Viewers dropped \(formatPoints(magnitude)) during the first \(formatSeconds(hookEnd)) (hook)."
                )
            }
        }

        var insights = dropInsights + spikeInsights
        if let hookInsight { insights.append(hookInsight) }
        insights.sort {
            if $0.magnitude != $1.magnitude { return $0.magnitude > $1.magnitude }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.kind.rawValue < $1.kind.rawValue
        }

        return RetentionAnalysisResult(
            scenes: sceneResults,
            insights: insights,
            hookLoss: hookInsight,
            overallStartRetention: curve.first?.retention,
            overallEndRetention: curve.last?.retention
        )
    }

    // MARK: - Per scene

    private struct SceneAnalysis {
        var scene: SceneRetention
        var dropInsight: RetentionInsight?
        var spikeInsight: RetentionInsight?
    }

    private static func analyzeScene(
        scene: RetentionScene,
        curve: [RetentionSample],
        hookEnd: TimeInterval?,
        configuration: RetentionAnalysisConfiguration
    ) -> SceneAnalysis {
        if scene.end <= scene.start {
            let value = interpolate(curve, at: scene.start) ?? curve.first?.retention
            return SceneAnalysis(
                scene: SceneRetention(
                    sceneID: scene.id,
                    start: scene.start,
                    end: scene.end,
                    averageRetention: value,
                    startRetention: value,
                    endRetention: value,
                    delta: value == nil ? nil : 0,
                    minimumRetention: value,
                    maximumRetention: value,
                    sampleCount: 0
                ),
                dropInsight: nil,
                spikeInsight: nil
            )
        }

        let startValue = interpolate(curve, at: scene.start) ?? curve.first?.retention
        let endValue = interpolate(curve, at: scene.end) ?? curve.last?.retention
        let points = pointsInScene(scene: scene, curve: curve, startValue: startValue, endValue: endValue)
        let average = trapezoidAverage(points)
        let insideSamples = curve.filter { sample in
            sample.position >= scene.start && sample.position < scene.end
        }
        let delta = zipOptional(endValue, startValue).map { $0.0 - $0.1 }

        let sceneRetention = SceneRetention(
            sceneID: scene.id,
            start: scene.start,
            end: scene.end,
            averageRetention: average,
            startRetention: startValue,
            endRetention: endValue,
            delta: delta,
            minimumRetention: points.map(\.retention).min(),
            maximumRetention: points.map(\.retention).max(),
            sampleCount: insideSamples.count
        )

        let effectiveStart: TimeInterval
        if let hookEnd, scene.start < hookEnd {
            effectiveStart = min(hookEnd, scene.end)
        } else {
            effectiveStart = scene.start
        }

        var dropInsight: RetentionInsight?
        if effectiveStart < scene.end - 0.0001,
           let before = interpolate(curve, at: effectiveStart),
           let after = interpolate(curve, at: scene.end) {
            let magnitude = before - after
            if isSignificantDrop(magnitude, before: before, configuration: configuration) {
                dropInsight = RetentionInsight(
                    id: insightID(sceneID: scene.id, kind: .sceneDrop, start: effectiveStart),
                    sceneID: scene.id,
                    kind: .sceneDrop,
                    start: effectiveStart,
                    end: scene.end,
                    magnitude: magnitude,
                    retentionBefore: before,
                    retentionAfter: after,
                    message: "Retention fell \(formatPoints(magnitude)) across this scene."
                )
            }
        }

        if dropInsight == nil,
           let local = strongestLocalDrop(
               scene: scene,
               curve: curve,
               hookEnd: hookEnd,
               configuration: configuration
           ) {
            dropInsight = local
        }

        let spike = strongestSpike(scene: scene, curve: curve, configuration: configuration)
        return SceneAnalysis(scene: sceneRetention, dropInsight: dropInsight, spikeInsight: spike)
    }

    private static func strongestLocalDrop(
        scene: RetentionScene,
        curve: [RetentionSample],
        hookEnd: TimeInterval?,
        configuration: RetentionAnalysisConfiguration
    ) -> RetentionInsight? {
        var points: [(position: Double, retention: Double)] = []
        if let value = interpolate(curve, at: scene.start) {
            points.append((scene.start, value))
        }
        for sample in curve where sample.position > scene.start && sample.position < scene.end {
            points.append((sample.position, sample.retention))
        }
        if let value = interpolate(curve, at: scene.end) {
            points.append((scene.end, value))
        }
        points.sort { $0.position < $1.position }

        guard points.count >= 2 else { return nil }
        var best: (start: Double, end: Double, before: Double, after: Double, magnitude: Double)?

        for startIndex in 0..<(points.count - 1) {
            for endIndex in (startIndex + 1)..<points.count {
                let span = points[endIndex].position - points[startIndex].position
                if span > configuration.localWindow { break }

                let effectiveStart = max(points[startIndex].position, hookEnd ?? 0)
                guard points[endIndex].position > effectiveStart + 0.0001 else { continue }
                let before = interpolate(curve, at: effectiveStart) ?? points[startIndex].retention
                let after = points[endIndex].retention
                let magnitude = before - after
                guard isSignificantDrop(magnitude, before: before, configuration: configuration) else { continue }
                if best == nil || magnitude > (best?.magnitude ?? -Double.infinity) {
                    best = (effectiveStart, points[endIndex].position, before, after, magnitude)
                }
            }
        }

        guard let best else { return nil }
        return RetentionInsight(
            id: insightID(sceneID: scene.id, kind: .localDrop, start: best.start),
            sceneID: scene.id,
            kind: .localDrop,
            start: best.start,
            end: best.end,
            magnitude: best.magnitude,
            retentionBefore: best.before,
            retentionAfter: best.after,
            message: "Retention dipped \(formatPoints(best.magnitude)) around \(formatClock(best.start))."
        )
    }

    private static func strongestSpike(
        scene: RetentionScene,
        curve: [RetentionSample],
        configuration: RetentionAnalysisConfiguration
    ) -> RetentionInsight? {
        var points: [(position: Double, retention: Double)] = []
        if let value = interpolate(curve, at: scene.start) {
            points.append((scene.start, value))
        }
        for sample in curve where sample.position > scene.start && sample.position < scene.end {
            points.append((sample.position, sample.retention))
        }
        if let value = interpolate(curve, at: scene.end) {
            points.append((scene.end, value))
        }
        points.sort { $0.position < $1.position }
        guard points.count >= 2 else { return nil }

        var best: (start: Double, end: Double, before: Double, after: Double, magnitude: Double)?
        for startIndex in 0..<(points.count - 1) {
            for endIndex in (startIndex + 1)..<points.count {
                let span = points[endIndex].position - points[startIndex].position
                if span > configuration.localWindow { break }
                let magnitude = points[endIndex].retention - points[startIndex].retention
                guard magnitude >= configuration.spikeThreshold else { continue }
                if best == nil || magnitude > (best?.magnitude ?? -Double.infinity) {
                    best = (points[startIndex].position, points[endIndex].position, points[startIndex].retention, points[endIndex].retention, magnitude)
                }
            }
        }

        guard let best else { return nil }
        return RetentionInsight(
            id: insightID(sceneID: scene.id, kind: .spike, start: best.start),
            sceneID: scene.id,
            kind: .spike,
            start: best.start,
            end: best.end,
            magnitude: best.magnitude,
            retentionBefore: best.before,
            retentionAfter: best.after,
            message: "Viewers replayed \(formatPoints(best.magnitude)) around \(formatClock(best.start))."
        )
    }

    // MARK: - Curve math

    private static func sanitize(_ samples: [RetentionSample]) -> [RetentionSample] {
        let cleaned = samples
            .filter { $0.position.isFinite && $0.retention.isFinite && $0.position >= 0 && $0.retention >= 0 }
            .sorted { $0.position < $1.position }
        guard !cleaned.isEmpty else { return [] }

        var merged: [Int: (sum: Double, count: Int)] = [:]
        for sample in cleaned {
            let key = Int((sample.position * 1000).rounded())
            var value = merged[key] ?? (0, 0)
            value.sum += sample.retention
            value.count += 1
            merged[key] = value
        }
        return merged.keys.sorted().compactMap { key in
            guard let value = merged[key] else { return nil }
            return RetentionSample(position: Double(key) / 1000, retention: value.sum / Double(value.count))
        }
    }

    static func interpolate(_ curve: [RetentionSample], at position: TimeInterval) -> Double? {
        guard let first = curve.first, let last = curve.last else { return nil }
        if position <= first.position { return first.retention }
        if position >= last.position { return last.retention }

        var low = 0
        var high = curve.count - 1
        while low + 1 < high {
            let middle = (low + high) / 2
            if curve[middle].position <= position {
                low = middle
            } else {
                high = middle
            }
        }
        let left = curve[low]
        let right = curve[high]
        let span = right.position - left.position
        guard span > 0 else { return right.retention }
        let fraction = (position - left.position) / span
        return left.retention + (right.retention - left.retention) * fraction
    }

    private static func pointsInScene(
        scene: RetentionScene,
        curve: [RetentionSample],
        startValue: Double?,
        endValue: Double?
    ) -> [(position: Double, retention: Double)] {
        var points: [(position: Double, retention: Double)] = []
        if let startValue { points.append((scene.start, startValue)) }
        for sample in curve where sample.position > scene.start && sample.position < scene.end {
            points.append((sample.position, sample.retention))
        }
        if let endValue { points.append((scene.end, endValue)) }
        points.sort { $0.position < $1.position }

        var unique: [(position: Double, retention: Double)] = []
        for point in points {
            if let last = unique.last, abs(last.position - point.position) < 0.0001 {
                continue
            }
            unique.append(point)
        }
        return unique
    }

    private static func trapezoidAverage(_ points: [(position: Double, retention: Double)]) -> Double? {
        guard let first = points.first else { return nil }
        guard points.count >= 2, let last = points.last, last.position > first.position else {
            return first.retention
        }
        var area = 0.0
        for index in 1..<points.count {
            let left = points[index - 1]
            let right = points[index]
            area += (left.retention + right.retention) / 2 * (right.position - left.position)
        }
        return area / (last.position - first.position)
    }

    private static func isSignificantDrop(
        _ magnitude: Double,
        before: Double,
        configuration: RetentionAnalysisConfiguration
    ) -> Bool {
        guard magnitude > 0 else { return false }
        let required = max(configuration.dropThreshold, configuration.relativeDropThreshold * max(before, 0))
        return magnitude >= required
    }

    // MARK: - Formatting

    private static func insightID(sceneID: String, kind: RetentionInsightKind, start: TimeInterval) -> String {
        "\(sceneID)-\(kind.rawValue)-\(Int((start * 10).rounded()))"
    }

    private static func formatPoints(_ fraction: Double) -> String {
        let points = fraction * 100
        return String(format: "%.1f points", points)
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.0f s", seconds)
    }

    private static func formatClock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let remainder = total % 60
        return String(format: "%d:%02d", minutes, remainder)
    }

    private static func zipOptional<T, U>(_ first: T?, _ second: U?) -> (T, U)? {
        guard let first, let second else { return nil }
        return (first, second)
    }
}
