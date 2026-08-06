// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WorkSwitch",
    platforms: [.macOS(.v14)],
    targets: [
        // Constants shared between the app and the native messaging relay.
        .target(
            name: "BridgeShared",
            path: "Sources/BridgeShared"
        ),
        // The menu bar app.
        .executableTarget(
            name: "WorkSwitch",
            dependencies: ["BridgeShared"],
            path: "Sources/WorkSwitch"
        ),
        // The native messaging host Chrome launches. Relays frames to the app's socket.
        .executableTarget(
            name: "WorkSwitchBridge",
            dependencies: ["BridgeShared"],
            path: "Sources/WorkSwitchBridge"
        ),
    ]
)
