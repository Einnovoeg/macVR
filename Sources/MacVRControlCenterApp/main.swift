import AppKit
import Foundation
import MacVRProtocol
import MacVRRuntimeCore
import SwiftUI

@MainActor
/// Holds the editable runtime settings, process lifecycle, and mirrored log lines
/// used by the desktop control center. The model deliberately keeps all user-facing
/// state in one place so the UI stays declarative and the release app can reuse the
/// same runtime entry points as the CLI.
final class ControlCenterModel: ObservableObject {
    @Published var controlPort = "42000"
    @Published var bridgePort = "43000"
    @Published var jpegInputPort = "44000"
    @Published var discoveryPort = "9943"
    @Published var fps = "72"
    @Published var serverName = "macVR Runtime"
    @Published var requireTrustedClients = false
    @Published var autoTrustLoopbackClients = true
    @Published var trustedClientsPath = RuntimeConfiguration.suggestedTrustedClientsPath()
    @Published var trustedClientName = "macvr-viewer"
    @Published var trustedClientHost = "127.0.0.1"
    @Published var trustedClientNote = ""
    @Published var frameTag = "runtime"
    @Published var maxPacketSize = "1200"
    @Published var bridgeMaxFrameAgeMs = "250"
    @Published var jpegMaxBytes = "2000000"
    @Published var trackingStatePath = OpenXRRuntimeManifest.suggestedTrackingStatePath()
    @Published var manifestPath = OpenXRRuntimeManifest.suggestedManifestPath().path
    @Published var runtimeLibraryPath = OpenXRRuntimeManifest.suggestedRuntimeLibraryPath()
    @Published var errorMessage: String?
    @Published private(set) var logs: [String] = []
    @Published private(set) var trustedClients: [TrustedClientRecord] = []
    @Published private(set) var runtimeStatus = RuntimeStatusSnapshot.stopped()
    @Published private(set) var isRunning = false

    private var runtime: RuntimeService?
    private var statusTask: Task<Void, Never>?

    var logsText: String {
        logs.joined(separator: "\n")
    }

    init() {
        refreshTrustedClients()
    }

    func startRuntime() {
        guard runtime == nil else {
            return
        }

        do {
            let configuration = try makeConfiguration()
            let service = RuntimeService(configuration: configuration) { [weak self] line in
                Task { @MainActor in
                    self?.appendLog(line)
                }
            }
            try service.start()
            runtime = service
            isRunning = true
            errorMessage = nil
            appendLog("macVR Control Center started the bundled runtime")
            refreshStatus()
            beginStatusPolling()
        } catch {
            errorMessage = error.localizedDescription
            appendLog("Start failed: \(error.localizedDescription)")
        }
    }

    func stopRuntime() {
        statusTask?.cancel()
        statusTask = nil
        runtime?.stop()
        runtime = nil
        isRunning = false
        refreshStatus()
        appendLog("Bundled runtime stopped")
    }

    func refreshStatus() {
        if let runtime {
            runtimeStatus = runtime.statusSnapshot()
            isRunning = runtimeStatus.isRunning
        } else {
            runtimeStatus = RuntimeStatusSnapshot.stopped()
            isRunning = false
        }
        refreshTrustedClients()
    }

    func writeManifest() {
        do {
            let trimmedManifestPath = manifestPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedLibraryPath = runtimeLibraryPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedManifestPath.isEmpty else {
                throw CocoaError(.fileNoSuchFile)
            }
            guard !trimmedLibraryPath.isEmpty else {
                throw CocoaError(.fileNoSuchFile)
            }
            let outputURL = try OpenXRRuntimeManifest.writeManifest(
                to: trimmedManifestPath,
                libraryPath: trimmedLibraryPath
            )
            errorMessage = nil
            appendLog("Wrote OpenXR runtime manifest to \(outputURL.path)")
        } catch {
            errorMessage = error.localizedDescription
            appendLog("Manifest write failed: \(error.localizedDescription)")
        }
    }

    func resetManifestPaths() {
        manifestPath = OpenXRRuntimeManifest.suggestedManifestPath().path
        runtimeLibraryPath = OpenXRRuntimeManifest.suggestedRuntimeLibraryPath(
            executablePath: preferredRuntimeLibraryBaseExecutablePath()
        )
        appendLog("Reset OpenXR manifest fields to the local build defaults")
    }

    func copyCaptureSenderCommand() {
        let senderInvocation: String
        if let senderExecutable = packagedExecutablePath(named: "macvr-capture-sender") {
            senderInvocation = "\"\(senderExecutable.path)\""
        } else {
            senderInvocation = "swift run macvr-capture-sender"
        }
        let command = "\(senderInvocation) --host 127.0.0.1 --port \(jpegInputPort) --fps 15 --jpeg-quality 60 --scale 0.50 --verbose"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        appendLog("Copied live capture sender command to the pasteboard")
    }

    func openViewer() {
        let fileManager = FileManager.default
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
        let packagedViewerApp = bundleParent.appendingPathComponent("macVR Viewer.app")

        if fileManager.fileExists(atPath: packagedViewerApp.path) {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: packagedViewerApp, configuration: configuration) { _, error in
                Task { @MainActor in
                    if let error {
                        self.errorMessage = error.localizedDescription
                        self.appendLog("Viewer launch failed: \(error.localizedDescription)")
                    } else {
                        self.appendLog("Opened packaged macVR Viewer.app")
                    }
                }
            }
            return
        }

        if let viewerExecutable = packagedExecutablePath(named: "macvr-viewer") {
            do {
                let process = Process()
                process.executableURL = viewerExecutable
                try process.run()
                appendLog("Launched macvr-viewer from \(viewerExecutable.path)")
            } catch {
                errorMessage = error.localizedDescription
                appendLog("Viewer launch failed: \(error.localizedDescription)")
            }
            return
        }

        appendLog("Viewer launch skipped: build macvr-viewer or use the packaged release bundle first")
    }

    func openManifestFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: manifestPath).deletingLastPathComponent())
    }

    func addTrustedClient() {
        let clientName = trustedClientName.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = trustedClientHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = trustedClientNote.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !clientName.isEmpty else {
            errorMessage = "Trusted client name cannot be empty."
            return
        }
        guard !host.isEmpty else {
            errorMessage = "Trusted client host cannot be empty."
            return
        }

        do {
            if let runtime {
                _ = try runtime.trustClient(
                    clientName: clientName,
                    host: host,
                    note: note.isEmpty ? nil : note
                )
            } else {
                let store = TrustedClientStore(path: trustedClientsPath)
                _ = try store.trust(
                    clientName: clientName,
                    host: host,
                    note: note.isEmpty ? nil : note
                )
            }
            errorMessage = nil
            trustedClientNote = ""
            appendLog("Trusted client added: \(clientName)@\(host)")
            refreshTrustedClients()
        } catch {
            errorMessage = error.localizedDescription
            appendLog("Failed to add trusted client: \(error.localizedDescription)")
        }
    }

    func removeTrustedClient(_ client: TrustedClientRecord) {
        do {
            let removed: Bool
            if let runtime {
                removed = try runtime.untrustClient(clientName: client.clientName, host: client.host)
            } else {
                let store = TrustedClientStore(path: trustedClientsPath)
                removed = try store.untrust(clientName: client.clientName, host: client.host)
            }

            if removed {
                appendLog("Trusted client removed: \(client.clientName)@\(client.host)")
                errorMessage = nil
            } else {
                appendLog("Trusted client not found: \(client.clientName)@\(client.host)")
            }
            refreshTrustedClients()
        } catch {
            errorMessage = error.localizedDescription
            appendLog("Failed to remove trusted client: \(error.localizedDescription)")
        }
    }

    func refreshTrustedClients() {
        if let runtime {
            trustedClients = runtime.trustedClients()
        } else {
            trustedClients = TrustedClientStore(path: trustedClientsPath).trustedClients()
        }
    }

    private func beginStatusPolling() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                // A short polling interval keeps the UI responsive without coupling the
                // runtime service to AppKit-specific observer plumbing.
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run {
                    self?.refreshStatus()
                }
            }
        }
    }

    private func appendLog(_ line: String) {
        logs.append(line)
        if logs.count > 250 {
            logs.removeFirst(logs.count - 250)
        }
    }

    private func makeConfiguration() throws -> RuntimeConfiguration {
        let parsedControlPort = try parsePort(controlPort, field: "Control port")
        let parsedBridgePort = try parsePort(bridgePort, field: "Bridge port")
        let parsedJPEGInputPort = try parsePort(jpegInputPort, field: "JPEG input port")
        let parsedDiscoveryPort = try parsePort(discoveryPort, field: "Discovery port")
        let parsedFPS = try parseInt(fps, field: "FPS", range: 1...240)
        let parsedPacketSize = try parseInt(maxPacketSize, field: "Max packet size", range: 512...65_507)
        let parsedBridgeAge = try parseInt(bridgeMaxFrameAgeMs, field: "Bridge max frame age", range: 0...10_000)
        let parsedJPEGMaxBytes = try parseInt(jpegMaxBytes, field: "JPEG max bytes", range: 16_384...16_000_000)
        let trimmedTrackingStatePath = trackingStatePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTrackingStatePath.isEmpty else {
            throw NSError(domain: "macVR.ControlCenter", code: 4, userInfo: [NSLocalizedDescriptionKey: "Tracking state path cannot be empty"])
        }

        let trimmedFrameTag = frameTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFrameTag.isEmpty else {
            throw NSError(domain: "macVR.ControlCenter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Frame tag cannot be empty"])
        }
        let trimmedServerName = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServerName.isEmpty else {
            throw NSError(domain: "macVR.ControlCenter", code: 5, userInfo: [NSLocalizedDescriptionKey: "Runtime name cannot be empty"])
        }
        let trimmedTrustedClientsPath = trustedClientsPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTrustedClientsPath.isEmpty else {
            throw NSError(domain: "macVR.ControlCenter", code: 6, userInfo: [NSLocalizedDescriptionKey: "Trusted clients path cannot be empty"])
        }

        return RuntimeConfiguration(
            controlPort: parsedControlPort,
            bridgePort: parsedBridgePort,
            jpegInputPort: parsedJPEGInputPort,
            discoveryPort: parsedDiscoveryPort,
            targetFPS: parsedFPS,
            serverName: trimmedServerName,
            requireTrustedClients: requireTrustedClients,
            autoTrustLoopbackClients: autoTrustLoopbackClients,
            trustedClientsPath: trimmedTrustedClientsPath,
            frameTag: trimmedFrameTag,
            maxPacketSize: parsedPacketSize,
            bridgeMaxFrameAgeMs: parsedBridgeAge,
            jpegMaxBytes: parsedJPEGMaxBytes,
            trackingStatePath: trimmedTrackingStatePath,
            verbose: true
        )
    }

    private func parsePort(_ value: String, field: String) throws -> UInt16 {
        guard let port = UInt16(value), port > 0 else {
            throw NSError(domain: "macVR.ControlCenter", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(field) must be a valid port"])
        }
        return port
    }

    private func parseInt(_ value: String, field: String, range: ClosedRange<Int>) throws -> Int {
        guard let parsed = Int(value), range.contains(parsed) else {
            throw NSError(domain: "macVR.ControlCenter", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(field) must be within \(range.lowerBound)-\(range.upperBound)"])
        }
        return parsed
    }

    /// Prefer a concrete executable path when the app is launched from a packaged
    /// release, but fall back to the development-time `swift run` workflow when the
    /// sender tool has not been built yet.
    private func packagedExecutablePath(named executableName: String) -> URL? {
        let fileManager = FileManager.default
        let executableURL = URL(fileURLWithPath: preferredRuntimeLibraryBaseExecutablePath())
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let candidates = [
            executableURL.deletingLastPathComponent().appendingPathComponent(executableName),
            bundleURL.deletingLastPathComponent().appendingPathComponent("bin", isDirectory: true).appendingPathComponent(executableName),
        ]
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    private func preferredRuntimeLibraryBaseExecutablePath() -> String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }
}

struct MetricCard: View {
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

struct SectionCard<Content: View>: View {
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

struct PortField: View {
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

struct ContentView: View {
    @EnvironmentObject private var model: ControlCenterModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.09, green: 0.14, blue: 0.20), Color(red: 0.18, green: 0.12, blue: 0.08)],
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
                    runtimeSection
                    trustedClientsSection
                    openXRSection
                    logsSection
                }
                .padding(24)
            }
        }
        .frame(minWidth: 980, minHeight: 760)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("macVR Control Center")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Bundled runtime, OpenXR manifest generation, and bridge-input monitoring for native macOS VR experiments.")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.86))
                    Text("Release \(macVRReleaseVersion) | Protocol \(macVRProtocolVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                }
                Spacer()
                Text(model.isRunning ? "Runtime Online" : "Runtime Offline")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Capsule(style: .continuous)
                            .fill(model.isRunning ? Color.green.opacity(0.75) : Color.gray.opacity(0.45))
                    )
                    .help("Shows whether the in-process bundled runtime is currently serving control, bridge, and local JPEG input sockets.")
            }

            HStack(spacing: 12) {
                Button(action: model.startRuntime) {
                    Label("Start Runtime", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(model.isRunning)
                .help("Start the bundled bridge-first runtime service with the ports and limits shown below.")

                Button(action: model.stopRuntime) {
                    Label("Stop Runtime", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!model.isRunning)
                .help("Stop the bundled runtime and close all active bridge and JPEG input sockets.")

                Button(action: model.writeManifest) {
                    Label("Write Manifest", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.bordered)
                .help("Write an OpenXR loader manifest that points to the experimental macVR runtime shim library.")

                Button(action: model.copyCaptureSenderCommand) {
                    Label("Copy Live Capture", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .help("Copy a working `macvr-capture-sender` example command that captures the current macOS display and targets the configured JPEG input port.")

                Button(action: model.openViewer) {
                    Label("Open Viewer", systemImage: "play.rectangle.on.rectangle")
                }
                .buttonStyle(.bordered)
                .help("Launch the packaged macVR Viewer app, or the locally built `macvr-viewer` executable, to preview the incoming stream in a stereo GUI.")

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
                title: "Accepted Input Frames",
                value: "\(model.runtimeStatus.inputFramesAccepted)",
                detail: "Local TCP JPEG frames accepted by the bundled runtime",
                helpText: "Counts successfully validated JPEG frames submitted through the localhost input seam."
            )
            MetricCard(
                title: "Bridge Frames Served",
                value: "\(model.runtimeStatus.bridgeStats.totalFrames)",
                detail: "Frames currently visible to clients through bridge-jpeg mode",
                helpText: "Tracks the most recent bridge frame inventory available to runtime and client sessions."
            )
            MetricCard(
                title: "Runtime Uptime",
                value: String(format: "%.1fs", model.runtimeStatus.uptimeSeconds),
                detail: model.runtimeStatus.lastInputResolution.map { "Latest decoded frame: \($0)" } ?? "No decoded input frame yet",
                helpText: "Shows how long the bundled runtime has been active and the latest decoded input resolution."
            )
            MetricCard(
                title: "Trusted Clients",
                value: "\(model.runtimeStatus.trustedClientCount)",
                detail: "Denied untrusted: \(model.runtimeStatus.deniedUntrustedClientCount)",
                helpText: "Current trusted-client inventory and count of rejected untrusted client handshakes."
            )
        }
    }

    private var runtimeSection: some View {
        SectionCard(
            title: "Bundled Runtime",
            subtitle: "These settings drive the in-process runtime service and are locked while it is running."
        ) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 12) {
                    PortField(
                        title: "Control Port",
                        value: $model.controlPort,
                        helpText: "TCP port used by macvr-client and other client probes to negotiate sessions.",
                        disabled: model.isRunning
                    )
                    PortField(
                        title: "Bridge Port",
                        value: $model.bridgePort,
                        helpText: "Shared TCP/UDP port used by bridge protocol producers.",
                        disabled: model.isRunning
                    )
                    PortField(
                        title: "JPEG Input Port",
                        value: $model.jpegInputPort,
                        helpText: "Localhost TCP port used by the length-prefixed JPEG ingest seam.",
                        disabled: model.isRunning
                    )
                    PortField(
                        title: "Discovery Port",
                        value: $model.discoveryPort,
                        helpText: "UDP port on which the bundled runtime listens for ALVR-style viewer discovery probes.",
                        disabled: model.isRunning
                    )
                    PortField(
                        title: "Target FPS",
                        value: $model.fps,
                        helpText: "Host-side target frame rate for bridge-jpeg sessions.",
                        disabled: model.isRunning
                    )
                }
                VStack(spacing: 12) {
                    PortField(
                        title: "Runtime Name",
                        value: $model.serverName,
                        helpText: "Friendly runtime name returned to viewers during discovery. Keep this generic if you do not want to advertise a machine hostname.",
                        disabled: model.isRunning
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Require Trusted Clients", isOn: $model.requireTrustedClients)
                            .disabled(model.isRunning)
                            .help("When enabled, the runtime rejects any hello handshake from clients that are not listed in the trusted-clients store.")
                        Toggle("Auto-Trust Loopback Clients", isOn: $model.autoTrustLoopbackClients)
                            .disabled(model.isRunning)
                            .help("Automatically trust localhost clients (127.0.0.1, ::1, localhost) during handshake to keep local testing fast.")
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.05))
                    )
                    PortField(
                        title: "Frame Tag",
                        value: $model.frameTag,
                        helpText: "Human-readable label attached to outgoing stream packets.",
                        disabled: model.isRunning
                    )
                    PortField(
                        title: "Max Packet Size",
                        value: $model.maxPacketSize,
                        helpText: "Maximum UDP packet size used when the bridge producer switches to chunked transport.",
                        disabled: model.isRunning
                    )
                    PortField(
                        title: "Bridge Max Frame Age (ms)",
                        value: $model.bridgeMaxFrameAgeMs,
                        helpText: "Maximum age for bridge frames before the host stops replaying stale content.",
                        disabled: model.isRunning
                    )
                    PortField(
                        title: "JPEG Max Bytes",
                        value: $model.jpegMaxBytes,
                        helpText: "Upper limit for a single local JPEG frame submitted to the runtime.",
                        disabled: model.isRunning
                    )
                    PortField(
                        title: "Tracking State Path",
                        value: $model.trackingStatePath,
                        helpText: "Binary pose handoff file written by the runtime so the OpenXR shim can read the newest tracked head pose across processes.",
                        disabled: model.isRunning
                    )
                    PortField(
                        title: "Trusted Clients Path",
                        value: $model.trustedClientsPath,
                        helpText: "JSON file used for persistent trusted-client entries. This file can be edited manually or through the controls below.",
                        disabled: model.isRunning
                    )
                }
            }

            Divider()

            HStack(spacing: 16) {
                MetricCard(
                    title: "Input Connections",
                    value: "\(model.runtimeStatus.inputConnectionCount)",
                    detail: "Active local TCP producers",
                    helpText: "The number of localhost producers currently connected to the runtime JPEG input socket."
                )
                MetricCard(
                    title: "Dropped Inputs",
                    value: "\(model.runtimeStatus.inputFramesDropped)",
                    detail: "Frames rejected by validation or size checks",
                    helpText: "Counts frames rejected because they were malformed, empty, or larger than the configured JPEG byte limit."
                )
                MetricCard(
                    title: "Input Bytes",
                    value: ByteCountFormatter.string(fromByteCount: Int64(model.runtimeStatus.inputBytesAccepted), countStyle: .file),
                    detail: model.runtimeStatus.bridgeStats.lastSource.map { "Last source: \($0)" } ?? "No bridge source observed yet",
                    helpText: "Total accepted JPEG payload volume since the bundled runtime was started."
                )
            }
        }
    }

    private var trustedClientsSection: some View {
        SectionCard(
            title: "Trusted Clients",
            subtitle: "Manage the runtime client allowlist used by strict trust mode. Entries are persisted to the configured trust-store JSON file."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    PortField(
                        title: "Client Name",
                        value: $model.trustedClientName,
                        helpText: "Client identifier sent in hello payloads, for example macvr-viewer.",
                        disabled: false
                    )
                    PortField(
                        title: "Client Host",
                        value: $model.trustedClientHost,
                        helpText: "Expected remote host or IP address for this trusted client entry.",
                        disabled: false
                    )
                    PortField(
                        title: "Note (optional)",
                        value: $model.trustedClientNote,
                        helpText: "Optional operator note stored with the trusted entry for future audit context.",
                        disabled: false
                    )
                }

                HStack(spacing: 12) {
                    Button(action: model.addTrustedClient) {
                        Label("Add Trusted Client", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .help("Persist a trusted client entry using the name and host fields above.")

                    Button(action: model.refreshTrustedClients) {
                        Label("Refresh List", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .help("Reload trusted-client entries from the current trust-store path.")
                }

                if model.trustedClients.isEmpty {
                    Text("No trusted clients configured yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .help("Add a client entry before enabling strict trust mode for remote clients.")
                } else {
                    ForEach(model.trustedClients) { trustedClient in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(trustedClient.clientName)@\(trustedClient.host)")
                                    .font(.subheadline.weight(.semibold))
                                Text("First trusted: \(trustedClient.firstTrustedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Last seen: \(trustedClient.lastSeenAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let note = trustedClient.note, !note.isEmpty {
                                    Text("Note: \(note)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                model.removeTrustedClient(trustedClient)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                            .help("Remove this client from the trusted allowlist.")
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.black.opacity(0.05))
                        )
                        .help("Trusted client entry persisted in the runtime trust-store file.")
                    }
                }
            }
        }
    }

    private var openXRSection: some View {
        SectionCard(
            title: "Experimental OpenXR Runtime",
            subtitle: "The included runtime shim is intended for loader integration and transport validation, not production game compatibility."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                PortField(
                    title: "Manifest Path",
                    value: $model.manifestPath,
                    helpText: "Where the control center will write the OpenXR active runtime manifest JSON file.",
                    disabled: false
                )
                PortField(
                    title: "Runtime Library Path",
                    value: $model.runtimeLibraryPath,
                    helpText: "Absolute path to libMacVROpenXRRuntime.dylib used in the generated manifest.",
                    disabled: false
                )
                HStack(spacing: 12) {
                    Button("Reset To Defaults", action: model.resetManifestPaths)
                        .buttonStyle(.bordered)
                        .help("Restore the manifest path and runtime library path to the local SwiftPM build defaults.")
                    Button("Open Manifest Folder", action: model.openManifestFolder)
                        .buttonStyle(.bordered)
                        .help("Open the folder containing the current manifest path in Finder.")
                    Text(OpenXRRuntimeManifest.statusSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .help("Version banner for the runtime shim that the generated OpenXR manifest will reference.")
                }
            }
        }
    }

    private var logsSection: some View {
        SectionCard(
            title: "Runtime Log",
            subtitle: "Recent runtime lines are mirrored here from the shared host logger so the GUI and CLI observe the same state changes."
        ) {
            ScrollView {
                Text(model.logsText.isEmpty ? "No runtime logs yet." : model.logsText)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.88))
                    .padding(16)
            }
            .frame(minHeight: 240)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.72))
            )
            .help("Read-only runtime log view mirroring the same lines emitted by the shared host logger.")
        }
    }
}

@main
struct MacVRControlCenterApp: App {
    @StateObject private var model = ControlCenterModel()

    init() {
        let arguments = Set(CommandLine.arguments.dropFirst())
        if arguments.contains("--version") {
            print("macvr-control-center \(macVRReleaseVersion)")
            exit(EXIT_SUCCESS)
        }
        if arguments.contains("--help") || arguments.contains("-h") {
            print("Usage: macvr-control-center [--version] [--help]")
            exit(EXIT_SUCCESS)
        }
    }

    var body: some Scene {
        WindowGroup("macVR Control Center") {
            ContentView()
                .environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About macVR Control Center") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "macVR Control Center",
                        .applicationVersion: macVRReleaseVersion,
                        .version: macVRReleaseVersion,
                    ])
                }
            }
        }
    }
}
