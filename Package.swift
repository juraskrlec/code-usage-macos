// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodeUsageBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "CodeUsageBar", path: "Sources"),
        .testTarget(
            name: "CodeUsageBarTests",
            dependencies: ["CodeUsageBar"]
        )
    ]
)
