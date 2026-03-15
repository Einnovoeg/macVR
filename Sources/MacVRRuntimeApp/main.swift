import Foundation
import MacVRProtocol
import MacVRRuntimeCore

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
            return "macvr-runtime \(macVRReleaseVersion)"
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
    var bridgePort: UInt16 = 43000
    var jpegInputPort: UInt16 = 44000
    var targetFPS: Int = 72
    var frameTag = "runtime"
    var maxPacketSize = 1200
    var bridgeMaxFrameAgeMs = 250
    var jpegMaxBytes = 2_000_000
    var statusIntervalSeconds: Double = 5
    var manifestPath: String?
    var runtimeLibraryPath: String?
    var manifestOnly = false
    var verbose = false

    static let usage = """
    Usage: macvr-runtime [options]
      --control-port <port>          TCP control port for clients (default: 42000)
      --bridge-port <port>           TCP/UDP bridge producer port (default: 43000)
      --jpeg-input-port <port>       Local TCP port for length-prefixed JPEG frames (default: 44000)
      --fps <value>                  Target stream FPS, 1-240 (default: 72)
      --frame-tag <text>             Tag used by the bundled host stream (default: runtime)
      --max-packet-size <n>          Max UDP packet size, 512-65507 (default: 1200)
      --bridge-max-frame-age-ms <m>  Drop stale bridge frames after ms, 0-10000 (default: 250)
      --jpeg-max-bytes <n>           Max accepted local JPEG size, 16384-16000000 (default: 2000000)
      --status-interval <seconds>    Periodic status log interval, 0 disables (default: 5)
      --write-openxr-manifest <p>    Write runtime manifest JSON to the given path
      --runtime-library <path>       Override runtime library path used in the manifest
      --manifest-only                Exit after writing the runtime manifest
      --version                      Show build/release version
      --verbose                      Enable debug logging
      -h, --help                     Show this help
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
            case "--control-port":
                let value = try requireValue(arg)
                guard let port = UInt16(value), port > 0 else {
                    throw CLIError.invalidValue("Invalid control port: \(value)")
                }
                options.controlPort = port
            case "--bridge-port":
                let value = try requireValue(arg)
                guard let port = UInt16(value), port > 0 else {
                    throw CLIError.invalidValue("Invalid bridge port: \(value)")
                }
                options.bridgePort = port
            case "--jpeg-input-port":
                let value = try requireValue(arg)
                guard let port = UInt16(value), port > 0 else {
                    throw CLIError.invalidValue("Invalid jpeg-input-port: \(value)")
                }
                options.jpegInputPort = port
            case "--fps":
                let value = try requireValue(arg)
                guard let fps = Int(value), (1...240).contains(fps) else {
                    throw CLIError.invalidValue("Invalid fps value: \(value)")
                }
                options.targetFPS = fps
            case "--frame-tag":
                let value = try requireValue(arg).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw CLIError.invalidValue("frame-tag cannot be empty")
                }
                options.frameTag = value
            case "--max-packet-size":
                let value = try requireValue(arg)
                guard let packetSize = Int(value), (512...65_507).contains(packetSize) else {
                    throw CLIError.invalidValue("Invalid max packet size: \(value)")
                }
                options.maxPacketSize = packetSize
            case "--bridge-max-frame-age-ms":
                let value = try requireValue(arg)
                guard let maxAge = Int(value), (0...10_000).contains(maxAge) else {
                    throw CLIError.invalidValue("Invalid bridge max frame age ms: \(value)")
                }
                options.bridgeMaxFrameAgeMs = maxAge
            case "--jpeg-max-bytes":
                let value = try requireValue(arg)
                guard let jpegMaxBytes = Int(value), (16_384...16_000_000).contains(jpegMaxBytes) else {
                    throw CLIError.invalidValue("Invalid jpeg-max-bytes: \(value)")
                }
                options.jpegMaxBytes = jpegMaxBytes
            case "--status-interval":
                let value = try requireValue(arg)
                guard let seconds = Double(value), seconds >= 0 else {
                    throw CLIError.invalidValue("Invalid status interval: \(value)")
                }
                options.statusIntervalSeconds = seconds
            case "--write-openxr-manifest":
                let value = try requireValue(arg).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw CLIError.invalidValue("write-openxr-manifest path cannot be empty")
                }
                options.manifestPath = value
            case "--runtime-library":
                let value = try requireValue(arg).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw CLIError.invalidValue("runtime-library cannot be empty")
                }
                options.runtimeLibraryPath = value
            case "--manifest-only":
                options.manifestOnly = true
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
struct MacVRRuntimeApp {
    static func main() {
        do {
            let cli = try CLIOptions.parse(arguments: Array(CommandLine.arguments.dropFirst()))
            if let manifestPath = cli.manifestPath {
                let runtimeLibraryPath = cli.runtimeLibraryPath ?? OpenXRRuntimeManifest.suggestedRuntimeLibraryPath()
                let outputURL = try OpenXRRuntimeManifest.writeManifest(to: manifestPath, libraryPath: runtimeLibraryPath)
                print("Wrote OpenXR runtime manifest to \(outputURL.path)")
                if cli.manifestOnly {
                    exit(EXIT_SUCCESS)
                }
            }

            let configuration = RuntimeConfiguration(
                controlPort: cli.controlPort,
                bridgePort: cli.bridgePort,
                jpegInputPort: cli.jpegInputPort,
                targetFPS: cli.targetFPS,
                frameTag: cli.frameTag,
                maxPacketSize: cli.maxPacketSize,
                bridgeMaxFrameAgeMs: cli.bridgeMaxFrameAgeMs,
                jpegMaxBytes: cli.jpegMaxBytes,
                verbose: cli.verbose
            )
            let runtime = RuntimeService(configuration: configuration)
            try runtime.start()

            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)

            let stopRuntime = {
                runtime.stop()
            }

            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigintSource.setEventHandler {
                stopRuntime()
                exit(EXIT_SUCCESS)
            }
            sigintSource.resume()

            let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            sigtermSource.setEventHandler {
                stopRuntime()
                exit(EXIT_SUCCESS)
            }
            sigtermSource.resume()

            let statusTimer: DispatchSourceTimer?
            if cli.statusIntervalSeconds > 0 {
                let timer = DispatchSource.makeTimerSource(queue: .main)
                let interval = max(cli.statusIntervalSeconds, 0.25)
                timer.schedule(deadline: .now() + interval, repeating: interval)
                timer.setEventHandler {
                    let status = runtime.statusSnapshot()
                    let uptime = String(format: "%.1f", status.uptimeSeconds)
                    let lastSource = status.bridgeStats.lastSource ?? "n/a"
                    let resolution = status.lastInputResolution ?? "unknown"
                    print(
                        "[STATUS] uptime=\(uptime)s inputFrames=\(status.inputFramesAccepted) drops=\(status.inputFramesDropped) activeInputs=\(status.inputConnectionCount) bridgeFrames=\(status.bridgeStats.totalFrames) lastSource=\(lastSource) lastResolution=\(resolution)"
                    )
                }
                timer.resume()
                statusTimer = timer
            } else {
                statusTimer = nil
            }

            print("macvr-runtime \(macVRReleaseVersion) running")
            print("OpenXR manifest hint: \(OpenXRRuntimeManifest.suggestedManifestPath().path)")
            print("Press Ctrl+C to stop")
            RunLoop.main.run()

            withExtendedLifetime(runtime) {
                withExtendedLifetime(sigintSource) {
                    withExtendedLifetime(sigtermSource) {
                        withExtendedLifetime(statusTimer) {}
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
                fputs(cliError.description + "\n", stderr)
                exit(EXIT_FAILURE)
            }
        } catch {
            fputs("Failed to start macvr-runtime: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
