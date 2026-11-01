// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Brim",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Updates: checks docs/appcast.xml on the website and installs new releases.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Brim",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Brim",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // build.sh copies Sparkle.framework into Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "BrimTests",
            dependencies: ["Brim"],
            path: "Tests/BrimTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
