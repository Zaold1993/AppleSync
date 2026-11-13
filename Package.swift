// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppleSync",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "AppleSyncCore",
            targets: ["AppleSyncCore"]
        ),
        .executable(
            name: "applesync",
            targets: ["AppleSyncCLI"]
        )
    ],
    targets: [
        .target(
            name: "AppleSyncCore",
            path: "Sources/AppleSyncCore"
        ),
        .executableTarget(
            name: "AppleSyncCLI",
            dependencies: ["AppleSyncCore"],
            path: "Sources/AppleSyncCLI"
        ),
        .testTarget(
            name: "AppleSyncCoreTests",
            dependencies: ["AppleSyncCore"],
            path: "Tests/AppleSyncCoreTests"
        )
    ]
)
