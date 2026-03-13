import CoreGraphics
import Foundation
import ImageIO
import MacVRProtocol
import Network
import UniformTypeIdentifiers

// The bridge simulator doubles as a practical ingest shim. It can synthesize frames,
// watch JPEG files/directories, or accept frames over a local TCP socket from external tools.
private enum SimulatorError: Error {
    case helpRequested
    case versionRequested
    case missingValue(String)
    case invalidValue(String)
    case unknownArgument(String)
    case invalidPort(UInt16)
}

private struct CLIOptions {
    var host = "127.0.0.1"
    var bridgePort: UInt16 = 43000
    var fps = 20
    var width = 960
    var height = 540
    var jpegQuality = 65
    var jpegFilePath: String?
    var jpegDirectoryPath: String?
    var jpegInputPort: UInt16?
    var maxJPEGBytes = 250_000
    var preferredTransport: BridgeFrameTransport = .udpChunked
    var source = "bridge-sim"
    var clientName = "macvr-bridge-sim"
    var verbose = false

    static let usage = """
    Usage: macvr-bridge-sim [options]
      --host <hostname>       Host address for bridge ingest (default: 127.0.0.1)
      --bridge-port <port>    Host bridge control/UDP ingest port (default: 43000)
      --fps <value>           Submit frame rate, 1-120 (default: 20)
      --width <pixels>        Generated frame width (default: 960)
      --height <pixels>       Generated frame height (default: 540)
      --jpeg-quality <1-100>  JPEG quality (default: 65)
      --jpeg-file <path>      Use an existing JPEG file as frame source (default: generated test pattern)
      --jpeg-dir <path>       Use newest .jpg/.jpeg in directory as frame source
      --jpeg-input-port <p>   Accept length-prefixed JPEG frames on localhost TCP port
      --max-jpeg-bytes <n>    Max bytes for transmitted JPEG (default: 250000)
      --prefer-transport <t>  Preferred transport: udp-chunked | tcp-inline-base64 (default: udp-chunked)
      --source <name>         Source tag sent to bridge service (default: bridge-sim)
      --client-name <name>    Client name used in hello (default: macvr-bridge-sim)
      --version               Show build/release version
      --verbose               Enable debug logging
      -h, --help              Show this help
    """

    static func parse(arguments: [String]) throws -> CLIOptions {
        var options = CLIOptions()
        var index = 0

        func requireValue(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else {
                throw SimulatorError.missingValue(flag)
            }
            return arguments[index]
        }

        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--host":
                let value = try requireValue(arg).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw SimulatorError.invalidValue("host cannot be empty")
                }
                options.host = value
            case "--bridge-port":
                let value = try requireValue(arg)
                guard let port = UInt16(value), port > 0 else {
                    throw SimulatorError.invalidValue("Invalid bridge port: \(value)")
                }
                options.bridgePort = port
            case "--fps":
                let value = try requireValue(arg)
                guard let fps = Int(value), (1...120).contains(fps) else {
                    throw SimulatorError.invalidValue("Invalid fps value: \(value)")
                }
                options.fps = fps
            case "--width":
                let value = try requireValue(arg)
                guard let width = Int(value), (64...4096).contains(width) else {
                    throw SimulatorError.invalidValue("Invalid width: \(value)")
                }
                options.width = width
            case "--height":
                let value = try requireValue(arg)
                guard let height = Int(value), (64...4096).contains(height) else {
                    throw SimulatorError.invalidValue("Invalid height: \(value)")
                }
                options.height = height
            case "--jpeg-quality":
                let value = try requireValue(arg)
                guard let quality = Int(value), (1...100).contains(quality) else {
                    throw SimulatorError.invalidValue("Invalid jpeg quality: \(value)")
                }
                options.jpegQuality = quality
            case "--jpeg-file":
                let value = try requireValue(arg).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw SimulatorError.invalidValue("jpeg-file cannot be empty")
                }
                options.jpegFilePath = value
            case "--jpeg-dir":
                let value = try requireValue(arg).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw SimulatorError.invalidValue("jpeg-dir cannot be empty")
                }
                options.jpegDirectoryPath = value
            case "--jpeg-input-port":
                let value = try requireValue(arg)
                guard let port = UInt16(value), port > 0 else {
                    throw SimulatorError.invalidValue("Invalid jpeg-input-port: \(value)")
                }
                options.jpegInputPort = port
            case "--max-jpeg-bytes":
                let value = try requireValue(arg)
                guard let maxBytes = Int(value), (16_384...16_000_000).contains(maxBytes) else {
                    throw SimulatorError.invalidValue("Invalid max-jpeg-bytes: \(value)")
                }
                options.maxJPEGBytes = maxBytes
            case "--prefer-transport":
                let value = try requireValue(arg)
                guard let transport = BridgeFrameTransport(rawValue: value) else {
                    throw SimulatorError.invalidValue("Invalid prefer-transport: \(value)")
                }
                options.preferredTransport = transport
            case "--source":
                let value = try requireValue(arg).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw SimulatorError.invalidValue("source cannot be empty")
                }
                options.source = value
            case "--client-name":
                let value = try requireValue(arg).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw SimulatorError.invalidValue("client-name cannot be empty")
                }
                options.clientName = value
            case "--version":
                throw SimulatorError.versionRequested
            case "--verbose":
                options.verbose = true
            case "-h", "--help":
                throw SimulatorError.helpRequested
            default:
                throw SimulatorError.unknownArgument(arg)
            }
            index += 1
        }

        if options.jpegFilePath != nil, options.jpegDirectoryPath != nil {
            throw SimulatorError.invalidValue("Use either --jpeg-file or --jpeg-dir, not both")
        }

        return options
    }
}

private extension SimulatorError {
    var description: String {
        switch self {
        case .helpRequested:
            return CLIOptions.usage
        case .versionRequested:
            return "macvr-bridge-sim \(macVRReleaseVersion)"
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

private final class SimLogger: @unchecked Sendable {
    private let lock = NSLock()
    private let verbose: Bool
    private let formatter: ISO8601DateFormatter

    init(verbose: Bool) {
        self.verbose = verbose
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
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

private final class BridgeSimulator: @unchecked Sendable {
    private let options: CLIOptions
    private let logger: SimLogger
    private let queue = DispatchQueue(label: "macvr.bridge.sim")
    private let reconnectMinDelayNs: UInt64 = 500_000_000
    private let reconnectMaxDelayNs: UInt64 = 8_000_000_000
    private let reconnectJitterMaxNs: UInt64 = 250_000_000
    private let controlPingIntervalNs: UInt64 = 2_000_000_000
    private let controlStaleTimeoutNs: UInt64 = 10_000_000_000

    private var controlConnection: NWConnection?
    private var udpConnection: NWConnection?
    private var inputListener: NWListener?
    private var inputConnections: [ObjectIdentifier: NWConnection] = [:]
    private var inputReceiveBuffers: [ObjectIdentifier: Data] = [:]
    private var latestInputJPEG: Data?
    private var latestInputFrameTimeNs: UInt64?
    private var jpegInputFrameCount: UInt64 = 0
    private var receiveBuffer = Data()
    private var sendTimer: DispatchSourceTimer?
    private var controlPingTimer: DispatchSourceTimer?
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempt: UInt32 = 0
    private var isStopped = false
    private var lastControlReceiveNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    private var frameIndex: UInt64 = 0
    private var selectedTransport: BridgeFrameTransport = .tcpInlineBase64
    private var selectedUDPPort: UInt16?
    private var selectedMaxPacketSize = FrameChunkPacketizer.defaultMaxPacketSize
    private var selectedUDPAuthToken: Data?
    private var jpegFileReadFailures: UInt64 = 0
    private var jpegSourceResolveFailures: UInt64 = 0
    private var cachedJPEGFilePath: String?
    private var cachedJPEGFileModDate: Date?
    private var cachedJPEGFileSize: UInt64?
    private var cachedProcessedJPEG: Data?
    private var cachedJPEGDirectoryLatestPath: String?
    private var lastJPEGDirectoryScanNs: UInt64 = 0
    private let jpegDirectoryScanIntervalNs: UInt64 = 250_000_000
    private let inputFrameStaleTimeoutNs: UInt64 = 2_000_000_000

    init(options: CLIOptions, logger: SimLogger) {
        self.options = options
        self.logger = logger
    }

    func start() throws {
        guard NWEndpoint.Port(rawValue: options.bridgePort) != nil else {
            throw SimulatorError.invalidPort(options.bridgePort)
        }
        isStopped = false
        try startInputListenerIfNeeded()
        connectControl()
    }

    func stop() {
        queue.async {
            self.isStopped = true
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.stopControlPingTimer()
            self.stopFrameTimer()
            self.stopUDPConnection()
            self.stopInputListener()
            self.controlConnection?.stateUpdateHandler = nil
            self.controlConnection?.cancel()
            self.controlConnection = nil
        }
    }

    private func connectControl() {
        guard !isStopped else {
            return
        }
        guard let port = NWEndpoint.Port(rawValue: options.bridgePort) else {
            logger.warning("Cannot connect bridge control: invalid port \(options.bridgePort)")
            return
        }

        reconnectWorkItem = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        let connection = NWConnection(
            host: NWEndpoint.Host(options.host),
            port: port,
            using: .tcp
        )
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else {
                return
            }
            self.handleControlState(state, connection: connection)
        }
        controlConnection = connection
        receiveControl(on: connection)
        connection.start(queue: queue)

        logger.info("Connecting to bridge ingest at \(options.host):\(options.bridgePort)")
    }

    private func handleControlState(_ state: NWConnection.State, connection: NWConnection) {
        guard isCurrentControlConnection(connection) else {
            return
        }

        switch state {
        case .ready:
            logger.info("Bridge control connection ready")
            reconnectAttempt = 0
            lastControlReceiveNs = DispatchTime.now().uptimeNanoseconds
            sendHello()
            startControlPingTimer()
        case .failed(let error):
            logger.warning("Bridge control connection failed: \(error)")
            handleControlDisconnect(connection: connection)
        case .cancelled:
            logger.info("Bridge control connection cancelled")
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
                self.lastControlReceiveNs = DispatchTime.now().uptimeNanoseconds
                self.consumeControlData(data)
            }

            if let error {
                self.logger.warning("Bridge receive error: \(error)")
                self.handleControlDisconnect(connection: connection)
                return
            }

            if isComplete {
                self.logger.info("Bridge connection closed by host")
                self.handleControlDisconnect(connection: connection)
                return
            }

            self.receiveControl(on: connection)
        }
    }

    private func startInputListenerIfNeeded() throws {
        guard let portValue = options.jpegInputPort else {
            return
        }
        guard inputListener == nil else {
            return
        }
        guard let port = NWEndpoint.Port(rawValue: portValue) else {
            throw SimulatorError.invalidPort(portValue)
        }

        let listener = try NWListener(using: .tcp, on: port)
        listener.stateUpdateHandler = { [weak self] state in
            self?.handleInputListenerState(state, port: portValue)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.acceptInputConnection(connection)
        }
        listener.start(queue: queue)
        inputListener = listener
        logger.info("JPEG input listener starting on tcp://127.0.0.1:\(portValue)")
    }

    private func stopInputListener() {
        inputListener?.cancel()
        inputListener = nil
        for (_, connection) in inputConnections {
            connection.cancel()
        }
        inputConnections.removeAll()
        inputReceiveBuffers.removeAll()
        latestInputJPEG = nil
        latestInputFrameTimeNs = nil
        jpegInputFrameCount = 0
    }

    private func handleInputListenerState(_ state: NWListener.State, port: UInt16) {
        switch state {
        case .ready:
            logger.info("JPEG input listener ready on 127.0.0.1:\(port)")
        case .failed(let error):
            logger.warning("JPEG input listener failed: \(error)")
        case .cancelled:
            logger.debug("JPEG input listener cancelled")
        default:
            break
        }
    }

    private func acceptInputConnection(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        inputConnections[key] = connection
        inputReceiveBuffers[key] = Data()
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleInputConnectionState(state, key: key, endpoint: connection.endpoint)
        }
        connection.start(queue: queue)
        receiveInput(on: connection, key: key)
    }

    private func handleInputConnectionState(_ state: NWConnection.State, key: ObjectIdentifier, endpoint: NWEndpoint) {
        switch state {
        case .ready:
            logger.info("JPEG input connection ready: \(endpoint)")
        case .failed(let error):
            logger.warning("JPEG input connection failed (\(endpoint)): \(error)")
            cleanupInputConnection(key: key)
        case .cancelled:
            cleanupInputConnection(key: key)
        default:
            break
        }
    }

    private func receiveInput(on connection: NWConnection, key: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if let data, !data.isEmpty {
                self.consumeInputData(data, key: key)
            }

            if let error {
                self.logger.warning("JPEG input receive error: \(error)")
                self.cleanupInputConnection(key: key)
                return
            }

            if isComplete {
                self.logger.info("JPEG input connection closed by peer")
                self.cleanupInputConnection(key: key)
                return
            }

            self.receiveInput(on: connection, key: key)
        }
    }

    private func consumeInputData(_ data: Data, key: ObjectIdentifier) {
        guard var buffer = inputReceiveBuffers[key] else {
            return
        }
        buffer.append(data)

        while true {
            guard buffer.count >= 4 else {
                break
            }

            // External producers send `uint32_be length` followed by raw JPEG bytes.
            let frameLength =
                (Int(buffer[0]) << 24)
                | (Int(buffer[1]) << 16)
                | (Int(buffer[2]) << 8)
                | Int(buffer[3])

            if frameLength <= 0 || frameLength > options.maxJPEGBytes {
                logger.warning(
                    "Dropped invalid JPEG input frame length=\(frameLength) (max=\(options.maxJPEGBytes))"
                )
                buffer.removeAll(keepingCapacity: true)
                break
            }

            guard buffer.count >= 4 + frameLength else {
                break
            }

            let start = buffer.index(buffer.startIndex, offsetBy: 4)
            let end = buffer.index(start, offsetBy: frameLength)
            let jpegData = Data(buffer[start..<end])
            buffer.removeSubrange(buffer.startIndex..<end)

            // Reuse the same JPEG processing path as file-backed inputs so bridge limits stay consistent.
            if let processed = processJPEGFileData(jpegData, path: "jpeg-input") {
                latestInputJPEG = processed
                latestInputFrameTimeNs = DispatchTime.now().uptimeNanoseconds
                jpegInputFrameCount &+= 1
                if jpegInputFrameCount % UInt64(max(options.fps * 4, 1)) == 0 {
                    logger.info(
                        "Accepted jpeg-input frame count=\(jpegInputFrameCount) size=\(processed.count)B"
                    )
                }
            }
        }

        inputReceiveBuffers[key] = buffer
    }

    private func cleanupInputConnection(key: ObjectIdentifier) {
        inputReceiveBuffers.removeValue(forKey: key)
        guard let connection = inputConnections.removeValue(forKey: key) else {
            return
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func consumeControlData(_ data: Data) {
        receiveBuffer.append(data)

        while let newlineIndex = receiveBuffer.firstIndex(of: 0x0A) {
            var line = Data(receiveBuffer[..<newlineIndex])
            let next = receiveBuffer.index(after: newlineIndex)
            receiveBuffer.removeSubrange(receiveBuffer.startIndex..<next)

            if line.last == 0x0D {
                line.removeLast()
            }
            guard !line.isEmpty else {
                continue
            }

            do {
                let message = try WireCodec.decode(BridgeServerMessage.self, from: line)
                handleControlMessage(message)
            } catch {
                logger.warning("Failed to decode bridge server message: \(error)")
            }
        }
    }

    private func handleControlMessage(_ message: BridgeServerMessage) {
        lastControlReceiveNs = DispatchTime.now().uptimeNanoseconds

        switch message.type {
        case .welcome:
            if let welcome = message.welcome {
                selectedTransport = welcome.frameTransport
                if let maxPacketSize = welcome.maxPacketSize {
                    selectedMaxPacketSize = Self.clampPacketSize(maxPacketSize)
                }
                if selectedTransport == .udpChunked {
                    guard
                        let tokenBase64 = welcome.udpAuthTokenBase64,
                        let token = Data(base64Encoded: tokenBase64),
                        token.count == BridgeUDPPacketEnvelope.authTokenByteCount
                    else {
                        selectedTransport = .tcpInlineBase64
                        selectedUDPAuthToken = nil
                        logger.warning(
                            "Bridge welcome missing/invalid udpAuthTokenBase64; falling back to \(selectedTransport.rawValue)"
                        )
                        stopUDPConnection()
                        startFrameTimer()
                        return
                    }
                    selectedUDPAuthToken = token
                    let udpPort = welcome.udpIngestPort ?? options.bridgePort
                    selectedUDPPort = udpPort
                    startUDPConnection(port: udpPort)
                    logger.info(
                        "Bridge welcome: \(welcome.message), source=\(welcome.acceptedSource), transport=\(selectedTransport.rawValue), udpPort=\(udpPort), mtu=\(selectedMaxPacketSize)"
                    )
                } else {
                    selectedUDPAuthToken = nil
                    logger.info(
                        "Bridge welcome: \(welcome.message), source=\(welcome.acceptedSource), transport=\(selectedTransport.rawValue)"
                    )
                    stopUDPConnection()
                }
                startFrameTimer()
            }
        case .error:
            if let error = message.error {
                logger.warning("Bridge error [\(error.code)]: \(error.message)")
            }
        case .pong:
            if let pong = message.pong {
                logger.debug("Bridge pong nonce=\(pong.nonce ?? "nil"), serverNs=\(pong.serverTimeNs)")
            }
        }
    }

    private func sendHello() {
        let hello = BridgeHelloPayload(
            clientName: options.clientName,
            source: options.source,
            preferredTransport: options.preferredTransport,
            maxPacketSize: selectedMaxPacketSize
        )
        sendControl(BridgeClientMessage.hello(hello))
    }

    private func startControlPingTimer() {
        guard controlPingTimer == nil else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .nanoseconds(Int(controlPingIntervalNs)), repeating: .nanoseconds(Int(controlPingIntervalNs)))
        timer.setEventHandler { [weak self] in
            self?.tickControlHealth()
        }
        timer.resume()
        controlPingTimer = timer
    }

    private func stopControlPingTimer() {
        controlPingTimer?.setEventHandler {}
        controlPingTimer?.cancel()
        controlPingTimer = nil
    }

    private func tickControlHealth() {
        guard controlConnection != nil else {
            return
        }

        let nowNs = DispatchTime.now().uptimeNanoseconds
        if nowNs &- lastControlReceiveNs > controlStaleTimeoutNs {
            logger.warning("Bridge control appears stale (> \(controlStaleTimeoutNs / 1_000_000_000)s without RX); reconnecting")
            handleControlDisconnect(connection: controlConnection)
            return
        }

        let nonce = String(nowNs, radix: 16)
        sendControl(.ping(BridgePingPayload(nonce: nonce)))
    }

    private func startFrameTimer() {
        guard sendTimer == nil else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        let intervalNs = UInt64(1_000_000_000 / max(options.fps, 1))
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .nanoseconds(max(Int(intervalNs), 1)))
        timer.setEventHandler { [weak self] in
            self?.submitFrame()
        }
        timer.resume()
        sendTimer = timer
    }

    private func stopFrameTimer() {
        sendTimer?.setEventHandler {}
        sendTimer?.cancel()
        sendTimer = nil
    }

    private func submitFrame() {
        frameIndex &+= 1
        let sentTimeNs = DispatchTime.now().uptimeNanoseconds
        guard let jpegData = loadFrameJPEG(frameIndex: frameIndex) else {
            return
        }

        if selectedTransport == .udpChunked {
            submitFrameUDP(jpegData: jpegData, sentTimeNs: sentTimeNs)
            return
        }

        submitFrameInline(jpegData: jpegData, sentTimeNs: sentTimeNs)
    }

    private func loadFrameJPEG(frameIndex: UInt64) -> Data? {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        if let inputJPEG = latestInputJPEG, let latestTimeNs = latestInputFrameTimeNs {
            let ageNs = nowNs &- latestTimeNs
            if ageNs <= inputFrameStaleTimeoutNs {
                return inputJPEG
            }
        }
        // If the live input socket has gone quiet, fall back to file/directory/generated sources.
        if let path = resolveJPEGSourcePath(nowNs: nowNs) {
            do {
                let fileURL = URL(fileURLWithPath: path)
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                let fileModDate = attributes[.modificationDate] as? Date
                let fileSize = (attributes[.size] as? NSNumber)?.uint64Value

                if
                    cachedJPEGFilePath == path,
                    cachedJPEGFileModDate == fileModDate,
                    cachedJPEGFileSize == fileSize,
                    let cachedProcessedJPEG
                {
                    return cachedProcessedJPEG
                }

                let jpegData = try Data(contentsOf: fileURL)
                guard !jpegData.isEmpty else {
                    jpegFileReadFailures &+= 1
                    if jpegFileReadFailures % 60 == 1 {
                        logger.warning("JPEG file is empty: \(path)")
                    }
                    return nil
                }

                guard let processed = processJPEGFileData(jpegData, path: path) else {
                    return nil
                }
                cachedJPEGFilePath = path
                cachedJPEGFileModDate = fileModDate
                cachedJPEGFileSize = fileSize
                cachedProcessedJPEG = processed
                return processed
            } catch {
                jpegFileReadFailures &+= 1
                if jpegFileReadFailures % 60 == 1 {
                    logger.warning("Failed to read JPEG file \(path): \(error)")
                }
                return nil
            }
        }

        guard let jpegData = makeTestFrameJPEG(frameIndex: frameIndex) else {
            logger.warning("Failed to generate JPEG test frame")
            return nil
        }
        return jpegData
    }

    private func resolveJPEGSourcePath(nowNs: UInt64) -> String? {
        if let path = options.jpegFilePath {
            return path
        }

        guard let directoryPath = options.jpegDirectoryPath else {
            return nil
        }

        let shouldRescan = cachedJPEGDirectoryLatestPath == nil
            || (nowNs &- lastJPEGDirectoryScanNs) >= jpegDirectoryScanIntervalNs
        if shouldRescan {
            lastJPEGDirectoryScanNs = nowNs
            do {
                cachedJPEGDirectoryLatestPath = try Self.findLatestJPEGPath(in: directoryPath)
            } catch {
                jpegSourceResolveFailures &+= 1
                if jpegSourceResolveFailures % 60 == 1 {
                    logger.warning("Failed to scan JPEG directory \(directoryPath): \(error)")
                }
            }
        }

        guard let path = cachedJPEGDirectoryLatestPath else {
            jpegSourceResolveFailures &+= 1
            if jpegSourceResolveFailures % 60 == 1 {
                logger.warning("No .jpg/.jpeg files available in directory: \(directoryPath)")
            }
            return nil
        }
        return path
    }

    private func processJPEGFileData(_ jpegData: Data, path: String) -> Data? {
        if jpegData.count <= options.maxJPEGBytes {
            return jpegData
        }

        guard let imageSource = CGImageSourceCreateWithData(jpegData as CFData, nil) else {
            jpegFileReadFailures &+= 1
            if jpegFileReadFailures % 60 == 1 {
                logger.warning("Failed to decode JPEG source for processing: \(path)")
            }
            return nil
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(options.width, options.height),
        ]
        let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbOptions as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(imageSource, 0, nil)

        guard let image else {
            jpegFileReadFailures &+= 1
            if jpegFileReadFailures % 60 == 1 {
                logger.warning("Failed to create image for JPEG processing: \(path)")
            }
            return nil
        }

        var bestCandidate: Data?
        let qualitySteps: [Int] = [options.jpegQuality, 60, 50, 40, 30, 25, 20]
        for quality in qualitySteps {
            guard let encoded = Self.encodeJPEG(image: image, quality: quality) else {
                continue
            }
            bestCandidate = encoded
            if encoded.count <= options.maxJPEGBytes {
                logger.info(
                    "Compressed JPEG file \(path) from \(jpegData.count)B to \(encoded.count)B (quality=\(quality))"
                )
                return encoded
            }
        }

        if let bestCandidate {
            jpegFileReadFailures &+= 1
            if jpegFileReadFailures % 60 == 1 {
                logger.warning(
                    "JPEG file \(path) is too large after compression (\(bestCandidate.count)B > max-jpeg-bytes=\(options.maxJPEGBytes)); dropping frame"
                )
            }
            return nil
        }

        jpegFileReadFailures &+= 1
        if jpegFileReadFailures % 60 == 1 {
            logger.warning("Failed to compress JPEG file \(path); dropping frame")
        }
        return nil
    }

    private static func encodeJPEG(image: CGImage, quality: Int) -> Data? {
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let clampedQuality = min(max(quality, 1), 100)
        let options = [kCGImageDestinationLossyCompressionQuality: CGFloat(clampedQuality) / 100.0] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return encoded as Data
    }

    private static func findLatestJPEGPath(in directoryPath: String) throws -> String? {
        let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentModificationDateKey,
        ]
        let entries = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        var bestURL: URL?
        var bestDate = Date.distantPast
        for entry in entries {
            let ext = entry.pathExtension.lowercased()
            guard ext == "jpg" || ext == "jpeg" else {
                continue
            }
            let values = try? entry.resourceValues(forKeys: resourceKeys)
            guard values?.isRegularFile == true else {
                continue
            }
            let modified = values?.contentModificationDate ?? Date.distantPast
            if modified > bestDate {
                bestDate = modified
                bestURL = entry
            } else if modified == bestDate, let currentBest = bestURL, entry.path > currentBest.path {
                bestURL = entry
            }
        }
        return bestURL?.path
    }

    private func submitFrameInline(jpegData: Data, sentTimeNs: UInt64) {
        let payload = BridgeSubmitFramePayload(
            frameIndex: frameIndex,
            sentTimeNs: sentTimeNs,
            jpegBase64: jpegData.base64EncodedString(),
            width: options.width,
            height: options.height
        )
        sendControl(.submitFrame(payload))

        if frameIndex % UInt64(options.fps * 2) == 0 {
            let mbps = Double(jpegData.count * options.fps * 8) / 1_000_000.0
            logger.info(
                String(
                    format: "Submitted inline frame=%llu size=%dB est=%.2fMbps",
                    frameIndex,
                    jpegData.count,
                    mbps
                )
            )
        }
    }

    private func submitFrameUDP(jpegData: Data, sentTimeNs: UInt64) {
        guard let udpConnection else {
            logger.warning("UDP transport selected but UDP connection is not available yet")
            return
        }
        guard let udpAuthToken = selectedUDPAuthToken else {
            logger.warning("UDP transport selected but auth token is not available")
            return
        }

        let packets: [Data]
        do {
            packets = try FrameChunkPacketizer.packetize(
                codec: .jpeg,
                flags: 0x01,
                frameIndex: frameIndex,
                sentTimeNs: sentTimeNs,
                payload: jpegData,
                maxPacketSize: selectedMaxPacketSize
            )
        } catch {
            logger.warning("Failed to packetize UDP bridge frame: \(error)")
            return
        }

        for packet in packets {
            let envelopePacket: Data
            do {
                envelopePacket = try BridgeUDPPacketEnvelope.encode(authToken: udpAuthToken, frameChunkPacket: packet)
            } catch {
                logger.warning("Failed to encode bridge UDP envelope: \(error)")
                return
            }

            udpConnection.send(content: envelopePacket, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.logger.warning("Failed to send bridge UDP packet: \(error)")
                }
            })
        }

        if frameIndex % UInt64(options.fps * 2) == 0 {
            let mbps = Double(jpegData.count * options.fps * 8) / 1_000_000.0
            logger.info(
                String(
                    format: "Submitted udp frame=%llu size=%dB chunks=%d est=%.2fMbps",
                    frameIndex,
                    jpegData.count,
                    packets.count,
                    mbps
                )
            )
        }
    }

    private func makeTestFrameJPEG(frameIndex: UInt64) -> Data? {
        let width = options.width
        let height = options.height
        let bytesPerRow = width * 4
        var rgba = Data(count: bytesPerRow * height)

        let phase = Double(frameIndex % 360) / 360.0
        let barX = Int((sin(phase * .pi * 2.0) * 0.5 + 0.5) * Double(max(width - 100, 1)))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let image = rgba.withUnsafeMutableBytes({ rawBuffer -> CGImage? in
            guard let base = rawBuffer.baseAddress else {
                return nil
            }

            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return nil
            }

            context.setFillColor(CGColor(red: 0.08, green: 0.10, blue: 0.16, alpha: 1.0))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))

            context.setFillColor(CGColor(red: 0.16, green: 0.22, blue: 0.34, alpha: 1.0))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height / 3))

            context.setFillColor(CGColor(red: 0.23, green: 0.12, blue: 0.12, alpha: 1.0))
            context.fill(CGRect(x: 0, y: height * 2 / 3, width: width, height: height / 3))

            context.setFillColor(CGColor(red: 0.94, green: 0.74, blue: 0.22, alpha: 1.0))
            context.fill(CGRect(x: barX, y: 0, width: 100, height: height))

            let markerSize = 14
            let markerY = Int((phase * Double(height - markerSize)).rounded())
            context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1.0))
            context.fill(CGRect(x: width / 2 - markerSize / 2, y: markerY, width: markerSize, height: markerSize))

            return context.makeImage()
        }) else {
            return nil
        }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let quality = CGFloat(options.jpegQuality) / 100.0
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return encoded as Data
    }

    private func startUDPConnection(port: UInt16) {
        if let existing = selectedUDPPort, existing == port, udpConnection != nil {
            return
        }
        stopUDPConnection()

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            logger.warning("Bridge welcome provided invalid UDP port: \(port)")
            return
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(options.host),
            port: endpointPort,
            using: .udp
        )
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleUDPState(state, port: port)
        }
        connection.start(queue: queue)
        udpConnection = connection
    }

    private func stopUDPConnection() {
        udpConnection?.stateUpdateHandler = nil
        udpConnection?.cancel()
        udpConnection = nil
    }

    private func handleUDPState(_ state: NWConnection.State, port: UInt16) {
        switch state {
        case .ready:
            logger.info("Bridge UDP sender ready to \(options.host):\(port)")
        case .failed(let error):
            logger.warning("Bridge UDP sender failed: \(error)")
        case .cancelled:
            logger.debug("Bridge UDP sender cancelled")
        default:
            break
        }
    }

    private func sendControl(_ message: BridgeClientMessage) {
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
                    self.logger.warning("Failed to send bridge message: \(error)")
                    self.handleControlDisconnect(connection: connection)
                }
            })
        } catch {
            logger.warning("Failed to encode bridge message: \(error)")
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

        stopControlPingTimer()
        stopFrameTimer()
        selectedTransport = .tcpInlineBase64
        selectedUDPAuthToken = nil
        selectedUDPPort = nil
        stopUDPConnection()
        receiveBuffer.removeAll(keepingCapacity: true)

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
        logger.info(String(format: "Reconnecting bridge control in %.0fms (attempt %u)", delayMs, attemptNumber))
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

    private static func clampPacketSize(_ size: Int) -> Int {
        min(max(size, 512), 65_507)
    }
}

@main
struct MacVRBridgeSimApp {
    static func main() {
        do {
            let options = try CLIOptions.parse(arguments: Array(CommandLine.arguments.dropFirst()))
            let logger = SimLogger(verbose: options.verbose)
            let simulator = BridgeSimulator(options: options, logger: logger)
            try simulator.start()

            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)

            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigintSource.setEventHandler {
                simulator.stop()
                exit(EXIT_SUCCESS)
            }
            sigintSource.resume()

            let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            sigtermSource.setEventHandler {
                simulator.stop()
                exit(EXIT_SUCCESS)
            }
            sigtermSource.resume()

            logger.info("Press Ctrl+C to stop")
            RunLoop.main.run()
            withExtendedLifetime(sigintSource) {
                withExtendedLifetime(sigtermSource) {
                    withExtendedLifetime(simulator) {}
                }
            }
        } catch let error as SimulatorError {
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
