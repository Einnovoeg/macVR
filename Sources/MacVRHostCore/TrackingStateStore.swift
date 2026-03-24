import Foundation
import MacVRProtocol
import simd

public enum TrackingStateStoreError: Error {
    case invalidPose(String)
}

extension TrackingStateStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPose(let message):
            return message
        }
    }
}

/// Fixed-layout head-pose snapshot shared between the Swift runtime services and
/// the C OpenXR shim. The format is intentionally tiny and append-free so the
/// writer can replace the whole file atomically on every pose update.
public struct TrackingStateRecord: Sendable {
    public let updatedTimeNs: UInt64
    public let headPositionMeters: SIMD3<Float>
    public let headOrientationQuaternion: SIMD4<Float>

    public init(updatedTimeNs: UInt64, headPositionMeters: SIMD3<Float>, headOrientationQuaternion: SIMD4<Float>) {
        self.updatedTimeNs = updatedTimeNs
        self.headPositionMeters = headPositionMeters
        self.headOrientationQuaternion = headOrientationQuaternion
    }
}

public final class TrackingStateStore: @unchecked Sendable {
    public static let magic: UInt32 = 0x4D54_5331 // "MTS1"
    public static let version: UInt32 = 1
    public static let headPoseValidFlag: UInt32 = 1 << 0
    public static let staleAfterNs: UInt64 = 2_000_000_000
    public static let environmentVariable = "MACVR_TRACKING_STATE_PATH"
    public static let encodedByteCount = 56

    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    /// Match the OpenXR runtime shim's fallback lookup path so the host/runtime
    /// process and the loader-driven game process agree without extra setup.
    public static func suggestedPath(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("macVR", isDirectory: true)
            .appendingPathComponent("tracking-state-v1.bin", isDirectory: false)
    }

    public func updateHeadPose(_ pose: PosePayload) throws {
        try write(record: Self.record(from: pose))
    }

    public func write(record: TrackingStateRecord) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.encode(record: record).write(to: path, options: .atomic)
    }

    public static func record(from pose: PosePayload) throws -> TrackingStateRecord {
        guard pose.positionMeters.count == 3 else {
            throw TrackingStateStoreError.invalidPose("Pose position must contain exactly 3 elements")
        }
        guard pose.orientationQuaternion.count == 4 else {
            throw TrackingStateStoreError.invalidPose("Pose orientation must contain exactly 4 elements")
        }

        let position = SIMD3(
            Float(pose.positionMeters[0]),
            Float(pose.positionMeters[1]),
            Float(pose.positionMeters[2])
        )
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite else {
            throw TrackingStateStoreError.invalidPose("Pose position must contain finite values")
        }
        let orientation = try normalizedQuaternion(from: pose.orientationQuaternion)

        return TrackingStateRecord(
            updatedTimeNs: pose.timestampNs,
            headPositionMeters: position,
            headOrientationQuaternion: orientation
        )
    }

    /// OpenXR consumers expect a unit quaternion. Normalize at the file-writing
    /// boundary so every reader sees a stable orientation even if a client sends
    /// an approximate or slightly denormalized value.
    private static func normalizedQuaternion(from source: [Double]) throws -> SIMD4<Float> {
        let quaternion = SIMD4(
            Float(source[0]),
            Float(source[1]),
            Float(source[2]),
            Float(source[3])
        )
        guard quaternion.x.isFinite, quaternion.y.isFinite, quaternion.z.isFinite, quaternion.w.isFinite else {
            throw TrackingStateStoreError.invalidPose("Pose orientation must contain finite values")
        }

        let magnitudeSquared = simd_length_squared(quaternion)
        guard magnitudeSquared > Float.ulpOfOne else {
            throw TrackingStateStoreError.invalidPose("Pose orientation quaternion must not be zero-length")
        }
        return quaternion / sqrt(magnitudeSquared)
    }

    public static func encode(record: TrackingStateRecord) -> Data {
        var data = Data(capacity: encodedByteCount)
        data.appendLittleEndian(magic)
        data.appendLittleEndian(version)
        data.appendLittleEndian(record.updatedTimeNs)
        data.appendLittleEndian(headPoseValidFlag)
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(record.headPositionMeters.x)
        data.appendLittleEndian(record.headPositionMeters.y)
        data.appendLittleEndian(record.headPositionMeters.z)
        data.appendLittleEndian(Float(0))
        data.appendLittleEndian(record.headOrientationQuaternion.x)
        data.appendLittleEndian(record.headOrientationQuaternion.y)
        data.appendLittleEndian(record.headOrientationQuaternion.z)
        data.appendLittleEndian(record.headOrientationQuaternion.w)
        return data
    }

    public static func decode(_ data: Data) -> TrackingStateRecord? {
        guard data.count >= encodedByteCount else {
            return nil
        }
        guard data.readUInt32LE(at: 0) == magic else {
            return nil
        }
        guard data.readUInt32LE(at: 4) == version else {
            return nil
        }
        let flags = data.readUInt32LE(at: 16)
        guard (flags & headPoseValidFlag) != 0 else {
            return nil
        }
        return TrackingStateRecord(
            updatedTimeNs: data.readUInt64LE(at: 8),
            headPositionMeters: SIMD3(
                data.readFloat32LE(at: 24),
                data.readFloat32LE(at: 28),
                data.readFloat32LE(at: 32)
            ),
            headOrientationQuaternion: SIMD4(
                data.readFloat32LE(at: 40),
                data.readFloat32LE(at: 44),
                data.readFloat32LE(at: 48),
                data.readFloat32LE(at: 52)
            )
        )
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(bytes.bindMemory(to: UInt8.self))
        }
    }

    mutating func appendLittleEndian(_ value: Float) {
        appendLittleEndian(value.bitPattern)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func readUInt64LE(at offset: Int) -> UInt64 {
        UInt64(self[offset])
            | (UInt64(self[offset + 1]) << 8)
            | (UInt64(self[offset + 2]) << 16)
            | (UInt64(self[offset + 3]) << 24)
            | (UInt64(self[offset + 4]) << 32)
            | (UInt64(self[offset + 5]) << 40)
            | (UInt64(self[offset + 6]) << 48)
            | (UInt64(self[offset + 7]) << 56)
    }

    func readFloat32LE(at offset: Int) -> Float {
        Float(bitPattern: readUInt32LE(at: offset))
    }
}
