// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "atmos-control",
    platforms: [
        .macOS("15.0")
    ],
    targets: [
        .testTarget(name: "SpatialEngineTests", dependencies: ["SpatialEngine"]),
        // Phase 0 de-risk spike: a CLI harness that instantiates AUSpatialMixer,
        // configures personalized + head-tracked binaural rendering, plays a test
        // signal to the current output device (AirPods), and reads back whether
        // personalized HRTF actually engaged (property 3116).
        .executableTarget(
            name: "Phase0Spike",
            path: "Sources/Phase0Spike"
        ),
        // Phase 2/3: shared spatializer engine — capture (atmos-control loopback) →
        // AUSpatialMixer (stereo AmbienceBed, head-tracked binaural) → real output.
        // Lock-free SPSC ring bridges the clock domains. Driven by the CLI + the app.
        .target(
            name: "SpatialEngine",
            path: "Sources/SpatialEngine",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        // Thin CLI over SpatialEngine: env-configurable, prints a 1 Hz diagnostic
        // (captured/played/ringFill/peak + 3116). The Phase-1/2 debug harness.
        .executableTarget(
            name: "AtmosDaemon",
            dependencies: ["SpatialEngine"],
            path: "Sources/AtmosDaemon"
        ),
        // Offline CPU benchmark + null-test regression harness over the real render path
        // (same mixer graph + RT callbacks, synthetic input, no device IO).
        // `swift run -c release EngineBench [--filter x] [--record dir | --compare dir]`.
        .executableTarget(
            name: "EngineBench",
            dependencies: ["SpatialEngine"],
            path: "Sources/EngineBench"
        ),
        // Phase 3: SwiftUI menu-bar control app. Hosts the engine in-process; the
        // binary is wrapped into atmos-control.app by App/build-app.sh (LSUIElement).
        .executableTarget(
            name: "AtmosControlApp",
            dependencies: ["SpatialEngine"],
            path: "Sources/AtmosControlApp"
        ),
        // Phase 4 spike: prove personalized HRTF (3116) engages while capturing the
        // system mix via a MUTING process tap, WITHOUT hijacking the default output
        // (AirPods stay default). Validates the premium-tier unlock path.
        .executableTarget(
            name: "TapSpike",
            dependencies: ["SpatialEngine"],
            path: "Sources/TapSpike",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
    ]
)
