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
    public let discoveryPort: UInt16
    public let targetFPS: Int
    public let serverName: String
    public let requireTrustedClients: Bool
    public let autoTrustLoopbackClients: Bool
    public let trustedClientsPath: String
    public let frameTag: String
    public let maxPacketSize: Int
    public let bridgeMaxFrameAgeMs: Int
    public let jpegMaxBytes: Int
    public let trackingStatePath: String
    public let verbose: Bool

    public init(
        controlPort: UInt16 = 42000,
        bridgePort: UInt16 = 43000,
        jpegInputPort: UInt16 = 44000,
        discoveryPort: UInt16 = 9943,
        targetFPS: Int = 72,
        serverName: String = "macVR Runtime",
        requireTrustedClients: Bool = false,
        autoTrustLoopbackClients: Bool = true,
        trustedClientsPath: String = RuntimeConfiguration.suggestedTrustedClientsPath(),
        frameTag: String = "runtime",
        maxPacketSize: Int = FrameChunkPacketizer.defaultMaxPacketSize,
        bridgeMaxFrameAgeMs: Int = 250,
        jpegMaxBytes: Int = 2_000_000,
        trackingStatePath: String = TrackingStateStore.suggestedPath().path,
        verbose: Bool = false
    ) {
        self.controlPort = controlPort
        self.bridgePort = bridgePort
        self.jpegInputPort = jpegInputPort
        self.discoveryPort = discoveryPort
        self.targetFPS = HostConfiguration.clampFPS(targetFPS)
        let trimmedServerName = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.serverName = trimmedServerName.isEmpty ? "macVR Runtime" : trimmedServerName
        self.requireTrustedClients = requireTrustedClients
        self.autoTrustLoopbackClients = autoTrustLoopbackClients
        let trimmedTrustedClientsPath = trustedClientsPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.trustedClientsPath = trimmedTrustedClientsPath.isEmpty
            ? Self.suggestedTrustedClientsPath()
            : trimmedTrustedClientsPath
        self.frameTag = frameTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "runtime" : frameTag
        self.maxPacketSize = HostConfiguration.clampPacketSize(maxPacketSize)
        self.bridgeMaxFrameAgeMs = HostConfiguration.clampBridgeFrameAgeMs(bridgeMaxFrameAgeMs)
        self.jpegMaxBytes = Self.clampJPEGMaxBytes(jpegMaxBytes)
        let trimmedTrackingStatePath = trackingStatePath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.trackingStatePath = trimmedTrackingStatePath.isEmpty
            ? TrackingStateStore.suggestedPath().path
            : trimmedTrackingStatePath
        self.verbose = verbose
    }

    public static func clampJPEGMaxBytes(_ value: Int) -> Int {
        min(max(value, 16_384), 16_000_000)
    }

    public static func suggestedTrustedClientsPath() -> String {
        TrustedClientStore.suggestedPath().path
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
            trackingStatePath: trackingStatePath,
            verbose: verbose
        )
    }
}
