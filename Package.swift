// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "clamshelled",
    platforms: [.macOS(.v13)],   // SMAppService.daemon + XPC code-signing pinning
    targets: [
        // XPC contract shared by the app and the root helper.
        .target(name: "ClamshelledShared"),
        .executableTarget(
            name: "clamshelled",
            dependencies: ["ClamshelledShared"],
            path: "Sources/clamshelled",
            resources: [.process("Resources")]
        ),
        // Runs as root via SMAppService; embedded in the app bundle.
        .executableTarget(
            name: "ClamshelledHelper",
            dependencies: ["ClamshelledShared"]
        ),
    ]
)
