// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BetterBackground",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "BetterBackground",
            path: "Sources/BetterBackground"
        )
    ],
    swiftLanguageModes: [.v5]
)
