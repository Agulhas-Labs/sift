//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// `sift run --without-line` on the one line that reads a binding, against a real package that builds with warnings as errors: the line is set aside as `_ = name`, so the run without it builds and the test fails an assertion — the proof — where commenting the line out left an unused value and a build that failed.
@Suite(.temporaryDirectories)
struct WithoutLineBindingRunTests {
    /// The test fails without the line and passes with it, and the file comes back byte for byte.
    @Test
    func aBindingOnlyTheSetAsideLineReadsStillBuildsAndTheTestFailsWithoutIt() throws {
        let root = try TemporaryDirectory.make("binding").appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = [
            "Package.swift": Self.manifest,
            ".gitignore": ".build/\n.sift/\n",
            "Sources/Gadget/Gadget.swift": Self.source,
            "Tests/GadgetTests/GadgetTests.swift": Self.tests,
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "test@example.com"], ["config", "user.name", "Tester"], ["add", "-A"], ["commit", "-q", "-m", "seed"]] {
            try RunWithoutCommandTests.git(arguments, in: root)
        }
        let number = try #require(Self.source.split(separator: "\n", omittingEmptySubsequences: false).firstIndex { $0.contains("settings = updated") }) + 1

        let result = try Self.sift(["run", "--without-line", "Sources/Gadget/Gadget.swift:\(number)", "--", "swift", "test", "--filter", "GadgetTests"], in: root)

        #expect(result.status == 0, "\(result.stdout)\(result.stderr)")
        #expect(result.stdout.hasPrefix("✔ 1 of 1 fails without Sources/Gadget/Gadget.swift:\(number) and passes with it\n"), "\(result.stdout)")
        #expect(result.stdout.contains("(set aside as `_ = updated` for the run without the change)"), "\(result.stdout)")
        #expect(!result.stdout.contains("never used"), "\(result.stdout)")
        #expect(try String(contentsOf: root.appendingPathComponent("Sources/Gadget/Gadget.swift"), encoding: .utf8) == Self.source)
    }

    /// `sift run --help` says a bare-name assignment is set aside as `_ = name`, and that the answer names the hand form.
    @Test
    func theDiscussionNamesTheUnderscoreForm() {
        let discussion = RunCommand.configuration.discussion.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        #expect(discussion.contains("A line that assigns one bare name (`settings = updated`) is set aside as `_ = updated` instead"), "\(discussion)")
        #expect(discussion.contains("the answer names that hand form"), "\(discussion)")
    }

    private static var manifest: String {
        """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "Gadget",
            targets: [
                .target(name: "Gadget", swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
                .testTarget(name: "GadgetTests", dependencies: ["Gadget"]),
            ]
        )

        """
    }

    private static var source: String {
        """
        public struct Gadget {
            public var settings = 1
            public init() {}

            public mutating func apply(_ proposal: Int?) {
                if let updated = proposal {
                    settings = updated
                }
            }
        }

        """
    }

    private static var tests: String {
        """
        @testable import Gadget
        import Testing

        struct GadgetTests {
            @Test
            func applies() {
                var gadget = Gadget()
                gadget.apply(5)
                #expect(gadget.settings == 5)
            }
        }

        """
    }

    private static func sift(_ arguments: [String], in root: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> RunWithoutCommandTests.Finished {
        let binary = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)", sourceLocation: sourceLocation)
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = root
        var environment = ProcessEnvironment.withoutGit()
        environment["SIFT_RUN_LOG"] = root.deletingLastPathComponent().appendingPathComponent("run.jsonl").path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let streams = ProcessStreams.drain(stdout: stdout, stderr: stderr)
        process.waitUntilExit()
        return RunWithoutCommandTests.Finished(
            status: process.terminationStatus,
            stdout: String(data: streams.output, encoding: .utf8) ?? "",
            stderr: String(data: streams.failure, encoding: .utf8) ?? ""
        )
    }
}
