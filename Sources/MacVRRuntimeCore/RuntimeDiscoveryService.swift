import Darwin
import Foundation
import MacVRHostCore
import MacVRProtocol

enum RuntimeDiscoveryServiceError: Error {
    case invalidPort(UInt16)
    case socket(String)
}

extension RuntimeDiscoveryServiceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Invalid discovery port: \(port)"
        case .socket(let message):
            return message
        }
    }
}

/// ALVR-style discovery seam for the bundled runtime. Viewers broadcast a small
/// probe packet and the runtime answers with the control ports and stream modes
/// needed to establish the real session over TCP/UDP.
final class RuntimeDiscoveryService: @unchecked Sendable {
    private let configuration: RuntimeConfiguration
    private let logger: HostLogger
    private let queue = DispatchQueue(label: "macvr.runtime.discovery")

    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?

    init(configuration: RuntimeConfiguration, logger: HostLogger) {
        self.configuration = configuration
        self.logger = logger
    }

    func start() throws {
        guard configuration.discoveryPort > 0 else {
            throw RuntimeDiscoveryServiceError.invalidPort(configuration.discoveryPort)
        }
        guard socketFD == -1 else {
            return
        }

        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            throw RuntimeDiscoveryServiceError.socket("Failed to create discovery socket: \(String(cString: strerror(errno)))")
        }

        do {
            try Self.configureSocket(fd)
            try Self.bindSocket(fd, port: configuration.discoveryPort)

            let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            readSource.setEventHandler { [weak self] in
                self?.handleReadableSocket()
            }
            readSource.setCancelHandler {
                Darwin.close(fd)
            }
            readSource.resume()

            socketFD = fd
            self.readSource = readSource
            logger.log(
                .info,
                "Runtime discovery listening on udp://0.0.0.0:\(configuration.discoveryPort) as '\(configuration.serverName)'"
            )
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        socketFD = -1
    }

    private func handleReadableSocket() {
        guard socketFD >= 0 else {
            return
        }

        var buffer = [UInt8](repeating: 0, count: 2048)

        while true {
            var remoteStorage = sockaddr_storage()
            var remoteLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let bytesRead = withUnsafeMutablePointer(to: &remoteStorage) { pointer in
                buffer.withUnsafeMutableBytes { rawBuffer in
                    Darwin.recvfrom(
                        socketFD,
                        rawBuffer.baseAddress,
                        rawBuffer.count,
                        0,
                        UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: sockaddr.self),
                        &remoteLength
                    )
                }
            }

            if bytesRead < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    break
                }
                logger.log(.warning, "Runtime discovery receive failed: \(String(cString: strerror(errno)))")
                break
            }

            guard bytesRead > 0 else {
                break
            }

            let payload = Data(buffer[0..<bytesRead])
            guard let probe = try? WireCodec.decode(RuntimeDiscoveryProbe.self, from: payload) else {
                continue
            }
            guard probe.protocolVersion == macVRProtocolVersion else {
                continue
            }

            let remoteHost = Self.hostString(from: remoteStorage) ?? "unknown"
            logger.log(.debug, "Runtime discovery probe from \(remoteHost), client=\(probe.clientName)")

            let announcement = RuntimeDiscoveryAnnouncement(
                requestID: probe.requestID,
                serverName: configuration.serverName,
                controlPort: configuration.controlPort,
                bridgePort: configuration.bridgePort,
                jpegInputPort: configuration.jpegInputPort,
                supportedStreamModes: [.bridgeJPEG, .displayJPEG, .mock],
                message: "macVR runtime available"
            )

            do {
                let encoded = try WireCodec.encode(announcement)
                _ = withUnsafePointer(to: &remoteStorage) { pointer in
                    encoded.withUnsafeBytes { rawBuffer in
                        Darwin.sendto(
                            socketFD,
                            rawBuffer.baseAddress,
                            rawBuffer.count,
                            0,
                            UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr.self),
                            remoteLength
                        )
                    }
                }
            } catch {
                logger.log(.warning, "Failed to encode discovery reply: \(error.localizedDescription)")
            }
        }
    }

    private static func configureSocket(_ fd: Int32) throws {
        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw RuntimeDiscoveryServiceError.socket("Failed to set SO_REUSEADDR: \(String(cString: strerror(errno)))")
        }

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw RuntimeDiscoveryServiceError.socket("Failed to set discovery socket nonblocking: \(String(cString: strerror(errno)))")
        }
    }

    private static func bindSocket(_ fd: Int32, port: UInt16) throws {
        var address = sockaddr_in()
#if os(macOS)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
#endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(fd, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw RuntimeDiscoveryServiceError.socket("Failed to bind discovery port \(port): \(String(cString: strerror(errno)))")
        }
    }

    private static func hostString(from storage: sockaddr_storage) -> String? {
        guard storage.ss_family == sa_family_t(AF_INET) else {
            return nil
        }

        var ipv4 = withUnsafePointer(to: storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &ipv4.sin_addr, &buffer, socklen_t(buffer.count)) != nil else {
            return nil
        }
        if let nullIndex = buffer.firstIndex(of: 0) {
            return String(decoding: buffer[..<nullIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return String(decoding: buffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
