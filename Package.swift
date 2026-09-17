// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "audio-booster",
    // AudioHardwareCreateProcessTap and CATapDescription ship in macOS 14.2.
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "BoosterKit", targets: ["BoosterKit"]),
        .executable(name: "booster", targets: ["booster"]),
    ],
    targets: [
        .target(
            name: "BoosterKit",
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        .executableTarget(
            name: "booster",
            dependencies: ["BoosterKit"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "BoosterKitTests",
            dependencies: ["BoosterKit"]
        ),
    ]
)
