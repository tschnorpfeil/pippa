// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Pippa",
    // Development language English, German is a full translation (docs/development.md "Localization").
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
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
        // Resources/{en,de}.lproj/*.strings become localized resources in Bundle.module (tables Core, Analysis, Skills).
        .target(name: "PippaCore", resources: [.process("Resources")]),
        // Bagel Fat One (SIL Open Font License, see Resources/Fonts/OFL.txt), only for the welcome heading.
        // Localization/{en,de}.lproj/*.strings: tables App, Views, Settings.
        .executableTarget(name: "Pippa", dependencies: ["PippaCore", "PiRPC", .product(name: "Sparkle", package: "Sparkle")],
                          resources: [.copy("Resources/Fonts"), .process("Localization")]),
        // Without Xcode there is neither XCTest nor Swift Testing: checks run as `swift run PippaChecks`.
        .executableTarget(name: "PippaChecks", dependencies: ["PippaCore"]),
        .executableTarget(name: "PippaUpdateProbe", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
        // Development only: all flows against a real model (runs only with PIPPA_LIVE=1, see Sources/PippaLive).
        .executableTarget(name: "PippaLive", dependencies: ["PippaCore"]),
        // Pi's RPC client (`pi --mode rpc`), used by the app and the probe programs.
        .target(name: "PiRPC"),
        // Probe: installer with a wrong HOME, llama-server, Pi via PiLaunchSpec.
        .executableTarget(name: "PiSetupSpike", dependencies: ["PippaCore", "PiRPC"]),
        // Probe: R2 and R7 acceptance on the RPC path (R7.swift).
        .executableTarget(name: "PiRPCR2Spike", dependencies: ["PippaCore", "PiRPC"]),
        // Probe: switching the AI, own online service only via Pippa's approval.
        .executableTarget(name: "PiRPCR10Spike", dependencies: ["PippaCore", "PiRPC"]),
        // Probe: event, reminder, mail draft with stand-in integrations + real Pi.
        .executableTarget(name: "PiRPCR3Spike", dependencies: ["PippaCore", "PiRPC"]),
    ]
)
