import AppKit
import Foundation
import ImageIO
import MacVRProtocol
import Network
import SwiftUI

private enum ViewerPreviewMode: String, CaseIterable, Identifiable {
    case duplicate = "Duplicate"
    case splitStereo = "Split Source"

    var id: String { rawValue }

    var helpText: String {
        switch self {
        case .duplicate:
            return "Mirror the same incoming frame into both eye panels. Useful when the source is mono or when you want to validate transport timing without stereo cropping."
        case .splitStereo:
            return "Crop the incoming frame into left and right halves and present them side by side. Use this when the source already renders stereo views in one wide image."
        }
    }
}

private struct ViewerLaunchOptions {
    var host = "127.0.0.1"
    var controlPort: UInt16 = 42000
    var udpPort: UInt16 = 9944
    var discoveryPort: UInt16 = 9943
    var requestedFPS = 72
    var requestedStreamMode: StreamMode = .bridgeJPEG
    var autoConnect = false
    var headless = false
    var quitAfterSeconds: Double?
    var verbose = false

    static let usage = """
    Usage: macvr-viewer [options]
      --host <hostname>       Host address for the TCP control channel (default: 127.0.0.1)
      --control-port <port>   Host TCP control port (default: 42000)
      --udp-port <port>       Local UDP port for video packets (default: 9944)
      --discovery-port <port> UDP runtime discovery port (default: 9943)
      --fps <value>           Requested pose update rate, 1-240 (default: 72)
      --stream-mode <mode>    Requested mode: display-jpeg | bridge-jpeg | mock (default: bridge-jpeg)
      --auto-connect          Connect automatically when the window opens
      --headless              Run the receiver without opening a GUI window
      --quit-after <seconds>  Quit automatically after the given number of seconds
      --verbose               Show debug logging in the viewer log pane and stdout
      --version               Show build/release version
      -h, --help              Show this help
    """

    static func parse(arguments: [String]) throws -> ViewerLaunchOptions {
        var options = ViewerLaunchOptions()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--host":
                index += 1
                guard index < arguments.count else {
                    throw ViewerArgumentError.missingValue(argument)
                }
                let value = arguments[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw ViewerArgumentError.invalidValue("Host cannot be empty")
                }
                options.host = value
            case "--control-port":
                index += 1
                guard index < arguments.count else {
                    throw ViewerArgumentError.missingValue(argument)
                }
                guard let value = UInt16(arguments[index]), value > 0 else {
                    throw ViewerArgumentError.invalidValue("Invalid control port: \(arguments[index])")
                }
                options.controlPort = value
            case "--udp-port":
                index += 1
                guard index < arguments.count else {
                    throw ViewerArgumentError.missingValue(argument)
                }
                guard let value = UInt16(arguments[index]), value > 0 else {
                    throw ViewerArgumentError.invalidValue("Invalid UDP port: \(arguments[index])")
                }
                options.udpPort = value
            case "--discovery-port":
                index += 1
                guard index < arguments.count else {
                    throw ViewerArgumentError.missingValue(argument)
                }
                guard let value = UInt16(arguments[index]), value > 0 else {
                    throw ViewerArgumentError.invalidValue("Invalid discovery port: \(arguments[index])")
                }
                options.discoveryPort = value
            case "--fps":
                index += 1
                guard index < arguments.count else {
                    throw ViewerArgumentError.missingValue(argument)
                }
                guard let value = Int(arguments[index]), (1...240).contains(value) else {
                    throw ViewerArgumentError.invalidValue("Invalid FPS value: \(arguments[index])")
                }
                options.requestedFPS = value
            case "--stream-mode":
                index += 1
                guard index < arguments.count else {
                    throw ViewerArgumentError.missingValue(argument)
                }
                guard let mode = StreamMode(rawValue: arguments[index]) else {
                    throw ViewerArgumentError.invalidValue("Invalid stream mode: \(arguments[index])")
                }
                options.requestedStreamMode = mode
            case "--auto-connect":
                options.autoConnect = true
            case "--headless":
                options.headless = true
            case "--quit-after":
                index += 1
                guard index < arguments.count else {
                    throw ViewerArgumentError.missingValue(argument)
                }
                guard let seconds = Double(arguments[index]), seconds > 0 else {
                    throw ViewerArgumentError.invalidValue("Invalid quit-after value: \(arguments[index])")
                }
                options.quitAfterSeconds = seconds
            case "--verbose":
                options.verbose = true
            case "--version":
                throw ViewerArgumentError.versionRequested
            case "-h", "--help":
                throw ViewerArgumentError.helpRequested
            default:
                throw ViewerArgumentError.unknownArgument(argument)
            }
            index += 1
        }

        return options
    }
}

private enum ViewerArgumentError: Error {
    case helpRequested
    case versionRequested
    case missingValue(String)
    case invalidValue(String)
    case unknownArgument(String)

    var description: String {
        switch self {
        case .helpRequested:
            return ViewerLaunchOptions.usage
        case .versionRequested:
            return "macvr-viewer \(macVRReleaseVersion)"
        case .missingValue(let flag):
            return "Missing value for \(flag)\n\n\(ViewerLaunchOptions.usage)"
        case .invalidValue(let message):
            return "\(message)\n\n\(ViewerLaunchOptions.usage)"
        case .unknownArgument(let argument):
            return "Unknown argument: \(argument)\n\n\(ViewerLaunchOptions.usage)"
        }
    }
}

private struct ViewerTransportConfiguration: Sendable {
    let host: String
    let controlPort: UInt16
    let udpPort: UInt16
    let requestedFPS: Int
    let requestedStreamMode: StreamMode
    let verbose: Bool
}

private struct ViewerTransportStatus: Sendable {
    var connectionState = "Idle"
    var streamState = "No session"
    var sessionID = "-"
    var negotiatedMode = "-"
    var negotiatedCodec = "-"
}

private struct ViewerFrameSnapshot: Sendable {
    let frameIndex: UInt64
    let sentTimeNs: UInt64
    let codec: FrameCodec
    let payload: Data
}

private final class ViewerTransport: @unchecked Sendable {
    private let configuration: ViewerTransportConfiguration
    private let queue = DispatchQueue(label: "com.macvr.viewer.transport")
    private let formatter: ISO8601DateFormatter
    private let reassembler = FrameReassembler()
    private let reconnectMinDelayNs: UInt64 = 500_000_000
    private let reconnectMaxDelayNs: UInt64 = 8_000_000_000
    private let reconnectJitterMaxNs: UInt64 = 250_000_000

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
    private var status = ViewerTransportStatus()

    var onLog: (@Sendable (String) -> Void)?
    var onStatus: (@Sendable (ViewerTransportStatus) -> Void)?
    var onFrame: (@Sendable (ViewerFrameSnapshot) -> Void)?

    init(configuration: ViewerTransportConfiguration) {
        self.configuration = configuration
        self.formatter = ISO8601DateFormatter()
        self.formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func start() throws {
        isStopped = false
        try startUDPListener()
        try startControlConnection()
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

            for connection in self.udpConnections.values {
                connection.cancel()
            }
            self.udpConnections.removeAll()
            self.controlReceiveBuffer.removeAll(keepingCapacity: false)
            self.status.connectionState = "Disconnected"
            self.status.streamState = "Stopped"
            self.emitStatus()
            self.log("INFO", "Viewer transport stopped")
        }
    }

    private func startUDPListener() throws {
        guard let udpPort = NWEndpoint.Port(rawValue: configuration.udpPort) else {
            throw NSError(
                domain: "macVR.ViewerTransport",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid UDP port: \(configuration.udpPort)"]
            )
        }

        let listener = try NWListener(using: .udp, on: udpPort)
        listener.stateUpdateHandler = { [weak self] state in
            self?.handleUDPListenerState(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.acceptUDP(connection)
        }
        udpListener = listener
        listener.start(queue: queue)
        log("INFO", "UDP listener starting on 0.0.0.0:\(configuration.udpPort)")
    }

    private func handleUDPListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            log("INFO", "UDP listener ready")
        case .failed(let error):
            log("WARN", "UDP listener failed: \(error)")
        case .cancelled:
            log("INFO", "UDP listener cancelled")
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
            log("DEBUG", "UDP connection ready: \(endpoint)", verboseOnly: true)
        case .failed(let error):
            log("WARN", "UDP connection failed (\(endpoint)): \(error)")
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
                self.log("WARN", "UDP receive error: \(error)")
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
                onFrame?(ViewerFrameSnapshot(
                    frameIndex: frame.frameIndex,
                    sentTimeNs: frame.sentTimeNs,
                    codec: frame.codec,
                    payload: frame.payload
                ))
            }
        } catch {
            log("DEBUG", "Dropped invalid UDP packet: \(error)", verboseOnly: true)
        }
    }

    private func startControlConnection() throws {
        guard let controlPort = NWEndpoint.Port(rawValue: configuration.controlPort) else {
            throw NSError(
                domain: "macVR.ViewerTransport",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid control port: \(configuration.controlPort)"]
            )
        }

        controlEndpointPort = controlPort
        let connection = NWConnection(
            host: NWEndpoint.Host(configuration.host),
            port: controlPort,
            using: .tcp
        )
        connectControl(using: connection)
    }

    private func connectControl(using connection: NWConnection? = nil) {
        guard !isStopped else {
            return
        }

        let resolvedConnection = connection ?? {
            guard let controlEndpointPort else {
                return nil
            }
            return NWConnection(
                host: NWEndpoint.Host(configuration.host),
                port: controlEndpointPort,
                using: .tcp
            )
        }()

        guard let resolvedConnection else {
            log("WARN", "Unable to reconnect control channel: port was not initialized")
            return
        }

        reconnectWorkItem = nil
        controlReceiveBuffer.removeAll(keepingCapacity: true)
        status.connectionState = "Connecting"
        emitStatus()

        resolvedConnection.stateUpdateHandler = { [weak self, weak resolvedConnection] state in
            guard let self, let resolvedConnection else {
                return
            }
            self.handleControlState(state, connection: resolvedConnection)
        }

        controlConnection = resolvedConnection
        receiveControl(on: resolvedConnection)
        resolvedConnection.start(queue: queue)
        log("INFO", "Connecting control channel to \(configuration.host):\(configuration.controlPort)")
    }

    private func handleControlState(_ state: NWConnection.State, connection: NWConnection) {
        guard isCurrentControlConnection(connection) else {
            return
        }

        switch state {
        case .ready:
            reconnectAttempt = 0
            status.connectionState = "Connected"
            emitStatus()
            log("INFO", "Control channel ready")
            sendHello()
            startPoseTimer()
            startPingTimer()
        case .waiting(let error):
            status.connectionState = "Waiting"
            emitStatus()
            log("WARN", "Control channel waiting: \(error)")
        case .failed(let error):
            status.connectionState = "Failed"
            emitStatus()
            log("WARN", "Control channel failed: \(error)")
            handleControlDisconnect(connection: connection)
        case .cancelled:
            status.connectionState = "Disconnected"
            emitStatus()
            log("INFO", "Control channel cancelled")
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
                self.log("WARN", "Control receive error: \(error)")
                self.handleControlDisconnect(connection: connection)
                return
            }

            if isComplete {
                self.log("INFO", "Control channel closed by host")
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
                log("WARN", "Failed to decode server control message: \(error)")
            }
        }
    }

    private func handleControlMessage(_ message: ServerControlMessage) {
        switch message.type {
        case .welcome:
            guard let welcome = message.welcome else {
                return
            }
            status.sessionID = welcome.sessionID
            status.negotiatedMode = welcome.streamMode.rawValue
            status.negotiatedCodec = String(describing: welcome.codec)
            status.streamState = welcome.message
            emitStatus()
            log(
                "INFO",
                "Welcome session=\(welcome.sessionID), mode=\(welcome.streamMode.rawValue), codec=\(welcome.codec), mtu=\(welcome.maxPacketSize)"
            )
        case .streamStatus:
            guard let streamStatus = message.streamStatus else {
                return
            }
            status.streamState = "\(streamStatus.state) (frame \(streamStatus.frameIndex))"
            emitStatus()
            log("INFO", "Stream status: \(streamStatus.state), frame=\(streamStatus.frameIndex)")
        case .error:
            guard let error = message.error else {
                return
            }
            status.streamState = "Error: \(error.code)"
            emitStatus()
            log("WARN", "Server error [\(error.code)]: \(error.message)")
        case .pong:
            guard let pong = message.pong else {
                return
            }
            log("DEBUG", "Pong nonce=\(pong.nonce ?? "nil") serverNs=\(pong.serverTimeNs)", verboseOnly: true)
        }
    }

    private func sendHello() {
        let hello = HelloPayload(
            clientName: "macvr-viewer",
            udpVideoPort: configuration.udpPort,
            requestedFPS: configuration.requestedFPS,
            requestedStreamMode: configuration.requestedStreamMode
        )
        sendControl(.hello(hello))
    }

    private func startPoseTimer() {
        guard poseTimer == nil else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        let intervalNs = UInt64(1_000_000_000 / max(configuration.requestedFPS, 1))
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
        sendControl(.pose(pose))
    }

    private func sendPing() {
        sendControl(.ping(PingPayload(nonce: UUID().uuidString.lowercased())))
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
                    self.log("WARN", "Failed to send control message: \(error)")
                    self.handleControlDisconnect(connection: connection)
                }
            })
        } catch {
            log("WARN", "Failed to encode control message: \(error)")
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

        status.connectionState = "Reconnecting"
        status.streamState = "Waiting for host"
        emitStatus()
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
        log("INFO", String(format: "Reconnecting control in %.0fms (attempt %u)", delayMs, attemptNumber))
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

    private func emitStatus() {
        onStatus?(status)
    }

    private func log(_ level: String, _ message: String, verboseOnly: Bool = false) {
        guard !verboseOnly || configuration.verbose else {
            return
        }
        let line = "[\(formatter.string(from: Date()))] [\(level)] \(message)"
        onLog?(line)
        print(line)
        fflush(stdout)
    }
}

private enum HeadlessViewerRunner {
    private final class FrameCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0

        func increment() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            value &+= 1
            return value
        }
    }

    static func run(options: ViewerLaunchOptions) throws {
        let configuration = ViewerTransportConfiguration(
            host: options.host,
            controlPort: options.controlPort,
            udpPort: options.udpPort,
            requestedFPS: options.requestedFPS,
            requestedStreamMode: options.requestedStreamMode,
            verbose: options.verbose
        )

        let transport = ViewerTransport(configuration: configuration)
        let semaphore = DispatchSemaphore(value: 0)
        let shutdownQueue = DispatchQueue(label: "com.macvr.viewer.headless")
        let quitAfterSeconds = options.quitAfterSeconds ?? 8
        let frameCounter = FrameCounter()

        transport.onStatus = { status in
            print("[HEADLESS] state=\(status.connectionState) session=\(status.sessionID) stream=\(status.streamState)")
            fflush(stdout)
        }
        transport.onFrame = { snapshot in
            let receivedFrames = frameCounter.increment()
            if snapshot.codec == .jpeg, receivedFrames % 30 == 0 {
                print("[HEADLESS] Received JPEG frame \(snapshot.frameIndex) bytes=\(snapshot.payload.count)")
                fflush(stdout)
            }
        }

        try transport.start()

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: shutdownQueue)
        sigintSource.setEventHandler {
            transport.stop()
            semaphore.signal()
        }
        sigintSource.resume()

        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: shutdownQueue)
        sigtermSource.setEventHandler {
            transport.stop()
            semaphore.signal()
        }
        sigtermSource.resume()

        shutdownQueue.asyncAfter(deadline: .now() + quitAfterSeconds) {
            print("[HEADLESS] Auto-quit timer elapsed after \(String(format: "%.1f", quitAfterSeconds)) seconds")
            fflush(stdout)
            transport.stop()
            semaphore.signal()
        }

        withExtendedLifetime(sigintSource) {
            withExtendedLifetime(sigtermSource) {
                semaphore.wait()
            }
        }
    }
}

@MainActor
private final class ViewerModel: ObservableObject {
    @Published var host: String
    @Published var controlPort: String
    @Published var udpPort: String
    @Published var discoveryPort: String
    @Published var requestedFPS: String
    @Published var requestedStreamMode: StreamMode
    @Published var previewMode: ViewerPreviewMode = .duplicate
    @Published var errorMessage: String?
    @Published private(set) var discoveredRuntimes: [DiscoveredRuntime] = []
    @Published private(set) var leftImage: NSImage?
    @Published private(set) var rightImage: NSImage?
    @Published private(set) var frameCount: UInt64 = 0
    @Published private(set) var frameBytes: Int = 0
    @Published private(set) var resolution = "No frame yet"
    @Published private(set) var connectionState = "Idle"
    @Published private(set) var streamState = "No session"
    @Published private(set) var sessionID = "-"
    @Published private(set) var negotiatedMode = "-"
    @Published private(set) var negotiatedCodec = "-"
    @Published private(set) var rxFPS = 0.0
    @Published private(set) var rxMbps = 0.0
    @Published private(set) var lastFrameLatencyMs = 0.0
    @Published private(set) var lastFrameClock = "Idle"
    @Published private(set) var logs: [String] = []
    @Published private(set) var isDiscovering = false
    @Published private(set) var isConnected = false

    private let launchOptions: ViewerLaunchOptions
    private var transport: ViewerTransport?
    private var lastDecodedImage: CGImage?
    private var lastJPEGData: Data?
    private var statsWindowStartNs = DispatchTime.now().uptimeNanoseconds
    private var statsFrameCount: UInt64 = 0
    private var statsByteCount: UInt64 = 0
    private var autoQuitTask: Task<Void, Never>?

    init(launchOptions: ViewerLaunchOptions) {
        self.launchOptions = launchOptions
        self.host = launchOptions.host
        self.controlPort = String(launchOptions.controlPort)
        self.udpPort = String(launchOptions.udpPort)
        self.discoveryPort = String(launchOptions.discoveryPort)
        self.requestedFPS = String(launchOptions.requestedFPS)
        self.requestedStreamMode = launchOptions.requestedStreamMode
    }

    deinit {
        autoQuitTask?.cancel()
    }

    var logsText: String {
        logs.joined(separator: "\n")
    }

    func startIfRequested() {
        if launchOptions.autoConnect {
            connect()
        }
        scheduleAutoQuitIfNeeded()
    }

    func connect() {
        guard transport == nil else {
            return
        }

        do {
            let configuration = try makeTransportConfiguration()
            let transport = ViewerTransport(configuration: configuration)
            transport.onLog = { [weak self] line in
                Task { @MainActor in
                    self?.appendLog(line)
                }
            }
            transport.onStatus = { [weak self] status in
                Task { @MainActor in
                    self?.apply(status: status)
                }
            }
            transport.onFrame = { [weak self] snapshot in
                Task { @MainActor in
                    self?.consume(frame: snapshot)
                }
            }
            try transport.start()
            self.transport = transport
            self.errorMessage = nil
            self.isConnected = true
            appendLog("Viewer connected to \(host):\(controlPort) and is waiting for frames")
        } catch {
            errorMessage = error.localizedDescription
            appendLog("Connect failed: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        transport?.stop()
        transport = nil
        isConnected = false
        connectionState = "Disconnected"
        streamState = "Stopped"
        appendLog("Viewer disconnected")
    }

    func discoverRuntimes() {
        guard !isDiscovering else {
            return
        }
        guard let parsedDiscoveryPort = UInt16(discoveryPort), parsedDiscoveryPort > 0 else {
            errorMessage = "Discovery port must be a valid port number"
            return
        }

        isDiscovering = true
        errorMessage = nil
        appendLog("Broadcasting discovery probe on UDP port \(parsedDiscoveryPort)")

        let requestedMode = requestedStreamMode
        Task.detached(priority: .userInitiated) {
            do {
                let runtimes = try ViewerDiscoveryClient.discover(
                    port: parsedDiscoveryPort,
                    clientName: "macvr-viewer",
                    requestedStreamMode: requestedMode
                )
                await MainActor.run {
                    self.discoveredRuntimes = runtimes
                    self.isDiscovering = false
                    self.appendLog("Discovery finished: found \(runtimes.count) runtime(s)")
                    self.errorMessage = runtimes.isEmpty ? "No macVR runtimes replied to the discovery probe." : nil
                }
            } catch {
                await MainActor.run {
                    self.isDiscovering = false
                    self.errorMessage = error.localizedDescription
                    self.appendLog("Discovery failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func applyDiscoveredRuntime(_ runtime: DiscoveredRuntime) {
        host = runtime.host
        controlPort = String(runtime.controlPort)
        if runtime.supportedStreamModes.contains(requestedStreamMode) == false, let fallbackMode = runtime.supportedStreamModes.first {
            requestedStreamMode = fallbackMode
        }
        errorMessage = nil
        appendLog("Selected discovered runtime \(runtime.serverName) at \(runtime.host):\(runtime.controlPort)")
    }

    func clearLogs() {
        logs.removeAll(keepingCapacity: false)
    }

    func saveLatestFrame() {
        guard let lastJPEGData else {
            errorMessage = "No JPEG frame has been received yet."
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "macvr-viewer-frame-\(formatter.string(from: Date())).jpg"

        let destinationDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let destination = destinationDirectory.appendingPathComponent(filename)

        do {
            try lastJPEGData.write(to: destination, options: .atomic)
            errorMessage = nil
            appendLog("Saved latest frame to \(destination.path)")
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            errorMessage = error.localizedDescription
            appendLog("Failed to save latest frame: \(error.localizedDescription)")
        }
    }

    func openSupportLink() {
        guard let url = URL(string: "https://buymeacoffee.com/einnovoeg") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func updatePreviewMode(_ mode: ViewerPreviewMode) {
        previewMode = mode
        rebuildPreviewImages()
    }

    private func makeTransportConfiguration() throws -> ViewerTransportConfiguration {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw NSError(
                domain: "macVR.Viewer",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Host cannot be empty"]
            )
        }
        guard let controlPort = UInt16(controlPort), controlPort > 0 else {
            throw NSError(
                domain: "macVR.Viewer",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Control port must be a valid port number"]
            )
        }
        guard let udpPort = UInt16(udpPort), udpPort > 0 else {
            throw NSError(
                domain: "macVR.Viewer",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "UDP port must be a valid port number"]
            )
        }
        guard let requestedFPS = Int(requestedFPS), (1...240).contains(requestedFPS) else {
            throw NSError(
                domain: "macVR.Viewer",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Requested FPS must be within 1-240"]
            )
        }

        return ViewerTransportConfiguration(
            host: trimmedHost,
            controlPort: controlPort,
            udpPort: udpPort,
            requestedFPS: requestedFPS,
            requestedStreamMode: requestedStreamMode,
            verbose: launchOptions.verbose
        )
    }

    private func apply(status: ViewerTransportStatus) {
        connectionState = status.connectionState
        streamState = status.streamState
        sessionID = status.sessionID
        negotiatedMode = status.negotiatedMode
        negotiatedCodec = status.negotiatedCodec
        isConnected = status.connectionState != "Idle" && status.connectionState != "Disconnected"
    }

    /// Decode and publish the newest frame on the main actor. The transport layer only
    /// handles sockets and packet reassembly; image decoding and preview composition stay
    /// in the UI model so the GUI can react immediately when the user switches modes.
    private func consume(frame snapshot: ViewerFrameSnapshot) {
        frameCount &+= 1
        frameBytes = snapshot.payload.count
        statsFrameCount &+= 1
        statsByteCount &+= UInt64(snapshot.payload.count)
        lastFrameLatencyMs = Double(DispatchTime.now().uptimeNanoseconds &- snapshot.sentTimeNs) / 1_000_000.0
        lastFrameClock = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        updateRollingStats(nowNs: DispatchTime.now().uptimeNanoseconds)

        switch snapshot.codec {
        case .jpeg:
            lastJPEGData = snapshot.payload
            guard let cgImage = Self.decodeJPEG(snapshot.payload) else {
                errorMessage = "Received an invalid JPEG frame."
                return
            }
            lastDecodedImage = cgImage
            resolution = "\(cgImage.width)x\(cgImage.height)"
            rebuildPreviewImages()
            if frameCount % 30 == 0 {
                appendLog("Received JPEG frame \(snapshot.frameIndex) at \(resolution)")
            }
            errorMessage = nil
        case .mockJSON:
            resolution = "Mock frame"
            do {
                let mock = try WireCodec.decode(MockFramePacket.self, from: snapshot.payload)
                appendLog("Received mock frame \(mock.frameIndex) tagged '\(mock.frameTag)'")
                errorMessage = nil
            } catch {
                errorMessage = "Received an undecodable mock frame payload."
            }
        }
    }

    private func updateRollingStats(nowNs: UInt64) {
        let deltaNs = nowNs &- statsWindowStartNs
        guard deltaNs >= 1_000_000_000 else {
            return
        }

        let seconds = Double(deltaNs) / 1_000_000_000.0
        rxFPS = Double(statsFrameCount) / seconds
        rxMbps = (Double(statsByteCount) * 8.0) / seconds / 1_000_000.0
        statsFrameCount = 0
        statsByteCount = 0
        statsWindowStartNs = nowNs
    }

    private func rebuildPreviewImages() {
        guard let image = lastDecodedImage else {
            leftImage = nil
            rightImage = nil
            return
        }

        let leftFrame: CGImage
        let rightFrame: CGImage

        switch previewMode {
        case .duplicate:
            leftFrame = image
            rightFrame = image
        case .splitStereo:
            let halfWidth = max(image.width / 2, 1)
            guard
                let leftCrop = image.cropping(to: CGRect(x: 0, y: 0, width: halfWidth, height: image.height)),
                let rightCrop = image.cropping(to: CGRect(x: halfWidth, y: 0, width: max(image.width - halfWidth, 1), height: image.height))
            else {
                errorMessage = "Failed to crop the latest frame into stereo halves."
                return
            }
            leftFrame = leftCrop
            rightFrame = rightCrop
        }

        leftImage = NSImage(cgImage: leftFrame, size: NSSize(width: leftFrame.width, height: leftFrame.height))
        rightImage = NSImage(cgImage: rightFrame, size: NSSize(width: rightFrame.width, height: rightFrame.height))
    }

    private func appendLog(_ line: String) {
        logs.append(line)
        if logs.count > 250 {
            logs.removeFirst(logs.count - 250)
        }
    }

    private func scheduleAutoQuitIfNeeded() {
        guard let quitAfterSeconds = launchOptions.quitAfterSeconds else {
            return
        }

        autoQuitTask?.cancel()
        autoQuitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(quitAfterSeconds * 1_000_000_000.0))
            await MainActor.run {
                self?.appendLog("Auto-quit timer elapsed after \(String(format: "%.1f", quitAfterSeconds)) seconds")
                NSApp.terminate(nil)
            }
        }
    }

    private static func decodeJPEG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let helpText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10))
        )
        .shadow(color: Color.black.opacity(0.15), radius: 18, y: 8)
        .help(helpText)
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12))
        )
    }
}

private struct ViewerTextField: View {
    let title: String
    @Binding var value: String
    let helpText: String
    let disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: $value)
                .textFieldStyle(.roundedBorder)
                .disabled(disabled)
                .help(helpText)
        }
    }
}

private struct PreviewSurface: View {
    let title: String
    let image: NSImage?
    let helpText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.92))
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.black.opacity(0.72))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(12)
                } else {
                    Text("No frame yet")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .frame(minHeight: 280)
        }
        .help(helpText)
    }
}

private struct ViewerContentView: View {
    @EnvironmentObject private var model: ViewerModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.11, blue: 0.18), Color(red: 0.20, green: 0.11, blue: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let errorMessage = model.errorMessage {
                        Text(errorMessage)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.red.opacity(0.78))
                            )
                    }
                    metrics
                    connectionSection
                    previewSection
                    logsSection
                }
                .padding(24)
            }
        }
        .frame(minWidth: 1180, minHeight: 880)
        .onAppear {
            model.startIfRequested()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("macVR Viewer")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Live GUI receiver for the macVR transport stack. It negotiates the control session, receives UDP frames, and renders a stereo preview so you can validate a sender path without leaving macOS.")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.86))
                    Text("Release \(macVRReleaseVersion) | Protocol \(macVRProtocolVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                }
                Spacer()
                Text(model.isConnected ? "Receiver Online" : "Receiver Offline")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Capsule(style: .continuous)
                            .fill(model.isConnected ? Color.green.opacity(0.75) : Color.gray.opacity(0.45))
                    )
                    .help("Shows whether the viewer transport is currently connected or attempting to reconnect to the configured host.")
            }

            HStack(spacing: 12) {
                Button(action: model.connect) {
                    Label("Connect", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(model.isConnected)
                .help("Open the UDP listener, connect the TCP control channel, and start receiving frames from the selected macVR host.")

                Button(action: model.disconnect) {
                    Label("Disconnect", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!model.isConnected)
                .help("Close the control and UDP sockets and stop the receiver without clearing the last preview frame.")

                Button(action: model.saveLatestFrame) {
                    Label("Save Latest JPEG", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .help("Save the newest received JPEG frame to your Downloads folder and reveal it in Finder.")

                Button(action: model.clearLogs) {
                    Label("Clear Logs", systemImage: "text.badge.xmark")
                }
                .buttonStyle(.bordered)
                .help("Clear the in-window log history without disconnecting the receiver.")

                Link(destination: URL(string: "https://buymeacoffee.com/einnovoeg")!) {
                    Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
                }
                .buttonStyle(.bordered)
                .help("Open the project support link in the default browser.")
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
    }

    private var metrics: some View {
        HStack(spacing: 16) {
            MetricCard(
                title: "Connection",
                value: model.connectionState,
                detail: "Session \(model.sessionID)",
                helpText: "Current control-channel state and the negotiated session identifier returned by the host."
            )
            MetricCard(
                title: "Receive Rate",
                value: String(format: "%.1f fps", model.rxFPS),
                detail: String(format: "%.2f Mbps", model.rxMbps),
                helpText: "Rolling one-second receive throughput measured from successfully reassembled frame payloads."
            )
            MetricCard(
                title: "Latency",
                value: String(format: "%.1f ms", model.lastFrameLatencyMs),
                detail: model.lastFrameClock,
                helpText: "Approximate age of the newest received frame using the sender timestamp carried in the transport packet."
            )
            MetricCard(
                title: "Frame Source",
                value: model.resolution,
                detail: "\(model.negotiatedMode) | \(model.negotiatedCodec)",
                helpText: "Resolution of the newest frame plus the negotiated stream mode and payload codec returned by the host."
            )
        }
    }

    private var connectionSection: some View {
        SectionCard(
            title: "Receiver Settings",
            subtitle: "These settings define how the GUI receiver joins a macVR session. They stay editable while disconnected and are locked once the sockets are open."
        ) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    ViewerTextField(
                        title: "Host",
                        value: $model.host,
                        helpText: "Hostname or IP address for the macVR host or bundled runtime control channel.",
                        disabled: model.isConnected
                    )
                    ViewerTextField(
                        title: "Control Port",
                        value: $model.controlPort,
                        helpText: "TCP port used for session negotiation, pings, and stream status updates.",
                        disabled: model.isConnected
                    )
                    ViewerTextField(
                        title: "UDP Port",
                        value: $model.udpPort,
                        helpText: "Local UDP port on which the viewer listens for packetized video frames.",
                        disabled: model.isConnected
                    )
                    ViewerTextField(
                        title: "Discovery Port",
                        value: $model.discoveryPort,
                        helpText: "UDP port used when the viewer broadcasts a discovery probe to find macVR runtimes on the local network.",
                        disabled: model.isConnected || model.isDiscovering
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    ViewerTextField(
                        title: "Requested FPS",
                        value: $model.requestedFPS,
                        helpText: "Pose update cadence requested during session negotiation. This also influences how often the viewer sends synthetic pose samples.",
                        disabled: model.isConnected
                    )

                    Picker(
                        "Requested Stream Mode",
                        selection: $model.requestedStreamMode
                    ) {
                        Text(StreamMode.bridgeJPEG.rawValue).tag(StreamMode.bridgeJPEG)
                        Text(StreamMode.displayJPEG.rawValue).tag(StreamMode.displayJPEG)
                        Text(StreamMode.mock.rawValue).tag(StreamMode.mock)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isConnected)
                    .help("Choose which host-side source path the viewer asks for when it says hello to the runtime.")

                    Picker(
                        "Preview Mode",
                        selection: Binding(
                            get: { model.previewMode },
                            set: { model.updatePreviewMode($0) }
                        )
                    ) {
                        ForEach(ViewerPreviewMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help(model.previewMode.helpText)

                    Text(model.streamState)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .help("Latest stream-status message reported by the host over the control channel.")

                    HStack(spacing: 12) {
                        Button(action: model.discoverRuntimes) {
                            Label(model.isDiscovering ? "Discovering..." : "Discover Runtimes", systemImage: "dot.radiowaves.left.and.right")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isConnected || model.isDiscovering)
                        .help("Broadcast a UDP discovery probe and collect matching macVR runtimes before opening the TCP control connection.")

                        if model.isDiscovering {
                            ProgressView()
                                .help("The viewer is waiting for discovery replies.")
                        }
                    }
                }
            }

            if model.discoveredRuntimes.isEmpty == false {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Discovered Runtimes")
                        .font(.headline)
                    ForEach(model.discoveredRuntimes) { runtime in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(runtime.serverName)
                                    .font(.subheadline.weight(.semibold))
                                Text("\(runtime.host):\(runtime.controlPort) | build \(runtime.buildVersion)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(runtime.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Use") {
                                model.applyDiscoveredRuntime(runtime)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .help("Apply this discovered runtime to the host and control-port fields.")
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.black.opacity(0.06))
                        )
                        .help("Runtime discovered over UDP with the ports and stream modes it advertised.")
                    }
                }
            }
        }
    }

    private var previewSection: some View {
        SectionCard(
            title: "Stereo Preview",
            subtitle: "Incoming frames are decoded locally and displayed here. Use duplicate mode for mono validation or split mode when the source already packs both eyes into one frame."
        ) {
            HStack(spacing: 16) {
                PreviewSurface(
                    title: "Left Eye",
                    image: model.leftImage,
                    helpText: "Preview of the left eye surface generated from the newest decoded frame."
                )
                PreviewSurface(
                    title: "Right Eye",
                    image: model.rightImage,
                    helpText: "Preview of the right eye surface generated from the newest decoded frame."
                )
            }
        }
    }

    private var logsSection: some View {
        SectionCard(
            title: "Logs",
            subtitle: "Transport and session events are mirrored here so you can verify reconnects, negotiation, and frame flow without watching a terminal."
        ) {
            ScrollView {
                Text(model.logsText.isEmpty ? "No log messages yet." : model.logsText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(14)
            }
            .frame(minHeight: 220, maxHeight: 280)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.08))
            )
            .help("Log history emitted by the viewer transport, including reconnect attempts and negotiated session details.")
        }
    }
}

@main
struct MacVRViewerApp: App {
    @StateObject private var model: ViewerModel

    init() {
        do {
            let options = try ViewerLaunchOptions.parse(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.headless {
                try HeadlessViewerRunner.run(options: options)
                exit(EXIT_SUCCESS)
            }
            _model = StateObject(wrappedValue: ViewerModel(launchOptions: options))
        } catch let error as ViewerArgumentError {
            switch error {
            case .helpRequested, .versionRequested:
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

    var body: some Scene {
        WindowGroup("macVR Viewer") {
            ViewerContentView()
                .environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About macVR Viewer") {
                    NSApp.orderFrontStandardAboutPanel(
                        options: [
                            .applicationName: "macVR Viewer",
                            .applicationVersion: macVRReleaseVersion,
                            .version: macVRReleaseVersion,
                        ]
                    )
                }
            }
        }
    }
}
