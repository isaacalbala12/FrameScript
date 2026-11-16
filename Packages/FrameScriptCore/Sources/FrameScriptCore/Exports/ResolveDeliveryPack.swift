import Foundation

/// Resolve marker colours for the delivery legend.
///
/// Resolve 21 accepts sixteen marker colours and none of them is called
/// "Orange" (see `ExportMarkerColor`). Graphics and tables therefore use
/// `sand`, the warm orange-brown Resolve ships, and the pack README says so.
public enum ResolveMarkerLegend {
    public static let scene: ExportMarkerColor = .blue
    public static let camera: ExportMarkerColor = .green
    public static let gameplay: ExportMarkerColor = .yellow
    public static let screen: ExportMarkerColor = .pink
    public static let warning: ExportMarkerColor = .red
    public static let rehook: ExportMarkerColor = .purple
    public static let graphic: ExportMarkerColor = .sand
    public static let music: ExportMarkerColor = .lavender

    public static func color(for source: ExportSourceTag) -> ExportMarkerColor {
        switch source {
        case .cam: camera
        case .obs: gameplay
        case .capture, .web: screen
        case .graphic: graphic
        case .music: music
        }
    }
}

/// Everything the delivery sheet can change about the exported pack.
public struct ResolvePackOptions: Sendable, Hashable, Codable {
    public var fps: FrameRate
    public var dropFrame: Bool
    public var startTimecode: Timecode
    /// Transliterate marker names and the EDL title to ASCII.
    public var asciiSafeNames: Bool
    public var includeMarkerEDL: Bool
    public var includeFCPXML: Bool
    public var includeShotList: Bool
    public var includeEditingNotes: Bool
    public var includeChapters: Bool
    public var includeChapterMarkersInFCPXML: Bool
    public var includeReadme: Bool

    public init(
        fps: FrameRate = .fps25,
        dropFrame: Bool = false,
        startTimecode: Timecode? = nil,
        asciiSafeNames: Bool = true,
        includeMarkerEDL: Bool = true,
        includeFCPXML: Bool = true,
        includeShotList: Bool = true,
        includeEditingNotes: Bool = true,
        includeChapters: Bool = true,
        includeChapterMarkersInFCPXML: Bool = true,
        includeReadme: Bool = true
    ) {
        self.fps = fps
        self.dropFrame = dropFrame && fps.supportsDropFrame
        self.startTimecode = startTimecode
            ?? Timecode.oneHour(rate: fps, dropFrame: dropFrame && fps.supportsDropFrame)
        self.asciiSafeNames = asciiSafeNames
        self.includeMarkerEDL = includeMarkerEDL
        self.includeFCPXML = includeFCPXML
        self.includeShotList = includeShotList
        self.includeEditingNotes = includeEditingNotes
        self.includeChapters = includeChapters
        self.includeChapterMarkersInFCPXML = includeChapterMarkersInFCPXML
        self.includeReadme = includeReadme
    }

    /// Returns a copy with a new rate. Changing the rate recomputes the default
    /// 01:00:00:00 start so 29.97 DF does not inherit the 25 fps frame count
    /// and land an hour off.
    public func with(
        fps newFPS: FrameRate? = nil,
        dropFrame newDropFrame: Bool? = nil,
        startTimecode newStartTimecode: Timecode? = nil
    ) -> ResolvePackOptions {
        let rateChanged = (newFPS != nil && newFPS != fps)
            || (newDropFrame != nil && newDropFrame != dropFrame)
        let resolvedStart = newStartTimecode ?? (rateChanged ? nil : startTimecode)
        return ResolvePackOptions(
            fps: newFPS ?? fps,
            dropFrame: newDropFrame ?? dropFrame,
            startTimecode: resolvedStart,
            asciiSafeNames: asciiSafeNames,
            includeMarkerEDL: includeMarkerEDL,
            includeFCPXML: includeFCPXML,
            includeShotList: includeShotList,
            includeEditingNotes: includeEditingNotes,
            includeChapters: includeChapters,
            includeChapterMarkersInFCPXML: includeChapterMarkersInFCPXML,
            includeReadme: includeReadme
        )
    }

    public var hasAnyFile: Bool {
        includeMarkerEDL || includeFCPXML || includeShotList
            || includeEditingNotes || includeChapters || includeReadme
    }

    public func settings(projectName: String) -> ExportSettings {
        ExportSettings(
            projectName: projectName,
            fps: fps,
            dropFrame: dropFrame,
            startTimecode: startTimecode,
            asciiSafeNames: asciiSafeNames,
            includeChapterMarkers: includeFCPXML && includeChapterMarkersInFCPXML
        )
    }
}

/// File and folder names inside the delivery bundle.
public struct ResolvePackNames: Sendable, Hashable {
    public let folder: String
    public let markerEDL: String
    public let fcpxml: String
    public let shotList: String
    public let editingNotes: String
    public let chapters: String
    public let readme: String

    public init(folder: String, markerEDL: String, fcpxml: String, shotList: String, editingNotes: String, chapters: String, readme: String = "README.md") {
        self.folder = folder
        self.markerEDL = markerEDL
        self.fcpxml = fcpxml
        self.shotList = shotList
        self.editingNotes = editingNotes
        self.chapters = chapters
        self.readme = readme
    }

    /// Every name the pack can write. Used to clean stale files on re-export.
    public var all: [String] {
        [markerEDL, fcpxml, shotList, editingNotes, chapters, readme]
    }
}

public enum ResolvePackNaming {
    /// Filesystem-safe project slug. ASCII-safe transliterates accents,
    /// question marks and emoji; otherwise the original Unicode survives.
    public static func slug(_ name: String, asciiSafe: Bool) -> String {
        var text = ExportTextSanitizer.collapseWhitespace(name)
        text = asciiSafe
            ? ExportTextSanitizer.asciiSafe(text)
            : ExportTextSanitizer.stripEmoji(ExportTextSanitizer.stripMarkdown(text))
        text = ExportTextSanitizer.stripControlCharacters(text)

        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        text = text.unicodeScalars
            .map { forbidden.contains($0) ? "-" : String($0) }
            .joined()
        text = ExportTextSanitizer.collapseWhitespace(text)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))

        let capped = ExportTextSanitizer.truncated(text, limit: 80).text
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        return capped.isEmpty ? "FrameScript" : capped
    }

    public static func names(projectName: String, asciiSafe: Bool) -> ResolvePackNames {
        let base = slug(projectName, asciiSafe: asciiSafe)
        return ResolvePackNames(
            folder: "\(base)_resolve",
            markerEDL: "\(base)_markers.edl",
            fcpxml: "\(base).fcpxml",
            shotList: "\(base)_shots.csv",
            editingNotes: "\(base)_edit_notes.md",
            chapters: "\(base)_chapters.txt"
        )
    }
}

/// One file ready to be written.
public struct ResolvePackFile: Sendable, Hashable, Identifiable {
    public let name: String
    public let data: Data

    public var id: String { name }

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    public init(name: String, text: String) {
        self.init(name: name, data: Data(text.utf8))
    }

    public var text: String? {
        String(data: data, encoding: .utf8)
    }
}

/// A marker as the delivery sheet previews it.
public struct ResolveMarkerPreview: Sendable, Hashable, Identifiable {
    public let frame: Int
    public let timecode: String
    public let name: String
    public let note: String
    public let color: ExportMarkerColor
    public let durationFrames: Int
    public let kind: ResolvedMarker.Kind

    public var id: String { "\(frame):\(name):\(color.rawValue)" }
}

/// Everything the sheet needs before writing anything: the scene snapshot, the
/// marker list, the warnings and the file names.
public struct ResolvePackPlan: Sendable {
    public let projectName: String
    public let names: ResolvePackNames
    public let options: ResolvePackOptions
    public let settings: ExportSettings
    public let scenes: [ExportScene]
    /// Markers after Resolve's one-per-frame collision merge.
    public let markers: [ResolvedMarker]
    /// Markers before the collision merge, in scene + re-hook + cue order.
    public let allMarkers: [ResolvedMarker]
    public let chapters: ChapterList
    public let warnings: [String]

    public init(
        projectName: String,
        names: ResolvePackNames,
        options: ResolvePackOptions,
        settings: ExportSettings,
        scenes: [ExportScene],
        markers: [ResolvedMarker],
        allMarkers: [ResolvedMarker],
        chapters: ChapterList,
        warnings: [String]
    ) {
        self.projectName = projectName
        self.names = names
        self.options = options
        self.settings = settings
        self.scenes = scenes
        self.markers = markers
        self.allMarkers = allMarkers
        self.chapters = chapters
        self.warnings = warnings
    }

    public var sceneCount: Int { scenes.count }

    /// Re-hooks and cues count as cues; every cue should have its own marker
    /// before Resolve's one-per-frame merge.
    public var cueCount: Int { allMarkers.filter { $0.kind != .scene }.count }

    public var durationFrames: Int {
        ExportMarkerResolver.timelineEndFrame(scenes: scenes, settings: settings)
    }

    public var durationSeconds: TimeInterval {
        Double(durationFrames) * Double(settings.fps.denominator) / Double(settings.fps.numerator)
    }

    public var prefixedTimecode: String {
        "\(settings.startTimecode.string(rate: settings.fps, dropFrame: settings.effectiveDropFrame)) · \(settings.fps) fps · \(settings.timecodeFormatLabel)"
    }

    /// Marker rows with absolute timecodes, exactly as the EDL writes them.
    public var markerPreviews: [ResolveMarkerPreview] {
        markers.map { marker in
            let timecode = Timecode(frames: settings.startTimecode.frames + marker.frame)
                .string(rate: settings.fps, dropFrame: settings.effectiveDropFrame)
            return ResolveMarkerPreview(
                frame: marker.frame,
                timecode: timecode,
                name: ExportTextSanitizer.markerName(
                    marker.name,
                    asciiSafe: settings.asciiSafeNames
                ),
                note: ExportTextSanitizer.markerNote(
                    marker.note,
                    asciiSafe: settings.asciiSafeNames
                ),
                color: marker.color,
                durationFrames: marker.durationFrames,
                kind: marker.kind
            )
        }
    }

    public func numberOfMarkers(of kind: ResolvedMarker.Kind) -> Int {
        markers.filter { $0.kind == kind }.count
    }
}

public enum ResolveDeliveryPack {
    /// Builds the plan and every warning the sheet shows before exporting.
    ///
    /// `extraWarnings` carries scene-mapping issues from the app (missing
    /// anchors, missing language variants) so they live next to the writer
    /// warnings.
    public static func plan(
        scenes: [ExportScene],
        projectName: String,
        options: ResolvePackOptions,
        extraWarnings: [String] = []
    ) -> ResolvePackPlan {
        let settings = options.settings(projectName: projectName)
        let names = ResolvePackNaming.names(
            projectName: projectName,
            asciiSafe: options.asciiSafeNames
        )
        let resolution = ExportMarkerResolver.resolve(scenes: scenes, settings: settings)
        let allMarkers = ExportMarkerResolver.allMarkers(scenes: scenes, settings: settings)
        let chapters = YouTubeChapters.make(scenes: scenes, rate: settings.fps)

        var warnings: [String] = []
        warnings.append(contentsOf: extraWarnings)
        warnings.append(contentsOf: settings.validationWarnings)
        warnings.append(contentsOf: resolution.warnings.map(\.message))
        if options.includeChapters || (options.includeFCPXML && options.includeChapterMarkersInFCPXML) {
            warnings.append(contentsOf: chapters.warnings.map(\.message))
        }
        warnings.append(contentsOf: truncationWarnings(
            markers: resolution.markers,
            settings: settings
        ))

        var seen = Set<String>()
        let uniqueWarnings = warnings.filter { seen.insert($0).inserted }

        return ResolvePackPlan(
            projectName: projectName,
            names: names,
            options: options,
            settings: settings,
            scenes: scenes,
            markers: resolution.markers,
            allMarkers: allMarkers,
            chapters: chapters,
            warnings: uniqueWarnings
        )
    }

    /// Renders the files selected in the plan. No file is written here.
    public static func files(for plan: ResolvePackPlan) -> [ResolvePackFile] {
        var files: [ResolvePackFile] = []
        let scenes = plan.scenes
        let settings = plan.settings
        let names = plan.names

        if plan.options.includeMarkerEDL {
            files.append(ResolvePackFile(
                name: names.markerEDL,
                text: ResolveMarkerEDL.make(scenes: scenes, settings: settings)
            ))
        }
        if plan.options.includeFCPXML {
            files.append(ResolvePackFile(
                name: names.fcpxml,
                text: ResolveFCPXML.make(scenes: scenes, settings: settings)
            ))
        }
        if plan.options.includeShotList {
            files.append(ResolvePackFile(
                name: names.shotList,
                data: ShotListCSV.makeData(scenes: scenes, settings: settings)
            ))
        }
        if plan.options.includeEditingNotes {
            files.append(ResolvePackFile(
                name: names.editingNotes,
                text: EditingNotesMarkdown.make(scenes: scenes, settings: settings)
            ))
        }
        if plan.options.includeChapters {
            let text = plan.chapters.text.isEmpty ? "" : plan.chapters.text + "\n"
            files.append(ResolvePackFile(name: names.chapters, text: text))
        }
        if plan.options.includeReadme {
            files.append(ResolvePackFile(
                name: names.readme,
                text: ResolvePackReadme.make(plan: plan)
            ))
        }
        return files
    }

    /// Writes `<project>_resolve/` inside `parentFolder` and returns the folder.
    ///
    /// Known pack files that are no longer selected are removed so a re-export
    /// never leaves a stale EDL next to a README that does not mention it.
    @discardableResult
    public static func write(_ plan: ResolvePackPlan, to parentFolder: URL) throws -> URL {
        let fileManager = FileManager.default
        let folder = parentFolder.appendingPathComponent(plan.names.folder, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let files = files(for: plan)
        let included = Set(files.map(\.name))
        for stale in plan.names.all where !included.contains(stale) {
            let url = folder.appendingPathComponent(stale)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
        for file in files {
            try file.data.write(to: folder.appendingPathComponent(file.name), options: .atomic)
        }
        return folder
    }

    // MARK: - Warnings

    private static func truncationWarnings(
        markers: [ResolvedMarker],
        settings: ExportSettings
    ) -> [String] {
        var seen = Set<String>()
        var messages: [String] = []
        for marker in markers {
            let info = ExportTextSanitizer.markerNameInfo(
                marker.name,
                asciiSafe: settings.asciiSafeNames
            )
            guard info.wasTruncated, seen.insert(info.text).inserted else { continue }
            let full = ExportTextSanitizer.collapseWhitespace(marker.name)
            messages.append(
                "«\(info.text)» se recorta a 60 caracteres en el EDL (nombre completo: «\(full)»)."
            )
        }
        guard messages.count > 8 else { return messages }
        return Array(messages.prefix(8)) + [
            "… y \(messages.count - 8) nombres más superan los 60 caracteres."
        ]
    }
}
