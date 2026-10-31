// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Brim",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Brim",
            path: "Sources/Brim",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
