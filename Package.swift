// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PhotoDiff",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PhotoDiff",
            path: "Sources/PhotoDiff",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Photos"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "PhotoDiffTests",
            dependencies: ["PhotoDiff"],
            path: "Tests/PhotoDiffTests"
        ),
    ]
)
