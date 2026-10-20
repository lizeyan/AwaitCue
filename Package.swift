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
        .library(name: "AwaitCueSelection", targets: ["AwaitCueSelection"]),
        .library(name: "AwaitCueModel", targets: ["AwaitCueModel"]),
        .library(name: "AwaitCuePersistence", targets: ["AwaitCuePersistence"]),
        .library(name: "AwaitCueBrowserBridge", targets: ["AwaitCueBrowserBridge"]),
        .library(name: "AwaitCueRuntime", targets: ["AwaitCueRuntime"]),
        .executable(name: "AwaitCueNativeHost", targets: ["AwaitCueNativeHost"]),
    ],
    targets: [
        .target(name: "AwaitCueCore"),
        .target(
            name: "AwaitCueCapture",
            dependencies: ["AwaitCueCore"]
        ),
        .target(
            name: "AwaitCueSelection",
            dependencies: ["AwaitCueCore", "AwaitCueCapture"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ScreenCaptureKit")]
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
            dependencies: ["AwaitCueCore"],
            linkerSettings: [.linkedFramework("Network")]
        ),
        .target(
            name: "AwaitCueRuntime",
            dependencies: ["AwaitCueCore", "AwaitCueCapture", "AwaitCueModel"]
        ),
        .executableTarget(
            name: "AwaitCueNativeHost",
            dependencies: ["AwaitCueBrowserBridge"]
        ),
        .executableTarget(
            name: "AwaitCueApp",
            dependencies: [
                "AwaitCueCore",
                "AwaitCueCapture",
                "AwaitCueSelection",
                "AwaitCueModel",
                "AwaitCuePersistence",
                "AwaitCueBrowserBridge",
                "AwaitCueRuntime",
            ],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(name: "AwaitCueCoreTests", dependencies: ["AwaitCueCore"]),
        .testTarget(name: "AwaitCueCaptureTests", dependencies: ["AwaitCueCapture", "AwaitCueCore"]),
        .testTarget(name: "AwaitCueSelectionTests", dependencies: ["AwaitCueSelection", "AwaitCueCore", "AwaitCueCapture"]),
        .testTarget(name: "AwaitCueModelTests", dependencies: ["AwaitCueModel", "AwaitCueCore"]),
        .testTarget(name: "AwaitCuePersistenceTests", dependencies: ["AwaitCuePersistence", "AwaitCueCore"]),
        .testTarget(name: "AwaitCueBrowserBridgeTests", dependencies: ["AwaitCueBrowserBridge", "AwaitCueCore"]),
        .testTarget(name: "AwaitCueRuntimeTests", dependencies: ["AwaitCueRuntime", "AwaitCueCore", "AwaitCueModel"]),
    ]
)
