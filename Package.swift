// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AwaitCue",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "AwaitCue", targets: ["AwaitCueApp"]),
        .library(name: "AwaitCueCore", targets: ["AwaitCueCore"]),
        .library(name: "AwaitCueCapture", targets: ["AwaitCueCapture"]),
        .library(name: "AwaitCueModel", targets: ["AwaitCueModel"]),
        .library(name: "AwaitCuePersistence", targets: ["AwaitCuePersistence"]),
        .library(name: "AwaitCueBrowserBridge", targets: ["AwaitCueBrowserBridge"]),
    ],
    targets: [
        .target(name: "AwaitCueCore"),
        .target(
            name: "AwaitCueCapture",
            dependencies: ["AwaitCueCore"]
        ),
        .target(
            name: "AwaitCueModel",
            dependencies: ["AwaitCueCore"]
        ),
        .target(
            name: "AwaitCuePersistence",
            dependencies: ["AwaitCueCore"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "AwaitCueBrowserBridge",
            dependencies: ["AwaitCueCore"]
        ),
        .executableTarget(
            name: "AwaitCueApp",
            dependencies: [
                "AwaitCueCore",
                "AwaitCueCapture",
                "AwaitCueModel",
                "AwaitCuePersistence",
                "AwaitCueBrowserBridge",
            ],
            resources: [.process("Resources")],
            linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("AppKit")]
        ),
        .testTarget(name: "AwaitCueCoreTests", dependencies: ["AwaitCueCore"]),
        .testTarget(name: "AwaitCueCaptureTests", dependencies: ["AwaitCueCapture", "AwaitCueCore"]),
        .testTarget(name: "AwaitCueModelTests", dependencies: ["AwaitCueModel", "AwaitCueCore"]),
        .testTarget(name: "AwaitCuePersistenceTests", dependencies: ["AwaitCuePersistence", "AwaitCueCore"]),
        .testTarget(name: "AwaitCueBrowserBridgeTests", dependencies: ["AwaitCueBrowserBridge", "AwaitCueCore"]),
    ]
)
