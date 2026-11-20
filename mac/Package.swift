// swift-tools-version: 6.2
import PackageDescription

// MatchCore has no UI and imports only Foundation, so a later iPhone/iPad viewer can share it.
// Keep AppKit, NSWorkspace and starting Python (BackendProcess) in the app target. Check it still
// builds for iOS from mac/: xcodebuild -scheme MatchCore -destination 'generic/platform=iOS Simulator' build
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
