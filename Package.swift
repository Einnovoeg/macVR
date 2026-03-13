// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "macVR",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "MacVRProtocol",
            targets: ["MacVRProtocol"]
        ),
        .library(
            name: "MacVRHostCore",
            targets: ["MacVRHostCore"]
        ),
        .executable(
            name: "macvr-host",
            targets: ["MacVRHostApp"]
        ),
        .executable(
            name: "macvr-client",
            targets: ["MacVRClientApp"]
        ),
        .executable(
            name: "macvr-bridge-sim",
            targets: ["MacVRBridgeSimApp"]
        ),
        .executable(
            name: "macvr-jpeg-sender",
            targets: ["MacVRJPEGSenderApp"]
        ),
    ],
    targets: [
        .target(
            name: "MacVRProtocol"
        ),
        .target(
            name: "MacVRHostCore",
            dependencies: ["MacVRProtocol"]
        ),
        .executableTarget(
            name: "MacVRHostApp",
            dependencies: ["MacVRHostCore", "MacVRProtocol"]
        ),
        .executableTarget(
            name: "MacVRClientApp",
            dependencies: ["MacVRProtocol"]
        ),
        .executableTarget(
            name: "MacVRBridgeSimApp",
            dependencies: ["MacVRProtocol"]
        ),
        .executableTarget(
            name: "MacVRJPEGSenderApp"
        ),
        .testTarget(
            name: "MacVRHostCoreTests",
            dependencies: ["MacVRHostCore", "MacVRProtocol"]
        ),
    ]
)
