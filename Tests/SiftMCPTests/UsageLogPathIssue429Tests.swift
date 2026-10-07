import Foundation
@testable import SiftMCP
import Testing

/// `SIFT_USAGE_LOG` redirects the log for the faces that read it as much as for those that write it.
@Suite(.temporaryDirectories) struct UsageLogPathIssue429Tests {
    @Test
    func usageReadsTheFileSIFTUSAGELOGNamesAndNamesItWhenItIsMissing() throws {
        let binary = try #require(BuiltExecutable.sift, "no `sift` built at \(BuiltExecutable.expected.path)")
        let home = try TemporaryDirectory.make("usage-429").appendingPathComponent("usage-429")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let missing = home.appendingPathComponent("redirected-429.jsonl")

        let process = Process()
        process.executableURL = binary
        process.arguments = ["usage", "--unredact"]
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home.path
        environment["SIFT_USAGE_LOG"] = missing.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let printed = try #require(String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
        process.waitUntilExit()

        #expect(printed.contains("redirected-429.jsonl is missing or empty"), "\(printed)")
        #expect(!printed.contains("~/.sift/usage.jsonl"))
    }

    /// The invariant: the shared log's path is composed in one place, ``UsageLog/standardFileURL(environment:)``, so a reader cannot resolve it differently from a writer.
    @Test
    func noCommandComposesTheUsageLogPathItself() throws {
        let sources = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let walker = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: Set<String> = []
        for case let file as URL in walker where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("appendingPathComponent(\"usage.jsonl\")") {
                offenders.insert(file.lastPathComponent)
            }
        }
        // `UsageLog` is the one resolver; `HookReplay` writes a log inside its own scratch directory, not the shared one.
        #expect(offenders == ["UsageLog.swift", "HookReplay.swift"], "\(offenders)")
    }
}
