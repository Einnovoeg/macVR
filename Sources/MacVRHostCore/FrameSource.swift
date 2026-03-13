import CoreGraphics
import Foundation
import ImageIO
import MacVRProtocol
import UniformTypeIdentifiers

/// Produces transport-ready frames for the active session stream mode.
struct ProducedFrame: Sendable {
    let codec: FrameCodec
    let flags: UInt8
    let payload: Data
}

protocol FrameSource: Sendable {
    func makeFrame(
        sessionID: String,
        frameIndex: UInt64,
        sentTimeNs: UInt64,
        predictedDisplayTimeNs: UInt64,
        pose: PosePayload?
    ) -> ProducedFrame?
}

enum FrameSourceFactory {
    static func make(
        streamMode: StreamMode,
        frameTag: String,
        bridgeFrameStore: BridgeFrameStore?,
        bridgeMaxFrameAgeMs: Int,
        displayID: UInt32?,
        jpegQuality: Int,
        logger: HostLogger
    ) -> any FrameSource {
        switch streamMode {
        case .mock:
            return MockFrameSource(frameTag: frameTag)
        case .displayJPEG:
            return DisplayJPEGFrameSource(
                frameTag: frameTag,
                displayID: displayID,
                jpegQuality: jpegQuality,
                logger: logger
            )
        case .bridgeJPEG:
            guard let bridgeFrameStore else {
                return UnavailableFrameSource(
                    streamMode: streamMode,
                    reason: "bridge frame store is not configured",
                    logger: logger
                )
            }
            return BridgeJPEGFrameSource(
                frameTag: frameTag,
                frameStore: bridgeFrameStore,
                maxFrameAgeMs: bridgeMaxFrameAgeMs,
                logger: logger
            )
        }
    }
}

final class UnavailableFrameSource: FrameSource, @unchecked Sendable {
    private let streamMode: StreamMode
    private let reason: String
    private let logger: HostLogger
    private var emittedWarning = false

    init(streamMode: StreamMode, reason: String, logger: HostLogger) {
        self.streamMode = streamMode
        self.reason = reason
        self.logger = logger
    }

    func makeFrame(
        sessionID _: String,
        frameIndex _: UInt64,
        sentTimeNs _: UInt64,
        predictedDisplayTimeNs _: UInt64,
        pose _: PosePayload?
    ) -> ProducedFrame? {
        if !emittedWarning {
            emittedWarning = true
            logger.log(.warning, "Stream mode \(streamMode.rawValue) is unavailable: \(reason)")
        }
        return nil
    }
}

final class MockFrameSource: FrameSource, @unchecked Sendable {
    private let frameTag: String

    init(frameTag: String) {
        self.frameTag = frameTag
    }

    func makeFrame(
        sessionID: String,
        frameIndex: UInt64,
        sentTimeNs: UInt64,
        predictedDisplayTimeNs: UInt64,
        pose: PosePayload?
    ) -> ProducedFrame? {
        let packet = MockFramePacket(
            sessionID: sessionID,
            frameIndex: frameIndex,
            sentTimeNs: sentTimeNs,
            predictedDisplayTimeNs: predictedDisplayTimeNs,
            pose: pose,
            frameTag: frameTag
        )

        do {
            let payload = try WireCodec.encode(packet)
            return ProducedFrame(codec: .mockJSON, flags: 0x01, payload: payload)
        } catch {
            return nil
        }
    }
}

final class DisplayJPEGFrameSource: FrameSource, @unchecked Sendable {
    private let frameTag: String
    private let displayID: CGDirectDisplayID
    private let jpegQuality: CGFloat
    private let logger: HostLogger
    private var droppedFrameCount: UInt64 = 0

    init(frameTag: String, displayID: UInt32?, jpegQuality: Int, logger: HostLogger) {
        self.frameTag = frameTag
        self.displayID = displayID.map { CGDirectDisplayID($0) } ?? CGMainDisplayID()
        self.jpegQuality = CGFloat(HostConfiguration.clampJPEGQuality(jpegQuality)) / 100.0
        self.logger = logger
    }

    func makeFrame(
        sessionID _: String,
        frameIndex _: UInt64,
        sentTimeNs _: UInt64,
        predictedDisplayTimeNs _: UInt64,
        pose _: PosePayload?
    ) -> ProducedFrame? {
        guard let image = CGDisplayCreateImage(displayID) else {
            droppedFrameCount &+= 1
            if droppedFrameCount % 120 == 1 {
                logger.log(
                    .warning,
                    "Display capture failed for display \(displayID). Screen Recording permission may be missing."
                )
            }
            return nil
        }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            droppedFrameCount &+= 1
            if droppedFrameCount % 120 == 1 {
                logger.log(.warning, "Unable to initialize JPEG encoder destination for frame source \(frameTag)")
            }
            return nil
        }

        let options = [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            droppedFrameCount &+= 1
            if droppedFrameCount % 120 == 1 {
                logger.log(.warning, "JPEG finalize failed for frame source \(frameTag)")
            }
            return nil
        }

        return ProducedFrame(codec: .jpeg, flags: 0x01, payload: encoded as Data)
    }
}

final class BridgeJPEGFrameSource: FrameSource, @unchecked Sendable {
    private let frameTag: String
    private let frameStore: BridgeFrameStore
    private let maxFrameAgeNs: UInt64?
    private let logger: HostLogger
    private var lastFrameIndex: UInt64?
    private var emptyPolls: UInt64 = 0
    private var stalePolls: UInt64 = 0

    init(frameTag: String, frameStore: BridgeFrameStore, maxFrameAgeMs: Int, logger: HostLogger) {
        self.frameTag = frameTag
        self.frameStore = frameStore
        let clamped = HostConfiguration.clampBridgeFrameAgeMs(maxFrameAgeMs)
        self.maxFrameAgeNs = clamped > 0 ? UInt64(clamped) * 1_000_000 : nil
        self.logger = logger
    }

    func makeFrame(
        sessionID _: String,
        frameIndex _: UInt64,
        sentTimeNs _: UInt64,
        predictedDisplayTimeNs _: UInt64,
        pose _: PosePayload?
    ) -> ProducedFrame? {
        guard let snapshot = frameStore.latestSnapshot() else {
            emptyPolls &+= 1
            if emptyPolls % 240 == 1 {
                logger.log(.warning, "No bridge frames available yet for frame source \(frameTag)")
            }
            return nil
        }

        if let maxFrameAgeNs {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            let ageNs = nowNs &- snapshot.receivedTimeNs
            if ageNs > maxFrameAgeNs {
                stalePolls &+= 1
                if stalePolls % 120 == 1 {
                    let ageMs = Double(ageNs) / 1_000_000.0
                    let limitMs = Double(maxFrameAgeNs) / 1_000_000.0
                    logger.log(
                        .warning,
                        String(
                            format: "Dropping stale bridge frame %.1fms old (limit=%.1fms) for source %@",
                            ageMs,
                            limitMs,
                            snapshot.source
                        )
                    )
                }
                return nil
            }

            if stalePolls > 0 {
                logger.log(.info, "Bridge frame source \(snapshot.source) resumed after stale period")
                stalePolls = 0
            }
        }

        emptyPolls = 0
        if lastFrameIndex != snapshot.frameIndex {
            lastFrameIndex = snapshot.frameIndex
            logger.log(
                .debug,
                "Bridge frame update source=\(snapshot.source) index=\(snapshot.frameIndex) bytes=\(snapshot.jpegData.count)"
            )
        }

        return ProducedFrame(codec: .jpeg, flags: 0x01, payload: snapshot.jpegData)
    }
}
