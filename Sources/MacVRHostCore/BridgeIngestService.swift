import Foundation
import MacVRProtocol
import Network

/// Accepts bridge-producer control traffic and authenticated frame submissions for bridge-jpeg mode.
public enum BridgeIngestError: Error {
    case invalidPort(UInt16)
}

extension BridgeIngestError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Invalid bridge ingest port: \(port)"
        }
    }
}

public final class BridgeIngestService: @unchecked Sendable {
    private final class ControlConnectionContext: @unchecked Sendable {
        let id = UUID()
        var didHello = false
        var source = "bridge-unknown"
        var transport: BridgeFrameTransport = .tcpInlineBase64
        var udpAuthToken: Data?
        var remoteHost: String?
        var receiveBuffer = Data()
    }

    private final class AuthorizedUDPSource: @unchecked Sendable {
        let source: String
        let maxChunkPacketSize: Int
        let maxDatagramSize: Int
        let reassembler: FrameReassembler

        init(
            source: String,
            maxChunkPacketSize: Int,
            maxDatagramSize: Int,
            reassembler: FrameReassembler = FrameReassembler()
        ) {
            self.source = source
            self.maxChunkPacketSize = maxChunkPacketSize
            self.maxDatagramSize = maxDatagramSize
            self.reassembler = reassembler
        }
    }

    private let port: UInt16
    private let maxPacketSize: Int
    private let frameStore: BridgeFrameStore
    private let logger: HostLogger
    private let queue = DispatchQueue(label: "macvr.host.bridge.listener")
    private let maxInlineFrameBytes = 16_000_000

    private var controlListener: NWListener?
    private var udpListener: NWListener?
    private var activeControlConnections: [UUID: NWConnection] = [:]
    private var controlContexts: [UUID: ControlConnectionContext] = [:]
    private var activeUDPConnections: [ObjectIdentifier: NWConnection] = [:]
    private var authorizedUDPByToken: [Data: AuthorizedUDPSource] = [:]
    private var unauthorizedUDPDrops: UInt64 = 0
    private var malformedUDPDrops: UInt64 = 0
    private var oversizeUDPDrops: UInt64 = 0
    private var codecUDPDrops: UInt64 = 0
    private var invalidFrameUDPDrops: UInt64 = 0

    public init(
        port: UInt16,
        maxPacketSize: Int = FrameChunkPacketizer.defaultMaxPacketSize,
        frameStore: BridgeFrameStore,
        logger: HostLogger
    ) throws {
        guard port > 0 else {
            throw BridgeIngestError.invalidPort(port)
        }
        self.port = port
        self.maxPacketSize = HostConfiguration.clampPacketSize(maxPacketSize)
        self.frameStore = frameStore
        self.logger = logger
    }

    private var maxBridgeUDPPacketSize: Int {
        maxPacketSize + BridgeUDPPacketEnvelope.headerByteCount
    }

    public func start() throws {
        guard controlListener == nil, udpListener == nil else {
            return
        }

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw BridgeIngestError.invalidPort(port)
        }

        let controlListener = try NWListener(using: .tcp, on: endpointPort)
        controlListener.stateUpdateHandler = { [weak self] state in
            self?.handleControlListenerState(state)
        }
        controlListener.newConnectionHandler = { [weak self] connection in
            self?.acceptControl(connection)
        }

        let udpListener = try NWListener(using: .udp, on: endpointPort)
        udpListener.stateUpdateHandler = { [weak self] state in
            self?.handleUDPListenerState(state)
        }
        udpListener.newConnectionHandler = { [weak self] connection in
            self?.acceptUDP(connection)
        }

        controlListener.start(queue: queue)
        udpListener.start(queue: queue)

        self.controlListener = controlListener
        self.udpListener = udpListener

        logger.log(.info, "Bridge control listening on tcp://0.0.0.0:\(port)")
        logger.log(
            .info,
            "Bridge frame ingest listening on udp://0.0.0.0:\(port), chunkMaxPacketSize=\(maxPacketSize), maxDatagram=\(maxBridgeUDPPacketSize)"
        )
    }

    public func stop() {
        queue.async {
            self.controlListener?.cancel()
            self.controlListener = nil
            self.udpListener?.cancel()
            self.udpListener = nil

            for (_, connection) in self.activeControlConnections {
                connection.cancel()
            }
            self.activeControlConnections.removeAll()
            self.controlContexts.removeAll()

            for (_, connection) in self.activeUDPConnections {
                connection.cancel()
            }
            self.activeUDPConnections.removeAll()
            self.authorizedUDPByToken.removeAll()
        }
    }

    private func handleControlListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            logger.log(.info, "Bridge control listener is ready")
        case .failed(let error):
            logger.log(.error, "Bridge control listener failed: \(error)")
        case .cancelled:
            logger.log(.info, "Bridge control listener cancelled")
        default:
            break
        }
    }

    private func handleUDPListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            logger.log(.info, "Bridge UDP listener is ready")
        case .failed(let error):
            logger.log(.error, "Bridge UDP listener failed: \(error)")
        case .cancelled:
            logger.log(.info, "Bridge UDP listener cancelled")
        default:
            break
        }
    }

    private func acceptControl(_ connection: NWConnection) {
        let context = ControlConnectionContext()
        context.remoteHost = Self.remoteHost(from: connection.endpoint)
        activeControlConnections[context.id] = connection
        controlContexts[context.id] = context

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleControlConnectionState(state, context: context, endpoint: connection.endpoint)
        }
        connection.start(queue: queue)
        receiveControl(on: connection, context: context)
    }

    private func acceptUDP(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        activeUDPConnections[key] = connection

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleUDPConnectionState(state, key: key, endpoint: connection.endpoint)
        }
        connection.start(queue: queue)
        receiveUDP(on: connection, key: key)
    }

    private func handleControlConnectionState(
        _ state: NWConnection.State,
        context: ControlConnectionContext,
        endpoint: NWEndpoint
    ) {
        switch state {
        case .ready:
            logger.log(.info, "Bridge control connection ready: \(endpoint)")
        case .failed(let error):
            logger.log(.warning, "Bridge control connection failed: \(endpoint), error: \(error)")
            cleanupControlConnection(id: context.id)
        case .cancelled:
            cleanupControlConnection(id: context.id)
        default:
            break
        }
    }

    private func handleUDPConnectionState(_ state: NWConnection.State, key: ObjectIdentifier, endpoint: NWEndpoint) {
        switch state {
        case .ready:
            logger.log(.debug, "Bridge UDP connection ready: \(endpoint)")
        case .failed(let error):
            logger.log(.warning, "Bridge UDP connection failed: \(endpoint), error: \(error)")
            cleanupUDPConnection(key: key)
        case .cancelled:
            cleanupUDPConnection(key: key)
        default:
            break
        }
    }

    private func receiveControl(on connection: NWConnection, context: ControlConnectionContext) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if let data, !data.isEmpty {
                self.consumeControlData(data, connection: connection, context: context)
            }

            if let error {
                self.logger.log(.warning, "Bridge control receive error: \(error)")
                self.cleanupControlConnection(id: context.id)
                return
            }

            if isComplete {
                self.cleanupControlConnection(id: context.id)
                return
            }

            self.receiveControl(on: connection, context: context)
        }
    }

    private func receiveUDP(on connection: NWConnection, key: ObjectIdentifier) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else {
                return
            }

            if let data, !data.isEmpty {
                self.consumeUDPPacket(data, endpoint: connection.endpoint)
            }

            if let error {
                self.logger.log(.warning, "Bridge UDP receive error: \(error)")
                self.cleanupUDPConnection(key: key)
                return
            }

            self.receiveUDP(on: connection, key: key)
        }
    }

    private func consumeControlData(_ data: Data, connection: NWConnection, context: ControlConnectionContext) {
        context.receiveBuffer.append(data)

        while let newlineIndex = context.receiveBuffer.firstIndex(of: 0x0A) {
            var line = Data(context.receiveBuffer[..<newlineIndex])
            let nextIndex = context.receiveBuffer.index(after: newlineIndex)
            context.receiveBuffer.removeSubrange(context.receiveBuffer.startIndex..<nextIndex)

            if line.last == 0x0D {
                line.removeLast()
            }
            guard !line.isEmpty else {
                continue
            }

            handleControlLine(line, connection: connection, context: context)
        }
    }

    private func handleControlLine(_ line: Data, connection: NWConnection, context: ControlConnectionContext) {
        let message: BridgeClientMessage
        do {
            message = try WireCodec.decode(BridgeClientMessage.self, from: line)
        } catch {
            sendError(
                code: "BAD_MESSAGE",
                message: "Invalid bridge JSON message: \(error.localizedDescription)",
                connection: connection
            )
            return
        }

        switch message.type {
        case .hello:
            handleHello(message.hello, connection: connection, context: context)
        case .submitFrame:
            handleSubmitFrame(message.submitFrame, connection: connection, context: context)
        case .ping:
            handlePing(message.ping, connection: connection)
        }
    }

    private func handleHello(
        _ payload: BridgeHelloPayload?,
        connection: NWConnection,
        context: ControlConnectionContext
    ) {
        guard let payload else {
            sendError(code: "HELLO_MISSING", message: "hello payload is required", connection: connection)
            return
        }

        guard !context.didHello else {
            sendError(code: "HELLO_ALREADY_DONE", message: "hello was already received on this connection", connection: connection)
            return
        }

        guard payload.protocolVersion == macVRProtocolVersion else {
            sendError(
                code: "PROTOCOL_MISMATCH",
                message: "Expected protocol version \(macVRProtocolVersion), received \(payload.protocolVersion)",
                connection: connection
            )
            return
        }

        context.didHello = true
        context.source = payload.source

        let requestedTransport = payload.preferredTransport ?? .udpChunked
        let negotiatedTransport: BridgeFrameTransport
        switch requestedTransport {
        case .udpChunked:
            negotiatedTransport = .udpChunked
        case .tcpInlineBase64:
            negotiatedTransport = .tcpInlineBase64
        }
        context.transport = negotiatedTransport

        let requestedPacketSize = payload.maxPacketSize.map(HostConfiguration.clampPacketSize) ?? maxPacketSize
        let negotiatedPacketSize = min(maxPacketSize, requestedPacketSize)
        var udpAuthTokenBase64: String?
        if negotiatedTransport == .udpChunked {
            let token = Self.makeUDPSessionToken()
            context.udpAuthToken = token
            authorizedUDPByToken[token] = AuthorizedUDPSource(
                source: payload.source,
                maxChunkPacketSize: negotiatedPacketSize,
                maxDatagramSize: negotiatedPacketSize + BridgeUDPPacketEnvelope.headerByteCount
            )
            udpAuthTokenBase64 = token.base64EncodedString()
        } else {
            context.udpAuthToken = nil
        }

        send(
            .welcome(
                BridgeWelcomePayload(
                    message: "Bridge ingest ready",
                    acceptedSource: payload.source,
                    frameTransport: negotiatedTransport,
                    udpIngestPort: negotiatedTransport == .udpChunked ? port : nil,
                    maxPacketSize: negotiatedTransport == .udpChunked ? negotiatedPacketSize : nil,
                    udpAuthTokenBase64: negotiatedTransport == .udpChunked ? udpAuthTokenBase64 : nil
                )
            ),
            connection: connection
        )
        logger.log(
            .info,
            "Bridge hello from \(payload.clientName), source=\(payload.source), transport=\(negotiatedTransport.rawValue)"
        )
    }

    private func handleSubmitFrame(
        _ payload: BridgeSubmitFramePayload?,
        connection: NWConnection,
        context: ControlConnectionContext
    ) {
        guard context.didHello else {
            sendError(code: "HELLO_REQUIRED", message: "send hello before submitFrame", connection: connection)
            return
        }

        guard let payload else {
            sendError(code: "FRAME_MISSING", message: "submitFrame payload is required", connection: connection)
            return
        }

        guard let jpegData = payload.decodeJPEGData(maxBytes: maxInlineFrameBytes) else {
            sendError(code: "INVALID_FRAME_DATA", message: "jpegBase64 is invalid or too large", connection: connection)
            return
        }

        if context.transport == .udpChunked {
            logger.log(.debug, "Received inline submitFrame while transport is udp-chunked; accepting for compatibility")
        }

        frameStore.update(
            frameIndex: payload.frameIndex,
            sentTimeNs: payload.sentTimeNs,
            source: context.source,
            width: payload.width,
            height: payload.height,
            jpegData: jpegData
        )
    }

    private func handlePing(_ payload: BridgePingPayload?, connection: NWConnection) {
        send(
            .pong(
                BridgePongPayload(
                    nonce: payload?.nonce,
                    serverTimeNs: DispatchTime.now().uptimeNanoseconds
                )
            ),
            connection: connection
        )
    }

    private func consumeUDPPacket(_ packetData: Data, endpoint: NWEndpoint) {
        guard packetData.count <= maxBridgeUDPPacketSize else {
            oversizeUDPDrops &+= 1
            if oversizeUDPDrops % 120 == 1 {
                logger.log(
                    .warning,
                    "Dropped oversize bridge UDP packet (\(packetData.count)B) > maxDatagram=\(maxBridgeUDPPacketSize)"
                )
            }
            return
        }

        let envelope: BridgeUDPPacketEnvelopePayload
        do {
            envelope = try BridgeUDPPacketEnvelope.decode(packetData)
        } catch {
            malformedUDPDrops &+= 1
            if malformedUDPDrops % 120 == 1 {
                logger.log(.warning, "Dropped malformed bridge UDP packet from \(endpoint): \(error)")
            }
            return
        }

        guard let authorized = authorizedUDPByToken[envelope.authToken] else {
            unauthorizedUDPDrops &+= 1
            if unauthorizedUDPDrops % 120 == 1 {
                logger.log(.warning, "Dropped unauthorized bridge UDP packet from \(endpoint)")
            }
            return
        }

        // Enforce both the global listener cap and the session-specific caps negotiated in hello/welcome.
        guard packetData.count <= authorized.maxDatagramSize else {
            oversizeUDPDrops &+= 1
            if oversizeUDPDrops % 120 == 1 {
                logger.log(
                    .warning,
                    "Dropped bridge UDP packet (\(packetData.count)B) larger than session maxDatagram=\(authorized.maxDatagramSize)"
                )
            }
            return
        }

        guard envelope.frameChunkPacket.count <= authorized.maxChunkPacketSize else {
            oversizeUDPDrops &+= 1
            if oversizeUDPDrops % 120 == 1 {
                logger.log(
                    .warning,
                    "Dropped bridge frame chunk (\(envelope.frameChunkPacket.count)B) larger than session maxChunkPacket=\(authorized.maxChunkPacketSize)"
                )
            }
            return
        }

        do {
            guard let frame = try authorized.reassembler.ingest(envelope.frameChunkPacket) else {
                return
            }
            guard frame.codec == .jpeg else {
                codecUDPDrops &+= 1
                if codecUDPDrops % 120 == 1 {
                    logger.log(.warning, "Dropped bridge frame with unsupported codec \(frame.codec) from \(endpoint)")
                }
                return
            }
            guard !frame.payload.isEmpty, frame.payload.count <= maxInlineFrameBytes else {
                invalidFrameUDPDrops &+= 1
                if invalidFrameUDPDrops % 120 == 1 {
                    logger.log(.warning, "Dropped bridge frame with invalid payload size \(frame.payload.count)")
                }
                return
            }

            frameStore.update(
                frameIndex: frame.frameIndex,
                sentTimeNs: frame.sentTimeNs,
                source: authorized.source,
                width: nil,
                height: nil,
                jpegData: frame.payload
            )
        } catch {
            malformedUDPDrops &+= 1
            if malformedUDPDrops % 120 == 1 {
                logger.log(.warning, "Dropped malformed bridge UDP packet from \(endpoint): \(error)")
            }
        }
    }

    private func sendError(code: String, message: String, connection: NWConnection) {
        send(.error(BridgeErrorPayload(code: code, message: message)), connection: connection)
    }

    private func send(_ message: BridgeServerMessage, connection: NWConnection) {
        do {
            let payload = try WireCodec.encodeLine(message)
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.logger.log(.warning, "Failed to send bridge control message: \(error)")
                }
            })
        } catch {
            logger.log(.error, "Failed to encode bridge control message: \(error)")
        }
    }

    private func cleanupControlConnection(id: UUID) {
        let context = controlContexts.removeValue(forKey: id)
        guard let connection = activeControlConnections.removeValue(forKey: id) else {
            return
        }
        connection.stateUpdateHandler = nil
        connection.cancel()

        if let context, let token = context.udpAuthToken {
            authorizedUDPByToken.removeValue(forKey: token)
            logger.log(.debug, "Bridge UDP authorization removed for control session \(id.uuidString.lowercased())")
        }
    }

    private static func makeUDPSessionToken() -> Data {
        Data((0..<BridgeUDPPacketEnvelope.authTokenByteCount).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
    }

    private func cleanupUDPConnection(key: ObjectIdentifier) {
        guard let connection = activeUDPConnections.removeValue(forKey: key) else {
            return
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private static func remoteHost(from endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else {
            return nil
        }

        switch host {
        case .ipv4(let address):
            return address.debugDescription
        case .ipv6(let address):
            return address.debugDescription
        case .name(let name, _):
            return name
        @unknown default:
            return nil
        }
    }
}
