// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Terminaly",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "TerminalyKit",
            path: "Sources/TerminalyKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Session host daemon + command-line client.
        .executableTarget(
            name: "tly",
            dependencies: ["TerminalyKit"],
            path: "Sources/tly",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Terminaly",
            dependencies: ["SwiftTerm", "TerminalyKit", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Terminaly",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle.framework is embedded in Terminaly.app/Contents/Frameworks by scripts/bundle.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
