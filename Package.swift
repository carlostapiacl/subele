// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "subele",
    // AudioHardwareCreateProcessTap and CATapDescription ship in macOS 14.2.
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "BoosterKit", targets: ["BoosterKit"]),
        .executable(name: "subele", targets: ["subele"]),
    ],
    targets: [
        // Atomics for the parameters shared with the audio thread. Swift's own
        // Atomic type needs macOS 15; this needs nothing.
        .target(name: "CAtomics"),
        .target(
            name: "BoosterKit",
            dependencies: ["CAtomics"],
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("Accelerate")]
        ),
        .executableTarget(
            name: "subele",
            dependencies: ["BoosterKit"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "BoosterKitTests",
            dependencies: ["BoosterKit"]
        ),
    ]
)
