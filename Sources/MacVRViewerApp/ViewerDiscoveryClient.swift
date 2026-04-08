import Darwin
import Foundation
import MacVRProtocol

struct DiscoveredRuntime: Identifiable, Sendable, Equatable {
    let host: String
    let serverName: String
    let controlPort: UInt16
    let bridgePort: UInt16
    let jpegInputPort: UInt16
    let supportedStreamModes: [StreamMode]
    let buildVersion: String
    let message: String

    var id: String {
        "\(host):\(controlPort)"
    }
}

enum ViewerDiscoveryClientError: Error {
    case invalidPort(UInt16)
    case socket(String)
}

extension ViewerDiscoveryClientError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Invalid discovery port: \(port)"
        case .socket(let message):
            return message
        }
    }
}

enum ViewerDiscoveryClient {
    static func discover(
        port: UInt16,
        clientName: String,
        requestedStreamMode: StreamMode?,
        timeoutSeconds: Double = 1.25
    ) throws -> [DiscoveredRuntime] {
        guard port > 0 else {
            throw ViewerDiscoveryClientError.invalidPort(port)
        }

        let socketFD = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else {
            throw ViewerDiscoveryClientError.socket("Failed to create discovery socket: \(String(cString: strerror(errno)))")
        }
        defer { Darwin.close(socketFD) }

        try configureSocket(socketFD)
        try bindEphemeralPort(socketFD)

        let requestID = UUID().uuidString.lowercased()
        let probe = RuntimeDiscoveryProbe(
            requestID: requestID,
            clientName: clientName,
            requestedStreamMode: requestedStreamMode
        )
        let payload = try WireCodec.encode(probe)

        try send(payload, toHost: "255.255.255.255", port: port, socketFD: socketFD)
        try send(payload, toHost: "127.0.0.1", port: port, socketFD: socketFD)

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var runtimes: [String: DiscoveredRuntime] = [:]
        var buffer = [UInt8](repeating: 0, count: 2048)

        while true {
            let remainingMs = Int(max(deadline.timeIntervalSinceNow, 0) * 1000.0)
            if remainingMs <= 0 {
                break
            }

            var pollDescriptor = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&pollDescriptor, 1, Int32(remainingMs))
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                throw ViewerDiscoveryClientError.socket("Discovery poll failed: \(String(cString: strerror(errno)))")
            }
            if pollResult == 0 {
                break
            }

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
            if bytesRead <= 0 {
                continue
            }

            let data = Data(buffer[0..<bytesRead])
            guard let announcement = try? WireCodec.decode(RuntimeDiscoveryAnnouncement.self, from: data) else {
                continue
            }
            guard announcement.protocolVersion == macVRProtocolVersion, announcement.requestID == requestID else {
                continue
            }
            guard let host = hostString(from: remoteStorage) else {
                continue
            }

            let runtime = DiscoveredRuntime(
                host: host,
                serverName: announcement.serverName,
                controlPort: announcement.controlPort,
                bridgePort: announcement.bridgePort,
                jpegInputPort: announcement.jpegInputPort,
                supportedStreamModes: announcement.supportedStreamModes,
                buildVersion: announcement.buildVersion,
                message: announcement.message
            )
            runtimes[runtime.id] = runtime
        }

        return runtimes.values.sorted {
            if $0.serverName == $1.serverName {
                return $0.host < $1.host
            }
            return $0.serverName.localizedCaseInsensitiveCompare($1.serverName) == .orderedAscending
        }
    }

    private static func configureSocket(_ socketFD: Int32) throws {
        var reuseAddress: Int32 = 1
        guard setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ViewerDiscoveryClientError.socket("Failed to set SO_REUSEADDR: \(String(cString: strerror(errno)))")
        }

        var allowBroadcast: Int32 = 1
        guard setsockopt(socketFD, SOL_SOCKET, SO_BROADCAST, &allowBroadcast, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ViewerDiscoveryClientError.socket("Failed to set SO_BROADCAST: \(String(cString: strerror(errno)))")
        }
    }

    private static func bindEphemeralPort(_ socketFD: Int32) throws {
        var address = sockaddr_in()
#if os(macOS)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
#endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw ViewerDiscoveryClientError.socket("Failed to bind discovery client socket: \(String(cString: strerror(errno)))")
        }
    }

    private static func send(_ payload: Data, toHost host: String, port: UInt16, socketFD: Int32) throws {
        var address = sockaddr_in()
#if os(macOS)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
#endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian

        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            throw ViewerDiscoveryClientError.socket("Invalid discovery destination host: \(host)")
        }

        let sentBytes = withUnsafePointer(to: &address) { pointer in
            payload.withUnsafeBytes { rawBuffer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                    Darwin.sendto(socketFD, rawBuffer.baseAddress, rawBuffer.count, 0, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sentBytes == payload.count else {
            throw ViewerDiscoveryClientError.socket("Failed to send discovery datagram to \(host):\(port): \(String(cString: strerror(errno)))")
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
