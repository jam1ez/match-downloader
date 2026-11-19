// swift-tools-version: 6.2
import PackageDescription

// MatchCore has no UI and imports only Foundation, so it also builds for iOS (see
// redesign/swiftui/PLAN.md > iOS readiness). Mac-only code lives in the app target.
let package = Package(
    name: "MatchDownloader",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "MatchCore", targets: ["MatchCore"]),
        .executable(name: "MatchDownloader", targets: ["MatchDownloader"]),
    ],
    targets: [
        .target(name: "MatchCore"),
        .executableTarget(name: "MatchDownloader", dependencies: ["MatchCore"]),
        .testTarget(name: "MatchDownloaderTests", dependencies: ["MatchDownloader", "MatchCore"]),
        .testTarget(
            name: "MatchCoreTests",
            dependencies: ["MatchCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
