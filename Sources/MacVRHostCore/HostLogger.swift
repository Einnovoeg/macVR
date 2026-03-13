import Foundation

public enum HostLogLevel: String {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
    case debug = "DEBUG"
}

public final class HostLogger: @unchecked Sendable {
    private let lock = NSLock()
    private let verbose: Bool
    private let timestampFormatter: ISO8601DateFormatter

    public init(verbose: Bool) {
        self.verbose = verbose
        self.timestampFormatter = ISO8601DateFormatter()
        self.timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func log(_ level: HostLogLevel, _ message: String) {
        if level == .debug && !verbose {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        let timestamp = timestampFormatter.string(from: Date())
        print("[\(timestamp)] [\(level.rawValue)] \(message)")
        fflush(stdout)
    }
}
