import Foundation

/// JSON line protocol used by the host and client control channels.
public enum ClientMessageType: String, Codable, Sendable {
    case hello
    case pose
    case ping
}

public enum ServerMessageType: String, Codable, Sendable {
    case welcome
    case error
    case pong
    case streamStatus
}

public enum StreamMode: String, Codable, Sendable {
    case mock
    case displayJPEG = "display-jpeg"
    case bridgeJPEG = "bridge-jpeg"
}

public struct HelloPayload: Codable, Sendable {
    public let protocolVersion: Int
    public let clientName: String
    public let udpVideoPort: UInt16
    public let requestedFPS: Int?
    public let requestedStreamMode: StreamMode?

    public init(
        protocolVersion: Int = macVRProtocolVersion,
        clientName: String,
        udpVideoPort: UInt16,
        requestedFPS: Int? = nil,
        requestedStreamMode: StreamMode? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.clientName = clientName
        self.udpVideoPort = udpVideoPort
        self.requestedFPS = requestedFPS
        self.requestedStreamMode = requestedStreamMode
    }
}

public struct PosePayload: Codable, Sendable {
    public let timestampNs: UInt64
    public let positionMeters: [Double]
    public let orientationQuaternion: [Double]

    public init(
        timestampNs: UInt64,
        positionMeters: [Double],
        orientationQuaternion: [Double]
    ) {
        self.timestampNs = timestampNs
        self.positionMeters = positionMeters
        self.orientationQuaternion = orientationQuaternion
    }
}

public struct PingPayload: Codable, Sendable {
    public let nonce: String?

    public init(nonce: String? = nil) {
        self.nonce = nonce
    }
}

public struct WelcomePayload: Codable, Sendable {
    public let protocolVersion: Int
    public let sessionID: String
    public let targetFPS: Int
    public let udpVideoPort: UInt16
    public let streamMode: StreamMode
    public let codec: FrameCodec
    public let maxPacketSize: Int
    public let serverTimeNs: UInt64
    public let message: String

    public init(
        protocolVersion: Int = macVRProtocolVersion,
        sessionID: String,
        targetFPS: Int,
        udpVideoPort: UInt16,
        streamMode: StreamMode = .mock,
        codec: FrameCodec = .mockJSON,
        maxPacketSize: Int = 1200,
        serverTimeNs: UInt64,
        message: String
    ) {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.targetFPS = targetFPS
        self.udpVideoPort = udpVideoPort
        self.streamMode = streamMode
        self.codec = codec
        self.maxPacketSize = maxPacketSize
        self.serverTimeNs = serverTimeNs
        self.message = message
    }
}

public struct ErrorPayload: Codable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct PongPayload: Codable, Sendable {
    public let nonce: String?
    public let serverTimeNs: UInt64

    public init(nonce: String? = nil, serverTimeNs: UInt64) {
        self.nonce = nonce
        self.serverTimeNs = serverTimeNs
    }
}

public struct StreamStatusPayload: Codable, Sendable {
    public let state: String
    public let frameIndex: UInt64

    public init(state: String, frameIndex: UInt64) {
        self.state = state
        self.frameIndex = frameIndex
    }
}

public struct ClientControlMessage: Codable, Sendable {
    public let type: ClientMessageType
    public let hello: HelloPayload?
    public let pose: PosePayload?
    public let ping: PingPayload?

    public init(
        type: ClientMessageType,
        hello: HelloPayload? = nil,
        pose: PosePayload? = nil,
        ping: PingPayload? = nil
    ) {
        self.type = type
        self.hello = hello
        self.pose = pose
        self.ping = ping
    }

    public static func hello(_ payload: HelloPayload) -> Self {
        Self(type: .hello, hello: payload)
    }

    public static func pose(_ payload: PosePayload) -> Self {
        Self(type: .pose, pose: payload)
    }

    public static func ping(_ payload: PingPayload) -> Self {
        Self(type: .ping, ping: payload)
    }
}

public struct ServerControlMessage: Codable, Sendable {
    public let type: ServerMessageType
    public let welcome: WelcomePayload?
    public let error: ErrorPayload?
    public let pong: PongPayload?
    public let streamStatus: StreamStatusPayload?

    public init(
        type: ServerMessageType,
        welcome: WelcomePayload? = nil,
        error: ErrorPayload? = nil,
        pong: PongPayload? = nil,
        streamStatus: StreamStatusPayload? = nil
    ) {
        self.type = type
        self.welcome = welcome
        self.error = error
        self.pong = pong
        self.streamStatus = streamStatus
    }

    public static func welcome(_ payload: WelcomePayload) -> Self {
        Self(type: .welcome, welcome: payload)
    }

    public static func error(_ payload: ErrorPayload) -> Self {
        Self(type: .error, error: payload)
    }

    public static func pong(_ payload: PongPayload) -> Self {
        Self(type: .pong, pong: payload)
    }

    public static func streamStatus(_ payload: StreamStatusPayload) -> Self {
        Self(type: .streamStatus, streamStatus: payload)
    }
}

public struct MockFramePacket: Codable, Sendable {
    public let protocolVersion: Int
    public let sessionID: String
    public let frameIndex: UInt64
    public let sentTimeNs: UInt64
    public let predictedDisplayTimeNs: UInt64
    public let pose: PosePayload?
    public let frameTag: String
    public let transport: String

    public init(
        protocolVersion: Int = macVRProtocolVersion,
        sessionID: String,
        frameIndex: UInt64,
        sentTimeNs: UInt64,
        predictedDisplayTimeNs: UInt64,
        pose: PosePayload?,
        frameTag: String,
        transport: String = "mock-json-udp"
    ) {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.frameIndex = frameIndex
        self.sentTimeNs = sentTimeNs
        self.predictedDisplayTimeNs = predictedDisplayTimeNs
        self.pose = pose
        self.frameTag = frameTag
        self.transport = transport
    }
}

public enum WireCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
