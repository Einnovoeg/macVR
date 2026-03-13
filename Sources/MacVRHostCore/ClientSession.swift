import Foundation
import MacVRProtocol
import Network

final class ClientSession: @unchecked Sendable {
    private let sessionID: String
    private let destinationHost: NWEndpoint.Host
    private let destinationPort: NWEndpoint.Port
    private let streamMode: StreamMode
    private let frameIntervalNs: UInt64
    private let frameSource: any FrameSource
    private let maxPacketSize: Int
    private let logger: HostLogger
    private let queue: DispatchQueue
    private let udpConnection: NWConnection

    private var frameTimer: DispatchSourceTimer?
    private var frameIndex: UInt64 = 0
    private var latestPose: PosePayload?

    init(
        sessionID: String,
        destinationHost: NWEndpoint.Host,
        destinationPort: UInt16,
        targetFPS: Int,
        streamMode: StreamMode,
        frameTag: String,
        bridgeFrameStore: BridgeFrameStore?,
        maxPacketSize: Int,
        bridgeMaxFrameAgeMs: Int,
        displayID: UInt32?,
        jpegQuality: Int,
        logger: HostLogger
    ) {
        guard let port = NWEndpoint.Port(rawValue: destinationPort) else {
            preconditionFailure("Invalid destination port \(destinationPort)")
        }

        self.sessionID = sessionID
        self.destinationHost = destinationHost
        self.destinationPort = port
        self.streamMode = streamMode
        self.frameIntervalNs = HostConfiguration.frameIntervalNanoseconds(targetFPS: targetFPS)
        self.frameSource = FrameSourceFactory.make(
            streamMode: streamMode,
            frameTag: frameTag,
            bridgeFrameStore: bridgeFrameStore,
            bridgeMaxFrameAgeMs: bridgeMaxFrameAgeMs,
            displayID: displayID,
            jpegQuality: jpegQuality,
            logger: logger
        )
        self.maxPacketSize = HostConfiguration.clampPacketSize(maxPacketSize)
        self.logger = logger
        self.queue = DispatchQueue(label: "macvr.host.session.\(sessionID)")
        self.udpConnection = NWConnection(host: destinationHost, port: port, using: .udp)
        self.udpConnection.stateUpdateHandler = { [weak self] state in
            self?.handleUDPState(state)
        }
        self.udpConnection.start(queue: self.queue)
    }

    func startStreaming() {
        queue.async {
            guard self.frameTimer == nil else {
                return
            }

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            let repeating = max(Int(self.frameIntervalNs), 1)
            timer.schedule(
                deadline: .now() + .milliseconds(20),
                repeating: .nanoseconds(repeating),
                leeway: .milliseconds(2)
            )
            timer.setEventHandler { [weak self] in
                self?.emitFrame()
            }
            self.frameTimer = timer
            timer.resume()
            self.logger.log(
                .info,
                "Started \(self.streamMode.rawValue) stream session \(self.sessionID) -> \(self.destinationHost):\(self.destinationPort.rawValue)"
            )
        }
    }

    func updatePose(_ pose: PosePayload) {
        queue.async {
            self.latestPose = pose
        }
    }

    func stop() {
        queue.async {
            self.frameTimer?.setEventHandler {}
            self.frameTimer?.cancel()
            self.frameTimer = nil
            self.udpConnection.cancel()
            self.logger.log(.info, "Stopped session \(self.sessionID)")
        }
    }

    private func emitFrame() {
        frameIndex &+= 1

        let sentTimeNs = DispatchTime.now().uptimeNanoseconds
        guard let frame = frameSource.makeFrame(
            sessionID: sessionID,
            frameIndex: frameIndex,
            sentTimeNs: sentTimeNs,
            predictedDisplayTimeNs: sentTimeNs + frameIntervalNs,
            pose: latestPose
        ) else {
            return
        }

        do {
            let packets = try FrameChunkPacketizer.packetize(
                codec: frame.codec,
                flags: frame.flags,
                frameIndex: frameIndex,
                sentTimeNs: sentTimeNs,
                payload: frame.payload,
                maxPacketSize: maxPacketSize
            )

            for (index, packetData) in packets.enumerated() {
                let completion: NWConnection.SendCompletion
                if index == packets.count - 1 {
                    completion = .contentProcessed { [weak self] error in
                        guard let self else {
                            return
                        }
                        if let error {
                            self.logger.log(.warning, "UDP send failed for session \(self.sessionID): \(error)")
                        }
                    }
                } else {
                    completion = .idempotent
                }
                udpConnection.send(content: packetData, completion: completion)
            }
        } catch {
            logger.log(.error, "Failed to packetize frame for \(sessionID): \(error)")
        }
    }

    private func handleUDPState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            logger.log(
                .debug,
                "UDP path ready for session \(sessionID) (\(destinationHost):\(destinationPort.rawValue))"
            )
        case .failed(let error):
            logger.log(.warning, "UDP path failed for session \(sessionID): \(error)")
        case .cancelled:
            logger.log(.debug, "UDP path cancelled for session \(sessionID)")
        default:
            break
        }
    }
}
