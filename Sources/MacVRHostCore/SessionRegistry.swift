import Foundation
import MacVRProtocol

final class SessionRegistry: @unchecked Sendable {
    private let queue = DispatchQueue(label: "macvr.host.registry")
    private var sessions: [UUID: ClientSession] = [:]

    func setSession(_ session: ClientSession, for connectionID: UUID) {
        queue.async {
            if let previous = self.sessions[connectionID] {
                previous.stop()
            }
            self.sessions[connectionID] = session
            session.startStreaming()
        }
    }

    func updatePose(_ pose: PosePayload, for connectionID: UUID) {
        queue.async {
            self.sessions[connectionID]?.updatePose(pose)
        }
    }

    func removeSession(for connectionID: UUID) {
        queue.async {
            guard let existing = self.sessions.removeValue(forKey: connectionID) else {
                return
            }
            existing.stop()
        }
    }

    func stopAll() {
        queue.async {
            for (_, session) in self.sessions {
                session.stop()
            }
            self.sessions.removeAll()
        }
    }
}
