import Foundation
import MacVRHostCore
import MacVRProtocol

/// Generates a loader manifest for the experimental OpenXR runtime shim that ships
/// with macVR. The manifest is intentionally minimal because the Khronos loader only
/// requires `file_format_version` and `runtime.library_path` for runtime discovery.
public enum OpenXRRuntimeManifest {
    private struct Root: Encodable {
        let fileFormatVersion: String
        let runtime: Runtime

        private enum CodingKeys: String, CodingKey {
            case fileFormatVersion = "file_format_version"
            case runtime
        }
    }

    private struct Runtime: Encodable {
        let libraryPath: String

        private enum CodingKeys: String, CodingKey {
            case libraryPath = "library_path"
        }
    }

    public static func suggestedManifestPath(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("openxr", isDirectory: true)
            .appendingPathComponent("1", isDirectory: true)
            .appendingPathComponent("active_runtime.json", isDirectory: false)
    }

    public static func suggestedTrackingStatePath(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        TrackingStateStore.suggestedPath(homeDirectory: homeDirectory).path
    }

    /// Resolve the runtime library next to whichever executable is currently
    /// driving the workflow. This keeps CLI builds, packaged binaries, and the
    /// bundled control-center app aligned without hard-coding machine-specific paths.
    public static func suggestedRuntimeLibraryPath(executablePath: String = CommandLine.arguments[0]) -> String {
        let executableURL = URL(fileURLWithPath: executablePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return executableURL
            .deletingLastPathComponent()
            .appendingPathComponent("libMacVROpenXRRuntime.dylib")
            .path
    }

    public static func makeJSON(libraryPath: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let root = Root(
            fileFormatVersion: "1.0.0",
            runtime: Runtime(libraryPath: libraryPath)
        )
        let data = try encoder.encode(root)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return json + "\n"
    }

    @discardableResult
    public static func writeManifest(to path: String, libraryPath: String) throws -> URL {
        let outputURL = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeJSON(libraryPath: libraryPath).write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    public static var statusSummary: String {
        "macVR \(macVRReleaseVersion) experimental OpenXR runtime shim"
    }
}
