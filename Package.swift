// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Ledge",
    platforms: [.macOS("15.0")],
    targets: [
        // Pure logic with no UI, so it can be unit tested.
        .target(name: "LedgeCore", path: "Sources/LedgeCore"),
        .executableTarget(
            name: "Ledge",
            dependencies: ["LedgeCore"],
            path: "Sources/Ledge",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(name: "LedgeCoreTests", dependencies: ["LedgeCore"], path: "Tests/LedgeCoreTests"),
    ]
)
