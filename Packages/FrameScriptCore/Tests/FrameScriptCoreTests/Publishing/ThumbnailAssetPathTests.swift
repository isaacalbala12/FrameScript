import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Thumbnail asset paths")
struct ThumbnailAssetPathTests {
    @Test("Uses the sibling assets folder and keeps the extension")
    func basicPath() {
        let path = ThumbnailAssetPath.relativePath(
            projectName: "Mi vídeo",
            originalFileName: "Portada.PNG",
            existingPaths: []
        )
        #expect(path == "Mi vídeo assets/Portada.png")
    }

    @Test("Avoids collisions without overwriting")
    func collisions() {
        let existing: Set<String> = [
            "Vídeo assets/miniatura.png",
            "Vídeo assets/miniatura 2.png",
        ]
        let path = ThumbnailAssetPath.relativePath(
            projectName: "Vídeo",
            originalFileName: "miniatura.png",
            existingPaths: existing
        )
        #expect(path == "Vídeo assets/miniatura 3.png")
    }

    @Test("Sanitizes path separators and falls back for empty names")
    func sanitizing() {
        #expect(ThumbnailAssetPath.assetsDirectoryName(projectName: "A/B:C") == "A-B-C assets")
        #expect(ThumbnailAssetPath.assetsDirectoryName(projectName: "   ") == "Proyecto assets")
        let path = ThumbnailAssetPath.relativePath(
            projectName: "Proyecto",
            originalFileName: ".png",
            existingPaths: []
        )
        #expect(path == "Proyecto assets/miniatura.png")
    }

    @Test("Resolves a relative path against the project directory")
    func resolvesURL() {
        let directory = URL(fileURLWithPath: "/tmp/proyecto")
        let url = ThumbnailAssetPath.resolvedURL(
            relativePath: "Proyecto assets/a.png",
            projectDirectory: directory
        )
        #expect(url.path == "/tmp/proyecto/Proyecto assets/a.png")
    }
}
