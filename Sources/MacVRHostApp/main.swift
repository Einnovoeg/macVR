import Foundation
import MacVRHostCore
import MacVRProtocol

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
            return "macvr-host \(macVRReleaseVersion)"
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
    var controlPort: UInt16 = 42000
    var targetFPS: Int = 72
    var frameTag = "mock"
    var streamMode: StreamMode = .displayJPEG
    var bridgePort: UInt16 = 43000
    var maxPacketSize = FrameChunkPacketizer.defaultMaxPacketSize
    var bridgeMaxFrameAgeMs = 250
    var displayID: UInt32?
    var jpegQuality = 70
    var trackingStatePath: String?
    var listDisplays = false
    var verbose = false

    static let usage = """
    Usage: macvr-host [options]
      --control-port <port>   TCP port for control channel (default: 42000)
      --fps <value>           Target stream FPS, 1-240 (default: 72)
      --frame-tag <text>      Label added to each frame packet (default: mock)
      --stream-mode <mode>    Stream mode: display-jpeg | bridge-jpeg | mock (default: display-jpeg)
      --bridge-port <port>    TCP port for bridge frame ingest (default: 43000)
      --max-packet-size <n>   Max UDP packet size, 512-65507 (default: 1200)
      --bridge-max-frame-age-ms <ms>
                              Max accepted age for bridge frames before drop, 0-10000 (default: 250, 0=disable)
      --display-id <id>       Optional display ID to capture (default: main display)
      --jpeg-quality <1-100>  JPEG quality for display-jpeg mode (default: 70)
      --tracking-state-path <path>
                              Optional binary tracking-state output path for OpenXR pose handoff
      --list-displays         Print available display IDs and exit
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
            case "--control-port":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.missingValue(arg)
                }
                guard let value = UInt16(arguments[index]), value > 0 else {
                    throw CLIError.invalidValue("Invalid control port: \(arguments[index])")
                }
                options.controlPort = value
            case "--fps":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.missingValue(arg)
                }
                guard let value = Int(arguments[index]), (1...240).contains(value) else {
                    throw CLIError.invalidValue("Invalid fps value: \(arguments[index])")
                }
                options.targetFPS = value
            case "--frame-tag":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.missingValue(arg)
                }
                let value = arguments[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw CLIError.invalidValue("frame-tag cannot be empty")
                }
                options.frameTag = value
            case "--stream-mode":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.missingValue(arg)
                }
                guard let mode = StreamMode(rawValue: arguments[index]) else {
                    throw CLIError.invalidValue("Invalid stream mode: \(arguments[index])")
                }
                options.streamMode = mode
            case "--bridge-port":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.missingValue(arg)
                }
                guard let value = UInt16(arguments[index]), value > 0 else {
                    throw CLIError.invalidValue("Invalid bridge port: \(arguments[index])")
                }
                options.bridgePort = value
            case "--max-packet-size":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.missingValue(arg)
                }
                guard let value = Int(arguments[index]), (512...65_507).contains(value) else {
                    throw CLIError.invalidValue("Invalid max packet size: \(arguments[index])")
                }
                options.maxPacketSize = value
            case "--bridge-max-frame-age-ms":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.missingValue(arg)
                }
                guard let value = Int(arguments[index]), (0...10_000).contains(value) else {
                    throw CLIError.invalidValue("Invalid bridge max frame age ms: \(arguments[index])")
                }
                options.bridgeMaxFrameAgeMs = value
            case "--display-id":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.missingValue(arg)
                }
                guard let value = UInt32(arguments[index]) else {
                    throw CLIError.invalidValue("Invalid display id: \(arguments[index])")
                }
                options.displayID = value
            case "--jpeg-quality":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.missingValue(arg)
                }
                guard let value = Int(arguments[index]), (1...100).contains(value) else {
                    throw CLIError.invalidValue("Invalid jpeg quality: \(arguments[index])")
                }
                options.jpegQuality = value
            case "--tracking-state-path":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.missingValue(arg)
                }
                let value = arguments[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw CLIError.invalidValue("tracking-state-path cannot be empty")
                }
                options.trackingStatePath = value
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

@main
struct MacVRHostApp {
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
                        let refresh = display.refreshRateHz > 0
                            ? String(format: "%.2f", display.refreshRateHz)
                            : "unknown"
                        print("  id=\(display.id) size=\(display.width)x\(display.height) refresh=\(refresh)Hz\(mainFlag)")
                    }
                }
                exit(EXIT_SUCCESS)
            }

            let config = HostConfiguration(
                controlPort: cli.controlPort,
                targetFPS: cli.targetFPS,
                frameTag: cli.frameTag,
                streamMode: cli.streamMode,
                bridgePort: cli.bridgePort,
                maxPacketSize: cli.maxPacketSize,
                bridgeMaxFrameAgeMs: cli.bridgeMaxFrameAgeMs,
                displayID: cli.displayID,
                jpegQuality: cli.jpegQuality,
                trackingStatePath: cli.trackingStatePath,
                verbose: cli.verbose
            )
            let logger = HostLogger(verbose: cli.verbose)
            var bridgeFrameStore: BridgeFrameStore?
            var bridgeService: BridgeIngestService?
            if cli.streamMode == .bridgeJPEG {
                let store = BridgeFrameStore()
                let ingestService = try BridgeIngestService(
                    port: cli.bridgePort,
                    maxPacketSize: cli.maxPacketSize,
                    frameStore: store,
                    logger: logger
                )
                try ingestService.start()
                bridgeFrameStore = store
                bridgeService = ingestService
            }
            let host = try HostService(
                configuration: config,
                logger: logger,
                bridgeFrameStore: bridgeFrameStore
            )

            try host.start()
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)

            // Route process signals through GCD so the host and bridge listener
            // can stop cleanly instead of being torn down mid-stream.
            let stopServices = {
                host.stop()
                bridgeService?.stop()
            }

            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigintSource.setEventHandler {
                stopServices()
                exit(EXIT_SUCCESS)
            }
            sigintSource.resume()

            let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            sigtermSource.setEventHandler {
                stopServices()
                exit(EXIT_SUCCESS)
            }
            sigtermSource.resume()

            logger.log(.info, "macVR protocol version \(macVRProtocolVersion)")
            logger.log(.info, "Press Ctrl+C to stop")
            RunLoop.main.run()
            withExtendedLifetime(host) {
                withExtendedLifetime(bridgeService) {
                    withExtendedLifetime(sigintSource) {
                        withExtendedLifetime(sigtermSource) {}
                    }
                }
            }
        } catch let cliError as CLIError {
            switch cliError {
            case .helpRequested:
                print(cliError.description)
                exit(EXIT_SUCCESS)
            case .versionRequested:
                print(cliError.description)
                exit(EXIT_SUCCESS)
            default:
                fputs("\(cliError.description)\n", stderr)
                exit(EXIT_FAILURE)
            }
        } catch {
            fputs("Fatal error: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
