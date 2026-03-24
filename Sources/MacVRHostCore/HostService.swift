import Foundation
import MacVRProtocol
import Network

/// Accepts client control connections and maps each accepted handshake to a streaming session.
public enum HostServiceError: Error {
    case invalidControlPort(UInt16)
}

extension HostServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidControlPort(let port):
            return "Invalid control port: \(port)"
        }
    }
}

public final class HostService: @unchecked Sendable {
    private final class ConnectionContext: @unchecked Sendable {
        let id = UUID()
        var didHandshake = false
        var clientName = "unknown-client"
        var streamMode: StreamMode = .mock
        var receiveBuffer = Data()
    }

    private let configuration: HostConfiguration
    private let bridgeFrameStore: BridgeFrameStore?
    private let logger: HostLogger
    private let registry = SessionRegistry()
    private let queue = DispatchQueue(label: "macvr.host.listener")
    private let trackingStateStore: TrackingStateStore?
    private var listener: NWListener?
    private var activeConnections: [UUID: NWConnection] = [:]

    public init(
        configuration: HostConfiguration,
        logger: HostLogger,
        bridgeFrameStore: BridgeFrameStore? = nil
    ) throws {
        guard configuration.controlPort > 0 else {
            throw HostServiceError.invalidControlPort(configuration.controlPort)
        }
        self.configuration = configuration
        self.bridgeFrameStore = bridgeFrameStore
        self.logger = logger
        self.trackingStateStore = configuration.trackingStatePath.map { TrackingStateStore(path: URL(fileURLWithPath: $0)) }
    }

    public func start() throws {
        guard listener == nil else {
            return
        }

        guard let port = NWEndpoint.Port(rawValue: configuration.controlPort) else {
            throw HostServiceError.invalidControlPort(configuration.controlPort)
        }

        let listener = try NWListener(using: .tcp, on: port)
        listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
        logger.log(.info, "Control channel listening on tcp://0.0.0.0:\(configuration.controlPort)")
    }

    public func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil

            for (_, connection) in self.activeConnections {
                connection.cancel()
            }
            self.activeConnections.removeAll()
            self.registry.stopAll()
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            logger.log(.info, "Host listener is ready")
        case .failed(let error):
            logger.log(.error, "Host listener failed: \(error)")
        case .cancelled:
            logger.log(.info, "Host listener cancelled")
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let context = ConnectionContext()
        activeConnections[context.id] = connection

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state, context: context, endpoint: connection.endpoint)
        }
        connection.start(queue: queue)
        receive(on: connection, context: context)
    }

    private func handleConnectionState(
        _ state: NWConnection.State,
        context: ConnectionContext,
        endpoint: NWEndpoint
    ) {
        switch state {
        case .ready:
            logger.log(.info, "Control connection ready: \(endpoint)")
        case .failed(let error):
            logger.log(.warning, "Control connection failed: \(endpoint), error: \(error)")
            cleanupConnection(id: context.id)
        case .cancelled:
            cleanupConnection(id: context.id)
        default:
            break
        }
    }

    private func receive(on connection: NWConnection, context: ConnectionContext) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if let data, !data.isEmpty {
                self.consume(data: data, connection: connection, context: context)
            }

            if let error {
                self.logger.log(.warning, "Receive error on control connection: \(error)")
                self.cleanupConnection(id: context.id)
                return
            }

            if isComplete {
                self.logger.log(.info, "Control connection closed by peer: \(connection.endpoint)")
                self.cleanupConnection(id: context.id)
                return
            }

            self.receive(on: connection, context: context)
        }
    }

    private func consume(data: Data, connection: NWConnection, context: ConnectionContext) {
        context.receiveBuffer.append(data)

        while let newlineIndex = context.receiveBuffer.firstIndex(of: 0x0A) {
            var line = Data(context.receiveBuffer[..<newlineIndex])
            let nextIndex = context.receiveBuffer.index(after: newlineIndex)
            context.receiveBuffer.removeSubrange(context.receiveBuffer.startIndex..<nextIndex)

            if line.last == 0x0D {
                line.removeLast()
            }

            if line.isEmpty {
                continue
            }

            handleLine(line, connection: connection, context: context)
        }
    }

    private func handleLine(_ line: Data, connection: NWConnection, context: ConnectionContext) {
        let message: ClientControlMessage

        do {
            message = try WireCodec.decode(ClientControlMessage.self, from: line)
        } catch {
            sendProtocolError(
                code: "BAD_MESSAGE",
                message: "Invalid JSON message: \(error.localizedDescription)",
                connection: connection
            )
            return
        }

        switch message.type {
        case .hello:
            handleHello(message.hello, connection: connection, context: context)
        case .pose:
            handlePose(message.pose, connection: connection, context: context)
        case .ping:
            handlePing(message.ping, connection: connection)
        }
    }

    private func handleHello(
        _ payload: HelloPayload?,
        connection: NWConnection,
        context: ConnectionContext
    ) {
        guard let payload else {
            sendProtocolError(
                code: "HELLO_PAYLOAD_MISSING",
                message: "hello payload is required",
                connection: connection
            )
            return
        }

        guard !context.didHandshake else {
            sendProtocolError(
                code: "HELLO_ALREADY_DONE",
                message: "hello was already received on this connection",
                connection: connection
            )
            return
        }

        guard payload.protocolVersion == macVRProtocolVersion else {
            sendProtocolError(
                code: "PROTOCOL_MISMATCH",
                message: "Expected protocol version \(macVRProtocolVersion), received \(payload.protocolVersion)",
                connection: connection
            )
            return
        }

        guard payload.udpVideoPort > 0 else {
            sendProtocolError(
                code: "INVALID_UDP_PORT",
                message: "udpVideoPort must be greater than 0",
                connection: connection
            )
            return
        }

        guard let host = Self.remoteHost(from: connection.endpoint) else {
            sendProtocolError(
                code: "UNSUPPORTED_ENDPOINT",
                message: "Unable to resolve client host from connection endpoint",
                connection: connection
            )
            return
        }

        let sessionID = UUID().uuidString.lowercased()
        let streamMode = payload.requestedStreamMode ?? configuration.streamMode
        if streamMode == .bridgeJPEG && bridgeFrameStore == nil {
            sendProtocolError(
                code: "BRIDGE_UNAVAILABLE",
                message: "bridge-jpeg requested but bridge ingest service is not configured",
                connection: connection
            )
            return
        }
        let codec = Self.codec(for: streamMode)
        context.didHandshake = true
        context.clientName = payload.clientName
        context.streamMode = streamMode

        let session = ClientSession(
            sessionID: sessionID,
            destinationHost: host,
            destinationPort: payload.udpVideoPort,
            targetFPS: configuration.targetFPS,
            streamMode: streamMode,
            frameTag: configuration.frameTag,
            bridgeFrameStore: bridgeFrameStore,
            maxPacketSize: configuration.maxPacketSize,
            bridgeMaxFrameAgeMs: configuration.bridgeMaxFrameAgeMs,
            displayID: configuration.displayID,
            jpegQuality: configuration.jpegQuality,
            logger: logger
        )
        registry.setSession(session, for: context.id)

        let welcome = WelcomePayload(
            sessionID: sessionID,
            targetFPS: configuration.targetFPS,
            udpVideoPort: payload.udpVideoPort,
            streamMode: streamMode,
            codec: codec,
            maxPacketSize: configuration.maxPacketSize,
            serverTimeNs: DispatchTime.now().uptimeNanoseconds,
            message: "\(streamMode.rawValue) stream active"
        )
        send(.welcome(welcome), connection: connection)
        send(
            .streamStatus(StreamStatusPayload(state: "streaming:\(streamMode.rawValue)", frameIndex: 0)),
            connection: connection
        )

        logger.log(
            .info,
            "Client \(payload.clientName) joined, session=\(sessionID), endpoint=\(connection.endpoint)"
        )
    }

    private func handlePose(
        _ payload: PosePayload?,
        connection: NWConnection,
        context: ConnectionContext
    ) {
        guard context.didHandshake else {
            sendProtocolError(
                code: "HELLO_REQUIRED",
                message: "send hello before pose updates",
                connection: connection
            )
            return
        }

        guard let payload else {
            sendProtocolError(
                code: "POSE_PAYLOAD_MISSING",
                message: "pose payload is required",
                connection: connection
            )
            return
        }

        registry.updatePose(payload, for: context.id)
        if let trackingStateStore {
            do {
                // Persist the latest headset pose to the shared binary handoff so
                // the OpenXR runtime can answer xrLocateSpace/xrLocateViews even
                // when it is loaded in a separate process from the transport host.
                try trackingStateStore.updateHeadPose(payload)
            } catch {
                logger.log(.warning, "Failed to persist tracking state: \(error.localizedDescription)")
            }
        }
    }

    private func handlePing(_ payload: PingPayload?, connection: NWConnection) {
        let pong = PongPayload(
            nonce: payload?.nonce,
            serverTimeNs: DispatchTime.now().uptimeNanoseconds
        )
        send(.pong(pong), connection: connection)
    }

    private func sendProtocolError(code: String, message: String, connection: NWConnection) {
        send(.error(ErrorPayload(code: code, message: message)), connection: connection)
    }

    private func send(_ message: ServerControlMessage, connection: NWConnection) {
        do {
            let payload = try WireCodec.encodeLine(message)
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.logger.log(.warning, "Failed to send control message: \(error)")
                }
            })
        } catch {
            logger.log(.error, "Failed to encode control message: \(error)")
        }
    }

    private func cleanupConnection(id: UUID) {
        guard let connection = activeConnections.removeValue(forKey: id) else {
            return
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        registry.removeSession(for: id)
    }

    private static func remoteHost(from endpoint: NWEndpoint) -> NWEndpoint.Host? {
        guard case .hostPort(let host, _) = endpoint else {
            return nil
        }
        return host
    }

    private static func codec(for mode: StreamMode) -> FrameCodec {
        switch mode {
        case .mock:
            return .mockJSON
        case .displayJPEG:
            return .jpeg
        case .bridgeJPEG:
            return .jpeg
        }
    }
}
