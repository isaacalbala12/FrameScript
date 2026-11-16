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
    /// Prefix cells starting with `=`, `+`, `-` or `@` with an apostrophe so
    /// Numbers/Excel never evaluate a shot description as a formula.
    public var csvEscapesFormulas: Bool
    /// Write `_chapters.txt` even when it has fewer than three chapters, which
    /// YouTube ignores. Off by default; the sheet asks explicitly.
    public var writeInvalidChapters: Bool

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
        includeReadme: Bool = true,
        csvEscapesFormulas: Bool = true,
        writeInvalidChapters: Bool = false
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
        self.csvEscapesFormulas = csvEscapesFormulas
        self.writeInvalidChapters = writeInvalidChapters
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
            includeReadme: includeReadme,
            csvEscapesFormulas: csvEscapesFormulas,
            writeInvalidChapters: writeInvalidChapters
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
            includeChapterMarkers: includeFCPXML && includeChapterMarkersInFCPXML,
            csvEscapesFormulas: csvEscapesFormulas
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
    /// Original text with Markdown and emoji stripped, never ASCII-folded and
    /// never truncated to the EDL's 60 characters.
    public let name: String
    /// Exactly what the marker EDL writes, after ASCII transliteration and the
    /// 60-character cap. Equal to `name` when the EDL is unchanged.
    public let edlName: String
    public let note: String
    public let edlNote: String
    public let color: ExportMarkerColor
    public let durationFrames: Int
    public let kind: ResolvedMarker.Kind

    public var id: String { "\(frame):\(name):\(color.rawValue)" }

    /// True when the EDL differs from what the preview shows (accents, emoji or
    /// the 60-character cap).
    public var edlDiffers: Bool { name != edlName || note != edlNote }
}

/// One delivery-sheet warning with enough structure to localize it.
///
/// `message` stays Spanish for the README, CLI and older callers; the app
/// reads `kind` and renders the same warning in the interface language.
public struct ResolvePackWarning: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case missingLanguageText(sceneTitle: String, language: String)
        case unestimableDuration(sceneTitle: String)
        case unanchoredBRoll(sceneTitle: String, item: String)
        case claimNeedsVerification(sceneTitle: String, status: String, text: String)
        case unlinkedClaim(status: String, text: String)
        case dropFrameUnsupported(fps: String)
        case emptyProjectName
        case markerCollision(name: String, otherName: String, frame: Int)
        case tooManyEvents(count: Int)
        case chapter(ChapterWarning)
        case markerNameTruncated(name: String, fullName: String)
        case moreNamesTruncated(count: Int)
        case chaptersOmitted(chapterCount: Int)
        case chapterListsDiffer
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
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
    /// Paste-ready chapter text (`_chapters.txt`) following the Publishing pack.
    public let chapters: ChapterList
    /// Chapter markers derived from the same scenes/frame rate as the marker
    /// EDL, so they line up with the scene markers in the FCPXML.
    public let timelineChapters: ChapterList
    /// Spanish fallback messages, kept for the README and existing callers.
    public let warnings: [String]
    public let warningItems: [ResolvePackWarning]

    public init(
        projectName: String,
        names: ResolvePackNames,
        options: ResolvePackOptions,
        settings: ExportSettings,
        scenes: [ExportScene],
        markers: [ResolvedMarker],
        allMarkers: [ResolvedMarker],
        chapters: ChapterList,
        timelineChapters: ChapterList? = nil,
        warnings: [String],
        warningItems: [ResolvePackWarning] = []
    ) {
        self.projectName = projectName
        self.names = names
        self.options = options
        self.settings = settings
        self.scenes = scenes
        self.markers = markers
        self.allMarkers = allMarkers
        self.chapters = chapters
        self.timelineChapters = timelineChapters ?? chapters
        self.warnings = warnings
        self.warningItems = warningItems
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
    /// `name`/`note` keep the original text; `edlName`/`edlNote` show what the
    /// ASCII-safe EDL actually receives.
    public var markerPreviews: [ResolveMarkerPreview] {
        markers.map { marker in
            let timecode = Timecode(frames: settings.startTimecode.frames + marker.frame)
                .string(rate: settings.fps, dropFrame: settings.effectiveDropFrame)
            let name = ExportTextSanitizer.markerName(
                marker.name,
                asciiSafe: false,
                limit: .max
            )
            let note = ExportTextSanitizer.markerNote(
                marker.note,
                asciiSafe: false,
                limit: .max
            )
            return ResolveMarkerPreview(
                frame: marker.frame,
                timecode: timecode,
                name: name,
                edlName: ExportTextSanitizer.markerName(
                    marker.name,
                    asciiSafe: settings.asciiSafeNames
                ),
                note: note,
                edlNote: ExportTextSanitizer.markerNote(
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

    /// The chapters file is only written when YouTube can use it, unless the
    /// creator explicitly asks for the invalid list (N-7).
    public var includesChaptersFile: Bool {
        options.includeChapters
            && (chapters.isValidForYouTube || options.writeInvalidChapters)
    }
}

public enum ResolveDeliveryPack {
    /// Compares chapter content, not formatting. Two lists with the same
    /// (start second, title) entries in any order are the same list; a title
    /// override, a different start or an extra imported chapter is a real
    /// difference.
    public static func chapterListsDiffer(_ lhs: ChapterList, _ rhs: ChapterList) -> Bool {
        func signature(_ list: ChapterList) -> [String] {
            list.chapters
                .map { "\($0.startSeconds)|\($0.title)" }
                .sorted()
        }
        return signature(lhs) != signature(rhs)
    }

    /// Builds the plan and every warning the sheet shows before exporting.
    ///
    /// `extraWarnings` carries scene-mapping issues from the app (missing
    /// anchors, missing language variants) so they live next to the writer
    /// warnings.
    public static func plan(
        scenes: [ExportScene],
        projectName: String,
        options: ResolvePackOptions,
        extraWarnings: [String] = [],
        extraWarningItems: [ResolvePackWarning] = [],
        chapters: ChapterList? = nil
    ) -> ResolvePackPlan {
        let settings = options.settings(projectName: projectName)
        let names = ResolvePackNaming.names(
            projectName: projectName,
            asciiSafe: options.asciiSafeNames
        )
        let resolution = ExportMarkerResolver.resolve(scenes: scenes, settings: settings)
        let allMarkers = ExportMarkerResolver.allMarkers(scenes: scenes, settings: settings)
        // `_chapters.txt` follows the Publishing pack (titles, exclusions and
        // imported chapters). FCPXML markers must follow the timeline this pack
        // is building, so they use the same scenes and frame rate as the EDL.
        let timelineChapters = YouTubeChapters.make(scenes: scenes, rate: settings.fps)
        let chapterList = chapters ?? timelineChapters

        var warningItems: [ResolvePackWarning] = []
        warningItems.append(contentsOf: extraWarningItems)
        warningItems.append(contentsOf: settings.validationIssues.map { issue in
            let kind: ResolvePackWarning.Kind
            switch issue {
            case let .dropFrameUnsupported(fps):
                kind = .dropFrameUnsupported(fps: fps)
            case .emptyProjectName:
                kind = .emptyProjectName
            }
            return ResolvePackWarning(kind: kind, message: issue.message)
        })
        warningItems.append(contentsOf: resolution.warnings.map { warning in
            let kind: ResolvePackWarning.Kind
            switch warning.kind {
            case .duplicateFrame:
                kind = .markerCollision(
                    name: warning.name ?? "",
                    otherName: warning.otherName ?? "",
                    frame: warning.frame ?? 0
                )
            case .tooManyEvents:
                kind = .tooManyEvents(count: warning.count ?? resolution.markers.count)
            }
            return ResolvePackWarning(kind: kind, message: warning.message)
        })
        if options.includeChapters || (options.includeFCPXML && options.includeChapterMarkersInFCPXML) {
            warningItems.append(contentsOf: chapterList.warnings.map {
                ResolvePackWarning(kind: .chapter($0), message: $0.message)
            })
            if options.includeFCPXML && options.includeChapterMarkersInFCPXML,
               Self.chapterListsDiffer(timelineChapters, chapterList) {
                warningItems.append(contentsOf: timelineChapters.warnings.map {
                    ResolvePackWarning(kind: .chapter($0), message: $0.message)
                })
            }
        }
        warningItems.append(contentsOf: truncationWarnings(
            markers: resolution.markers,
            settings: settings
        ))

        if options.includeChapters,
           !chapterList.isValidForYouTube,
           !options.writeInvalidChapters {
            let count = chapterList.chapters.count
            warningItems.append(
                ResolvePackWarning(
                    kind: .chaptersOmitted(chapterCount: count),
                    message: "No se escribe el archivo de capítulos: YouTube necesita al menos 3 capítulos de 10 s y esta lista tiene \(count)."
                )
            )
        }

        let chaptersFileWillBeWritten = options.includeChapters
            && (chapterList.isValidForYouTube || options.writeInvalidChapters)
        let fcpxmlHasChapterMarkers = options.includeFCPXML
            && options.includeChapterMarkersInFCPXML
        if chaptersFileWillBeWritten,
           fcpxmlHasChapterMarkers,
           Self.chapterListsDiffer(chapterList, timelineChapters) {
            warningItems.append(
                ResolvePackWarning(
                    kind: .chapterListsDiffer,
                    message: "El archivo de capítulos y los marcadores del FCPXML no coinciden. Puede venir de las duraciones de las tomas frente a las estimaciones, o de capítulos importados sin escena que solo existen en el archivo."
                )
            )
        }

        var warnings = extraWarnings
        warnings.append(contentsOf: warningItems.map(\.message))

        // Keep the first message for duplicates such as two truncation
        // warnings that sanitize to the same EDL name.
        var seenWarningKinds = Set<ResolvePackWarning.Kind>()
        let uniqueWarningItems = warningItems.filter {
            seenWarningKinds.insert($0.kind).inserted
        }
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
            chapters: chapterList,
            timelineChapters: timelineChapters,
            warnings: uniqueWarnings,
            warningItems: uniqueWarningItems
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
                text: ResolveFCPXML.make(
                    markers: plan.markers,
                    durationFrames: plan.durationFrames,
                    settings: settings,
                    chapters: settings.includeChapterMarkers ? plan.timelineChapters.chapters : []
                )
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
        if plan.includesChaptersFile {
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
    ) -> [ResolvePackWarning] {
        var seen = Set<String>()
        var items: [ResolvePackWarning] = []
        for marker in markers {
            let info = ExportTextSanitizer.markerNameInfo(
                marker.name,
                asciiSafe: settings.asciiSafeNames
            )
            guard info.wasTruncated, seen.insert(info.text).inserted else { continue }
            let full = ExportTextSanitizer.collapseWhitespace(marker.name)
            items.append(
                ResolvePackWarning(
                    kind: .markerNameTruncated(name: info.text, fullName: full),
                    message: "«\(info.text)» se recorta a 60 caracteres en el EDL (nombre completo: «\(full)»)."
                )
            )
        }
        guard items.count > 8 else { return items }
        let extra = items.count - 8
        return Array(items.prefix(8)) + [
            ResolvePackWarning(
                kind: .moreNamesTruncated(count: extra),
                message: "… y \(extra) nombres más superan los 60 caracteres."
            )
        ]
    }
}
