//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the contract around the wrapped process: its exit code, its raw log, and passing it through untouched.
///
/// These run real subprocesses. The filtered path is driven by a shell script named `swift`, which is enough because recognition reads the command's name — that keeps the assertions about this tool rather than about how fast the toolchain is today.
@Suite(.temporaryDirectories)
struct RunLaunchTests {
    @Test
    func theWrappedCommandsExitCodeIsWhatComesBack() throws {
        let root = try TestSources.makeTempDirectory()

        let outcome = try RunLauncher(workingDirectory: root).run(["sh", "-c", "exit 42"])

        #expect(outcome.exitCode == 42)
        #expect(outcome.kind == .unrecognized)
    }

    @Test
    func aCommandKilledBySignalReportsTheShellsCode() throws {
        let root = try TestSources.makeTempDirectory()

        let outcome = try RunLauncher(workingDirectory: root).run(["sh", "-c", "kill -TERM $$"])

        // 128 + SIGTERM, which is what a shell would have reported for the same death.
        #expect(outcome.exitCode == 143)
    }

    /// The wrapped command is the caller's own, run exactly as their shell would have run it — `sift run` scrubs nothing from it and adds nothing to it, `GIT_OPTIONAL_LOCKS` included.
    ///
    /// Forcing it off would mask a regression in the wrapped command's own git usage under a green `sift run`, which is what sift's own pre-push gate is.
    @Test
    func theWrappedCommandSeesGitOptionalLocksExactlyAsTheCallerHadIt() throws {
        let root = try TestSources.makeTempDirectory()
        var forwarded = Data()

        _ = try RunLauncher(workingDirectory: root).run(
            ["sh", "-c", "echo \"[$GIT_OPTIONAL_LOCKS]\""],
            passingThrough: { forwarded.append($0) },
            environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""]
        )

        let text = try #require(String(bytes: forwarded, encoding: .utf8))

        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "[]", "the wrapped command must see GIT_OPTIONAL_LOCKS unset when the caller had it unset")
    }

    @Test
    func anUnrecognizedCommandIsHandedStraightBack() throws {
        let root = try TestSources.makeTempDirectory()
        var forwarded = Data()

        let outcome = try RunLauncher(workingDirectory: root).run(
            ["sh", "-c", "printf 'on stdout\\n'; printf 'on stderr\\n' >&2"],
            passingThrough: { forwarded.append($0) }
        )

        #expect(outcome.report == nil)
        #expect(outcome.exitCode == 0)
        let text = try #require(String(bytes: forwarded, encoding: .utf8))
        #expect(text.contains("on stdout"))
        #expect(text.contains("on stderr"))
    }

    @Test
    func theRawOutputIsKeptUnderTheWorkingDirectory() throws {
        let root = try TestSources.makeTempDirectory()

        let outcome = try RunLauncher(workingDirectory: root).run(["sh", "-c", "printf 'kept verbatim\\n'"])

        let log = try #require(outcome.log)
        let runs = root.appendingPathComponent(".sift/runs")

        #expect(log.url.deletingLastPathComponent().path == runs.path)
        #expect(log.url.lastPathComponent.hasPrefix("run-"))
        #expect(log.url.pathExtension == "log")
        #expect(try String(bytes: #require(log.contents()), encoding: .utf8) == "kept verbatim\n")
    }

    /// Two runs of one repository at the same moment must each be able to point at their own transcript.
    ///
    /// A single fixed path makes the receipt a lie: the slow run's answer names a file holding the fast run's bytes, and the fail-open branch stands ready to print another run's build log as this one's. Parallel sessions in one repo are the assumed norm here, not an edge case, so this drives two genuinely overlapping runs rather than two sequential ones.
    @Test
    func overlappingRunsEachNameTheirOwnTranscript() async throws {
        let root = try TestSources.makeTempDirectory()
        // The slow one starts first and finishes last, so its window strictly contains the fast one's. Each
        // task reports only its receipt — the path its answer would name, and what stands at that path.
        async let slow = Task.detached { try Self.receipt(of: "printf 'alpha\\n'; sleep 1", in: root) }.value
        async let fast = Task.detached {
            try await Task.sleep(nanoseconds: 200_000_000)
            return try Self.receipt(of: "printf 'beta\\n'", in: root)
        }.value
        let (slowReceipt, fastReceipt) = try await (slow, fast)

        #expect(slowReceipt.path != fastReceipt.path)
        #expect(slowReceipt.contents == "alpha\n")
        #expect(fastReceipt.contents == "beta\n")
    }

    /// The transcripts are bounded: a repo built all day does not accumulate an xcodebuild log per run forever.
    @Test
    func onlyTheMostRecentTranscriptsAreKept() throws {
        let root = try TestSources.makeTempDirectory()
        let launcher = RunLauncher(workingDirectory: root)
        var served: [URL] = []
        for index in 1 ... (RunLog.keptLogs + 3) {
            try served.append(#require(launcher.run(["sh", "-c", "printf 'run \(index)\\n'"]).log).url)
        }

        let runs = root.appendingPathComponent(".sift/runs")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: runs.path)

        #expect(remaining.count == RunLog.keptLogs)
        // The newest survive, and the last answer's receipt is still a path that resolves.
        #expect(Set(remaining) == Set(served.suffix(RunLog.keptLogs).map(\.lastPathComponent)))
    }

    /// A run still writing its transcript must survive every pruning that happens inside its lifetime.
    ///
    /// The shape neither test above reaches. `overlappingRunsEachNameTheirOwnTranscript` drives two runs, and `onlyTheMostRecentTranscriptsAreKept` drives its runs one after another — but the log being written is by construction the *oldest* file in the directory, so it takes ``RunLog/keptLogs`` completions inside one slow run's window to push it over the edge. Unguarded, that unlinks an `xcodebuild test`'s transcript while its handle goes on appending to the orphaned inode, and the fail-open path — the one that must hand back the raw log when the filter cannot explain a failure — then serves nothing at all, under a message blaming a write that never failed.
    @Test
    func aRunInFlightSurvivesEveryPruningItsLifetimeContains() async throws {
        let root = try TestSources.makeTempDirectory()
        // Verdict-only, so the answer has to come from the raw log or not at all.
        let transcript = """
        Testing started
        Testing failed:
        \tTest runner exited before starting test execution.
        ** TEST FAILED **

        """
        let swift = try Self.fakeTool(in: root, printing: transcript, exiting: 65, holdingOpenFor: 3)

        async let slow = Task.detached { try Self.failOpenReceipt(of: swift, in: root) }.value
        try await Task.sleep(nanoseconds: 300_000_000)
        for index in 1 ... RunLog.keptLogs {
            _ = try RunLauncher(workingDirectory: root).run(["sh", "-c", "printf 'quick \(index)\\n'"])
        }
        let receipt = try await slow

        #expect(receipt.filteredAnswer == nil)
        #expect(receipt.survives)
        let raw = try #require(receipt.raw)
        #expect(raw.contains("Test runner exited before starting test execution."))
        // Its own bytes, not a neighbour's: the receipt names one file and that file holds this run.
        #expect(!raw.contains("quick"))
    }

    /// The temporary fallback is bounded the same way the in-repo directory is.
    ///
    /// It is the branch nobody looks at — a repo whose `.sift/` cannot be written keeps working, and every one of its transcripts lands among the machine's temporary files under a name of its own. A single fixed path would limit itself by accident and per-run names do not, so the bound has to be stated here too.
    @Test
    func theTemporaryFallbackIsBoundedToo() throws {
        let root = try TestSources.makeTempDirectory()
        // A plain file where the cache directory would go, so the in-repo branch cannot be created at all.
        try "not a directory".write(to: root.appendingPathComponent(".sift"), atomically: true, encoding: .utf8)
        let temporary = try TestSources.makeTempDirectory()

        var served: [URL] = []
        for index in 1 ... (RunLog.keptLogs + 3) {
            let log = try #require(RunLog.open(inDirectory: root, fallingBackTo: temporary))
            log.append(Data("run \(index)\n".utf8))
            log.close()
            served.append(log.url)
        }

        #expect(served.allSatisfy { $0.lastPathComponent.hasPrefix("sift-run-") })
        let remaining = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
        #expect(remaining.count == RunLog.keptLogs)
        #expect(Set(remaining) == Set(served.suffix(RunLog.keptLogs).map(\.lastPathComponent)))
    }

    /// A transcript orphaned by a run that died mid-write costs a day of disk, not forever — and a live one is never in range.
    ///
    /// The price of making "never prune a live run" structural: an unfinished transcript is exempt from the count, so the only thing that can ever reclaim one is age. A day is far longer than any real run, which is what keeps the two cases apart without asking whether a process is still alive.
    @Test
    func anAbandonedTranscriptGoesByAgeWhileAFreshOneStays() throws {
        let root = try TestSources.makeTempDirectory()
        try "not a directory".write(to: root.appendingPathComponent(".sift"), atomically: true, encoding: .utf8)
        let temporary = try TestSources.makeTempDirectory()
        let abandoned = try Self.part(named: "sift-run-20260101-000000-deadbeef", in: temporary, age: RunLog.abandonedPartAge + 60)
        let live = try Self.part(named: "sift-run-20260818-101503-4f2a91c7", in: temporary, age: 60)

        try #require(RunLog.open(inDirectory: root, fallingBackTo: temporary)).close()

        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: live.path))
    }

    /// `run` writes into `.sift/` without ever building an engine, so it has to carry the engine's ignore coverage with it — and it reports the repository it found on the way.
    ///
    /// The root is not incidental: it is the only thing that files this run under a repository in `run.jsonl`, and therefore the only thing `usage --root` can scope a run by.
    @Test
    func aRunExcludesTheCacheFromAnUnindexedRepository() throws {
        let root = try TestSources.makeTempRepo()

        let outcome = try RunLauncher(workingDirectory: root).run(["sh", "-c", "printf 'built\\n'"])

        // Compared canonically because a temporary directory is reached through a symlink on macOS
        // (`/tmp` → `/private/tmp`), and `git rev-parse` answers with the resolved side.
        #expect(outcome.repositoryRoot.map { CanonicalPath.of($0.path) } == CanonicalPath.of(root.path))
        let exclude = try String(contentsOf: root.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        #expect(exclude.contains(".sift/"))
        // And git agrees, rather than the line merely existing in a file nothing consulted: `check-ignore`
        // exits nonzero when the path is not ignored, which `runGit` turns into a thrown failure.
        try TestSources.runGit(["check-ignore", "-q", ".sift/"], in: root)
    }

    /// The entry is written once: `ensureCacheExcluded` runs on every engine open and every wrapped run, and a file that gained a line each time would be someone else's `.git/info/exclude` growing without bound.
    @Test
    func anExcludeAlreadyNamingTheCacheIsNotWrittenAgain() throws {
        let root = try TestSources.makeTempRepo()
        let exclude = root.appendingPathComponent(".git/info/exclude")
        try "\(SiftPaths.directoryName)/\n".write(to: exclude, atomically: true, encoding: .utf8)

        GitContext(repoRoot: root).ensureCacheExcluded()

        let contents = try String(contentsOf: exclude, encoding: .utf8)

        #expect(contents.components(separatedBy: "\(SiftPaths.directoryName)/").count == 2, "the entry already there was written again")
    }

    /// An xcodebuild verdict is not an explanation, and a failure explained by nothing else must serve the raw log.
    ///
    /// The shape that would make Docs/Design.md §3 rule 4's fallback unreachable for the tool whose logs are longest: the runner dies before a single test runs, and the two lines that say so are not shapes the filter keeps.
    @Test
    func aFailureCarryingOnlyAVerdictServesNoFilteredAnswer() throws {
        let root = try TestSources.makeTempDirectory()
        let transcript = """
        Testing started
        Testing failed:
        \tTest runner exited before starting test execution.
        ** TEST FAILED **
        """
        let xcodebuild = try Self.fakeTool(in: root, named: "xcodebuild", printing: transcript + "\n", exiting: 65)

        let outcome = try RunLauncher(workingDirectory: root).run([xcodebuild.path, "test"])

        #expect(outcome.exitCode == 65)
        #expect(try #require(outcome.report).summaryLines == ["** TEST FAILED **"])
        #expect(outcome.filteredAnswer(workingDirectory: root) == nil)
        // And the fallback the caller reaches for has the lines the filter dropped.
        let logged = try #require(outcome.log?.contents())
        let raw = try #require(String(bytes: logged, encoding: .utf8))
        #expect(raw.contains("Test runner exited before starting test execution."))
    }

    /// A selected build failure with no `error:` line at all — the shape a build script's own non-zero exit leaves, with only `Testing cancelled because the build failed.` and the tab-indented `Testing failed:` summary — still serves no filtered answer, but the raw-output fallback it forces must not claim ignorance: the same fact that carries the headline on the filtered path is there to read regardless.
    @Test
    func aSelectedBuildFailureWithNoErrorLineStillNamesItselfInTheFallback() throws {
        let root = try TestSources.makeTempDirectory()
        let arguments = ["test", "--filter", "WidgetTests"]
        let transcript = """
        Testing cancelled because the build failed.

        Testing failed:
        \tThe following build commands failed:

        ** TEST FAILED **
        """
        let swift = try Self.fakeTool(in: root, printing: transcript + "\n", exiting: 65)

        let outcome = try RunLauncher(workingDirectory: root).run([swift.path] + arguments)
        let report = try #require(outcome.report)
        let selector = try #require(RunTestSelector.named(in: ["swift"] + arguments))

        #expect(report.errors.isEmpty)
        #expect(report.testFailures.isEmpty)
        #expect(!report.isUsable(exitCode: 65))
        #expect(outcome.filteredAnswer(workingDirectory: root, selector: selector) == nil)
        #expect(selector.ownExitCode(report, exitCode: 65) == RunTestSelector.didNotBuildExitCode)
        #expect(
            outcome.didNotBuildFallbackHeadline(selector: selector)
                == "✘ swift test — did not build — no test ran (the command exited 65; sift run exits 5)"
        )
    }

    @Test
    func theLogHoldsEverythingTheFilterDropped() throws {
        let root = try TestSources.makeTempDirectory()
        let swift = try Self.fakeTool(in: root, printing: TestSources.runOutput("swift-build-failure"), exiting: 1)

        let outcome = try RunLauncher(workingDirectory: root).run([swift.path, "build"])

        #expect(outcome.kind == .swiftBuild)
        #expect(outcome.exitCode == 1)
        let logged = try #require(outcome.log?.contents())
        let raw = try #require(String(bytes: logged, encoding: .utf8))
        #expect(raw.contains("[4/4] Compiling Widget Broken.swift"))
        let answer = try #require(outcome.filteredAnswer(workingDirectory: root))
        #expect(!answer.text.contains("[4/4] Compiling Widget Broken.swift"))
        #expect(answer.text.contains("error: cannot find 'missingSymbol' in scope"))
        // The number the run log files as this run's cost is the answer's own, and its receipt states it.
        let total = try #require(outcome.report).totalLines
        #expect(answer.text.contains("(\(total) lines in, \(answer.lines) out)"))
    }

    @Test
    func aFailureTheFilterCannotExplainServesNoFilteredAnswerAtAll() throws {
        let root = try TestSources.makeTempDirectory()
        let swift = try Self.fakeTool(in: root, printing: "nothing here resembles a diagnostic\n", exiting: 65)

        let outcome = try RunLauncher(workingDirectory: root).run([swift.path, "test"])

        #expect(outcome.exitCode == 65)
        #expect(outcome.report != nil)
        // The caller falls back to the raw log rather than reporting a failure with no cause.
        #expect(outcome.filteredAnswer(workingDirectory: root) == nil)
    }

    /// A build whose only `error:` line was its driver's own exit status has nothing left that explains it, so the whole raw log goes out.
    ///
    /// **The one rule that can make the output longer rather than shorter**, and it is the right answer rather than a regression: `error: <subcommand> command failed with exit code N` names no file, quotes no source, and reports an exit status `run` already passes through, so a report holding only that holds nothing — and a short answer over a nonzero exit is exactly what Docs/Design.md §3 rule 4 forbids. `sift help run-output` promises this where it says the line is dropped, and this is what holds the promise.
    @Test
    func aBuildExplainedOnlyByItsDriversExitStatusServesItsRawLog() throws {
        let root = try TestSources.makeTempDirectory()
        let transcript = """
        Building for debugging...
        [1/2] Compiling Widget Broken.swift
        error: emit-module command failed with exit code 1 (use -v to see invocation)

        """
        let swift = try Self.fakeTool(in: root, printing: transcript, exiting: 1)

        let outcome = try RunLauncher(workingDirectory: root).run([swift.path, "build"])
        let report = try #require(outcome.report)

        #expect(report.errors.isEmpty)
        #expect(!report.isUsable(exitCode: 1))
        #expect(outcome.filteredAnswer(workingDirectory: root) == nil)
        // And the transcript the caller falls back to still holds every line, the dropped one included.
        let logged = try #require(outcome.log?.contents())
        let raw = try #require(String(bytes: logged, encoding: .utf8))
        #expect(raw.contains("error: emit-module command failed with exit code 1"))
    }

    /// The key the launcher hands the run log names the action, where the kind that chose the filter names only the tool.
    ///
    /// The wiring neither half can be checked without: ``RunCommandKind/recognize(_:)`` reads the executable, which is all a filter needs and would file a build and a test under one word, and ``RunCommandKind/logKey(of:)`` reads the action beside it. Both runs below are the same kind, and everything downstream of the log depends on their keys differing.
    @Test
    func aWrappedRunFilesUnderTheActionItsArgvNamed() throws {
        let root = try TestSources.makeTempDirectory()
        let xcodebuild = try Self.fakeTool(in: root, named: "xcodebuild", printing: "** TEST SUCCEEDED **\n", exiting: 0)

        let testing = try RunLauncher(workingDirectory: root).run([xcodebuild.path, "-scheme", "Gizmo", "test"])
        let building = try RunLauncher(workingDirectory: root).run([xcodebuild.path, "-scheme", "Gizmo"])

        #expect(testing.kind == building.kind)
        #expect(testing.logKey == "xcodebuild test")
        #expect(building.logKey == "xcodebuild build")
    }

    @Test
    func nothingToRunIsTheOneRefusal() throws {
        let root = try TestSources.makeTempDirectory()

        #expect(throws: RunError.self) {
            _ = try RunLauncher(workingDirectory: root).run([])
        }
    }

    /// A `swift test` that offers no event-stream option is never handed one, whichever `swift` `PATH` would have found: the option is asked of the command the run starts, from its directory and with its environment.
    ///
    /// Named by path, and named bare but found on a `PATH` only the run's environment carries — each a `swift` this process's own `PATH` would never have asked. Given the option, it fails as an old toolchain does, so a run asked about the wrong `swift` exits 64 where it passed.
    @Test(arguments: [true, false])
    func aSwiftTestOfferingNoEventStreamRunsExactlyAsItDoesUnasked(namedByPath: Bool) throws {
        let root = try TestSources.makeTempDirectory()
        let toolchain = root.appendingPathComponent("toolchain", isDirectory: true)
        try FileManager.default.createDirectory(at: toolchain, withIntermediateDirectories: true)
        let transcript = toolchain.appendingPathComponent("transcript.txt")
        try """
        ◇ Test run started.
        ◇ Test one() started.
        ✔ Test one() passed after 0.001 seconds.
        ✔ Test run with 1 test in 1 suite passed after 0.001 seconds.

        """.write(to: transcript, atomically: true, encoding: .utf8)
        let swift = toolchain.appendingPathComponent("swift")
        try """
        #!/bin/sh
        for argument in "$@"; do
          case "$argument" in
            --event-stream-output-path*|--experimental-event-stream-output*) echo "error: Unknown option '$argument'" >&2; exit 64 ;;
            --help-hidden) echo "  --filter <filter>"; exit 0 ;;
          esac
        done
        cat '\(transcript.path)'
        exit 0

        """.write(to: swift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
        var environment = ProcessInfo.processInfo.environment
        if !namedByPath {
            environment["PATH"] = "\(toolchain.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        }
        let arguments = namedByPath ? [swift.path, "test"] : ["swift", "test"]
        let launcher = RunLauncher(workingDirectory: root)

        let asked = try launcher.run(arguments, environment: environment, readingEventStream: true)
        let unasked = try launcher.run(arguments, environment: environment)

        #expect(asked.exitCode == 0)
        #expect(asked.exitCode == unasked.exitCode)
        #expect(asked.report?.testOutcomes == unasked.report?.testOutcomes)
        #expect(asked.report?.eventStreamNote == nil)
        #expect(!FileManager.default.fileExists(atPath: SiftPaths.cache(in: root).appendingPathComponent("run-events").path))
    }

    /// A stream directory that cannot be made leaves the run exactly as it is unasked: no path is handed to a `swift test` that could not open it, so a passing run keeps its verdict.
    ///
    /// A regular file stands where the parent directory would be. The `swift test` here fails, as the real one does, when the stream path it is given cannot be written.
    @Test
    func aStreamDirectoryThatCannotBeMadeLeavesTheVerdictOfAPassingRunUnchanged() throws {
        let root = try TestSources.makeTempDirectory()
        let swift = root.appendingPathComponent("swift")
        try """
        #!/bin/sh
        while [ $# -gt 0 ]; do
          case "$1" in
            --help-hidden) echo "  --event-stream-output-path <path>"; exit 0 ;;
            --event-stream-output-path) : > "$2" || exit 1 ;;
          esac
          shift
        done
        echo "✔ Test run with 1 test in 1 suite passed after 0.001 seconds."
        exit 0

        """.write(to: swift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
        let cache = SiftPaths.cache(in: root)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try "in the way".write(to: cache.appendingPathComponent("run-events"), atomically: true, encoding: .utf8)
        let launcher = RunLauncher(workingDirectory: root)

        let asked = try launcher.run([swift.path, "test"], readingEventStream: true)
        let unasked = try launcher.run([swift.path, "test"])

        #expect(unasked.exitCode == 0)
        #expect(asked.exitCode == unasked.exitCode)
        #expect(asked.report?.eventStreamNote == nil)
    }

    /// Runs `script` under the wrapper and returns what its answer would say about the raw log.
    ///
    /// The path it names, and the bytes standing there — the two halves of the receipt that must belong to the same run.
    private static func receipt(
        of script: String,
        in root: URL,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> (path: String, contents: String) {
        let outcome = try RunLauncher(workingDirectory: root).run(["sh", "-c", script])
        let log = try #require(outcome.log, sourceLocation: sourceLocation)
        let contents = try #require(log.contents(), sourceLocation: sourceLocation)
        return try (log.url.path, #require(String(bytes: contents, encoding: .utf8), sourceLocation: sourceLocation))
    }

    /// Runs the fake `swift test` at `executable` and reports what its answer would have to stand on.
    private static func failOpenReceipt(
        of executable: URL,
        in root: URL,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> FailOpenReceipt {
        let outcome = try RunLauncher(workingDirectory: root).run([executable.path, "test"])
        let log = try #require(outcome.log, sourceLocation: sourceLocation)
        return FailOpenReceipt(
            filteredAnswer: outcome.filteredAnswer(workingDirectory: root).map(\.text),
            survives: FileManager.default.fileExists(atPath: log.url.path),
            raw: log.contents().flatMap { String(bytes: $0, encoding: .utf8) }
        )
    }

    /// An unfinished transcript standing in `directory`, created `age` seconds ago.
    private static func part(named name: String, in directory: URL, age: TimeInterval) throws -> URL {
        let url = directory.appendingPathComponent("\(name).log.part")
        try "half a run\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    /// A stand-in toolchain command that replays a captured transcript and exits with a chosen code.
    ///
    /// Named, because recognition and the run log's key are both read off argv: a script called `xcodebuild` is an `xcodebuild` invocation to everything under test here, with none of a real one's cost.
    ///
    /// `holdingOpenFor` keeps the process alive after the transcript is written, which is how a run of any real length is simulated without waiting on a real toolchain — the bytes are on disk while other runs come and go around it.
    private static func fakeTool(in directory: URL, named name: String = "swift", printing output: String, exiting code: Int32, holdingOpenFor seconds: Int = 0) throws -> URL {
        let payload = directory.appendingPathComponent("transcript.txt")
        try output.write(to: payload, atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent(name)
        let hold = seconds > 0 ? "sleep \(seconds)\n" : ""
        try "#!/bin/sh\ncat '\(payload.path)'\n\(hold)exit \(code)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}

private extension RunLaunchTests {
    /// What the fail-open path would find, as plain values that can cross a task boundary.
    ///
    /// A `RunLog` is a handle, not something to send, so the three things a caller would ask it are read on the far side and carried back: whether the filter had an answer, whether the file the receipt names is still there, and what stands in it.
    struct FailOpenReceipt: Sendable {
        let filteredAnswer: String?
        let survives: Bool
        let raw: String?
    }
}
