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
            dependencies: ["FrameScriptCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "FrameScriptMCPTests",
            dependencies: ["FrameScriptMCP"]
        )
    ]
)
