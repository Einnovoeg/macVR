import Foundation

/// Encodes large logical frames into datagram-sized chunks and reassembles them on receive.
public enum FrameCodec: UInt8, Codable, Sendable {
    case mockJSON = 0
    case jpeg = 1
}

public struct FrameChunkHeader: Sendable {
    public static let magic: UInt32 = 0x4D565232 // "MVR2"
    public static let version: UInt8 = 1
    public static let byteCount = 28

    public let codec: FrameCodec
    public let flags: UInt8
    public let frameIndex: UInt64
    public let sentTimeNs: UInt64
    public let chunkIndex: UInt16
    public let chunkCount: UInt16

    public var isKeyFrame: Bool {
        (flags & 0x01) != 0
    }

    public init(
        codec: FrameCodec,
        flags: UInt8,
        frameIndex: UInt64,
        sentTimeNs: UInt64,
        chunkIndex: UInt16,
        chunkCount: UInt16
    ) {
        self.codec = codec
        self.flags = flags
        self.frameIndex = frameIndex
        self.sentTimeNs = sentTimeNs
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
    }
}

public struct FrameChunkPacket: Sendable {
    public let header: FrameChunkHeader
    public let payload: Data

    public init(header: FrameChunkHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }
}

public struct ReassembledFrame: Sendable {
    public let codec: FrameCodec
    public let flags: UInt8
    public let frameIndex: UInt64
    public let sentTimeNs: UInt64
    public let payload: Data

    public init(codec: FrameCodec, flags: UInt8, frameIndex: UInt64, sentTimeNs: UInt64, payload: Data) {
        self.codec = codec
        self.flags = flags
        self.frameIndex = frameIndex
        self.sentTimeNs = sentTimeNs
        self.payload = payload
    }
}

public enum FrameTransportError: Error {
    case packetTooSmall(Int)
    case invalidMagic(UInt32)
    case unsupportedVersion(UInt8)
    case invalidCodec(UInt8)
    case invalidChunkLayout(chunkIndex: UInt16, chunkCount: UInt16)
    case maxPacketSizeTooSmall(Int)
    case frameTooLarge
    case mismatchedChunkMetadata
}

public enum FrameChunkPacketizer {
    public static let defaultMaxPacketSize = 1200

    public static func packetize(
        codec: FrameCodec,
        flags: UInt8,
        frameIndex: UInt64,
        sentTimeNs: UInt64,
        payload: Data,
        maxPacketSize: Int = defaultMaxPacketSize
    ) throws -> [Data] {
        let maxPayloadSize = maxPacketSize - FrameChunkHeader.byteCount
        guard maxPayloadSize > 0 else {
            throw FrameTransportError.maxPacketSizeTooSmall(maxPacketSize)
        }

        let chunkCountInt = max(1, (payload.count + maxPayloadSize - 1) / maxPayloadSize)
        guard chunkCountInt <= Int(UInt16.max) else {
            throw FrameTransportError.frameTooLarge
        }

        let chunkCount = UInt16(chunkCountInt)
        var offset = 0
        var packets: [Data] = []
        packets.reserveCapacity(chunkCountInt)

        for chunkIndex in 0..<chunkCountInt {
            let end = min(offset + maxPayloadSize, payload.count)
            let chunkPayload = payload[offset..<end]
            offset = end

            let header = FrameChunkHeader(
                codec: codec,
                flags: flags,
                frameIndex: frameIndex,
                sentTimeNs: sentTimeNs,
                chunkIndex: UInt16(chunkIndex),
                chunkCount: chunkCount
            )
            var packet = Data(capacity: FrameChunkHeader.byteCount + chunkPayload.count)
            encodeHeader(header, into: &packet)
            packet.append(chunkPayload)
            packets.append(packet)
        }

        return packets
    }

    private static func encodeHeader(_ header: FrameChunkHeader, into data: inout Data) {
        data.appendBigEndian(FrameChunkHeader.magic)
        data.append(FrameChunkHeader.version)
        data.append(header.codec.rawValue)
        data.append(header.flags)
        data.append(0x00) // reserved
        data.appendBigEndian(header.frameIndex)
        data.appendBigEndian(header.sentTimeNs)
        data.appendBigEndian(header.chunkIndex)
        data.appendBigEndian(header.chunkCount)
    }
}

public enum FrameChunkParser {
    public static func parse(_ packetData: Data) throws -> FrameChunkPacket {
        guard packetData.count >= FrameChunkHeader.byteCount else {
            throw FrameTransportError.packetTooSmall(packetData.count)
        }

        let magic = packetData.readUInt32BE(at: 0)
        guard magic == FrameChunkHeader.magic else {
            throw FrameTransportError.invalidMagic(magic)
        }

        let version = packetData[4]
        guard version == FrameChunkHeader.version else {
            throw FrameTransportError.unsupportedVersion(version)
        }

        let codecRaw = packetData[5]
        guard let codec = FrameCodec(rawValue: codecRaw) else {
            throw FrameTransportError.invalidCodec(codecRaw)
        }

        let flags = packetData[6]
        let frameIndex = packetData.readUInt64BE(at: 8)
        let sentTimeNs = packetData.readUInt64BE(at: 16)
        let chunkIndex = packetData.readUInt16BE(at: 24)
        let chunkCount = packetData.readUInt16BE(at: 26)
        guard chunkCount > 0, chunkIndex < chunkCount else {
            throw FrameTransportError.invalidChunkLayout(chunkIndex: chunkIndex, chunkCount: chunkCount)
        }

        let payload = Data(packetData[FrameChunkHeader.byteCount...])
        let header = FrameChunkHeader(
            codec: codec,
            flags: flags,
            frameIndex: frameIndex,
            sentTimeNs: sentTimeNs,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount
        )
        return FrameChunkPacket(header: header, payload: payload)
    }
}

public final class FrameReassembler: @unchecked Sendable {
    // Each multi-packet frame is tracked until all chunks arrive or the frame ages out.
    private struct PendingFrame {
        var codec: FrameCodec
        var flags: UInt8
        var sentTimeNs: UInt64
        var chunks: [Data?]
        var receivedChunks: Int
        var createdTimeNs: UInt64
    }

    private var pending: [UInt64: PendingFrame] = [:]
    private let maxPendingFrames: Int
    private let maxFrameAgeNs: UInt64

    public init(maxPendingFrames: Int = 120, maxFrameAgeNs: UInt64 = 5_000_000_000) {
        self.maxPendingFrames = max(maxPendingFrames, 8)
        self.maxFrameAgeNs = max(maxFrameAgeNs, 250_000_000)
    }

    public func ingest(_ packetData: Data, nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) throws -> ReassembledFrame? {
        let packet = try FrameChunkParser.parse(packetData)
        let header = packet.header

        if header.chunkCount == 1 {
            return ReassembledFrame(
                codec: header.codec,
                flags: header.flags,
                frameIndex: header.frameIndex,
                sentTimeNs: header.sentTimeNs,
                payload: packet.payload
            )
        }

        var pendingFrame = pending[header.frameIndex] ?? PendingFrame(
            codec: header.codec,
            flags: header.flags,
            sentTimeNs: header.sentTimeNs,
            chunks: Array(repeating: nil, count: Int(header.chunkCount)),
            receivedChunks: 0,
            createdTimeNs: nowNs
        )

        let expectedChunks = Int(header.chunkCount)
        if pendingFrame.chunks.count != expectedChunks
            || pendingFrame.codec != header.codec
            || pendingFrame.sentTimeNs != header.sentTimeNs
        {
            throw FrameTransportError.mismatchedChunkMetadata
        }

        let chunkSlot = Int(header.chunkIndex)
        if pendingFrame.chunks[chunkSlot] == nil {
            pendingFrame.chunks[chunkSlot] = packet.payload
            pendingFrame.receivedChunks += 1
        }

        if pendingFrame.receivedChunks == expectedChunks {
            let totalLength = pendingFrame.chunks.reduce(0) { partial, chunk in
                partial + (chunk?.count ?? 0)
            }
            var joined = Data(capacity: totalLength)
            // Preserve original chunk order rather than arrival order.
            for chunk in pendingFrame.chunks {
                if let chunk {
                    joined.append(chunk)
                }
            }
            pending.removeValue(forKey: header.frameIndex)
            return ReassembledFrame(
                codec: header.codec,
                flags: header.flags,
                frameIndex: header.frameIndex,
                sentTimeNs: header.sentTimeNs,
                payload: joined
            )
        }

        pending[header.frameIndex] = pendingFrame
        purgeExpired(nowNs: nowNs)
        enforcePendingLimit()
        return nil
    }

    public func purgeExpired(nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        pending = pending.filter { _, pendingFrame in
            nowNs &- pendingFrame.createdTimeNs <= maxFrameAgeNs
        }
    }

    private func enforcePendingLimit() {
        guard pending.count > maxPendingFrames else {
            return
        }

        let keysByAge = pending
            .map { ($0.key, $0.value.createdTimeNs) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)

        let dropCount = pending.count - maxPendingFrames
        for key in keysByAge.prefix(dropCount) {
            pending.removeValue(forKey: key)
        }
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            append(bytes.bindMemory(to: UInt8.self))
        }
    }

    func readUInt16BE(at offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        (UInt64(self[offset]) << 56)
            | (UInt64(self[offset + 1]) << 48)
            | (UInt64(self[offset + 2]) << 40)
            | (UInt64(self[offset + 3]) << 32)
            | (UInt64(self[offset + 4]) << 24)
            | (UInt64(self[offset + 5]) << 16)
            | (UInt64(self[offset + 6]) << 8)
            | UInt64(self[offset + 7])
    }
}
