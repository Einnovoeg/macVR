import Foundation
import simd
import simd

public protocol TrackingSourcePlugin: AnyObject {
    var name: String { get }
    var version: String { get }
    var isRunning: Bool { get }

    func start() throws
    func stop()
    func getTrackingState() -> BodyTrackingPose?
}

public protocol TrackingSourceDelegate: AnyObject {
    func trackingSource(_ source: TrackingSourcePlugin, didUpdatePose pose: BodyTrackingPose)
    func trackingSource(_ source: TrackingSourcePlugin, didFailWithError error: Error)
}

public final class PluginManager: @unchecked Sendable {
    private var plugins: [String: TrackingSourcePlugin] = [:]
    private var activeSource: TrackingSourcePlugin?
    private let lock = NSLock()

    public weak var delegate: TrackingSourceDelegate?

    public static let shared = PluginManager()

    private init() {}

    public func registerPlugin(_ plugin: TrackingSourcePlugin) {
        lock.lock()
        defer { lock.unlock() }

        plugins[plugin.name] = plugin
    }

    public func unregisterPlugin(name: String) {
        lock.lock()
        defer { lock.unlock() }

        if activeSource?.name == name {
            activeSource?.stop()
            activeSource = nil
        }
        plugins.removeValue(forKey: name)
    }

    public func getPlugin(name: String) -> TrackingSourcePlugin? {
        lock.lock()
        defer { lock.unlock() }

        return plugins[name]
    }

    public func getAllPlugins() -> [TrackingSourcePlugin] {
        lock.lock()
        defer { lock.unlock() }

        return Array(plugins.values)
    }

    public func setActiveSource(name: String) throws {
        lock.lock()
        defer { lock.unlock() }

        if let current = activeSource {
            current.stop()
        }

        guard let plugin = plugins[name] else {
            throw PluginError.pluginNotFound
        }

        try plugin.start()
        activeSource = plugin
    }

    public func update() {
        lock.lock()
        let source = activeSource
        lock.unlock()

        guard let pose = source?.getTrackingState() else { return }
        delegate?.trackingSource(source!, didUpdatePose: pose)
    }
}

public enum PluginError: Error {
    case pluginNotFound
    case failedToStart
    case invalidConfiguration
}

public final class IMUTrackerPlugin: TrackingSourcePlugin {
    public let name: String = "imu-tracker"
    public let version: String = "1.0.0"
    public private(set) var isRunning: Bool = false

    private let headTracker: HeadTracker

    public init() {
        self.headTracker = HeadTracker()
    }

    public func start() throws {
        headTracker.startSimulation()
        isRunning = true
    }

    public func stop() {
        headTracker.stopSimulation()
        isRunning = false
    }

    public func getTrackingState() -> BodyTrackingPose? {
        let state = headTracker.getState()

        var pose = BodyTrackingPose()
        pose.head = state.position
        pose.headOrientation = state.orientation
        pose.timestamp = state.timestamp
        pose.confidence = 1.0

        return pose
    }
}

public final class BodySimulatorPlugin: TrackingSourcePlugin {
    public let name: String = "body-simulator"
    public let version: String = "1.0.0"
    public private(set) var isRunning: Bool = false

    private let bodyTracker: BodyTracker

    public init() {
        self.bodyTracker = BodyTracker()
    }

    public func start() throws {
        bodyTracker.start()
        isRunning = true
    }

    public func stop() {
        bodyTracker.stop()
        isRunning = false
    }

    public func getTrackingState() -> BodyTrackingPose? {
        return bodyTracker.getCurrentPose()
    }
}

public struct PluginManifest: Codable, Sendable {
    public let name: String
    public let version: String
    public let description: String
    public let author: String
    public let sourceType: String

    public init(name: String, version: String, description: String, author: String, sourceType: String) {
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.sourceType = sourceType
    }
}

public final class PluginRegistry: @unchecked Sendable {
    private var manifests: [String: PluginManifest] = [:]
    private let lock = NSLock()

    public static let shared = PluginRegistry()

    private init() {}

    public func registerPlugin(manifest: PluginManifest) {
        lock.lock()
        defer { lock.unlock() }

        manifests[manifest.name] = manifest
    }

    public func getManifest(name: String) -> PluginManifest? {
        lock.lock()
        defer { lock.unlock() }

        return manifests[name]
    }

    public func getAllManifests() -> [PluginManifest] {
        lock.lock()
        defer { lock.unlock() }

        return Array(manifests.values)
    }

    public func loadBuiltInPlugins() {
        let imuManifest = PluginManifest(
            name: "imu-tracker",
            version: "1.0.0",
            description: "Head tracking using IMU simulation",
            author: "macVR",
            sourceType: "simulation"
        )

        let bodySimManifest = PluginManifest(
            name: "body-simulator",
            version: "1.0.0",
            description: "Full body tracking simulation",
            author: "macVR",
            sourceType: "simulation"
        )

        registerPlugin(manifest: imuManifest)
        registerPlugin(manifest: bodySimManifest)
    }

    public func writeManifestToDisk() throws {
        let manifests = getAllManifests()

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        let data = try encoder.encode(manifests)

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let pluginsDir = homeDir.appendingPathComponent(".macvr/plugins")
        let manifestPath = pluginsDir.appendingPathComponent("registry.json")

        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try data.write(to: manifestPath)
    }
}
