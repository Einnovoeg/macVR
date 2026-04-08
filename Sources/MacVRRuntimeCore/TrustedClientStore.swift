import Foundation

public enum TrustedClientStoreError: Error {
    case invalidClientName
    case invalidHost
}

extension TrustedClientStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidClientName:
            return "Client name cannot be empty"
        case .invalidHost:
            return "Client host cannot be empty"
        }
    }
}

/// Persisted trust entry used by the runtime to allow known control-channel
/// clients when strict trust mode is enabled.
public struct TrustedClientRecord: Codable, Sendable, Equatable, Identifiable {
    public let clientName: String
    public let host: String
    public let firstTrustedAt: Date
    public let lastSeenAt: Date
    public let note: String?

    public var id: String {
        TrustedClientStore.identityKey(clientName: clientName, host: host)
    }

    public init(
        clientName: String,
        host: String,
        firstTrustedAt: Date,
        lastSeenAt: Date,
        note: String?
    ) {
        self.clientName = clientName
        self.host = host
        self.firstTrustedAt = firstTrustedAt
        self.lastSeenAt = lastSeenAt
        self.note = note
    }
}

private struct TrustedClientFile: Codable {
    let formatVersion: Int
    let generatedAt: Date
    let clients: [TrustedClientRecord]
}

/// JSON-backed trust database for runtime/client authorization. The file is
/// intentionally human-readable so users can audit and edit trusted identities
/// without reverse engineering binary state.
public final class TrustedClientStore: @unchecked Sendable {
    private let path: URL
    private let lock = NSLock()
    private var records: [String: TrustedClientRecord] = [:]

    public init(path: URL) {
        self.path = path
        self.records = Self.load(path: path)
    }

    public convenience init(path: String) {
        self.init(path: URL(fileURLWithPath: path))
    }

    public static func suggestedPath() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("macVR", isDirectory: true)
            .appendingPathComponent("trusted-clients-v1.json")
    }

    public func trustedClients() -> [TrustedClientRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records.values.sorted {
            if $0.clientName == $1.clientName {
                return $0.host.localizedCaseInsensitiveCompare($1.host) == .orderedAscending
            }
            return $0.clientName.localizedCaseInsensitiveCompare($1.clientName) == .orderedAscending
        }
    }

    public func trustedClientCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return records.count
    }

    public func isTrusted(clientName: String, host: String) -> Bool {
        let key = Self.identityKey(clientName: clientName, host: host)
        lock.lock()
        defer { lock.unlock() }
        return records[key] != nil
    }

    @discardableResult
    public func trust(clientName: String, host: String, note: String? = nil) throws -> TrustedClientRecord {
        let normalizedClientName = try Self.normalizeClientName(clientName)
        let normalizedHost = try Self.normalizeHost(host)
        let now = Date()
        let key = Self.identityKey(clientName: normalizedClientName, host: normalizedHost)

        lock.lock()
        defer { lock.unlock() }

        let firstTrustedAt = records[key]?.firstTrustedAt ?? now
        let record = TrustedClientRecord(
            clientName: normalizedClientName,
            host: normalizedHost,
            firstTrustedAt: firstTrustedAt,
            lastSeenAt: now,
            note: note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? note?.trimmingCharacters(in: .whitespacesAndNewlines)
                : records[key]?.note
        )
        records[key] = record
        try persistLocked()
        return record
    }

    @discardableResult
    public func untrust(clientName: String, host: String) throws -> Bool {
        let key = Self.identityKey(clientName: clientName, host: host)

        lock.lock()
        defer { lock.unlock() }

        guard records.removeValue(forKey: key) != nil else {
            return false
        }
        try persistLocked()
        return true
    }

    public func markSeen(clientName: String, host: String) throws {
        let key = Self.identityKey(clientName: clientName, host: host)

        lock.lock()
        defer { lock.unlock() }

        guard let existing = records[key] else {
            return
        }

        records[key] = TrustedClientRecord(
            clientName: existing.clientName,
            host: existing.host,
            firstTrustedAt: existing.firstTrustedAt,
            lastSeenAt: Date(),
            note: existing.note
        )
        try persistLocked()
    }

    fileprivate static func identityKey(clientName: String, host: String) -> String {
        let normalizedClient = (try? normalizeClientName(clientName))?.lowercased() ?? ""
        let normalizedHost = (try? normalizeHost(host))?.lowercased() ?? ""
        return "\(normalizedClient)@\(normalizedHost)"
    }

    private static func load(path: URL) -> [String: TrustedClientRecord] {
        guard let data = try? Data(contentsOf: path) else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(TrustedClientFile.self, from: data) else {
            return [:]
        }

        var map: [String: TrustedClientRecord] = [:]
        for entry in decoded.clients {
            map[identityKey(clientName: entry.clientName, host: entry.host)] = entry
        }
        return map
    }

    private func persistLocked() throws {
        let directory = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let file = TrustedClientFile(
            formatVersion: 1,
            generatedAt: Date(),
            clients: records.values.sorted {
                if $0.clientName == $1.clientName {
                    return $0.host.localizedCaseInsensitiveCompare($1.host) == .orderedAscending
                }
                return $0.clientName.localizedCaseInsensitiveCompare($1.clientName) == .orderedAscending
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(file)
        try encoded.write(to: path, options: .atomic)
    }

    private static func normalizeClientName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TrustedClientStoreError.invalidClientName
        }
        return trimmed
    }

    private static func normalizeHost(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TrustedClientStoreError.invalidHost
        }
        return trimmed
    }
}
