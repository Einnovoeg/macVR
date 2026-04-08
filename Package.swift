// swift-tools-version: 6.2

import Foundation
import PackageDescription

// Keep C-target release metadata sourced from the checked-in VERSION file so
// package builds and release docs do not drift independently.
let releaseVersion: String = {
    guard
        let raw = try? String(contentsOfFile: "VERSION", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
        !raw.isEmpty
    else {
        return "0.7.0"
    }
    return raw
}()

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
        .library(
            name: "MacVRRuntimeCore",
            targets: ["MacVRRuntimeCore"]
        ),
        .library(
            name: "MacVROpenXRRuntime",
            type: .dynamic,
            targets: ["MacVROpenXRRuntime"]
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
        .executable(
            name: "macvr-capture-sender",
            targets: ["MacVRCaptureSenderApp"]
        ),
        .executable(
            name: "macvr-runtime",
            targets: ["MacVRRuntimeApp"]
        ),
        .executable(
            name: "macvr-control-center",
            targets: ["MacVRControlCenterApp"]
        ),
        .executable(
            name: "macvr-viewer",
            targets: ["MacVRViewerApp"]
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
        .target(
            name: "MacVRRuntimeCore",
            dependencies: ["MacVRHostCore", "MacVRProtocol"]
        ),
        .target(
            name: "MacVROpenXRRuntime",
            publicHeadersPath: "include",
            cSettings: [
                .define("MACVR_RELEASE_VERSION", to: "\"\(releaseVersion)\""),
            ]
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
            name: "MacVRJPEGSenderApp",
            cSettings: [
                .define("MACVR_RELEASE_VERSION", to: "\"\(releaseVersion)\""),
            ]
        ),
        .executableTarget(
            name: "MacVRCaptureSenderApp",
            dependencies: ["MacVRHostCore", "MacVRProtocol"]
        ),
        .executableTarget(
            name: "MacVRRuntimeApp",
            dependencies: ["MacVRRuntimeCore", "MacVRProtocol"]
        ),
        .executableTarget(
            name: "MacVRControlCenterApp",
            dependencies: ["MacVRRuntimeCore", "MacVRProtocol"]
        ),
        .executableTarget(
            name: "MacVRViewerApp",
            dependencies: ["MacVRHostCore", "MacVRProtocol"]
        ),
        .testTarget(
            name: "MacVRHostCoreTests",
            dependencies: ["MacVRHostCore", "MacVRProtocol", "MacVRRuntimeCore", "MacVROpenXRRuntime"]
        ),
    ]
)
