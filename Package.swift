// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "atmos-control",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        // The engine + state model as a dynamic library with a C ABI, loaded by the Rust (Rune)
        // app binary from Contents/Frameworks (crates/atmos-core-sys links it; App/build-app.sh
        // bundles it).
        .library(name: "AtmosCore", type: .dynamic, targets: ["AtmosCore"]),
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
        // The C ABI's header (include/atmos_core.h): the contract with the Rust UI. A C target
        // so the Swift implementation and the Rust declarations share one definition.
        .target(
            name: "AtmosCoreABI",
            path: "Sources/AtmosCoreABI"
        ),
        // The app's state model (EngineController: power orchestration, device hot-swap, format
        // recovery, telemetry, head motion) behind the C ABI. Built as libAtmosCore.dylib.
        // Sources/AtmosControlApp holds the former SwiftUI views; they are no longer built and
        // stay only as the reference for the Rune port until it reaches parity.
        .target(
            name: "AtmosCore",
            dependencies: ["SpatialEngine", "AtmosCoreABI"],
            path: "Sources/AtmosCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreMotion"),
                .linkedFramework("CoreAudio"),
            ]
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
