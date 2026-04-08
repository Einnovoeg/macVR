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
    var discoveryPort: UInt16 = 9943
    var targetFPS: Int = 72
    var serverName = "macVR Runtime"
    var requireTrustedClients = false
    var autoTrustLoopbackClients = true
    var trustedClientsPath = RuntimeConfiguration.suggestedTrustedClientsPath()
    var trustClientSpecs: [String] = []
    var untrustClientSpecs: [String] = []
    var listTrustedClients = false
    var frameTag = "runtime"
    var maxPacketSize = 1200
    var bridgeMaxFrameAgeMs = 250
    var jpegMaxBytes = 2_000_000
    var trackingStatePath = OpenXRRuntimeManifest.suggestedTrackingStatePath()
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
      --discovery-port <port>        UDP discovery port for viewers (default: 9943)
      --fps <value>                  Target stream FPS, 1-240 (default: 72)
      --server-name <text>           Friendly runtime name returned by discovery replies (default: macVR Runtime)
      --require-trusted-clients      Reject clients unless they are explicitly trusted
      --no-auto-trust-loopback       Disable automatic trust for localhost clients
      --trusted-clients-path <path>  JSON trust store path (default: ~/Library/Application Support/macVR/trusted-clients-v1.json)
      --trust-client <client@host>   Add or update a trusted client entry before startup
      --untrust-client <client@host> Remove a trusted client entry before startup
      --list-trusted-clients         Print trusted clients and exit
      --frame-tag <text>             Tag used by the bundled host stream (default: runtime)
      --max-packet-size <n>          Max UDP packet size, 512-65507 (default: 1200)
      --bridge-max-frame-age-ms <m>  Drop stale bridge frames after ms, 0-10000 (default: 250)
      --jpeg-max-bytes <n>           Max accepted local JPEG size, 16384-16000000 (default: 2000000)
      --tracking-state-path <path>   Binary tracking-state output path (default: ~/Library/Application Support/macVR/tracking-state-v1.bin)
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
            case "--discovery-port":
                let value = try requireValue(arg)
                guard let port = UInt16(value), port > 0 else {
                    throw CLIError.invalidValue("Invalid discovery-port: \(value)")
                }
                options.discoveryPort = port
            case "--fps":
                let value = try requireValue(arg)
                guard let fps = Int(value), (1...240).contains(fps) else {
                    throw CLIError.invalidValue("Invalid fps value: \(value)")
                }
                options.targetFPS = fps
            case "--server-name":
                let value = try requireValue(arg).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw CLIError.invalidValue("server-name cannot be empty")
                }
                options.serverName = value
            case "--require-trusted-clients":
                options.requireTrustedClients = true
            case "--no-auto-trust-loopback":
                options.autoTrustLoopbackClients = false
            case "--trusted-clients-path":
                let value = try requireValue(arg).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw CLIError.invalidValue("trusted-clients-path cannot be empty")
                }
                options.trustedClientsPath = value
            case "--trust-client":
                let value = try requireValue(arg).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw CLIError.invalidValue("trust-client value cannot be empty")
                }
                options.trustClientSpecs.append(value)
            case "--untrust-client":
                let value = try requireValue(arg).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw CLIError.invalidValue("untrust-client value cannot be empty")
                }
                options.untrustClientSpecs.append(value)
            case "--list-trusted-clients":
                options.listTrustedClients = true
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
            case "--tracking-state-path":
                let value = try requireValue(arg).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw CLIError.invalidValue("tracking-state-path cannot be empty")
                }
                options.trackingStatePath = value
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

private func parseTrustedClientSpec(_ spec: String) throws -> (clientName: String, host: String) {
    let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let separator = trimmed.lastIndex(of: "@") else {
        throw CLIError.invalidValue("Invalid trusted client value '\(spec)'. Expected format: <client@host>")
    }

    let clientName = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
    let host = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clientName.isEmpty, !host.isEmpty else {
        throw CLIError.invalidValue("Invalid trusted client value '\(spec)'. Expected format: <client@host>")
    }

    return (clientName, host)
}

private func printTrustedClients(_ trustedClients: [TrustedClientRecord], path: String) {
    print("Trusted clients (\(trustedClients.count)) from \(path):")
    if trustedClients.isEmpty {
        print("  (none)")
        return
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    for entry in trustedClients {
        let firstTrusted = formatter.string(from: entry.firstTrustedAt)
        let lastSeen = formatter.string(from: entry.lastSeenAt)
        let noteSuffix: String
        if let note = entry.note, !note.isEmpty {
            noteSuffix = " note=\"\(note)\""
        } else {
            noteSuffix = ""
        }
        print("  - \(entry.clientName)@\(entry.host) firstTrusted=\(firstTrusted) lastSeen=\(lastSeen)\(noteSuffix)")
    }
}

@main
struct MacVRRuntimeApp {
    static func main() {
        do {
            let cli = try CLIOptions.parse(arguments: Array(CommandLine.arguments.dropFirst()))

            let trustedClientStore = TrustedClientStore(path: cli.trustedClientsPath)
            for spec in cli.trustClientSpecs {
                let identity = try parseTrustedClientSpec(spec)
                let trusted = try trustedClientStore.trust(
                    clientName: identity.clientName,
                    host: identity.host,
                    note: "Added via CLI"
                )
                print("Trusted client added: \(trusted.clientName)@\(trusted.host)")
            }
            for spec in cli.untrustClientSpecs {
                let identity = try parseTrustedClientSpec(spec)
                let removed = try trustedClientStore.untrust(clientName: identity.clientName, host: identity.host)
                if removed {
                    print("Trusted client removed: \(identity.clientName)@\(identity.host)")
                } else {
                    print("Trusted client not found: \(identity.clientName)@\(identity.host)")
                }
            }

            if cli.listTrustedClients {
                printTrustedClients(trustedClientStore.trustedClients(), path: cli.trustedClientsPath)
                exit(EXIT_SUCCESS)
            }

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
                discoveryPort: cli.discoveryPort,
                targetFPS: cli.targetFPS,
                serverName: cli.serverName,
                requireTrustedClients: cli.requireTrustedClients,
                autoTrustLoopbackClients: cli.autoTrustLoopbackClients,
                trustedClientsPath: cli.trustedClientsPath,
                frameTag: cli.frameTag,
                maxPacketSize: cli.maxPacketSize,
                bridgeMaxFrameAgeMs: cli.bridgeMaxFrameAgeMs,
                jpegMaxBytes: cli.jpegMaxBytes,
                trackingStatePath: cli.trackingStatePath,
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
                        "[STATUS] uptime=\(uptime)s inputFrames=\(status.inputFramesAccepted) drops=\(status.inputFramesDropped) activeInputs=\(status.inputConnectionCount) trustedClients=\(status.trustedClientCount) deniedUntrusted=\(status.deniedUntrustedClientCount) bridgeFrames=\(status.bridgeStats.totalFrames) lastSource=\(lastSource) lastResolution=\(resolution)"
                    )
                }
                timer.resume()
                statusTimer = timer
            } else {
                statusTimer = nil
            }

            print("macvr-runtime \(macVRReleaseVersion) running")
            print("Discovery: udp://0.0.0.0:\(configuration.discoveryPort) as \(configuration.serverName)")
            print("Trusted client policy: require=\(configuration.requireTrustedClients), autoLoopback=\(configuration.autoTrustLoopbackClients)")
            print("Trusted client store: \(configuration.trustedClientsPath)")
            print("OpenXR manifest hint: \(OpenXRRuntimeManifest.suggestedManifestPath().path)")
            print("Tracking state hint: \(configuration.trackingStatePath)")
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
