// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FrameScriptCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FrameScriptCore", targets: ["FrameScriptCore"]),
        .library(name: "FrameScriptMCP", targets: ["FrameScriptMCP"]),
        .executable(name: "framescript", targets: ["framescript"])
    ],
    targets: [
        .target(name: "FrameScriptCore"),
        /// The dormant delivery pack: Resolve/YouTube exports, history
        /// snapshots, Plane sync and published-video comparison. Kept in a
        /// separate target that the app does not link, so the shipped app never
        /// gains an unwired feature surface by accident.
        .target(
            name: "FrameScriptLabs",
            dependencies: ["FrameScriptCore"]
        ),
        .target(
            name: "FrameScriptMCP",
            dependencies: ["FrameScriptCore"]
        ),
        .executableTarget(
            name: "framescript",
            dependencies: ["FrameScriptCore", "FrameScriptMCP"]
        ),
        .testTarget(
            name: "FrameScriptCoreTests",
            dependencies: ["FrameScriptCore", "FrameScriptLabs"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "FrameScriptLabsTests",
            dependencies: ["FrameScriptLabs", "FrameScriptCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "FrameScriptMCPTests",
            dependencies: ["FrameScriptMCP"]
        )
    ]
)
