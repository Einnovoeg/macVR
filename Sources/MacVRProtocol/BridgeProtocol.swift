import Foundation

/// Bridge control and UDP envelope messages used by external frame producers.
public enum BridgeClientMessageType: String, Codable, Sendable {
    case hello
    case submitFrame
    case ping
}

public enum BridgeServerMessageType: String, Codable, Sendable {
    case welcome
    case error
    case pong
}

public enum BridgeFrameTransport: String, Codable, Sendable {
    case tcpInlineBase64 = "tcp-inline-base64"
    case udpChunked = "udp-chunked"
}

public struct BridgeHelloPayload: Codable, Sendable {
    public let protocolVersion: Int
    public let clientName: String
    public let source: String
    public let preferredTransport: BridgeFrameTransport?
    public let maxPacketSize: Int?

    public init(
        protocolVersion: Int = macVRProtocolVersion,
        clientName: String,
        source: String = "bridge",
        preferredTransport: BridgeFrameTransport? = nil,
        maxPacketSize: Int? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.clientName = clientName
        self.source = source
        self.preferredTransport = preferredTransport
        self.maxPacketSize = maxPacketSize
    }
}

public struct BridgeSubmitFramePayload: Codable, Sendable {
    public let frameIndex: UInt64
    public let sentTimeNs: UInt64
    public let jpegBase64: String
    public let width: Int?
    public let height: Int?

    public init(
        frameIndex: UInt64,
        sentTimeNs: UInt64,
        jpegBase64: String,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.frameIndex = frameIndex
        self.sentTimeNs = sentTimeNs
        self.jpegBase64 = jpegBase64
        self.width = width
        self.height = height
    }

    public func decodeJPEGData(maxBytes: Int = 16_000_000) -> Data? {
        guard let data = Data(base64Encoded: jpegBase64), !data.isEmpty else {
            return nil
        }
        guard data.count <= maxBytes else {
            return nil
        }
        return data
    }
}

public struct BridgePingPayload: Codable, Sendable {
    public let nonce: String?

    public init(nonce: String? = nil) {
        self.nonce = nonce
    }
}

public struct BridgeWelcomePayload: Codable, Sendable {
    public let protocolVersion: Int
    public let message: String
    public let acceptedSource: String
    public let frameTransport: BridgeFrameTransport
    public let udpIngestPort: UInt16?
    public let maxPacketSize: Int?
    public let udpAuthTokenBase64: String?

    public init(
        protocolVersion: Int = macVRProtocolVersion,
        message: String,
        acceptedSource: String,
        frameTransport: BridgeFrameTransport = .tcpInlineBase64,
        udpIngestPort: UInt16? = nil,
        maxPacketSize: Int? = nil,
        udpAuthTokenBase64: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.message = message
        self.acceptedSource = acceptedSource
        self.frameTransport = frameTransport
        self.udpIngestPort = udpIngestPort
        self.maxPacketSize = maxPacketSize
        self.udpAuthTokenBase64 = udpAuthTokenBase64
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case message
        case acceptedSource
        case frameTransport
        case udpIngestPort
        case maxPacketSize
        case udpAuthTokenBase64
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        message = try container.decode(String.self, forKey: .message)
        acceptedSource = try container.decode(String.self, forKey: .acceptedSource)
        frameTransport = try container.decodeIfPresent(BridgeFrameTransport.self, forKey: .frameTransport) ?? .tcpInlineBase64
        udpIngestPort = try container.decodeIfPresent(UInt16.self, forKey: .udpIngestPort)
        maxPacketSize = try container.decodeIfPresent(Int.self, forKey: .maxPacketSize)
        udpAuthTokenBase64 = try container.decodeIfPresent(String.self, forKey: .udpAuthTokenBase64)
    }
}

public struct BridgeErrorPayload: Codable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct BridgePongPayload: Codable, Sendable {
    public let nonce: String?
    public let serverTimeNs: UInt64

    public init(nonce: String? = nil, serverTimeNs: UInt64) {
        self.nonce = nonce
        self.serverTimeNs = serverTimeNs
    }
}

public struct BridgeUDPPacketEnvelopePayload: Sendable {
    public let authToken: Data
    public let frameChunkPacket: Data

    public init(authToken: Data, frameChunkPacket: Data) {
        self.authToken = authToken
        self.frameChunkPacket = frameChunkPacket
    }
}

public enum BridgeUDPPacketEnvelopeError: Error {
    case invalidTokenLength(Int)
    case packetTooSmall(Int)
    case invalidMagic(UInt32)
    case missingFrameChunk
}

public enum BridgeUDPPacketEnvelope {
    public static let magic: UInt32 = 0x4D425231 // "MBR1"
    public static let authTokenByteCount = 16
    public static let headerByteCount = 4 + authTokenByteCount

    public static func encode(authToken: Data, frameChunkPacket: Data) throws -> Data {
        guard authToken.count == authTokenByteCount else {
            throw BridgeUDPPacketEnvelopeError.invalidTokenLength(authToken.count)
        }
        guard !frameChunkPacket.isEmpty else {
            throw BridgeUDPPacketEnvelopeError.missingFrameChunk
        }

        var packet = Data(capacity: headerByteCount + frameChunkPacket.count)
        packet.appendBigEndian(magic)
        packet.append(authToken)
        packet.append(frameChunkPacket)
        return packet
    }

    public static func decode(_ packet: Data) throws -> BridgeUDPPacketEnvelopePayload {
        guard packet.count >= headerByteCount else {
            throw BridgeUDPPacketEnvelopeError.packetTooSmall(packet.count)
        }

        let packetMagic = packet.readUInt32BE(at: 0)
        guard packetMagic == magic else {
            throw BridgeUDPPacketEnvelopeError.invalidMagic(packetMagic)
        }

        let chunk = Data(packet[headerByteCount...])
        guard !chunk.isEmpty else {
            throw BridgeUDPPacketEnvelopeError.missingFrameChunk
        }

        let authToken = Data(packet[4..<headerByteCount])
        return BridgeUDPPacketEnvelopePayload(authToken: authToken, frameChunkPacket: chunk)
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            append(bytes.bindMemory(to: UInt8.self))
        }
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }
}

public struct BridgeClientMessage: Codable, Sendable {
    public let type: BridgeClientMessageType
    public let hello: BridgeHelloPayload?
    public let submitFrame: BridgeSubmitFramePayload?
    public let ping: BridgePingPayload?

    public init(
        type: BridgeClientMessageType,
        hello: BridgeHelloPayload? = nil,
        submitFrame: BridgeSubmitFramePayload? = nil,
        ping: BridgePingPayload? = nil
    ) {
        self.type = type
        self.hello = hello
        self.submitFrame = submitFrame
        self.ping = ping
    }

    public static func hello(_ payload: BridgeHelloPayload) -> Self {
        Self(type: .hello, hello: payload)
    }

    public static func submitFrame(_ payload: BridgeSubmitFramePayload) -> Self {
        Self(type: .submitFrame, submitFrame: payload)
    }

    public static func ping(_ payload: BridgePingPayload) -> Self {
        Self(type: .ping, ping: payload)
    }
}

public struct BridgeServerMessage: Codable, Sendable {
    public let type: BridgeServerMessageType
    public let welcome: BridgeWelcomePayload?
    public let error: BridgeErrorPayload?
    public let pong: BridgePongPayload?

    public init(
        type: BridgeServerMessageType,
        welcome: BridgeWelcomePayload? = nil,
        error: BridgeErrorPayload? = nil,
        pong: BridgePongPayload? = nil
    ) {
        self.type = type
        self.welcome = welcome
        self.error = error
        self.pong = pong
    }

    public static func welcome(_ payload: BridgeWelcomePayload) -> Self {
        Self(type: .welcome, welcome: payload)
    }

    public static func error(_ payload: BridgeErrorPayload) -> Self {
        Self(type: .error, error: payload)
    }

    public static func pong(_ payload: BridgePongPayload) -> Self {
        Self(type: .pong, pong: payload)
    }
}
