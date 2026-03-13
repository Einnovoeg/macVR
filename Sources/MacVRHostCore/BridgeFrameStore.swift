import Foundation

public struct BridgeFrameSnapshot: Sendable {
    public let frameIndex: UInt64
    public let sentTimeNs: UInt64
    public let receivedTimeNs: UInt64
    public let source: String
    public let width: Int?
    public let height: Int?
    public let jpegData: Data

    public init(
        frameIndex: UInt64,
        sentTimeNs: UInt64,
        receivedTimeNs: UInt64,
        source: String,
        width: Int?,
        height: Int?,
        jpegData: Data
    ) {
        self.frameIndex = frameIndex
        self.sentTimeNs = sentTimeNs
        self.receivedTimeNs = receivedTimeNs
        self.source = source
        self.width = width
        self.height = height
        self.jpegData = jpegData
    }
}

public struct BridgeFrameStats: Sendable {
    public let totalFrames: UInt64
    public let totalBytes: UInt64
    public let lastFrameIndex: UInt64?
    public let lastSource: String?

    public init(totalFrames: UInt64, totalBytes: UInt64, lastFrameIndex: UInt64?, lastSource: String?) {
        self.totalFrames = totalFrames
        self.totalBytes = totalBytes
        self.lastFrameIndex = lastFrameIndex
        self.lastSource = lastSource
    }
}

public final class BridgeFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: BridgeFrameSnapshot?
    private var totalFrames: UInt64 = 0
    private var totalBytes: UInt64 = 0

    public init() {}

    public func update(
        frameIndex: UInt64,
        sentTimeNs: UInt64,
        source: String,
        width: Int?,
        height: Int?,
        jpegData: Data
    ) {
        lock.lock()
        defer { lock.unlock() }

        let nowNs = DispatchTime.now().uptimeNanoseconds
        latest = BridgeFrameSnapshot(
            frameIndex: frameIndex,
            sentTimeNs: sentTimeNs,
            receivedTimeNs: nowNs,
            source: source,
            width: width,
            height: height,
            jpegData: jpegData
        )
        totalFrames &+= 1
        totalBytes &+= UInt64(jpegData.count)
    }

    public func latestSnapshot() -> BridgeFrameSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    public func stats() -> BridgeFrameStats {
        lock.lock()
        defer { lock.unlock() }
        return BridgeFrameStats(
            totalFrames: totalFrames,
            totalBytes: totalBytes,
            lastFrameIndex: latest?.frameIndex,
            lastSource: latest?.source
        )
    }
}
