import Foundation
import simd

public enum TrackerDriverError: Error {
    case failedToInitialize
    case deviceNotFound
    case invalidConfiguration
}

public protocol TrackerDevice: AnyObject {
    var deviceId: Int32 { get }
    var serialNumber: String { get }
    var modelNumber: String { get }
    var manufacturer: String { get }

    func updateTrackingState(position: SIMD3<Float>, orientation: simd_quatf, velocity: SIMD3<Float>, angularVelocity: SIMD3<Float>)
    func setBatteryLevel(_ level: Float)
    func setSignalQuality(_ quality: Int)
}

public final class SteamVRTrackerDriver: @unchecked Sendable {
    public static let manifestFileName = "steamvr.vrtrackerdriver"

    private var trackers: [Int32: TrackerDevice] = [:]
    private var nextDeviceId: Int32 = 2000
    private let lock = NSLock()

    public var driverVersion: String = "1.0.0"
    public var manifestPath: String?

    public init() {}

    public func registerTracker(_ tracker: TrackerDevice) {
        lock.lock()
        defer { lock.unlock() }

        trackers[tracker.deviceId] = tracker
    }

    public func unregisterTracker(deviceId: Int32) {
        lock.lock()
        defer { lock.unlock() }

        trackers.removeValue(forKey: deviceId)
    }

    public func createTracker(serial: String, role: TrackerRole) -> Int32 {
        lock.lock()
        defer { lock.unlock() }

        let deviceId = nextDeviceId
        nextDeviceId += 1

        return deviceId
    }

    public func getTracker(deviceId: Int32) -> TrackerDevice? {
        lock.lock()
        defer { lock.unlock() }

        return trackers[deviceId]
    }

    public func getAllTrackers() -> [TrackerDevice] {
        lock.lock()
        defer { lock.unlock() }

        return Array(trackers.values)
    }

    public func writeDriverManifest() throws -> Data {
        let manifest: [String: Any] = [
            "version": driverVersion,
            "trackers": trackers.values.map { tracker -> [String: Any] in
                return [
                    "serial": tracker.serialNumber,
                    "model": tracker.modelNumber,
                    "manufacturer": tracker.manufacturer,
                    "device_id": tracker.deviceId
                ]
            }
        ]

        return try JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted)
    }
}

public final class GenericTrackerDevice: TrackerDevice {
    public let deviceId: Int32
    public let serialNumber: String
    public let modelNumber: String
    public let manufacturer: String

    private var currentPosition: SIMD3<Float> = .zero
    private var currentOrientation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var currentVelocity: SIMD3<Float> = .zero
    private var currentAngularVelocity: SIMD3<Float> = .zero

    private var batteryLevel: Float = 1.0
    private var signalQuality: Int = 100

    public init(deviceId: Int32, serial: String, model: String, manufacturer: String) {
        self.deviceId = deviceId
        self.serialNumber = serial
        self.modelNumber = model
        self.manufacturer = manufacturer
    }

    public func updateTrackingState(position: SIMD3<Float>, orientation: simd_quatf, velocity: SIMD3<Float>, angularVelocity: SIMD3<Float>) {
        currentPosition = position
        currentOrientation = orientation
        currentVelocity = velocity
        currentAngularVelocity = angularVelocity
    }

    public func setBatteryLevel(_ level: Float) {
        batteryLevel = max(0, min(1, level))
    }

    public func setSignalQuality(_ quality: Int) {
        signalQuality = max(0, min(100, quality))
    }
}

public final class BodyTrackingDriver: @unchecked Sendable {
    private let trackerDriver: SteamVRTrackerDriver
    private let bodyTracker: BodyTracker

    private var trackerRoleToDeviceId: [TrackerRole: Int32] = [:]

    public init(bodyTracker: BodyTracker) {
        self.bodyTracker = bodyTracker
        self.trackerDriver = SteamVRTrackerDriver()
    }

    public func initialize() throws {
        let roles: [TrackerRole] = [.head, .leftHand, .rightHand, .waist, .leftFoot, .rightFoot, .leftElbow, .rightElbow, .leftKnee, .rightKnee, .chest]

        for role in roles {
            let deviceId = trackerDriver.createTracker(
                serial: "macvr-tracker-\(role.rawValue)",
                role: role
            )
            trackerRoleToDeviceId[role] = deviceId

            let tracker = GenericTrackerDevice(
                deviceId: deviceId,
                serial: "macvr-tracker-\(role.rawValue)",
                model: "macVR Body Tracker",
                manufacturer: "macVR"
            )

            trackerDriver.registerTracker(tracker)
        }

        try writeManifest()
    }

    private func writeManifest() throws {
        let manifestData = try trackerDriver.writeDriverManifest()

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let manifestDir = homeDir.appendingPathComponent("Library/Application Support/SteamVR/driver/macvr")
        let manifestPath = manifestDir.appendingPathComponent("driver.vrtrackerdriver")

        try FileManager.default.createDirectory(at: manifestDir, withIntermediateDirectories: true)
        try manifestData.write(to: manifestPath)
    }

    public func update() {
        bodyTracker.update(deltaTime: 1.0/72.0)

        let pose = bodyTracker.getCurrentPose()

        if let deviceId = trackerRoleToDeviceId[.head], let tracker = trackerDriver.getTracker(deviceId: deviceId) {
            tracker.updateTrackingState(
                position: pose.head,
                orientation: pose.headOrientation,
                velocity: .zero,
                angularVelocity: .zero
            )
        }

        if let leftHand = pose.leftHand, let leftHandOrient = pose.leftHandOrientation,
           let deviceId = trackerRoleToDeviceId[.leftHand], let tracker = trackerDriver.getTracker(deviceId: deviceId) {
            tracker.updateTrackingState(
                position: leftHand,
                orientation: leftHandOrient,
                velocity: .zero,
                angularVelocity: .zero
            )
        }

        if let rightHand = pose.rightHand, let rightHandOrient = pose.rightHandOrientation,
           let deviceId = trackerRoleToDeviceId[.rightHand], let tracker = trackerDriver.getTracker(deviceId: deviceId) {
            tracker.updateTrackingState(
                position: rightHand,
                orientation: rightHandOrient,
                velocity: .zero,
                angularVelocity: .zero
            )
        }

        if let waist = pose.waist, let waistOrient = pose.waistOrientation,
           let deviceId = trackerRoleToDeviceId[.waist], let tracker = trackerDriver.getTracker(deviceId: deviceId) {
            tracker.updateTrackingState(
                position: waist,
                orientation: waistOrient,
                velocity: .zero,
                angularVelocity: .zero
            )
        }

        if let leftFoot = pose.leftFoot, let leftFootOrient = pose.leftFootOrientation,
           let deviceId = trackerRoleToDeviceId[.leftFoot], let tracker = trackerDriver.getTracker(deviceId: deviceId) {
            tracker.updateTrackingState(
                position: leftFoot,
                orientation: leftFootOrient,
                velocity: .zero,
                angularVelocity: .zero
            )
        }

        if let rightFoot = pose.rightFoot, let rightFootOrient = pose.rightFootOrientation,
           let deviceId = trackerRoleToDeviceId[.rightFoot], let tracker = trackerDriver.getTracker(deviceId: deviceId) {
            tracker.updateTrackingState(
                position: rightFoot,
                orientation: rightFootOrient,
                velocity: .zero,
                angularVelocity: .zero
            )
        }
    }
}
