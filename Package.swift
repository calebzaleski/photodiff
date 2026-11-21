// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PhotoDiff",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic and file reading. No UI, no PhotoKit, so it is fully testable.
        .target(
            name: "PhotoDiffCore",
            path: "Sources/PhotoDiffCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The app itself: SwiftUI window plus the PhotoKit side.
        .executableTarget(
            name: "PhotoDiff",
            dependencies: ["PhotoDiffCore"],
            path: "Sources/PhotoDiff",
            linkerSettings: [
                .linkedFramework("Photos"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "PhotoDiffCoreTests",
            dependencies: ["PhotoDiffCore"],
            path: "Tests/PhotoDiffCoreTests"
        ),
    ]
)
