import Foundation
import MacVRHostCore

/// Runtime trust gate used by `RuntimeService` to enforce optional trusted-client
/// policies without duplicating handshake logic inside `HostService`.
final class RuntimeTrustPolicy: @unchecked Sendable {
    private let requireTrustedClients: Bool
    private let autoTrustLoopbackClients: Bool
    private let trustedClientStore: TrustedClientStore
    private let logger: HostLogger
    private let lock = NSLock()

    private var deniedConnectionCount: UInt64 = 0

    init(
        requireTrustedClients: Bool,
        autoTrustLoopbackClients: Bool,
        trustedClientStore: TrustedClientStore,
        logger: HostLogger
    ) {
        self.requireTrustedClients = requireTrustedClients
        self.autoTrustLoopbackClients = autoTrustLoopbackClients
        self.trustedClientStore = trustedClientStore
        self.logger = logger
    }

    func authorize(_ identity: ClientIdentity) -> ClientAuthorizationDecision {
        let isLoopback = Self.isLoopbackHost(identity.remoteHost)

        if autoTrustLoopbackClients, isLoopback {
            do {
                if trustedClientStore.isTrusted(clientName: identity.clientName, host: identity.remoteHost) == false {
                    try trustedClientStore.trust(
                        clientName: identity.clientName,
                        host: identity.remoteHost,
                        note: "Auto-trusted loopback client"
                    )
                    logger.log(.info, "Auto-trusted local client \(identity.clientName) at \(identity.remoteHost)")
                } else {
                    try trustedClientStore.markSeen(clientName: identity.clientName, host: identity.remoteHost)
                }
            } catch {
                logger.log(.warning, "Failed to auto-trust loopback client: \(error.localizedDescription)")
            }
            return .allow
        }

        if requireTrustedClients == false {
            return .allow
        }

        if trustedClientStore.isTrusted(clientName: identity.clientName, host: identity.remoteHost) {
            do {
                try trustedClientStore.markSeen(clientName: identity.clientName, host: identity.remoteHost)
            } catch {
                logger.log(.warning, "Failed to update trusted-client lastSeen timestamp: \(error.localizedDescription)")
            }
            return .allow
        }

        lock.lock()
        deniedConnectionCount &+= 1
        lock.unlock()

        return .deny(
            reason: "Client \(identity.clientName) at \(identity.remoteHost) is not trusted. Add it with --trust-client '<client>@<host>' or disable --require-trusted-clients."
        )
    }

    func deniedCount() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return deniedConnectionCount
    }

    func trustedClientCount() -> Int {
        trustedClientStore.trustedClientCount()
    }

    func trustedClients() -> [TrustedClientRecord] {
        trustedClientStore.trustedClients()
    }

    @discardableResult
    func trust(clientName: String, host: String, note: String? = nil) throws -> TrustedClientRecord {
        try trustedClientStore.trust(clientName: clientName, host: host, note: note)
    }

    @discardableResult
    func untrust(clientName: String, host: String) throws -> Bool {
        try trustedClientStore.untrust(clientName: clientName, host: host)
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized == "localhost"
            || normalized == "::ffff:127.0.0.1"
    }
}
