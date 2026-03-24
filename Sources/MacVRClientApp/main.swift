import Foundation
import MacVRProtocol
import Network

// The client is intentionally self-contained so it can be used as a transport probe
// without requiring any macOS app scaffolding or VR runtime integration.
private enum ClientError: Error {
    case helpRequested
    case versionRequested
    case missingValue(String)
    case invalidValue(String)
    case unknownArgument(String)
    case invalidPort(UInt16)

    var description: String {
        switch self {
        case .helpRequested:
            return CLIOptions.usage
        case .versionRequested:
            return "macvr-client \(macVRReleaseVersion)"
        case .missingValue(let flag):
            return "Missing value for \(flag)\n\n\(CLIOptions.usage)"
        case .invalidValue(let message):
            return "\(message)\n\n\(CLIOptions.usage)"
        case .unknownArgument(let arg):
            return "Unknown argument: \(arg)\n\n\(CLIOptions.usage)"
        case .invalidPort(let port):
            return "Invalid port: \(port)\n\n\(CLIOptions.usage)"
        }
    }
}

private struct CLIOptions {
    var host = "127.0.0.1"
    var controlPort: UInt16 = 42000
    var udpPort: UInt16 = 9944
    var targetFPS = 72
    var requestedStreamMode: StreamMode = .displayJPEG
    var saveJPEGEvery = 30
    var outputDirectory = "/tmp/macvr-client-capture"
    var verbose = false

    static let usage = """
    Usage: macvr-client [options]
      --host <hostname>       Host address for TCP control channel (default: 127.0.0.1)
      --control-port <port>   Host TCP control port (default: 42000)
      --udp-port <port>       Local UDP port to receive video chunks (default: 9944)
      --fps <value>           Requested pose update rate, 1-240 (default: 72)
      --stream-mode <mode>    Requested mode: display-jpeg | bridge-jpeg | mock (default: display-jpeg)
      --save-jpeg-every <n>   Save every n-th JPEG frame, 0 disables saving (default: 30)
      --output-dir <path>     Output path for saved JPEG frames (default: /tmp/macvr-client-capture)
      --version               Show build/release version
      --verbose               Enable debug logging
      -h, --help              Show this help
    """

    static func parse(arguments: [String]) throws -> CLIOptions {
        var options = CLIOptions()
        var index = 0

        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--host":
                index += 1
                guard index < arguments.count else {
                    throw ClientError.missingValue(arg)
                }
                let value = arguments[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw ClientError.invalidValue("host cannot be empty")
                }
                options.host = value
            case "--control-port":
                index += 1
                guard index < arguments.count else {
                    throw ClientError.missingValue(arg)
                }
                guard let value = UInt16(arguments[index]), value > 0 else {
                    throw ClientError.invalidValue("Invalid control port: \(arguments[index])")
                }
                options.controlPort = value
            case "--udp-port":
                index += 1
                guard index < arguments.count else {
                    throw ClientError.missingValue(arg)
                }
                guard let value = UInt16(arguments[index]), value > 0 else {
                    throw ClientError.invalidValue("Invalid udp port: \(arguments[index])")
                }
                options.udpPort = value
            case "--fps":
                index += 1
                guard index < arguments.count else {
                    throw ClientError.missingValue(arg)
                }
                guard let value = Int(arguments[index]), (1...240).contains(value) else {
                    throw ClientError.invalidValue("Invalid fps value: \(arguments[index])")
                }
                options.targetFPS = value
            case "--stream-mode":
                index += 1
                guard index < arguments.count else {
                    throw ClientError.missingValue(arg)
                }
                guard let mode = StreamMode(rawValue: arguments[index]) else {
                    throw ClientError.invalidValue("Invalid stream mode: \(arguments[index])")
                }
                options.requestedStreamMode = mode
            case "--save-jpeg-every":
                index += 1
                guard index < arguments.count else {
                    throw ClientError.missingValue(arg)
                }
                guard let value = Int(arguments[index]), value >= 0 else {
                    throw ClientError.invalidValue("Invalid save-jpeg-every value: \(arguments[index])")
                }
                options.saveJPEGEvery = value
            case "--output-dir":
                index += 1
                guard index < arguments.count else {
                    throw ClientError.missingValue(arg)
                }
                let value = arguments[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw ClientError.invalidValue("output-dir cannot be empty")
                }
                options.outputDirectory = value
            case "--version":
                throw ClientError.versionRequested
            case "--verbose":
                options.verbose = true
            case "-h", "--help":
                throw ClientError.helpRequested
            default:
                throw ClientError.unknownArgument(arg)
            }
            index += 1
        }

        return options
    }
}

private final class ClientLogger: @unchecked Sendable {
    private let verbose: Bool
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter

    init(verbose: Bool) {
        self.verbose = verbose
        self.formatter = ISO8601DateFormatter()
        self.formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func info(_ message: String) {
        log("INFO", message)
    }

    func warning(_ message: String) {
        log("WARN", message)
    }

    func debug(_ message: String) {
        guard verbose else {
            return
        }
        log("DEBUG", message)
    }

    private func log(_ level: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        print("[\(formatter.string(from: Date()))] [\(level)] \(message)")
        fflush(stdout)
    }
}

private final class MacVRClient: @unchecked Sendable {
    private let options: CLIOptions
    private let logger: ClientLogger
    private let queue = DispatchQueue(label: "macvr.client.main")
    private let reconnectMinDelayNs: UInt64 = 500_000_000
    private let reconnectMaxDelayNs: UInt64 = 8_000_000_000
    private let reconnectJitterMaxNs: UInt64 = 250_000_000
    private let reassembler = FrameReassembler()
    private let outputDirectoryURL: URL

    private var controlConnection: NWConnection?
    private var controlEndpointPort: NWEndpoint.Port?
    private var udpListener: NWListener?
    private var udpConnections: [ObjectIdentifier: NWConnection] = [:]
    private var controlReceiveBuffer = Data()
    private var poseTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempt: UInt32 = 0
    private var isStopped = false

    private var framesSinceReport: UInt64 = 0
    private var bytesSinceReport: UInt64 = 0
    private var lastReportTimeNs: UInt64 = DispatchTime.now().uptimeNanoseconds

    init(options: CLIOptions, logger: ClientLogger) {
        self.options = options
        self.logger = logger
        self.outputDirectoryURL = URL(fileURLWithPath: options.outputDirectory, isDirectory: true)
    }

    func start() throws {
        isStopped = false
        try prepareOutputDirectory()
        try startUDP()
        try startControl()
    }

    func stop() {
        queue.async {
            self.isStopped = true
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.stopControlTimers()
            self.controlConnection?.cancel()
            self.controlConnection = nil

            self.udpListener?.cancel()
            self.udpListener = nil

            for (_, connection) in self.udpConnections {
                connection.cancel()
            }
            self.udpConnections.removeAll()
        }
    }

    private func prepareOutputDirectory() throws {
        guard options.saveJPEGEvery > 0 else {
            return
        }
        try FileManager.default.createDirectory(
            at: outputDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func startUDP() throws {
        guard let udpPort = NWEndpoint.Port(rawValue: options.udpPort) else {
            throw ClientError.invalidPort(options.udpPort)
        }

        let listener = try NWListener(using: .udp, on: udpPort)
        listener.stateUpdateHandler = { [weak self] state in
            self?.handleUDPListenerState(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.acceptUDP(connection)
        }
        listener.start(queue: queue)
        udpListener = listener
        logger.info("UDP listener starting on 0.0.0.0:\(options.udpPort)")
    }

    private func handleUDPListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            logger.info("UDP listener ready")
        case .failed(let error):
            logger.warning("UDP listener failed: \(error)")
        case .cancelled:
            logger.info("UDP listener cancelled")
        default:
            break
        }
    }

    private func acceptUDP(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        udpConnections[key] = connection

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleUDPConnectionState(state, key: key, endpoint: connection.endpoint)
        }
        connection.start(queue: queue)
        receiveUDP(on: connection, key: key)
    }

    private func handleUDPConnectionState(_ state: NWConnection.State, key: ObjectIdentifier, endpoint: NWEndpoint) {
        switch state {
        case .ready:
            logger.debug("UDP connection ready: \(endpoint)")
        case .failed(let error):
            logger.warning("UDP connection failed (\(endpoint)): \(error)")
            cleanupUDPConnection(key: key)
        case .cancelled:
            cleanupUDPConnection(key: key)
        default:
            break
        }
    }

    private func receiveUDP(on connection: NWConnection, key: ObjectIdentifier) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else {
                return
            }

            if let data, !data.isEmpty {
                self.consumeUDPPacket(data)
            }

            if let error {
                self.logger.warning("UDP receive error: \(error)")
                self.cleanupUDPConnection(key: key)
                return
            }

            self.receiveUDP(on: connection, key: key)
        }
    }

    private func cleanupUDPConnection(key: ObjectIdentifier) {
        guard let connection = udpConnections.removeValue(forKey: key) else {
            return
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func consumeUDPPacket(_ packetData: Data) {
        do {
            if let frame = try reassembler.ingest(packetData) {
                handleFrame(frame)
            }
        } catch {
            logger.debug("Dropped invalid UDP packet: \(error)")
        }
    }

    private func handleFrame(_ frame: ReassembledFrame) {
        framesSinceReport &+= 1
        bytesSinceReport &+= UInt64(frame.payload.count)

        switch frame.codec {
        case .mockJSON:
            if framesSinceReport % 30 == 0 {
                do {
                    let mock = try WireCodec.decode(MockFramePacket.self, from: frame.payload)
                    logger.debug("Mock frame \(mock.frameIndex) tag=\(mock.frameTag)")
                } catch {
                    logger.debug("Unable to decode mock frame payload: \(error)")
                }
            }
        case .jpeg:
            maybeSaveJPEGFrame(frame)
        }

        maybeReportStreamStats()
    }

    private func maybeSaveJPEGFrame(_ frame: ReassembledFrame) {
        guard options.saveJPEGEvery > 0 else {
            return
        }
        guard frame.frameIndex % UInt64(options.saveJPEGEvery) == 0 else {
            return
        }

        let filename = String(format: "frame-%08llu.jpg", frame.frameIndex)
        let url = outputDirectoryURL.appendingPathComponent(filename)
        do {
            try frame.payload.write(to: url, options: .atomic)
            logger.info("Saved JPEG frame \(frame.frameIndex) -> \(url.path)")
        } catch {
            logger.warning("Failed to write JPEG frame \(frame.frameIndex): \(error)")
        }
    }

    private func maybeReportStreamStats() {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let deltaNs = nowNs &- lastReportTimeNs
        guard deltaNs >= 1_000_000_000 else {
            return
        }

        let seconds = Double(deltaNs) / 1_000_000_000.0
        let fps = Double(framesSinceReport) / seconds
        let mbps = (Double(bytesSinceReport) * 8.0) / seconds / 1_000_000.0
        logger.info(String(format: "RX %.1f fps, %.2f Mbps", fps, mbps))

        framesSinceReport = 0
        bytesSinceReport = 0
        lastReportTimeNs = nowNs
    }

    private func startControl() throws {
        guard let controlPort = NWEndpoint.Port(rawValue: options.controlPort) else {
            throw ClientError.invalidPort(options.controlPort)
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(options.host),
            port: controlPort,
            using: .tcp
        )
        controlEndpointPort = controlPort
        connectControl(using: connection)
    }

    private func connectControl(using connection: NWConnection? = nil) {
        guard !isStopped else {
            return
        }
        let connection = connection ?? {
            guard let controlEndpointPort else {
                return nil
            }
            return NWConnection(
                host: NWEndpoint.Host(options.host),
                port: controlEndpointPort,
                using: .tcp
            )
        }()

        guard let connection else {
            logger.warning("Unable to reconnect: control port is not initialized")
            return
        }

        reconnectWorkItem = nil
        controlReceiveBuffer.removeAll(keepingCapacity: true)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else {
                return
            }
            self.handleControlState(state, connection: connection)
        }
        controlConnection = connection
        receiveControl(on: connection)
        connection.start(queue: queue)
        logger.info("Connecting control channel to \(options.host):\(options.controlPort)")
    }

    private func handleControlState(_ state: NWConnection.State, connection: NWConnection) {
        guard isCurrentControlConnection(connection) else {
            return
        }

        switch state {
        case .ready:
            logger.info("Control channel ready")
            reconnectAttempt = 0
            sendHello()
            startPoseTimer()
            startPingTimer()
        case .waiting(let error):
            logger.warning("Control channel waiting: \(error)")
        case .failed(let error):
            logger.warning("Control channel failed: \(error)")
            handleControlDisconnect(connection: connection)
        case .cancelled:
            logger.info("Control channel cancelled")
            handleControlDisconnect(connection: connection)
        default:
            break
        }
    }

    private func receiveControl(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            guard self.isCurrentControlConnection(connection) else {
                return
            }

            if let data, !data.isEmpty {
                self.consumeControlData(data)
            }

            if let error {
                self.logger.warning("Control receive error: \(error)")
                self.handleControlDisconnect(connection: connection)
                return
            }

            if isComplete {
                self.logger.info("Control channel closed by host")
                self.handleControlDisconnect(connection: connection)
                return
            }

            self.receiveControl(on: connection)
        }
    }

    private func consumeControlData(_ data: Data) {
        controlReceiveBuffer.append(data)

        while let newlineIndex = controlReceiveBuffer.firstIndex(of: 0x0A) {
            var line = Data(controlReceiveBuffer[..<newlineIndex])
            let next = controlReceiveBuffer.index(after: newlineIndex)
            controlReceiveBuffer.removeSubrange(controlReceiveBuffer.startIndex..<next)

            if line.last == 0x0D {
                line.removeLast()
            }
            guard !line.isEmpty else {
                continue
            }

            do {
                let message = try WireCodec.decode(ServerControlMessage.self, from: line)
                handleControlMessage(message)
            } catch {
                logger.warning("Failed to decode server control message: \(error)")
            }
        }
    }

    private func handleControlMessage(_ message: ServerControlMessage) {
        switch message.type {
        case .welcome:
            if let welcome = message.welcome {
                logger.info(
                    "Welcome session=\(welcome.sessionID), mode=\(welcome.streamMode.rawValue), codec=\(welcome.codec), mtu=\(welcome.maxPacketSize)"
                )
            }
        case .streamStatus:
            if let status = message.streamStatus {
                logger.info("Stream status: \(status.state), frame=\(status.frameIndex)")
            }
        case .error:
            if let error = message.error {
                logger.warning("Server error [\(error.code)]: \(error.message)")
            }
        case .pong:
            if let pong = message.pong {
                logger.debug("Pong nonce=\(pong.nonce ?? "nil") serverNs=\(pong.serverTimeNs)")
            }
        }
    }

    private func sendHello() {
        let hello = HelloPayload(
            clientName: "macvr-client",
            udpVideoPort: options.udpPort,
            requestedFPS: options.targetFPS,
            requestedStreamMode: options.requestedStreamMode
        )
        sendControl(ClientControlMessage.hello(hello))
    }

    private func startPoseTimer() {
        guard poseTimer == nil else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        let intervalNs = UInt64(1_000_000_000 / max(options.targetFPS, 1))
        timer.schedule(
            deadline: .now() + .milliseconds(20),
            repeating: .nanoseconds(max(Int(intervalNs), 1)),
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in
            self?.sendSyntheticPose()
        }
        timer.resume()
        poseTimer = timer
    }

    private func startPingTimer() {
        guard pingTimer == nil else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.sendPing()
        }
        timer.resume()
        pingTimer = timer
    }

    private func stopControlTimers() {
        poseTimer?.setEventHandler {}
        poseTimer?.cancel()
        poseTimer = nil

        pingTimer?.setEventHandler {}
        pingTimer?.cancel()
        pingTimer = nil
    }

    private func sendSyntheticPose() {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let phase = Double(nowNs % 10_000_000_000) / 10_000_000_000.0
        let yawAngle = sin(phase * .pi * 2.0) * 0.10
        let halfYaw = yawAngle * 0.5

        let pose = PosePayload(
            timestampNs: nowNs,
            positionMeters: [0.0, 1.6, 0.0],
            orientationQuaternion: [0.0, sin(halfYaw), 0.0, cos(halfYaw)]
        )
        sendControl(ClientControlMessage.pose(pose))
    }

    private func sendPing() {
        let nonce = UUID().uuidString.lowercased()
        sendControl(ClientControlMessage.ping(PingPayload(nonce: nonce)))
    }

    private func sendControl(_ message: ClientControlMessage) {
        guard let connection = controlConnection else {
            return
        }

        do {
            let payload = try WireCodec.encodeLine(message)
            connection.send(content: payload, completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection else {
                    return
                }
                if let error {
                    self.logger.warning("Failed to send control message: \(error)")
                    self.handleControlDisconnect(connection: connection)
                }
            })
        } catch {
            logger.warning("Failed to encode control message: \(error)")
        }
    }

    private func isCurrentControlConnection(_ connection: NWConnection?) -> Bool {
        guard let connection, let active = controlConnection else {
            return false
        }
        return ObjectIdentifier(connection) == ObjectIdentifier(active)
    }

    private func handleControlDisconnect(connection: NWConnection?) {
        guard !isStopped else {
            return
        }
        guard connection == nil || isCurrentControlConnection(connection) else {
            return
        }

        stopControlTimers()
        controlReceiveBuffer.removeAll(keepingCapacity: true)

        if let active = controlConnection {
            active.stateUpdateHandler = nil
            active.cancel()
            controlConnection = nil
        }

        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !isStopped else {
            return
        }
        guard reconnectWorkItem == nil else {
            return
        }

        let delayNs = reconnectDelayNanoseconds(attempt: reconnectAttempt)
        let delayMs = Double(delayNs) / 1_000_000.0
        let attemptNumber = reconnectAttempt + 1
        logger.info(String(format: "Reconnecting control in %.0fms (attempt %u)", delayMs, attemptNumber))
        reconnectAttempt = min(reconnectAttempt + 1, 16)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.reconnectWorkItem = nil
            self.connectControl()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(delayNs)), execute: workItem)
    }

    private func reconnectDelayNanoseconds(attempt: UInt32) -> UInt64 {
        let shift = UInt64(min(attempt, 4))
        let factor = UInt64(1) << shift
        let baseDelay = min(reconnectMinDelayNs * factor, reconnectMaxDelayNs)
        let jitter = UInt64.random(in: 0...reconnectJitterMaxNs)
        return min(baseDelay + jitter, reconnectMaxDelayNs)
    }
}

@main
struct MacVRClientApp {
    static func main() {
        do {
            let options = try CLIOptions.parse(arguments: Array(CommandLine.arguments.dropFirst()))
            let logger = ClientLogger(verbose: options.verbose)
            let client = MacVRClient(options: options, logger: logger)
            try client.start()

            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)

            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigintSource.setEventHandler {
                client.stop()
                exit(EXIT_SUCCESS)
            }
            sigintSource.resume()

            let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            sigtermSource.setEventHandler {
                client.stop()
                exit(EXIT_SUCCESS)
            }
            sigtermSource.resume()

            logger.info("Press Ctrl+C to stop")
            RunLoop.main.run()
            withExtendedLifetime(sigintSource) {
                withExtendedLifetime(sigtermSource) {
                    withExtendedLifetime(client) {}
                }
            }
        } catch let error as ClientError {
            switch error {
            case .helpRequested:
                print(error.description)
                exit(EXIT_SUCCESS)
            case .versionRequested:
                print(error.description)
                exit(EXIT_SUCCESS)
            default:
                fputs("\(error.description)\n", stderr)
                exit(EXIT_FAILURE)
            }
        } catch {
            fputs("Fatal error: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
