import Foundation

public enum HostLogLevel: String {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
    case debug = "DEBUG"
}

public typealias HostLogSink = @Sendable (String) -> Void

public final class HostLogger: @unchecked Sendable {
    private let lock = NSLock()
    private let verbose: Bool
    private let timestampFormatter: ISO8601DateFormatter
    private let sink: HostLogSink?

    public init(verbose: Bool, sink: HostLogSink? = nil) {
        self.verbose = verbose
        self.sink = sink
        self.timestampFormatter = ISO8601DateFormatter()
        self.timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func log(_ level: HostLogLevel, _ message: String) {
        if level == .debug && !verbose {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        let line = "[\(timestampFormatter.string(from: Date()))] [\(level.rawValue)] \(message)"
        print(line)
        fflush(stdout)
        sink?(line)
    }
}
