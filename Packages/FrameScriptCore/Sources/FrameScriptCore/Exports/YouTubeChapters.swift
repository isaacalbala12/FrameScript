import Foundation

/// A YouTube chapter: a frame-accurate start, the timestamp YouTube will read,
/// and a clean title.
public struct Chapter: Sendable, Hashable {
    public let startFrame: Int
    /// Rounded real-time position, exactly what the chapter text prints.
    public let startSeconds: Int
    public let title: String
    /// One-based position, used for the fallback title.
    public let position: Int

    public init(startFrame: Int, startSeconds: Int, title: String, position: Int) {
        self.startFrame = startFrame
        self.startSeconds = startSeconds
        self.title = title
        self.position = position
    }
}

public struct ChapterWarning: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case noScenes
        case tooFewChapters
        case firstSceneNotAtZero
        case unsortedScenes
        case duplicateStart
        case duplicateTimestamp
        case shortSceneMerged
        case emptyTitle
        case titleTruncated
        case sceneOutsideVideo
    }

    public let kind: Kind
    public let message: String
    public let sceneIndex: Int?

    public init(kind: Kind, message: String, sceneIndex: Int? = nil) {
        self.kind = kind
        self.message = message
        self.sceneIndex = sceneIndex
    }
}

/// Result of chapter generation: paste-ready text plus everything that was
/// merged, clamped or skipped on the way.
public struct ChapterList: Sendable, Hashable {
    public let chapters: [Chapter]
    public let text: String
    public let warnings: [ChapterWarning]
    /// Rounded real-time end of the video, used to validate the last chapter.
    public let videoEndSeconds: Int

    public init(
        chapters: [Chapter],
        text: String,
        warnings: [ChapterWarning],
        videoEndSeconds: Int
    ) {
        self.chapters = chapters
        self.text = text
        self.warnings = warnings
        self.videoEndSeconds = videoEndSeconds
    }

    /// YouTube needs at least three timestamps, the first at 00:00, and each
    /// displayed chapter must span at least 10 seconds.
    public var isValidForYouTube: Bool {
        let minimum = Int(YouTubeChapters.minimumChapterDuration)
        guard chapters.count >= 3, chapters.first?.startSeconds == 0 else { return false }
        for index in 0..<(chapters.count - 1) {
            if chapters[index + 1].startSeconds - chapters[index].startSeconds < minimum {
                return false
            }
        }
        guard let last = chapters.last else { return false }
        return videoEndSeconds - last.startSeconds >= minimum
    }
}

/// Generates the YouTube description chapter block.
///
/// Rules verified against YouTube Help (support.google.com/youtube/answer/9884579):
/// the first timestamp starts at 0:00, there are at least three, they are
/// ascending, and each chapter lasts at least 10 seconds.
///
/// YouTube reads the rounded timestamps, not frame numbers, so both the
/// displayed positions and the 10-second minimum are computed in real-time
/// seconds. This keeps 29.97 from printing 19:59 for a 20:00 scene and keeps
/// ordinary 10-second chapters at 59.94.
///
/// `rate` defaults to 25 fps for the project's default workflow. Pass the
/// project rate, or use `make(scenes:settings:)`, for other frame rates.
public enum YouTubeChapters {
    public static let minimumChapterDuration: TimeInterval = 10

    public static func make(scenes: [ExportScene], rate: FrameRate = .fps25) -> ChapterList {
        guard !scenes.isEmpty else {
            let warning = ChapterWarning(
                kind: .noScenes,
                message: "No hay escenas: no se pueden generar capítulos."
            )
            return ChapterList(chapters: [], text: "", warnings: [warning], videoEndSeconds: 0)
        }

        var warnings: [ChapterWarning] = []

        let indexed = scenes.enumerated()
        let sorted = indexed.sorted { lhs, rhs in
            if lhs.element.start == rhs.element.start { return lhs.offset < rhs.offset }
            return lhs.element.start < rhs.element.start
        }

        if sorted.map(\.offset) != Array(scenes.indices) {
            warnings.append(
                ChapterWarning(
                    kind: .unsortedScenes,
                    message: "Las escenas no venían ordenadas por tiempo; se han ordenado para los capítulos."
                )
            )
        }

        let videoEndFrame = scenes.reduce(0) { partial, scene in
            let end = Timecode(
                seconds: max(0, scene.start) + max(0, scene.duration),
                rate: rate
            ).frames
            return max(partial, end)
        }
        let videoEndSeconds = displaySeconds(frames: videoEndFrame, rate: rate)

        struct Candidate {
            var frame: Int
            var seconds: Int
            var title: String
            var sceneIndex: Int
        }

        var candidates: [Candidate] = []
        for (index, scene) in sorted {
            guard scene.includesInChapters else { continue }
            let frame = Timecode(seconds: max(0, scene.start), rate: rate).frames
            let seconds = displaySeconds(frames: frame, rate: rate)

            if let last = candidates.last, last.frame == frame {
                warnings.append(
                    ChapterWarning(
                        kind: .duplicateStart,
                        message: "«\(scene.title)» empieza en el mismo fotograma que la escena anterior; se omite como capítulo.",
                        sceneIndex: index
                    )
                )
                continue
            }
            if let last = candidates.last, last.seconds == seconds {
                warnings.append(
                    ChapterWarning(
                        kind: .duplicateTimestamp,
                        message: "«\(scene.title)» comparte el timestamp \(DurationFormat.clock(seconds: seconds)) con la escena anterior; se omite como capítulo.",
                        sceneIndex: index
                    )
                )
                continue
            }
            if frame >= videoEndFrame {
                warnings.append(
                    ChapterWarning(
                        kind: .sceneOutsideVideo,
                        message: "«\(scene.title)» empieza en o después del final del vídeo; se omite como capítulo.",
                        sceneIndex: index
                    )
                )
                continue
            }

            let rawTitle = scene.chapterTitle ?? scene.title
            let cleaned = ExportTextSanitizer.chapterTitle(rawTitle)
            var title = cleaned.text
            if cleaned.wasTruncated {
                warnings.append(
                    ChapterWarning(
                        kind: .titleTruncated,
                        message: "El título de «\(scene.title)» supera los 60 caracteres y se ha recortado.",
                        sceneIndex: index
                    )
                )
            }
            if title.isEmpty {
                title = "Capítulo \(candidates.count + 1)"
                warnings.append(
                    ChapterWarning(
                        kind: .emptyTitle,
                        message: "Una escena no tiene título; se usa «\(title)».",
                        sceneIndex: index
                    )
                )
            }

            candidates.append(
                Candidate(frame: frame, seconds: seconds, title: title, sceneIndex: index)
            )
        }

        guard !candidates.isEmpty else {
            warnings.append(
                ChapterWarning(
                    kind: .tooFewChapters,
                    message: "Ninguna escena entra en la lista de capítulos."
                )
            )
            return ChapterList(chapters: [], text: "", warnings: warnings, videoEndSeconds: videoEndSeconds)
        }

        if candidates[0].seconds > 0 || candidates[0].frame > 0 {
            if candidates[0].seconds > 0 {
                warnings.append(
                    ChapterWarning(
                        kind: .firstSceneNotAtZero,
                        message: "El primer capítulo no empezaba en 0:00; se ha ajustado al inicio del vídeo.",
                        sceneIndex: candidates[0].sceneIndex
                    )
                )
            }
            candidates[0].frame = 0
            candidates[0].seconds = 0
        }

        let minimumSeconds = Int(minimumChapterDuration)

        // Merge chapters shorter than 10 displayed seconds into a neighbour.
        var changed = true
        while changed && candidates.count > 1 {
            changed = false
            for index in candidates.indices {
                let endSeconds = index + 1 < candidates.count
                    ? candidates[index + 1].seconds
                    : videoEndSeconds
                let span = endSeconds - candidates[index].seconds
                guard span < minimumSeconds else { continue }

                if index == 0 {
                    // First chapter too short: it absorbs the next boundary.
                    let shortTitle = candidates[0].title
                    let shortScene = candidates[0].sceneIndex
                    let nextTitle = candidates[1].title
                    candidates.remove(at: 1)
                    warnings.append(
                        ChapterWarning(
                            kind: .shortSceneMerged,
                            message: "«\(shortTitle)» dura menos de 10 s; se fusiona con «\(nextTitle)» en un solo capítulo.",
                            sceneIndex: shortScene
                        )
                    )
                } else {
                    let removed = candidates.remove(at: index)
                    warnings.append(
                        ChapterWarning(
                            kind: .shortSceneMerged,
                            message: "«\(removed.title)» dura menos de 10 s; se ha fusionado con «\(candidates[index - 1].title)».",
                            sceneIndex: removed.sceneIndex
                        )
                    )
                }
                changed = true
                break
            }
        }

        let chapters = candidates.enumerated().map { position, candidate in
            Chapter(
                startFrame: candidate.frame,
                startSeconds: candidate.seconds,
                title: candidate.title,
                position: position + 1
            )
        }

        if chapters.count < 3 {
            warnings.append(
                ChapterWarning(
                    kind: .tooFewChapters,
                    message: "YouTube necesita al menos 3 capítulos y solo se han podido formar \(chapters.count)."
                )
            )
        }

        let text = chapters
            .map { "\(DurationFormat.clock(seconds: $0.startSeconds)) \($0.title)" }
            .joined(separator: "\n")

        return ChapterList(
            chapters: chapters,
            text: text,
            warnings: warnings,
            videoEndSeconds: videoEndSeconds
        )
    }

    public static func make(scenes: [ExportScene], settings: ExportSettings) -> ChapterList {
        make(scenes: scenes, rate: settings.fps)
    }

    /// Convenience for callers that only need the paste-ready block.
    public static func text(scenes: [ExportScene], rate: FrameRate = .fps25) -> String {
        make(scenes: scenes, rate: rate).text
    }

    /// Rounds a frame position to the second YouTube will display.
    private static func displaySeconds(frames: Int, rate: FrameRate) -> Int {
        Int((Double(frames) * Double(rate.denominator) / Double(rate.numerator)).rounded())
    }
}
