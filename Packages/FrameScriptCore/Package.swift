// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FrameScriptCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FrameScriptCore", targets: ["FrameScriptCore"])
    ],
    targets: [
        .target(name: "FrameScriptCore"),
        .testTarget(
            name: "FrameScriptCoreTests",
            dependencies: ["FrameScriptCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
