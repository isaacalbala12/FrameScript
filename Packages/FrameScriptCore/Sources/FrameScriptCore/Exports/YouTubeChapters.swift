import Foundation

/// A YouTube chapter: a frame-accurate start plus a clean title.
public struct Chapter: Sendable, Hashable {
    public let startFrame: Int
    public let title: String
    /// One-based position, used for the fallback title.
    public let position: Int

    public init(startFrame: Int, title: String, position: Int) {
        self.startFrame = startFrame
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

    public init(chapters: [Chapter], text: String, warnings: [ChapterWarning]) {
        self.chapters = chapters
        self.text = text
        self.warnings = warnings
    }

    /// YouTube needs at least three timestamps, the first at 00:00.
    public var isValidForYouTube: Bool {
        chapters.count >= 3 && chapters.first?.startFrame == 0
    }
}

/// Generates the YouTube description chapter block.
///
/// Rules verified against YouTube Help (support.google.com/youtube/answer/9884579):
/// the first timestamp starts at 0:00, there are at least three, they are
/// ascending, and each chapter lasts at least 10 seconds. Short scenes are
/// merged into the neighbouring chapter and reported as warnings.
public enum YouTubeChapters {
    public static let minimumChapterDuration: TimeInterval = 10

    public static func make(scenes: [ExportScene], rate: FrameRate = .fps25) -> ChapterList {
        guard !scenes.isEmpty else {
            let warning = ChapterWarning(
                kind: .noScenes,
                message: "No hay escenas: no se pueden generar capítulos."
            )
            return ChapterList(chapters: [], text: "", warnings: [warning])
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

        let videoEnd = scenes.reduce(0) { partial, scene in
            let start = Timecode(seconds: max(0, scene.start), rate: rate).frames
            let duration = Timecode(seconds: max(0, scene.duration), rate: rate).frames
            return max(partial, start + duration)
        }

        struct Candidate {
            var frame: Int
            var title: String
            var sceneIndex: Int
        }

        var candidates: [Candidate] = []
        for (index, scene) in sorted {
            guard scene.includesInChapters else { continue }
            let frame = Timecode(seconds: max(0, scene.start), rate: rate).frames

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
            if frame >= videoEnd {
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

            candidates.append(Candidate(frame: frame, title: title, sceneIndex: index))
        }

        guard !candidates.isEmpty else {
            warnings.append(
                ChapterWarning(
                    kind: .tooFewChapters,
                    message: "Ninguna escena entra en la lista de capítulos."
                )
            )
            return ChapterList(chapters: [], text: "", warnings: warnings)
        }

        if candidates[0].frame > 0 {
            warnings.append(
                ChapterWarning(
                    kind: .firstSceneNotAtZero,
                    message: "El primer capítulo no empezaba en 0:00; se ha ajustado al inicio del vídeo.",
                    sceneIndex: candidates[0].sceneIndex
                )
            )
            candidates[0].frame = 0
        }

        let minimumFrames = max(1, Int((minimumChapterDuration * rate.framesPerSecond).rounded(.up)))

        // Merge chapters shorter than 10 s into a neighbour until all fit.
        var changed = true
        while changed && candidates.count > 1 {
            changed = false
            for index in candidates.indices {
                let end = index + 1 < candidates.count ? candidates[index + 1].frame : videoEnd
                let span = end - candidates[index].frame
                guard span < minimumFrames else { continue }

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
            Chapter(startFrame: candidate.frame, title: candidate.title, position: position + 1)
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
            .map { "\(DurationFormat.clock(frames: $0.startFrame, rate: rate)) \($0.title)" }
            .joined(separator: "\n")

        return ChapterList(chapters: chapters, text: text, warnings: warnings)
    }

    /// Convenience for callers that only need the paste-ready block.
    public static func text(scenes: [ExportScene], rate: FrameRate = .fps25) -> String {
        make(scenes: scenes, rate: rate).text
    }
}
