// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MultiDock",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MultiDock",
            path: "Sources/MultiDock"
        ),
        .testTarget(
            name: "MultiDockTests",
            dependencies: ["MultiDock"],
            path: "Tests/MultiDockTests"
        ),
    ]
)
