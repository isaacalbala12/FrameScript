import AppKit
import Foundation
import FrameScriptCore

// MARK: - Asset library actions

/// The project writes asset entries into `FrameProject.assets`. This extension
/// is the only place the app mutates them, so dirtying, de-duplication,
/// metadata refreshes and OBS take syncing stay in one place.
@MainActor
extension AppState {
    var assets: [ProjectAsset] {
        project.assets
    }

    var isAssetsPresented: Bool {
        get { windowState.isAssetsPresented }
        set { windowState.isAssetsPresented = newValue }
    }

    /// Folder that project-relative asset paths are resolved against.
    var assetProjectDirectory: URL? {
        projectStore.currentFileURL?.deletingLastPathComponent()
    }

    /// Current path for a reference. New entries are absolute; projects saved
    /// by an older build keep `<Project> assets/portada.png`, which belongs to
    /// the project folder and never to the process working directory.
    func resolvedAssetPath(_ path: String) -> String {
        AssetPath.resolved(path, relativeTo: assetProjectDirectory)
    }

    /// Adds one or more files by reference. Directories are ignored; duplicate
    /// paths enrich the existing entry instead of adding a second one.
    ///
    /// The file is never copied. Bookmark creation is best effort: the stored
    /// path is always kept so an asset still works when no bookmark can be made.
    @discardableResult
    func addAssets(
        at urls: [URL],
        kind overrideKind: AssetKind? = nil,
        tags: [String] = []
    ) -> [ProjectAsset] {
        let fileManager = FileManager.default
        var result: [ProjectAsset] = []
        var didChange = false

        for rawURL in urls {
            let url = rawURL.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { continue }

            let path = AssetPath.normalized(url.path)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let detectedKind = overrideKind ?? appKind(AssetKindDetector.kind(for: url))
            let incoming = FrameScriptDocument.ProjectAsset(
                path: path,
                bookmarkData: AssetBookmark.make(for: url),
                kind: coreKind(detectedKind),
                tags: AssetTags.normalized(tags),
                isCopiedIntoProject: false,
                fileSize: values?.fileSize.map(Int64.init),
                modifiedAt: values?.contentModificationDate
            )

            var coreAssets = assets.map(coreAsset)
            if let index = AssetDeduplication.index(ofPath: path, in: coreAssets) {
                AssetDeduplication.merge(incoming, into: &coreAssets[index])
                let merged = coreAssets[index].makeAsset()
                if project.assets[index] != merged {
                    project.assets[index] = merged
                    didChange = true
                }
                result.append(merged)
            } else {
                let added = incoming.makeAsset()
                project.assets.append(added)
                result.append(added)
                didChange = true
                loadAssetMetadata(assetID: added.id)
            }
        }

        if didChange {
            touchProject()
        }
        return result
    }

    @discardableResult
    func addAsset(at url: URL, kind: AssetKind? = nil, tags: [String] = []) -> ProjectAsset? {
        addAssets(at: [url], kind: kind, tags: tags).first
    }

    func removeAsset(id: UUID) {
        guard let index = project.assets.firstIndex(where: { $0.id == id }) else { return }
        project.assets.remove(at: index)
        removePublishingVariants(referencing: id)
        touchProject()
    }

    /// How many A/B thumbnail variants use this asset. The confirmation alert
    /// mentions them before the user deletes a library row.
    func publishingUsageCount(forAssetID id: UUID) -> Int {
        project.publishingPacks.values.reduce(0) { partial, pack in
            partial + pack.thumbnailVariants.filter { $0.assetID == id }.count
        }
    }

    /// Keeps every publishing pack free of dangling `assetID`s after the
    /// library row is gone. Each pack keeps a chosen variant when possible.
    private func removePublishingVariants(referencing assetID: UUID) {
        for key in project.publishingPacks.keys {
            guard var pack = project.publishingPacks[key] else { continue }
            let before = pack.thumbnailVariants.count
            pack.thumbnailVariants.removeAll { $0.assetID == assetID }
            guard pack.thumbnailVariants.count != before else { continue }
            if !pack.thumbnailVariants.contains(where: \.isChosen),
               !pack.thumbnailVariants.isEmpty {
                pack.thumbnailVariants[0].isChosen = true
            }
            project.publishingPacks[key] = pack
        }
    }

    func setAssetKind(_ kind: AssetKind, assetID: UUID) {
        updateAsset(assetID: assetID) { $0.kind = kind }
    }

    func addAssetTag(_ tag: String, assetID: UUID) {
        updateAsset(assetID: assetID) { $0.tags = AssetTags.adding(tag, to: $0.tags) }
    }

    func removeAssetTag(_ tag: String, assetID: UUID) {
        updateAsset(assetID: assetID) { $0.tags = AssetTags.removing(tag, from: $0.tags) }
    }

    func toggleAssetSceneLink(assetID: UUID, sceneID: UUID) {
        updateAsset(assetID: assetID) { asset in
            var core = FrameScriptDocument.ProjectAsset(asset: asset)
            AssetLinks.toggle(sceneID: sceneID, in: &core)
            asset.linkedSceneIDs = core.linkedSceneIDs
        }
    }

    func toggleAssetBRollLink(assetID: UUID, bRollItemID: UUID) {
        updateAsset(assetID: assetID) { asset in
            var core = FrameScriptDocument.ProjectAsset(asset: asset)
            AssetLinks.toggle(bRollItemID: bRollItemID, in: &core)
            asset.linkedBRollItemIDs = core.linkedBRollItemIDs
        }
    }

    func toggleAssetTakeLink(assetID: UUID, takeID: UUID) {
        updateAsset(assetID: assetID) { asset in
            var core = FrameScriptDocument.ProjectAsset(asset: asset)
            AssetLinks.toggle(takeID: takeID, in: &core)
            asset.linkedTakeIDs = core.linkedTakeIDs
        }
    }

    /// Relinks a stale entry to a file the user picked by hand.
    func locateAsset(id: UUID, at url: URL) {
        guard let index = project.assets.firstIndex(where: { $0.id == id }) else { return }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var asset = project.assets[index]
        asset.path = AssetPath.normalized(url.path)
        asset.bookmarkData = AssetBookmark.make(for: url)
        asset.fileSize = values?.fileSize.map(Int64.init)
        asset.modifiedAt = values?.contentModificationDate
        asset.isLastKnownMissing = false
        project.assets[index] = asset
        touchProject()
        loadAssetMetadata(assetID: id)
    }

    /// Checks every reference and keeps stale entries visible with their
    /// missing flag set. Moves tracked by a bookmark update the stored path.
    ///
    /// Before checking, legacy project-relative paths are migrated to absolute
    /// paths inside the project folder. Nothing is lost: the file stays where
    /// it is and only the stored string changes.
    func refreshAssetReachability() async {
        let projectDirectory = assetProjectDirectory
        let projectFileURL = projectStore.currentFileURL
        var migrated = false
        for index in project.assets.indices {
            let path = project.assets[index].path
            guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var resolved: String?
            if !AssetPath.isAbsolute(path) {
                if let projectDirectory {
                    resolved = AssetPath.resolved(path, relativeTo: projectDirectory)
                }
            } else if project.assets[index].isCopiedIntoProject,
                      !FileManager.default.fileExists(atPath: path),
                      let projectFileURL,
                      let repaired = repairedCopiedPath(
                          path,
                          asset: project.assets[index],
                          projectFileURL: projectFileURL
                      ) {
                // A build before the C-1 fix saved `/<cwd>/Proyecto
                // assets/portada.png` (or `/Proyecto assets/portada.png`).
                // The file is still beside the project; rewrite the stale
                // absolute path instead of reporting it missing.
                resolved = repaired
            }
            guard let resolved, resolved != path else { continue }
            project.assets[index].path = resolved
            migrated = true
        }
        if migrated {
            touchProject()
        }

        let coreAssets = assets.map(coreAsset)
        guard !coreAssets.isEmpty else { return }
        let results = await Task.detached(priority: .utility) { [projectDirectory] in
            AssetReachabilityChecker.check(coreAssets, projectDirectory: projectDirectory)
        }.value
        var updated = coreAssets
        guard AssetReachabilityChecker.apply(results, to: &updated) else { return }
        let byID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        for index in project.assets.indices {
            guard let refreshed = byID[project.assets[index].id] else { continue }
            let appAsset = refreshed.makeAsset()
            if project.assets[index] != appAsset {
                project.assets[index] = appAsset
            }
        }
    }

    /// Repairs an absolute-looking thumbnail path by looking for the copied
    /// file inside the project's own `<Project> assets/` folder.
    ///
    /// Only copied thumbnails qualify, only after their bookmark failed to
    /// resolve, and only when the stale path still ends in
    /// `<Project> assets/<file>`. A reference to an unmounted external drive
    /// must never be silently repointed to a same-named local file.
    private func repairedCopiedPath(
        _ storedPath: String,
        asset: ProjectAsset,
        projectFileURL: URL
    ) -> String? {
        guard asset.isCopiedIntoProject else { return nil }
        if let bookmarkData = asset.bookmarkData,
           let resolved = AssetBookmark.resolve(bookmarkData),
           FileManager.default.fileExists(atPath: resolved.path) {
            return nil
        }
        let assetsName = AssetStore.assetsDirectoryName(forProjectFile: projectFileURL)
        let components = (storedPath as NSString).pathComponents
        guard components.count >= 2,
              components[components.count - 2] == assetsName else { return nil }
        let fileName = components[components.count - 1]
        guard !fileName.isEmpty else { return nil }
        let candidate = AssetStore.assetsDirectory(forProjectFile: projectFileURL)
            .appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate.path
    }

    /// Adds or refreshes the OBS asset for a take that just finished. Called by
    /// the recording gateway; never deletes anything when a take is removed.
    func ensureOBSAsset(sceneID: UUID, takeID: UUID, preferredPath: String = "") {
        let appTake = take(withID: takeID)
        var coreTake: FrameScriptDocument.Take
        if let appTake {
            coreTake = FrameScriptDocument.Take(take: appTake)
            if coreTake.filePath.isEmpty {
                coreTake.filePath = preferredPath
            }
        } else if !preferredPath.isEmpty {
            coreTake = FrameScriptDocument.Take(
                id: takeID,
                number: 0,
                startedAt: Date(),
                filePath: preferredPath
            )
        } else {
            return
        }
        guard !coreTake.filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        var coreAssets = assets.map(coreAsset)
        guard let index = OBSTakeAssetSync.upsert(take: coreTake, sceneID: sceneID, into: &coreAssets) else { return }
        let synced = coreAssets[index].makeAsset()
        if let existingIndex = project.assets.firstIndex(where: { $0.id == synced.id }) {
            if project.assets[existingIndex] != synced {
                project.assets[existingIndex] = synced
            }
        } else {
            project.assets.append(synced)
        }
        loadAssetMetadata(assetID: synced.id)
    }

    /// Adds library entries for OBS takes that already existed when the project
    /// was opened (older projects, or files recorded before this feature).
    /// Deletions are never propagated back to takes or files.
    func syncOBSAssetsFromTakes() {
        let before = assets.count
        for scene in project.scenes {
            for take in scene.takes {
                ensureOBSAsset(sceneID: scene.id, takeID: take.id, preferredPath: take.filePath)
            }
            for variant in scene.languageVariants {
                for take in variant.takes {
                    ensureOBSAsset(sceneID: scene.id, takeID: take.id, preferredPath: take.filePath)
                }
            }
        }
        if assets.count != before {
            touchProject()
        }
    }

    /// Loads duration, image dimensions and file metadata away from the main
    /// actor. Values are persisted the next time the project is saved.
    func loadAssetMetadata(assetID: UUID) {
        guard let asset = project.assets.first(where: { $0.id == assetID }) else { return }
        let path = resolvedAssetPath(asset.path)
        let bookmarkData = asset.bookmarkData
        Task { [weak self] in
            let metadata = await AssetMetadataLoader.shared.load(path: path, bookmarkData: bookmarkData)
            guard let self else { return }
            guard let index = project.assets.firstIndex(where: { $0.id == assetID }) else { return }
            var asset = project.assets[index]
            var changed = false
            if let duration = metadata.duration, asset.duration != duration {
                asset.duration = duration
                changed = true
            }
            if let byteSize = metadata.byteSize, asset.fileSize != byteSize {
                asset.fileSize = byteSize
                changed = true
            }
            if let modifiedAt = metadata.modifiedAt, asset.modifiedAt != modifiedAt {
                asset.modifiedAt = modifiedAt
                changed = true
            }
            if changed {
                project.assets[index] = asset
            }
        }
    }

    /// Best URL for opening or previewing an asset. Prefers the live path and
    /// falls back to the bookmark for moved files.
    func assetReferenceURL(_ asset: ProjectAsset) -> URL? {
        let path = resolvedAssetPath(asset.path)
        if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let bookmarkData = asset.bookmarkData, let resolved = AssetBookmark.resolve(bookmarkData) {
            return resolved
        }
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    // MARK: Helpers

    private func updateAsset(assetID: UUID, _ body: (inout ProjectAsset) -> Void) {
        guard let index = project.assets.firstIndex(where: { $0.id == assetID }) else { return }
        var asset = project.assets[index]
        body(&asset)
        guard asset != project.assets[index] else { return }
        project.assets[index] = asset
        touchProject()
    }

    private func take(withID takeID: UUID) -> Take? {
        for scene in project.scenes {
            if let take = scene.takes.first(where: { $0.id == takeID }) { return take }
            for variant in scene.languageVariants {
                if let take = variant.takes.first(where: { $0.id == takeID }) { return take }
            }
        }
        return nil
    }

    private func coreAsset(_ asset: ProjectAsset) -> FrameScriptDocument.ProjectAsset {
        FrameScriptDocument.ProjectAsset(asset: asset)
    }

    private func coreKind(_ kind: AssetKind) -> FrameScriptDocument.AssetKind {
        FrameScriptDocument.AssetKind(rawValue: kind.rawValue) ?? .web
    }

    private func appKind(_ kind: FrameScriptDocument.AssetKind) -> AssetKind {
        AssetKind(rawValue: kind.rawValue) ?? .web
    }
}
