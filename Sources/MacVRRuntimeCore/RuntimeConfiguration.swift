import Foundation
import MacVRHostCore
import MacVRProtocol

/// Shared runtime defaults used by the CLI service and the macOS control center.
/// The bundled runtime is intentionally bridge-first so external producers can feed
/// frames into the existing host transport without requiring SteamVR or another
/// third-party runtime to be present.
public struct RuntimeConfiguration: Sendable {
    public let controlPort: UInt16
    public let bridgePort: UInt16
    public let jpegInputPort: UInt16
    public let targetFPS: Int
    public let frameTag: String
    public let maxPacketSize: Int
    public let bridgeMaxFrameAgeMs: Int
    public let jpegMaxBytes: Int
    public let verbose: Bool

    public init(
        controlPort: UInt16 = 42000,
        bridgePort: UInt16 = 43000,
        jpegInputPort: UInt16 = 44000,
        targetFPS: Int = 72,
        frameTag: String = "runtime",
        maxPacketSize: Int = FrameChunkPacketizer.defaultMaxPacketSize,
        bridgeMaxFrameAgeMs: Int = 250,
        jpegMaxBytes: Int = 2_000_000,
        verbose: Bool = false
    ) {
        self.controlPort = controlPort
        self.bridgePort = bridgePort
        self.jpegInputPort = jpegInputPort
        self.targetFPS = HostConfiguration.clampFPS(targetFPS)
        self.frameTag = frameTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "runtime" : frameTag
        self.maxPacketSize = HostConfiguration.clampPacketSize(maxPacketSize)
        self.bridgeMaxFrameAgeMs = HostConfiguration.clampBridgeFrameAgeMs(bridgeMaxFrameAgeMs)
        self.jpegMaxBytes = Self.clampJPEGMaxBytes(jpegMaxBytes)
        self.verbose = verbose
    }

    public static func clampJPEGMaxBytes(_ value: Int) -> Int {
        min(max(value, 16_384), 16_000_000)
    }

    public var hostConfiguration: HostConfiguration {
        HostConfiguration(
            controlPort: controlPort,
            targetFPS: targetFPS,
            frameTag: frameTag,
            streamMode: .bridgeJPEG,
            bridgePort: bridgePort,
            maxPacketSize: maxPacketSize,
            bridgeMaxFrameAgeMs: bridgeMaxFrameAgeMs,
            displayID: nil,
            jpegQuality: 70,
            verbose: verbose
        )
    }
}
