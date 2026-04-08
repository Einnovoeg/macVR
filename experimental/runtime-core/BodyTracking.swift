import Foundation
import simd

public struct BodyTrackingPose: Sendable {
    public var head: SIMD3<Float>
    public var headOrientation: simd_quatf

    public var leftHand: SIMD3<Float>?
    public var leftHandOrientation: simd_quatf?
    public var rightHand: SIMD3<Float>?
    public var rightHandOrientation: simd_quatf?

    public var chest: SIMD3<Float>?
    public var chestOrientation: simd_quatf?

    public var waist: SIMD3<Float>?
    public var waistOrientation: simd_quatf?

    public var leftFoot: SIMD3<Float>?
    public var leftFootOrientation: simd_quatf?
    public var rightFoot: SIMD3<Float>?
    public var rightFootOrientation: simd_quatf?

    public var leftElbow: SIMD3<Float>?
    public var leftElbowOrientation: simd_quatf?
    public var rightElbow: SIMD3<Float>?
    public var rightElbowOrientation: simd_quatf?

    public var leftKnee: SIMD3<Float>?
    public var leftKneeOrientation: simd_quatf?
    public var rightKnee: SIMD3<Float>?
    public var rightKneeOrientation: simd_quatf?

    public var timestamp: UInt64
    public var confidence: Float

    public init() {
        self.head = .zero
        self.headOrientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        self.timestamp = 0
        self.confidence = 0
    }
}

public enum TrackerRole: Int, Sendable {
    case head = 0
    case leftHand = 1
    case rightHand = 2
    case waist = 3
    case leftFoot = 4
    case rightFoot = 5
    case leftElbow = 6
    case rightElbow = 7
    case leftKnee = 8
    case rightKnee = 9
    case chest = 10
    case unknown = 99
}

public struct TrackerState: Sendable {
    public let role: TrackerRole
    public var position: SIMD3<Float>
    public var orientation: simd_quatf
    public var linearVelocity: SIMD3<Float>
    public var angularVelocity: SIMD3<Float>
    public var isConnected: Bool
    public var isTracking: Bool
    public var confidence: Float
    public var timestamp: UInt64

    public init(role: TrackerRole, position: SIMD3<Float> = .zero, orientation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)) {
        self.role = role
        self.position = position
        self.orientation = orientation
        self.linearVelocity = .zero
        self.angularVelocity = .zero
        self.isConnected = true
        self.isTracking = true
        self.confidence = 1.0
        self.timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
    }
}

public final class BodyTracker: @unchecked Sendable {
    private var trackers: [TrackerRole: TrackerState] = [:]
    private var currentPose = BodyTrackingPose()
    private let stateLock = NSLock()

    private var isRunning = false

    public init() {
        setupDefaultTrackers()
    }

    private func setupDefaultTrackers() {
        trackers[.head] = TrackerState(role: .head, position: SIMD3(0, 1.6, 0))
        trackers[.leftHand] = TrackerState(role: .leftHand, position: SIMD3(-0.3, 1.0, 0))
        trackers[.rightHand] = TrackerState(role: .rightHand, position: SIMD3(0.3, 1.0, 0))
        trackers[.waist] = TrackerState(role: .waist, position: SIMD3(0, 0.9, 0))
        trackers[.leftFoot] = TrackerState(role: .leftFoot, position: SIMD3(-0.1, 0.2, 0))
        trackers[.rightFoot] = TrackerState(role: .rightFoot, position: SIMD3(0.1, 0.2, 0))
        trackers[.leftElbow] = TrackerState(role: .leftElbow, position: SIMD3(-0.4, 0.8, 0))
        trackers[.rightElbow] = TrackerState(role: .rightElbow, position: SIMD3(0.4, 0.8, 0))
        trackers[.leftKnee] = TrackerState(role: .leftKnee, position: SIMD3(-0.1, 0.5, 0))
        trackers[.rightKnee] = TrackerState(role: .rightKnee, position: SIMD3(0.1, 0.5, 0))
        trackers[.chest] = TrackerState(role: .chest, position: SIMD3(0, 1.2, 0))
    }

    public func start() {
        isRunning = true
    }

    public func stop() {
        isRunning = false
    }

    public func update(deltaTime: Double) {
        guard isRunning else { return }

        stateLock.lock()
        defer { stateLock.unlock() }

        let now = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)

        let breathOffset = Float(sin(Date().timeIntervalSince1970 * 1.5) * 0.005)
        let swayOffset = Float(cos(Date().timeIntervalSince1970 * 0.7) * 0.003)

        if var head = trackers[.head] {
            head.position.y = 1.6 + breathOffset
            head.position.x = swayOffset
            head.timestamp = now
            trackers[.head] = head
            currentPose.head = head.position
            currentPose.headOrientation = head.orientation
        }

        if var waist = trackers[.waist] {
            waist.position.y = 0.9 + breathOffset * 0.5
            waist.position.x = swayOffset * 0.5
            waist.timestamp = now
            trackers[.waist] = waist
            currentPose.waist = waist.position
            currentPose.waistOrientation = waist.orientation
        }

        if var chest = trackers[.chest] {
            chest.position.y = 1.2 + breathOffset * 0.8
            chest.timestamp = now
            trackers[.chest] = chest
            currentPose.chest = chest.position
            currentPose.chestOrientation = chest.orientation
        }

        if var leftHand = trackers[.leftHand] {
            leftHand.position.y = 1.0 + breathOffset
            leftHand.timestamp = now
            trackers[.leftHand] = leftHand
            currentPose.leftHand = leftHand.position
            currentPose.leftHandOrientation = leftHand.orientation
        }

        if var rightHand = trackers[.rightHand] {
            rightHand.position.y = 1.0 + breathOffset
            rightHand.timestamp = now
            trackers[.rightHand] = rightHand
            currentPose.rightHand = rightHand.position
            currentPose.rightHandOrientation = rightHand.orientation
        }

        currentPose.timestamp = now
        currentPose.confidence = 1.0
    }

    public func setTrackerPosition(_ position: SIMD3<Float>, for role: TrackerRole) {
        stateLock.lock()
        defer { stateLock.unlock() }

        if var tracker = trackers[role] {
            tracker.position = position
            tracker.timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
            trackers[role] = tracker
        }
    }

    public func setTrackerOrientation(_ orientation: simd_quatf, for role: TrackerRole) {
        stateLock.lock()
        defer { stateLock.unlock() }

        if var tracker = trackers[role] {
            tracker.orientation = orientation
            tracker.timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
            trackers[role] = tracker
        }
    }

    public func getTrackerState(for role: TrackerRole) -> TrackerState? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return trackers[role]
    }

    public func getAllTrackerStates() -> [TrackerState] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Array(trackers.values)
    }

    public func getCurrentPose() -> BodyTrackingPose {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentPose
    }

    public func setBodyPose(_ pose: BodyTrackingPose) {
        stateLock.lock()
        defer { stateLock.unlock() }

        currentPose = pose

        if let headPos = getPositionForRole(.head, from: pose) {
            trackers[.head]?.position = headPos
        }
        if let leftHandPos = getPositionForRole(.leftHand, from: pose) {
            trackers[.leftHand]?.position = leftHandPos
        }
        if let rightHandPos = getPositionForRole(.rightHand, from: pose) {
            trackers[.rightHand]?.position = rightHandPos
        }
        if let waistPos = getPositionForRole(.waist, from: pose) {
            trackers[.waist]?.position = waistPos
        }
        if let leftFootPos = getPositionForRole(.leftFoot, from: pose) {
            trackers[.leftFoot]?.position = leftFootPos
        }
        if let rightFootPos = getPositionForRole(.rightFoot, from: pose) {
            trackers[.rightFoot]?.position = rightFootPos
        }
    }

    private func getPositionForRole(_ role: TrackerRole, from pose: BodyTrackingPose) -> SIMD3<Float>? {
        switch role {
        case .head: return pose.head
        case .leftHand: return pose.leftHand
        case .rightHand: return pose.rightHand
        case .waist: return pose.waist
        case .leftFoot: return pose.leftFoot
        case .rightFoot: return pose.rightFoot
        case .chest: return pose.chest
        default: return nil
        }
    }
}
