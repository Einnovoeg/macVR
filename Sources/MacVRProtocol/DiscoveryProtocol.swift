import Foundation

/// Lightweight UDP discovery messages used by the native macVR runtime and
/// viewer. The goal is not full session negotiation over UDP; it is simply to
/// help a viewer find runtimes on the local network before the normal TCP
/// control channel takes over.
public struct RuntimeDiscoveryProbe: Codable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let clientName: String
    public let requestedStreamMode: StreamMode?

    public init(
        protocolVersion: Int = macVRProtocolVersion,
        requestID: String,
        clientName: String,
        requestedStreamMode: StreamMode? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.clientName = clientName
        self.requestedStreamMode = requestedStreamMode
    }
}

/// Sent as a unicast UDP reply to `RuntimeDiscoveryProbe`. The viewer uses the
/// packet source address as the runtime host and the payload for the remaining
/// session metadata.
public struct RuntimeDiscoveryAnnouncement: Codable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let serverName: String
    public let controlPort: UInt16
    public let bridgePort: UInt16
    public let jpegInputPort: UInt16
    public let supportedStreamModes: [StreamMode]
    public let buildVersion: String
    public let message: String

    public init(
        protocolVersion: Int = macVRProtocolVersion,
        requestID: String,
        serverName: String,
        controlPort: UInt16,
        bridgePort: UInt16,
        jpegInputPort: UInt16,
        supportedStreamModes: [StreamMode],
        buildVersion: String = macVRReleaseVersion,
        message: String
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.serverName = serverName
        self.controlPort = controlPort
        self.bridgePort = bridgePort
        self.jpegInputPort = jpegInputPort
        self.supportedStreamModes = supportedStreamModes
        self.buildVersion = buildVersion
        self.message = message
    }
}
