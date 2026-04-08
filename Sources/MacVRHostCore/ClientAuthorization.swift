import Foundation
import MacVRProtocol

/// Stable identity envelope for a control-channel client attempting the initial
/// hello handshake. The runtime trust policy uses this to decide whether the
/// host should open a streaming session for the connection.
public struct ClientIdentity: Sendable, Equatable {
    public let clientName: String
    public let remoteHost: String
    public let requestedFPS: Int?
    public let requestedStreamMode: StreamMode?

    public init(
        clientName: String,
        remoteHost: String,
        requestedFPS: Int?,
        requestedStreamMode: StreamMode?
    ) {
        self.clientName = clientName
        self.remoteHost = remoteHost
        self.requestedFPS = requestedFPS
        self.requestedStreamMode = requestedStreamMode
    }
}

/// Result produced by host-side trust/authorization checks during handshake.
public enum ClientAuthorizationDecision: Sendable, Equatable {
    case allow
    case deny(reason: String)
}

/// Optional host callback used to gate hello handshakes before a session is created.
public typealias HostClientAuthorizer = @Sendable (ClientIdentity) -> ClientAuthorizationDecision
