import Foundation

/// The export-facing scene. Deliberately small and UI-free so the app, the CLI
/// and the MCP server can all build it from their own models.
public struct ExportScene: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    /// Full title, as written by the creator.
    public var title: String
    /// Timeline position in seconds from the start of the video.
    public var start: TimeInterval
    /// Planned duration in seconds.
    public var duration: TimeInterval
    /// Marks the scene as a re-hook; the pack emits an extra purple marker.
    public var isRehook: Bool
    /// Extra cue markers, with offsets relative to the scene start.
    public var markers: [ExportMarker]
    /// Shot list rows for this scene.
    public var shots: [ExportShot]
    /// Optional script excerpt for the editing notes.
    public var scriptExcerpt: String?
    /// Editing notes (`MONTAJE` bullets).
    public var editingNotes: [String]
    /// Rigour / claim warnings (`AVISOS` bullets).
    public var warnings: [String]
    /// Target duration in seconds, if the project sets one.
    public var targetDuration: TimeInterval?
    /// Optional chapter title overriding `title`.
    public var chapterTitle: String?
    /// When false the scene is skipped and its duration is absorbed.
    public var includesInChapters: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        start: TimeInterval,
        duration: TimeInterval,
        isRehook: Bool = false,
        markers: [ExportMarker] = [],
        shots: [ExportShot] = [],
        scriptExcerpt: String? = nil,
        editingNotes: [String] = [],
        warnings: [String] = [],
        targetDuration: TimeInterval? = nil,
        chapterTitle: String? = nil,
        includesInChapters: Bool = true
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.duration = duration
        self.isRehook = isRehook
        self.markers = markers
        self.shots = shots
        self.scriptExcerpt = scriptExcerpt
        self.editingNotes = editingNotes
        self.warnings = warnings
        self.targetDuration = targetDuration
        self.chapterTitle = chapterTitle
        self.includesInChapters = includesInChapters
    }
}

/// A cue marker inside a scene. `offset` is relative to the scene start.
public struct ExportMarker: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var offset: TimeInterval
    public var name: String
    public var note: String
    public var color: ExportMarkerColor
    /// 1 for a point marker; larger values make a range marker (`|D:`).
    public var durationFrames: Int

    public init(
        id: UUID = UUID(),
        offset: TimeInterval,
        name: String,
        note: String = "",
        color: ExportMarkerColor = .blue,
        durationFrames: Int = 1
    ) {
        self.id = id
        self.offset = offset
        self.name = name
        self.note = note
        self.color = color
        self.durationFrames = max(1, durationFrames)
    }
}

/// One row of the shot list.
public struct ExportShot: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var summary: String
    public var source: ExportSourceTag
    public var status: ExportShotStatus
    public var notes: String
    /// Optional offset within the scene; defaults to the scene start.
    public var offset: TimeInterval?

    public init(
        id: UUID = UUID(),
        summary: String,
        source: ExportSourceTag = .cam,
        status: ExportShotStatus = .pending,
        notes: String = "",
        offset: TimeInterval? = nil
    ) {
        self.id = id
        self.summary = summary
        self.source = source
        self.status = status
        self.notes = notes
        self.offset = offset
    }
}

/// Resolve marker colours. These are the 16 names accepted by Resolve's
/// scripting API and written in marker EDL comments as `ResolveColor<Name>`.
public enum ExportMarkerColor: String, Sendable, Hashable, Codable, CaseIterable {
    case blue = "ResolveColorBlue"
    case cyan = "ResolveColorCyan"
    case green = "ResolveColorGreen"
    case yellow = "ResolveColorYellow"
    case red = "ResolveColorRed"
    case pink = "ResolveColorPink"
    case purple = "ResolveColorPurple"
    case fuchsia = "ResolveColorFuchsia"
    case rose = "ResolveColorRose"
    case lavender = "ResolveColorLavender"
    case sky = "ResolveColorSky"
    case mint = "ResolveColorMint"
    case lemon = "ResolveColorLemon"
    case sand = "ResolveColorSand"
    case cocoa = "ResolveColorCocoa"
    case cream = "ResolveColorCream"

    /// Spanish label for the editing notes and the colour legend.
    public var spanishName: String {
        switch self {
        case .blue: "azul"
        case .cyan: "cian"
        case .green: "verde"
        case .yellow: "amarillo"
        case .red: "rojo"
        case .pink: "rosa"
        case .purple: "morado"
        case .fuchsia: "fucsia"
        case .rose: "granate"
        case .lavender: "lavanda"
        case .sky: "celeste"
        case .mint: "menta"
        case .lemon: "limón"
        case .sand: "arena"
        case .cocoa: "cacao"
        case .cream: "crema"
        }
    }

    /// Default colour used for each kind of note.
    public static func suggested(for source: ExportSourceTag) -> ExportMarkerColor {
        switch source {
        case .cam: .green
        case .obs: .yellow
        case .capture, .web: .pink
        case .music: .lavender
        case .graphic: .lemon
        }
    }
}

/// Footage source tag used by the shot list.
public enum ExportSourceTag: String, Sendable, Hashable, Codable, CaseIterable {
    case cam = "CAM"
    case obs = "OBS"
    case capture = "captura"
    case web = "web"
    case music = "música"
    case graphic = "gráfico"

    public var displayName: String { rawValue }
}

public enum ExportShotStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case pending = "pendiente"
    case recorded = "grabado"
    case approved = "aprobado"
    case discarded = "descartado"

    public var displayName: String { rawValue }
}

/// Timeline and file settings for the Resolve / YouTube pack.
public struct ExportSettings: Sendable, Hashable, Codable {
    public var projectName: String
    /// The frame rate is fixed at init so the default start timecode cannot go
    /// stale. Use `with(fps:…)` to change it.
    public let fps: FrameRate
    public let dropFrame: Bool
    /// Absolute timeline timecode where frame 0 sits.
    public var startTimecode: Timecode
    /// Transliterate marker names and the EDL title to ASCII.
    public var asciiSafeNames: Bool
    /// Also emit FCPXML `chapter-marker` elements. Resolve may ignore them.
    public var includeChapterMarkers: Bool
    /// Prefix the CSV with a UTF-8 byte-order mark. Off by default so the
    /// output stays strict RFC 4180; turn it on for Excel.
    public var csvIncludesByteOrderMark: Bool
    /// Prefix cells starting with = + - @ with an apostrophe so spreadsheet
    /// apps do not evaluate them as formulas. Off by default to preserve data.
    public var csvEscapesFormulas: Bool

    public init(
        projectName: String = "FrameScript",
        fps: FrameRate = .fps25,
        dropFrame: Bool = false,
        startTimecode: Timecode? = nil,
        asciiSafeNames: Bool = true,
        includeChapterMarkers: Bool = false,
        csvIncludesByteOrderMark: Bool = false,
        csvEscapesFormulas: Bool = false
    ) {
        self.projectName = projectName
        self.fps = fps
        self.dropFrame = dropFrame
        self.startTimecode = startTimecode ?? Timecode.oneHour(rate: fps, dropFrame: dropFrame)
        self.asciiSafeNames = asciiSafeNames
        self.includeChapterMarkers = includeChapterMarkers
        self.csvIncludesByteOrderMark = csvIncludesByteOrderMark
        self.csvEscapesFormulas = csvEscapesFormulas
    }

    /// Returns a copy with a new rate. When the rate changes, the default
    /// 01:00:00:00 start is recomputed unless an explicit one is supplied.
    public func with(
        fps newFPS: FrameRate? = nil,
        dropFrame newDropFrame: Bool? = nil,
        startTimecode newStartTimecode: Timecode? = nil
    ) -> ExportSettings {
        let rateChanged = (newFPS != nil && newFPS != fps)
            || (newDropFrame != nil && newDropFrame != dropFrame)
        let resolvedStart = newStartTimecode ?? (rateChanged ? nil : startTimecode)
        return ExportSettings(
            projectName: projectName,
            fps: newFPS ?? fps,
            dropFrame: newDropFrame ?? dropFrame,
            startTimecode: resolvedStart,
            asciiSafeNames: asciiSafeNames,
            includeChapterMarkers: includeChapterMarkers,
            csvIncludesByteOrderMark: csvIncludesByteOrderMark,
            csvEscapesFormulas: csvEscapesFormulas
        )
    }

    /// Drop frame is silently disabled for rates that do not support it.
    public var effectiveDropFrame: Bool {
        dropFrame && fps.supportsDropFrame
    }

    public var timecodeFormatLabel: String {
        effectiveDropFrame ? "DF" : "NDF"
    }

    /// Human-readable issues worth surfacing in the delivery UI.
    public var validationWarnings: [String] {
        var warnings: [String] = []
        if dropFrame && !fps.supportsDropFrame {
            warnings.append("Drop frame no existe a \(fps) fps; se exporta como NON-DROP FRAME.")
        }
        if projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append("El proyecto no tiene nombre; se usará «FrameScript».")
        }
        return warnings
    }
}

/// A marker flattened onto the absolute timeline.
public struct ResolvedMarker: Sendable, Hashable {
    public enum Kind: Int, Sendable, Hashable {
        case scene = 0
        case rehook = 1
        case cue = 2
    }

    public var frame: Int
    public var name: String
    public var note: String
    public var color: ExportMarkerColor
    public var durationFrames: Int
    public var kind: Kind
    public var sceneIndex: Int
}

public struct MarkerWarning: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case duplicateFrame
        case tooManyEvents
    }

    public let kind: Kind
    public let message: String
    public let frame: Int?

    public init(kind: Kind, message: String, frame: Int? = nil) {
        self.kind = kind
        self.message = message
        self.frame = frame
    }
}

public struct MarkerResolution: Sendable, Hashable {
    public let markers: [ResolvedMarker]
    public let warnings: [MarkerWarning]

    public init(markers: [ResolvedMarker], warnings: [MarkerWarning]) {
        self.markers = markers
        self.warnings = warnings
    }
}

public enum ExportMarkerResolver {
    /// Flattens scene markers, cue markers and re-hook markers onto the
    /// timeline, sorted by frame, without merging collisions.
    ///
    /// Re-hook markers sit one frame after the scene marker so they do not
    /// stack on it. Cue offsets are rounded together with the scene start so
    /// the EDL/FCPXML frame matches the CSV frame.
    public static func allMarkers(scenes: [ExportScene], settings: ExportSettings) -> [ResolvedMarker] {
        let indexed = scenes.enumerated().sorted { lhs, rhs in
            if lhs.element.start == rhs.element.start { return lhs.offset < rhs.offset }
            return lhs.element.start < rhs.element.start
        }

        var resolved: [ResolvedMarker] = []
        for (position, entry) in indexed.enumerated() {
            let index = entry.offset
            let scene = entry.element
            let sceneStart = max(0, scene.start)
            let startFrame = Timecode(seconds: sceneStart, rate: settings.fps).frames
            let sceneNumber = String(format: "%02d", position)
            let title = scene.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = title.isEmpty ? "Escena" : title

            resolved.append(
                ResolvedMarker(
                    frame: startFrame,
                    name: "\(sceneNumber) \(displayTitle)",
                    note: scene.isRehook ? "Escena con re-hook" : "Inicio de escena",
                    color: .blue,
                    durationFrames: 1,
                    kind: .scene,
                    sceneIndex: index
                )
            )

            if scene.isRehook {
                resolved.append(
                    ResolvedMarker(
                        frame: startFrame + 1,
                        name: "\(sceneNumber) Re-hook \(displayTitle)",
                        note: "Punto de re-enganche",
                        color: .purple,
                        durationFrames: 1,
                        kind: .rehook,
                        sceneIndex: index
                    )
                )
            }

            for marker in scene.markers {
                let absoluteSeconds = sceneStart + max(0, marker.offset)
                let absoluteFrame = Timecode(seconds: absoluteSeconds, rate: settings.fps).frames
                resolved.append(
                    ResolvedMarker(
                        frame: absoluteFrame,
                        name: marker.name,
                        note: marker.note,
                        color: marker.color,
                        durationFrames: max(1, marker.durationFrames),
                        kind: .cue,
                        sceneIndex: index
                    )
                )
            }
        }

        return resolved.sorted { lhs, rhs in
            if lhs.frame != rhs.frame { return lhs.frame < rhs.frame }
            if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.name < rhs.name
        }
    }

    /// Resolves markers and merges any that share a frame.
    ///
    /// Resolve stores one marker per frame, so two events at the same record
    /// timecode cannot both survive. The scene (or re-hook) marker is kept and
    /// the colliding marker's name and note are appended to its note; the
    /// collision is reported as a warning.
    public static func resolve(scenes: [ExportScene], settings: ExportSettings) -> MarkerResolution {
        let raw = allMarkers(scenes: scenes, settings: settings)
        var groups: [Int: [ResolvedMarker]] = [:]
        for marker in raw {
            groups[marker.frame, default: []].append(marker)
        }

        var merged: [ResolvedMarker] = []
        var warnings: [MarkerWarning] = []

        for frame in groups.keys.sorted() {
            let group = groups[frame] ?? []
            guard var primary = group.first else { continue }
            for dropped in group.dropFirst() {
                let addition = dropped.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? dropped.name
                    : "\(dropped.name): \(dropped.note)"
                primary.note = primary.note.isEmpty ? addition : "\(primary.note) · \(addition)"
                primary.durationFrames = max(primary.durationFrames, dropped.durationFrames)
                warnings.append(
                    MarkerWarning(
                        kind: .duplicateFrame,
                        message: "«\(dropped.name)» coincide en el fotograma \(frame) con «\(primary.name)»; se ha fusionado en su nota.",
                        frame: frame
                    )
                )
            }
            merged.append(primary)
        }

        if merged.count > 999 {
            warnings.append(
                MarkerWarning(
                    kind: .tooManyEvents,
                    message: "Hay \(merged.count) marcadores; CMX3600 solo admite 999 eventos. Resolve puede ignorar los últimos."
                )
            )
        }

        return MarkerResolution(markers: merged, warnings: warnings)
    }

    /// Deduplicated markers, ready to write to EDL or FCPXML.
    public static func markers(scenes: [ExportScene], settings: ExportSettings) -> [ResolvedMarker] {
        resolve(scenes: scenes, settings: settings).markers
    }

    /// Last frame covered by scenes and markers, at least one frame long.
    public static func timelineEndFrame(scenes: [ExportScene], settings: ExportSettings) -> Int {
        var end = 1
        for scene in scenes {
            let sceneEnd = Timecode(
                seconds: max(0, scene.start) + max(0, scene.duration),
                rate: settings.fps
            ).frames
            end = max(end, sceneEnd)
        }
        for marker in allMarkers(scenes: scenes, settings: settings) {
            end = max(end, marker.frame + marker.durationFrames)
        }
        return end
    }
}
