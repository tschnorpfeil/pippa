// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Pippa",
    // Development language English, German is a full translation (docs/development.md "Localization").
    defaultLocalization: "en",
    // macOS 26.2: the oldest macOS the MLX binaries in Pippa's AI runtime load on (scripts/macho-minos.py).
    platforms: [.macOS("26.2")],
    products: [
        .executable(name: "Pippa", targets: ["Pippa"]),
        .library(name: "PippaCore", targets: ["PippaCore"]),
    ],
    dependencies: [
        // Automatic updates (see docs/development.md "Releasing"). Pinned exactly: Sparkle updates
        // change signature and sandbox details that build-app.sh replicates.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // Resources/{en,de}.lproj/*.strings become localized resources in Bundle.module (tables Core, MCP, Setup, …; list in scripts/check-strings.py).
        .target(name: "PippaCore", resources: [.process("Resources")]),
        // Localization/{en,de}.lproj/*.strings: tables App, Views, Settings, CalendarUI, Island.
        .executableTarget(name: "Pippa", dependencies: ["PippaCore", "PiRPC", .product(name: "Sparkle", package: "Sparkle")],
                          resources: [.process("Localization")]),
        // Without Xcode there is neither XCTest nor Swift Testing: checks run as `swift run PippaChecks`.
        .executableTarget(name: "PippaChecks", dependencies: ["PippaCore"]),
        .executableTarget(name: "PippaUpdateProbe", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
        // Pi's RPC client (`pi --mode rpc`), used by the app.
        .target(name: "PiRPC"),
        // Protocol regression checks with a fake Pi subprocess; no model, network, or macOS permissions.
        .executableTarget(name: "PiRPCChecks", dependencies: ["PiRPC"]),
    ]
)
