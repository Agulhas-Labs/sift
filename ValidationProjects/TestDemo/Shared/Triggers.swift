import Foundation

/// Sentinel-file triggers read by the demo's test targets, since `xcodebuild` does not forward the invoking shell's environment to the test process and a trigger cannot be an environment variable.
///
/// It has to be a file `gates.sh` (or a hand-run `touch`) leaves behind, found through the compile-time `#filePath` of the caller rather than any assumption about the current working directory a test runs with.
struct Triggers {
    /// Whether the named trigger file exists in `.triggers`, resolved from `callerFilePath` (defaulting to the call site's own `#filePath`) by walking up to the `TestDemo` directory.
    static func isSet(_ name: String, callerFilePath: String = #filePath) -> Bool {
        FileManager.default.fileExists(atPath: triggersDirectory(from: callerFilePath).appendingPathComponent(name).path)
    }

    /// Creates the named trigger file, used by tests that record their own attempts (`fail-once`).
    static func set(_ name: String, callerFilePath: String = #filePath) {
        FileManager.default.createFile(atPath: triggersDirectory(from: callerFilePath).appendingPathComponent(name).path, contents: nil)
    }

    private static func triggersDirectory(from callerFilePath: String) -> URL {
        var directory = URL(fileURLWithPath: callerFilePath).deletingLastPathComponent()
        while directory.lastPathComponent != "TestDemo", directory.pathComponents.count > 1 {
            directory = directory.deletingLastPathComponent()
        }
        return directory.appendingPathComponent(".triggers")
    }
}
