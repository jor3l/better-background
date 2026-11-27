// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BetterBackground",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Over-the-air updates from GitHub Releases (EdDSA-signed appcast).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4")
    ],
    targets: [
        .executableTarget(
            name: "BetterBackground",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/BetterBackground",
            linkerSettings: [
                // Sparkle.framework is copied into BetterBackground.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
