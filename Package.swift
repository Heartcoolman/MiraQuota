// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MiraQuota",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MiraQuota",
            path: "Sources/MiraQuota",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
