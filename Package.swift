// swift-tools-version: 6.0
// SwiftPM manifest: lets you build and test Macro Maker with only the Command Line Tools
// (no Xcode). `scripts/build-app.sh` wraps the binary into a universal .app bundle.
// The Xcode project is generated from `project.yml` and compiles the same sources.
import PackageDescription

let package = Package(
    name: "MacroMaker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacroMaker",
            path: "Sources/MacroMaker"
        ),
        .testTarget(
            name: "MacroMakerTests",
            dependencies: ["MacroMaker"],
            path: "Tests/MacroMakerTests"
        ),
    ]
)
