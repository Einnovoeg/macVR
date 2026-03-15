import Foundation
import ImageIO
import MacVRHostCore
import Network
import UniformTypeIdentifiers

public enum RuntimeServiceError: Error {
    case invalidPort(UInt16)
    case invalidJPEGInput(String)
}

extension RuntimeServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Invalid runtime port: \(port)"
        case .invalidJPEGInput(let message):
            return message
        }
    }
}

public struct RuntimeStatusSnapshot: Sendable {
    public let isRunning: Bool
    public let startedAt: Date?
    public let uptimeSeconds: TimeInterval
    public let controlPort: UInt16
    public let bridgePort: UInt16
    public let jpegInputPort: UInt16
    public let inputConnectionCount: Int
    public let inputFramesAccepted: UInt64
    public let inputFramesDropped: UInt64
    public let inputBytesAccepted: UInt64
    public let lastInputResolution: String?
    public let bridgeStats: BridgeFrameStats

    public init(
        isRunning: Bool,
        startedAt: Date?,
        uptimeSeconds: TimeInterval,
        controlPort: UInt16,
        bridgePort: UInt16,
        jpegInputPort: UInt16,
        inputConnectionCount: Int,
        inputFramesAccepted: UInt64,
        inputFramesDropped: UInt64,
        inputBytesAccepted: UInt64,
        lastInputResolution: String?,
        bridgeStats: BridgeFrameStats
    ) {
        self.isRunning = isRunning
        self.startedAt = startedAt
        self.uptimeSeconds = uptimeSeconds
        self.controlPort = controlPort
        self.bridgePort = bridgePort
        self.jpegInputPort = jpegInputPort
        self.inputConnectionCount = inputConnectionCount
        self.inputFramesAccepted = inputFramesAccepted
        self.inputFramesDropped = inputFramesDropped
        self.inputBytesAccepted = inputBytesAccepted
        self.lastInputResolution = lastInputResolution
        self.bridgeStats = bridgeStats
    }

    public static func stopped(configuration: RuntimeConfiguration = RuntimeConfiguration()) -> Self {
        Self(
            isRunning: false,
            startedAt: nil,
            uptimeSeconds: 0,
            controlPort: configuration.controlPort,
            bridgePort: configuration.bridgePort,
            jpegInputPort: configuration.jpegInputPort,
            inputConnectionCount: 0,
            inputFramesAccepted: 0,
            inputFramesDropped: 0,
            inputBytesAccepted: 0,
            lastInputResolution: nil,
            bridgeStats: BridgeFrameStats(totalFrames: 0, totalBytes: 0, lastFrameIndex: nil, lastSource: nil)
        )
    }
}

/// Bundles the host bridge transport and a local TCP JPEG ingest seam into a
/// single long-running process. This gives the project a native macOS runtime
/// service instead of requiring users to chain `macvr-host` and `macvr-bridge-sim`
/// manually for every session.
public final class RuntimeService: @unchecked Sendable {
    private let configuration: RuntimeConfiguration
    private let bridgeFrameStore = BridgeFrameStore()
    private let logger: HostLogger
    private let queue = DispatchQueue(label: "macvr.runtime.service")
    private let stateLock = NSLock()

    private var hostService: HostService?
    private var bridgeIngestService: BridgeIngestService?
    private var inputListener: NWListener?
    private var inputConnections: [ObjectIdentifier: NWConnection] = [:]
    private var inputBuffers: [ObjectIdentifier: Data] = [:]
    private var isRunning = false
    private var startedAt: Date?
    private var inputFramesAccepted: UInt64 = 0
    private var inputFramesDropped: UInt64 = 0
    private var inputBytesAccepted: UInt64 = 0
    private var nextInputFrameIndex: UInt64 = 0
    private var lastInputWidth: Int?
    private var lastInputHeight: Int?

    public init(configuration: RuntimeConfiguration, logSink: HostLogSink? = nil) {
        self.configuration = configuration
        self.logger = HostLogger(verbose: configuration.verbose, sink: logSink)
    }

    public func start() throws {
        guard configuration.controlPort > 0 else {
            throw RuntimeServiceError.invalidPort(configuration.controlPort)
        }
        guard configuration.bridgePort > 0 else {
            throw RuntimeServiceError.invalidPort(configuration.bridgePort)
        }
        guard configuration.jpegInputPort > 0 else {
            throw RuntimeServiceError.invalidPort(configuration.jpegInputPort)
        }

        if snapshotRunningState() {
            return
        }

        let host = try HostService(
            configuration: configuration.hostConfiguration,
            logger: logger,
            bridgeFrameStore: bridgeFrameStore
        )
        let bridgeIngest = try BridgeIngestService(
            port: configuration.bridgePort,
            maxPacketSize: configuration.maxPacketSize,
            frameStore: bridgeFrameStore,
            logger: logger
        )

        do {
            try bridgeIngest.start()
            try startJPEGInputListener()
            try host.start()
        } catch {
            stopNetworkComponents()
            throw error
        }

        stateLock.lock()
        hostService = host
        bridgeIngestService = bridgeIngest
        inputFramesAccepted = 0
        inputFramesDropped = 0
        inputBytesAccepted = 0
        nextInputFrameIndex = 0
        lastInputWidth = nil
        lastInputHeight = nil
        isRunning = true
        startedAt = Date()
        stateLock.unlock()

        logger.log(
            .info,
            "Bundled runtime ready: control=\(configuration.controlPort), bridge=\(configuration.bridgePort), jpeg-input=\(configuration.jpegInputPort)"
        )
    }

    public func stop() {
        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            self.stopNetworkComponents()
            self.stateLock.lock()
            self.hostService = nil
            self.bridgeIngestService = nil
            self.isRunning = false
            self.startedAt = nil
            self.stateLock.unlock()
            semaphore.signal()
        }
        semaphore.wait()
    }

    public func statusSnapshot() -> RuntimeStatusSnapshot {
        stateLock.lock()
        let isRunning = self.isRunning
        let startedAt = self.startedAt
        let inputConnectionCount = self.inputConnections.count
        let inputFramesAccepted = self.inputFramesAccepted
        let inputFramesDropped = self.inputFramesDropped
        let inputBytesAccepted = self.inputBytesAccepted
        let lastInputWidth = self.lastInputWidth
        let lastInputHeight = self.lastInputHeight
        stateLock.unlock()

        let bridgeStats = bridgeFrameStore.stats()
        let uptimeSeconds: TimeInterval
        if let startedAt {
            uptimeSeconds = max(Date().timeIntervalSince(startedAt), 0)
        } else {
            uptimeSeconds = 0
        }

        let resolutionSummary: String?
        if let lastInputWidth, let lastInputHeight {
            resolutionSummary = "\(lastInputWidth)x\(lastInputHeight)"
        } else {
            resolutionSummary = nil
        }

        return RuntimeStatusSnapshot(
            isRunning: isRunning,
            startedAt: startedAt,
            uptimeSeconds: uptimeSeconds,
            controlPort: configuration.controlPort,
            bridgePort: configuration.bridgePort,
            jpegInputPort: configuration.jpegInputPort,
            inputConnectionCount: inputConnectionCount,
            inputFramesAccepted: inputFramesAccepted,
            inputFramesDropped: inputFramesDropped,
            inputBytesAccepted: inputBytesAccepted,
            lastInputResolution: resolutionSummary,
            bridgeStats: bridgeStats
        )
    }

    private func snapshotRunningState() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning
    }

    private func startJPEGInputListener() throws {
        guard inputListener == nil else {
            return
        }
        guard let port = NWEndpoint.Port(rawValue: configuration.jpegInputPort) else {
            throw RuntimeServiceError.invalidPort(configuration.jpegInputPort)
        }

        let listener = try NWListener(using: .tcp, on: port)
        listener.stateUpdateHandler = { [weak self] state in
            self?.handleInputListenerState(state, port: self?.configuration.jpegInputPort ?? 0)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.acceptInput(connection)
        }
        listener.start(queue: queue)
        inputListener = listener
        logger.log(.info, "Runtime JPEG input listening on tcp://127.0.0.1:\(configuration.jpegInputPort)")
    }

    private func stopNetworkComponents() {
        inputListener?.cancel()
        inputListener = nil

        for (_, connection) in inputConnections {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        inputConnections.removeAll()
        inputBuffers.removeAll()

        hostService?.stop()
        bridgeIngestService?.stop()
    }

    private func handleInputListenerState(_ state: NWListener.State, port: UInt16) {
        switch state {
        case .ready:
            logger.log(.info, "Runtime JPEG input listener ready on 127.0.0.1:\(port)")
        case .failed(let error):
            logger.log(.error, "Runtime JPEG input listener failed: \(error)")
        case .cancelled:
            logger.log(.debug, "Runtime JPEG input listener cancelled")
        default:
            break
        }
    }

    private func acceptInput(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        stateLock.lock()
        inputConnections[key] = connection
        inputBuffers[key] = Data()
        stateLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleInputConnectionState(state, key: key, endpoint: connection.endpoint)
        }
        connection.start(queue: queue)
        receiveInput(on: connection, key: key)
    }

    private func handleInputConnectionState(_ state: NWConnection.State, key: ObjectIdentifier, endpoint: NWEndpoint) {
        switch state {
        case .ready:
            logger.log(.info, "Runtime JPEG input connection ready: \(endpoint)")
        case .failed(let error):
            logger.log(.warning, "Runtime JPEG input connection failed (\(endpoint)): \(error)")
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
                self.logger.log(.warning, "Runtime JPEG input receive error: \(error)")
                self.cleanupInputConnection(key: key)
                return
            }

            if isComplete {
                self.logger.log(.info, "Runtime JPEG input connection closed by peer")
                self.cleanupInputConnection(key: key)
                return
            }

            self.receiveInput(on: connection, key: key)
        }
    }

    private func consumeInputData(_ data: Data, key: ObjectIdentifier) {
        stateLock.lock()
        var buffer = inputBuffers[key] ?? Data()
        stateLock.unlock()
        buffer.append(data)

        while true {
            guard buffer.count >= 4 else {
                break
            }

            // The ingest seam intentionally uses a tiny protocol so Wine/GPTK-side
            // helpers can implement it in a few lines: a big-endian byte count
            // followed by exactly that many JPEG bytes.
            let frameLength =
                (Int(buffer[0]) << 24)
                | (Int(buffer[1]) << 16)
                | (Int(buffer[2]) << 8)
                | Int(buffer[3])

            if frameLength <= 0 || frameLength > configuration.jpegMaxBytes {
                logger.log(
                    .warning,
                    "Dropped runtime JPEG frame length=\(frameLength) (max=\(configuration.jpegMaxBytes))"
                )
                recordInputDrop()
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

            do {
                let metadata = try validateJPEG(jpegData)
                submitInputJPEG(jpegData, width: metadata.width, height: metadata.height)
            } catch {
                logger.log(.warning, "Dropped invalid runtime JPEG input: \(error.localizedDescription)")
                recordInputDrop()
            }
        }

        stateLock.lock()
        inputBuffers[key] = buffer
        stateLock.unlock()
    }

    private func validateJPEG(_ data: Data) throws -> (width: Int?, height: Int?) {
        guard !data.isEmpty else {
            throw RuntimeServiceError.invalidJPEGInput("JPEG payload is empty")
        }
        // ImageIO validation catches malformed data early and also gives us the
        // width and height used by bridge stats and control-center status cards.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw RuntimeServiceError.invalidJPEGInput("ImageIO could not parse the JPEG payload")
        }
        if let type = CGImageSourceGetType(source) as String?, type != UTType.jpeg.identifier {
            throw RuntimeServiceError.invalidJPEGInput("Expected JPEG input, received \(type)")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        return (width, height)
    }

    private func submitInputJPEG(_ data: Data, width: Int?, height: Int?) {
        let nowNs = DispatchTime.now().uptimeNanoseconds

        stateLock.lock()
        nextInputFrameIndex &+= 1
        let frameIndex = nextInputFrameIndex
        inputFramesAccepted &+= 1
        inputBytesAccepted &+= UInt64(data.count)
        lastInputWidth = width
        lastInputHeight = height
        let acceptedCount = inputFramesAccepted
        stateLock.unlock()

        bridgeFrameStore.update(
            frameIndex: frameIndex,
            sentTimeNs: nowNs,
            source: "runtime-jpeg-input",
            width: width,
            height: height,
            jpegData: data
        )

        // Log only periodic acceptance milestones so steady-state producer traffic
        // remains visible without flooding the terminal or GUI log mirror.
        if acceptedCount % UInt64(max(configuration.targetFPS * 4, 1)) == 0 {
            logger.log(
                .info,
                "Accepted runtime JPEG frame count=\(acceptedCount) size=\(data.count)B"
            )
        }
    }

    private func recordInputDrop() {
        stateLock.lock()
        inputFramesDropped &+= 1
        stateLock.unlock()
    }

    private func cleanupInputConnection(key: ObjectIdentifier) {
        stateLock.lock()
        inputBuffers.removeValue(forKey: key)
        let connection = inputConnections.removeValue(forKey: key)
        stateLock.unlock()

        guard let connection else {
            return
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}
