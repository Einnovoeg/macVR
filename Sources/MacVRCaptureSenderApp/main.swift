import Foundation
import MacVRHostCore
import MacVRProtocol
import Network

private enum CLIError: Error {
    case helpRequested
    case versionRequested
    case missingValue(String)
    case invalidValue(String)
    case unknownArgument(String)

    var description: String {
        switch self {
        case .helpRequested:
            return CLIOptions.usage
        case .versionRequested:
            return "macvr-capture-sender \(macVRReleaseVersion)"
        case .missingValue(let flag):
            return "Missing value for \(flag)\n\n\(CLIOptions.usage)"
        case .invalidValue(let message):
            return "\(message)\n\n\(CLIOptions.usage)"
        case .unknownArgument(let arg):
            return "Unknown argument: \(arg)\n\n\(CLIOptions.usage)"
        }
    }
}

private struct CLIOptions {
    var host = "127.0.0.1"
    var port: UInt16 = 44000
    var displayID: UInt32?
    var fps = 15
    var count: UInt64 = 0
    var reconnectDelayMs = 1000
    var jpegQuality = 60
    var captureScale = 0.5
    var maxJPEGBytes = 2_000_000
    var listDisplays = false
    var verbose = false

    static let usage = """
    Usage: macvr-capture-sender [options]
      --host <hostname>             Destination host (default: 127.0.0.1)
      --port <port>                 Destination TCP port (default: 44000)
      --display-id <id>             Optional display ID to capture (default: main display)
      --fps <value>                 Capture/send rate, 1-240 (default: 15)
      --count <n>                   Frames to send, 0=infinite (default: 0)
      --reconnect-delay-ms <ms>     Delay before reconnect, 10-30000 (default: 1000)
      --jpeg-quality <1-100>        JPEG quality for captured frames (default: 60)
      --scale <0.05-1.0>            Display capture scale factor (default: 0.5)
      --max-jpeg-bytes <n>          Max accepted JPEG size, 16384-16000000 (default: 2000000)
      --list-displays               Print available display IDs and exit
      --version                     Show build/release version
      --verbose                     Enable debug logging
      -h, --help                    Show this help
    """

    static func parse(arguments: [String]) throws -> CLIOptions {
        var options = CLIOptions()
        var index = 0

        func requireValue(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else {
                throw CLIError.missingValue(flag)
            }
            return arguments[index]
        }

        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--host":
                let value = try requireValue(arg).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw CLIError.invalidValue("host cannot be empty")
                }
                options.host = value
            case "--port":
                let value = try requireValue(arg)
                guard let parsed = UInt16(value), parsed > 0 else {
                    throw CLIError.invalidValue("Invalid port: \(value)")
                }
                options.port = parsed
            case "--display-id":
                let value = try requireValue(arg)
                guard let parsed = UInt32(value) else {
                    throw CLIError.invalidValue("Invalid display id: \(value)")
                }
                options.displayID = parsed
            case "--fps":
                let value = try requireValue(arg)
                guard let parsed = Int(value), (1...240).contains(parsed) else {
                    throw CLIError.invalidValue("Invalid fps value: \(value)")
                }
                options.fps = parsed
            case "--count":
                let value = try requireValue(arg)
                guard let parsed = UInt64(value) else {
                    throw CLIError.invalidValue("Invalid count value: \(value)")
                }
                options.count = parsed
            case "--reconnect-delay-ms":
                let value = try requireValue(arg)
                guard let parsed = Int(value), (10...30_000).contains(parsed) else {
                    throw CLIError.invalidValue("Invalid reconnect delay ms: \(value)")
                }
                options.reconnectDelayMs = parsed
            case "--jpeg-quality":
                let value = try requireValue(arg)
                guard let parsed = Int(value), (1...100).contains(parsed) else {
                    throw CLIError.invalidValue("Invalid jpeg quality: \(value)")
                }
                options.jpegQuality = parsed
            case "--scale":
                let value = try requireValue(arg)
                guard let parsed = Double(value), (0.05...1.0).contains(parsed) else {
                    throw CLIError.invalidValue("Invalid scale value: \(value)")
                }
                options.captureScale = parsed
            case "--max-jpeg-bytes":
                let value = try requireValue(arg)
                guard let parsed = Int(value), (16_384...16_000_000).contains(parsed) else {
                    throw CLIError.invalidValue("Invalid max-jpeg-bytes value: \(value)")
                }
                options.maxJPEGBytes = parsed
            case "--list-displays":
                options.listDisplays = true
            case "--version":
                throw CLIError.versionRequested
            case "--verbose":
                options.verbose = true
            case "-h", "--help":
                throw CLIError.helpRequested
            default:
                throw CLIError.unknownArgument(arg)
            }
            index += 1
        }

        return options
    }
}

private final class CaptureSenderLogger: @unchecked Sendable {
    private let verbose: Bool
    private let formatter: ISO8601DateFormatter

    init(verbose: Bool) {
        self.verbose = verbose
        self.formatter = ISO8601DateFormatter()
        self.formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func info(_ message: String) {
        log(level: "INFO", message: message)
    }

    func warning(_ message: String) {
        log(level: "WARN", message: message)
    }

    func debug(_ message: String) {
        guard verbose else {
            return
        }
        log(level: "DEBUG", message: message)
    }

    private func log(level: String, message: String) {
        print("[\(formatter.string(from: Date()))] [\(level)] \(message)")
        fflush(stdout)
    }
}

private enum ConnectionError: Error {
    case connectTimeout
    case sendTimeout
    case failed(Error)
}

private final class LockedResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func load() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class TCPFrameSender {
    private let queue = DispatchQueue(label: "macvr.capture.sender.connection")
    private var connection: NWConnection?
    private(set) var isConnected = false

    func connect(host: String, port: UInt16, timeout: TimeInterval = 5) throws {
        close()
        let endpointHost = NWEndpoint.Host(host)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw CLIError.invalidValue("Invalid port: \(port)")
        }
        let connection = NWConnection(host: endpointHost, port: endpointPort, using: .tcp)
        let semaphore = DispatchSemaphore(value: 0)
        let connectResult = LockedResultBox<Void>()

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connectResult.store(.success(()))
                semaphore.signal()
            case .failed(let error):
                connectResult.store(.failure(ConnectionError.failed(error)))
                semaphore.signal()
            default:
                break
            }
        }

        connection.start(queue: queue)
        let deadline = DispatchTime.now() + timeout
        guard semaphore.wait(timeout: deadline) == .success else {
            connection.cancel()
            throw ConnectionError.connectTimeout
        }

        switch connectResult.load() {
        case .success:
            self.connection = connection
            self.isConnected = true
        case .failure(let error):
            connection.cancel()
            throw error
        case .none:
            connection.cancel()
            throw ConnectionError.connectTimeout
        }
    }

    func sendFrame(_ jpegData: Data, timeout: TimeInterval = 5) throws {
        guard let connection else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var payload = Data(capacity: 4 + jpegData.count)
        var networkLength = UInt32(jpegData.count).bigEndian
        withUnsafeBytes(of: &networkLength) { payload.append(contentsOf: $0) }
        payload.append(jpegData)
        try sendData(payload, over: connection, timeout: timeout)
    }

    func close() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        isConnected = false
    }

    private func sendData(_ data: Data, over connection: NWConnection, timeout: TimeInterval) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedResultBox<Void>()
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                result.store(.failure(ConnectionError.failed(error)))
            } else {
                result.store(.success(()))
            }
            semaphore.signal()
        })

        let deadline = DispatchTime.now() + timeout
        guard semaphore.wait(timeout: deadline) == .success else {
            throw ConnectionError.sendTimeout
        }

        if case .failure(let error) = result.load() {
            throw error
        }
    }
}

@main
struct MacVRCaptureSenderApp {
    static func main() {
        do {
            let cli = try CLIOptions.parse(arguments: Array(CommandLine.arguments.dropFirst()))

            if cli.listDisplays {
                let displays = DisplayDiscovery.activeDisplays()
                if displays.isEmpty {
                    print("No active displays discovered.")
                } else {
                    print("Active displays:")
                    for display in displays {
                        let mainFlag = display.isMain ? " [main]" : ""
                        let refresh = display.refreshRateHz > 0 ? String(format: "%.2f", display.refreshRateHz) : "unknown"
                        print("  id=\(display.id) size=\(display.width)x\(display.height) refresh=\(refresh)Hz\(mainFlag)")
                    }
                }
                exit(EXIT_SUCCESS)
            }

            let logger = CaptureSenderLogger(verbose: cli.verbose)
            let sender = TCPFrameSender()
            var framesSent: UInt64 = 0
            let logInterval = UInt64(max(cli.fps * 2, 1))

            logger.info(
                "Starting live capture sender -> \(cli.host):\(cli.port), fps=\(cli.fps), scale=\(String(format: "%.2f", cli.captureScale)), jpeg-quality=\(cli.jpegQuality), count=\(cli.count)"
            )

            while cli.count == 0 || framesSent < cli.count {
                do {
                    if !sender.isConnected {
                        try sender.connect(host: cli.host, port: cli.port)
                        logger.info("Connected to \(cli.host):\(cli.port)")
                    }

                    let capture = try DisplayCapture.captureJPEG(
                        displayID: cli.displayID,
                        jpegQuality: cli.jpegQuality,
                        scale: cli.captureScale
                    )
                    if capture.jpegData.count > cli.maxJPEGBytes {
                        logger.warning(
                            "Dropped captured frame size=\(capture.jpegData.count)B (max=\(cli.maxJPEGBytes)B). Lower --scale or --jpeg-quality."
                        )
                        Thread.sleep(forTimeInterval: Double(cli.reconnectDelayMs) / 1000.0)
                        continue
                    }

                    try sender.sendFrame(capture.jpegData)
                    framesSent &+= 1

                    if cli.verbose || framesSent % logInterval == 0 {
                        logger.info(
                            "Sent frame=\(framesSent) display=\(capture.displayID) size=\(capture.jpegData.count)B resolution=\(capture.width)x\(capture.height)"
                        )
                    } else {
                        logger.debug(
                            "Sent frame=\(framesSent) size=\(capture.jpegData.count)B"
                        )
                    }
                } catch {
                    logger.warning("Capture/send failed: \(error.localizedDescription)")
                    sender.close()
                    Thread.sleep(forTimeInterval: Double(cli.reconnectDelayMs) / 1000.0)
                    continue
                }

                if cli.count == 0 || framesSent < cli.count {
                    Thread.sleep(forTimeInterval: 1.0 / Double(max(cli.fps, 1)))
                }
            }

            sender.close()
            logger.info("Stopped sender after \(framesSent) frames")
        } catch let error as CLIError {
            let output = error.description
            switch error {
            case .helpRequested, .versionRequested:
                print(output)
                exit(EXIT_SUCCESS)
            default:
                fputs(output + "\n", stderr)
                exit(EXIT_FAILURE)
            }
        } catch {
            fputs("macvr-capture-sender failed: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
