import Foundation
import MacVRProtocol

/// Static host defaults plus value clamping shared by CLI parsing and runtime setup.
public struct HostConfiguration: Sendable {
    public let controlPort: UInt16
    public let targetFPS: Int
    public let frameTag: String
    public let streamMode: StreamMode
    public let bridgePort: UInt16
    public let maxPacketSize: Int
    public let bridgeMaxFrameAgeMs: Int
    public let displayID: UInt32?
    public let jpegQuality: Int
    public let trackingStatePath: String?
    public let verbose: Bool

    public init(
        controlPort: UInt16 = 42000,
        targetFPS: Int = 72,
        frameTag: String = "mock",
        streamMode: StreamMode = .displayJPEG,
        bridgePort: UInt16 = 43000,
        maxPacketSize: Int = FrameChunkPacketizer.defaultMaxPacketSize,
        bridgeMaxFrameAgeMs: Int = 250,
        displayID: UInt32? = nil,
        jpegQuality: Int = 70,
        trackingStatePath: String? = nil,
        verbose: Bool = false
    ) {
        self.controlPort = controlPort
        self.targetFPS = Self.clampFPS(targetFPS)
        self.frameTag = frameTag
        self.streamMode = streamMode
        self.bridgePort = bridgePort
        self.maxPacketSize = Self.clampPacketSize(maxPacketSize)
        self.bridgeMaxFrameAgeMs = Self.clampBridgeFrameAgeMs(bridgeMaxFrameAgeMs)
        self.displayID = displayID
        self.jpegQuality = Self.clampJPEGQuality(jpegQuality)
        let trimmedTrackingStatePath = trackingStatePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.trackingStatePath = trimmedTrackingStatePath?.isEmpty == false ? trimmedTrackingStatePath : nil
        self.verbose = verbose
    }

    public static func clampFPS(_ fps: Int) -> Int {
        min(max(fps, 1), 240)
    }

    public static func frameIntervalNanoseconds(targetFPS: Int) -> UInt64 {
        UInt64(1_000_000_000 / clampFPS(targetFPS))
    }

    public static func clampPacketSize(_ packetSize: Int) -> Int {
        min(max(packetSize, 512), 65_507)
    }

    public static func clampJPEGQuality(_ quality: Int) -> Int {
        // Keep runtime behavior aligned with the advertised CLI range.
        min(max(quality, 1), 100)
    }

    public static func clampBridgeFrameAgeMs(_ maxAgeMs: Int) -> Int {
        min(max(maxAgeMs, 0), 10_000)
    }
}
