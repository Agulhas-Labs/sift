//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// What `sift run` keys on the checkout its command builds — a `--package-path`, `-C` or `-project` naming another repository — rather than the one it was started in.
@Suite(.temporaryDirectories)
struct RunBuiltCheckoutTests {
    /// A set-aside out of the checkout the command builds refuses the run as one out of the launching checkout does: what it would build is not the caller's code.
    @Test
    func aSetAsideOutOfTheBuiltCheckoutRefusesTheRun() throws {
        let launched = try RunWithoutCommandTests.Fixture()
        let built = try RunWithoutCommandTests.Fixture()
        _ = try SetAside.capture(pathspecs: ["Sources/"], from: built.root, into: SetAsideStore(repositoryRoot: built.root))
        let file = launched.root.appendingPathComponent("run.jsonl")
        var command = try RunCommand.parse(["--", "/usr/bin/true", "build", "--package-path", built.root.path])
        command.log = RunUsageLog(fileURL: file)
        command.writesUnder = launched.root

        #expect(throws: ExitCode.failure) {
            try command.run()
        }
        #expect(!FileManager.default.fileExists(atPath: file.path), "a refused run starts nothing and files nothing")
    }

    /// `--without` refuses a command that builds another checkout, or one it names through a variable, and touches nothing: its pathspec names files in the checkout it was started in, and setting those aside proves nothing about a build of another.
    @Test
    func withoutRefusesACommandThatBuildsAnotherCheckout() throws {
        let fixture = try RunWithoutCommandTests.Fixture()
        let other = try RunWithoutCommandTests.Fixture()
        let before = try fixture.snapshot()

        for (named, says) in [(other.root.path, "the command builds \(other.root.path), not the checkout"), ("$OTHER", "the command names the directory it builds through a variable")] {
            let result = try fixture.sift(["run", "--without", "Sources/", "--", "swift", "test", "--filter", "WidgetTests", "--package-path", named])

            #expect(result.status == 64, "\(result.stdout)\(result.stderr)")
            #expect(result.stderr.contains("sift run --without: \(says)"), "\(result.stderr)")
            #expect(try fixture.snapshot() == before)
            #expect(!fixture.recordExists)
        }
    }

    /// A test run of another checkout is filed for `flakes` under the tree it read, that checkout's, never the tree of the one `sift run` was started in.
    @Test
    func aTestRunOfAnotherCheckoutFilesThatCheckoutsTree() throws {
        let launched = try RunWithoutCommandTests.Fixture()
        let built = try RunWithoutCommandTests.Fixture()
        let swift = try Self.standIn("swift", in: launched)
        let file = launched.bin.appendingPathComponent("run.jsonl")
        var command = try RunCommand.parse(["--", swift.path, "test", "--package-path", built.root.path])
        command.log = RunUsageLog(fileURL: file)
        command.writesUnder = launched.root

        try command.run()
        let line = try #require(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").first)
        let recorded = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])

        let tree = try #require(recorded["tree"] as? String)

        #expect(tree == TreeContentHash.of(repositoryRoot: built.root))
    }

    /// `--coverage` of another checkout measures the change from a revision in that checkout's history, and says what it found there, never that the revision names no commit because it looked in the checkout `sift run` was started in.
    @Test
    func coverageOfAnotherCheckoutMeasuresFromThatCheckoutsHistory() throws {
        let launched = try RunWithoutCommandTests.Fixture()
        let built = try RunWithoutCommandTests.Fixture()
        let xcodebuild = try Self.xcodebuild(in: launched)
        let head = try built.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let bundle = launched.beside("unwritten.xcresult")
        let project = built.root.appendingPathComponent("Demo.xcodeproj").path

        let result = try launched.sift(["run", "--coverage", "--from", head, "--", xcodebuild.path, "-project", project, "test", "-resultBundlePath", bundle.path])

        #expect(result.stdout.contains("coverage: refused — this run left no result bundle at \(bundle.path)"), "\(result.stdout)\(result.stderr)")
        #expect(!result.stdout.contains("names no commit"), "\(result.stdout)")
    }

    /// `--coverage` of a command naming the directory it builds through a variable says in one line that it cannot be keyed to a checkout, rather than measuring the checkout `sift run` was started in.
    @Test
    func coverageOfACheckoutNamedThroughAVariableRefusesInOneLine() throws {
        let fixture = try RunWithoutCommandTests.Fixture()

        let result = try fixture.sift(["run", "--coverage", "--", "swift", "test", "--package-path", "$X"])
        let section = result.stdout.split(separator: "\n").filter { $0.hasPrefix("coverage:") }

        #expect(section == ["coverage: refused — the command names the directory it builds through a variable, so its coverage cannot be keyed to a checkout"], "\(result.stdout)\(result.stderr)")
    }

    /// A wrapped `xcodebuild test` of another checkout seeds that checkout's durations store, the one a sharded run of it plans from, and leaves the launching checkout's alone.
    @Test
    func aTestRunOfAnotherCheckoutSeedsThatCheckoutsDurations() throws {
        let launched = try RunWithoutCommandTests.Fixture()
        let built = try RunWithoutCommandTests.Fixture()
        let xcodebuild = try Self.xcodebuild(in: launched)
        let project = built.root.appendingPathComponent("Demo.xcodeproj").path

        let result = try launched.sift(["run", "--", xcodebuild.path, "-project", project, "test"])

        #expect(result.status == 0, "\(result.stdout)\(result.stderr)")
        #expect(TestDurationStore(repositoryRoot: built.root).median(for: "WidgetTests/WidgetTests/testOne()") == 1.5)
        #expect(TestDurationStore(repositoryRoot: launched.root).median(for: "WidgetTests/WidgetTests/testOne()") == nil)
    }

    /// `--proved` of a command naming the directory it builds through a variable says that is why it cannot tell, never that a run inside a repository is outside one, and still exits 2.
    @Test
    func provedOfACheckoutNamedThroughAVariableSaysSo() throws {
        let fixture = try RunWithoutCommandTests.Fixture()

        let result = try fixture.sift(["run", "--proved", "--", "swift", "test", "--package-path", "$X"])

        #expect(result.status == 2, "\(result.stdout)\(result.stderr)")
        #expect(result.stdout.contains("the question could not be put: the command names the directory it builds through a variable"), "\(result.stdout)")
        #expect(!result.stdout.contains("not a git repository"), "\(result.stdout)")
    }
}

private extension RunBuiltCheckoutTests {
    /// A stand-in `name` beside the fixture's repository that prints `output` and exits 0, so the run reads nothing of the tool it stands for.
    static func standIn(_ name: String, printing output: String = "", in fixture: RunWithoutCommandTests.Fixture) throws -> URL {
        let tool = fixture.root.deletingLastPathComponent().appendingPathComponent("tools").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\ncat <<'EOF'\n\(output)\nEOF\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    /// A stand-in `xcodebuild` that reports one passing test.
    static func xcodebuild(in fixture: RunWithoutCommandTests.Fixture) throws -> URL {
        try standIn("xcodebuild", printing: """
        Test Case '-[WidgetTests.WidgetTests testOne]' started.
        Test Case '-[WidgetTests.WidgetTests testOne]' passed (1.5 seconds).
        ** TEST SUCCEEDED **
        """, in: fixture)
    }
}
