//
// Copyright © Agulhas Labs
//

import CryptoKit
import Foundation

/// Best-effort, append-only JSONL record of `sift run` invocations — one line per wrapped command, in `~/.sift/run.jsonl`.
///
/// **Its own file, deliberately.** `usage.jsonl` means *index lookups*, whichever face served them, and every consumer inherits that meaning: the usage headline's call count, the savings sentence's "over N of M calls" denominator, the audit. A wrapped build is not a lookup, so writing a run there would silently restate all three numbers rather than adding one.
///
/// **What it is for** is the half a CLI wrapper otherwise leaves invisible: without it, a session that took every `run` suggestion looks exactly like one that ignored them. `sift usage` reports this log in a section of its own, which makes run adoption a measured number instead of an assumption.
///
/// Not to be confused with ``RunLog``, which is one run's raw transcript inside the repository being built. This is the durable per-user tally across every repository, and holds no output at all.
public struct RunUsageLog: Sendable {
    /// How many of a run's failing tests one line names before it stops naming them.
    ///
    /// A bound rather than a budget. The capture behind ``RunFailureShape`` reported 666 failures, and a line naming every one of them would put tens of kilobytes into a file that is appended to forever and never pruned — a few hundred lines of that is a log nobody can read. Fifty distinct names sits far above every ordinary red run and below the runs a per-test history could honestly use anyway: a gate that fails wholesale says something about the environment, not about one test.
    ///
    /// **Exceeding it is recorded, never silently trimmed.** The line also carries how many distinct names there were, so a reader can tell a run that named all of its failures from one that named some — and the second kind cannot be used to say a test did *not* fail, which is the whole reason the count is kept beside the names.
    public static let failedTestCap = 50

    /// How wide one recorded test name may be before the rest is left to the raw log.
    ///
    /// A test is normally named by its signature, but Swift Testing lets an author write a display name of any length and prints that instead — so a name is unbounded input like every other string this tool takes off a log. 120 characters clears the longest name in the corpus several times over, and a name that is cut ends in an ellipsis rather than stopping mid-word, because a truncated identifier that looks whole is one a reader will go and search for.
    public static let testNameCap = 120

    private let log: JSONLineLog

    public init(fileURL: URL, note: @escaping @Sendable (String) -> Void = { _ in }) {
        log = JSONLineLog(fileURL: fileURL, subject: "sift run: run log", note: note)
    }

    /// The shared per-user log, beside the usage log it deliberately is not part of.
    ///
    /// Named here rather than spelled out at each of the four places that reach for it — the writer, the advice ledger, `usage` and `report` — so the file cannot end up meaning one path to the thing that writes it and another to the things that read it.
    ///
    /// `SIFT_RUN_LOG` names another file, on `SIFT_SERVER_LOG`'s terms: what `run --without` does across a signal is only observable by driving the binary from outside, and a test doing that must not append runs of a throwaway repository to the record `flakes` and `usage` read.
    public static var standardFileURL: URL {
        standardFileURL(environment: ProcessInfo.processInfo.environment)
    }

    static func standardFileURL(environment: [String: String]) -> URL {
        if let path = environment["SIFT_RUN_LOG"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return SiftPaths.home(environment: environment).appendingPathComponent("run.jsonl")
    }

    public static func standard(note: @escaping @Sendable (String) -> Void = { _ in }) -> RunUsageLog {
        RunUsageLog(fileURL: standardFileURL, note: note)
    }

    /// Appends one line for this run; the line counts are written only where a filter ran *and* produced an answer.
    ///
    /// `shown` and `total` are the pair, not `shown` and `suppressed`: two independently measured numbers leave the derived one no room to disagree with them, and `total` is what an aggregate over many runs has to sum, since summing ratios would let a five-line run weigh as much as a five-thousand-line one. A passthrough records neither, because nothing was filtered and a zero there would read as a run that suppressed nothing.
    ///
    /// **`shown` is what the answer actually printed** — ``Answer/lines``, counted on the text served to the caller. A count the filter accumulated while parsing is not the same thing once the failures are served as a shape: 1,302 counted against 23 printed on the failing capture, which would understate the saving `usage` and the report page draw from this file.
    ///
    /// **``Answer/failedTests`` is what failed.** Every other field says that *something* went wrong and none of them say what, so without it the log could see hundreds of runs and dozens of nonzero exits and still not answer "has this failed before?" — the one question a per-user history spanning every repository is uniquely placed to answer. The names are the identity worth keeping: a test that fails intermittently rarely fails the same way twice, so the normalised message signature ``RunFailureSignature`` computes beside them groups *messages* and would answer a different question. `nil` where the run is in no position to say, which is a third state and not a zero — see ``RunOutcome/reportedTestFailures``.
    ///
    /// The names are written distinct, sorted and bounded: distinct because a parameterized function failing once per case is one test, sorted so a line is stable to read and to diff like every other key here, and bounded by ``failedTestCap`` with the pre-cap count kept beside them.
    ///
    /// **`startedOn` is the ``TreeContentHash`` the run started on and the command line it was given**, written as `tree` and `invocation` when there is one and left out when there is not — a line without them is unknown to `flakes`, never a tree of its own.
    ///
    /// **`repositoryRoot` is written twice**: as `root`, the checkout the run happened in, and as `repo`, ``repositoryKey(of:)`` — the value every worktree of that repository shares, so `flakes --root` can set a failure in an agent's worktree beside a pass in the primary checkout wherever the worktree was cut. `repo` is left out where git cannot say, which is how every line written before the field existed reads too.
    ///
    /// **`logKey` arrives spelled rather than derived here, and the field it lands in is called `kind`.** The key names the tool *and*, for `xcodebuild`, the action — a distinction ``RunCommandKind`` cannot carry, since the action changes which runs a report may count together and not which filter runs. The field keeps its name because existing logs carry it: renaming the JSON key would orphan every line already written to buy a better word, and the meaning it holds is "how this run files itself".
    public func record(
        logKey: String,
        exitCode: Int32,
        answer: Answer,
        repositoryRoot: URL?,
        milliseconds: Int,
        startedOn: TreeContentHash.RunKey? = nil
    ) {
        var entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "kind": logKey,
            "exit": Int(exitCode),
            "ms": milliseconds,
        ]
        if let report = answer.report, let lines = answer.lines {
            entry["shown"] = lines
            entry["total"] = report.totalLines
        }
        if let failedTests = answer.failedTests {
            let distinct = Set(failedTests.map(Self.clipped)).sorted()
            entry["failed"] = Array(distinct.prefix(Self.failedTestCap))
            entry["failed_total"] = distinct.count
        }
        if let repositoryRoot {
            entry["root"] = repositoryRoot.path
            if let repository = Self.repositoryKey(of: repositoryRoot) {
                entry["repo"] = repository
            }
        }
        if let startedOn {
            entry["tree"] = startedOn.tree
            entry["invocation"] = startedOn.invocation
        }
        log.append(entry)
    }

    /// What a run's repository is filed under: the first 16 hex digits of SHA-256 over the canonical path of the git directory every worktree of it shares, or `nil` where `root` is in no repository git can name.
    ///
    /// A digest rather than the path because the path would be a second directory per line in a log that already records one, and the only question asked of it is whether two lines share it. The path is canonical before it is hashed, so the `/tmp` and `/private/tmp` spellings of one repository are one key.
    public static func repositoryKey(of root: URL) -> String? {
        guard let common = GitContext.commonDirectory(of: root) else { return nil }
        return SHA256.hash(data: Data(common.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// `name` bounded to ``testNameCap``, ending in an ellipsis when it was cut.
    ///
    /// Clipped before the names are made distinct rather than after, so the count filed beside them and the names themselves are over one population — two names that differ only past the cap are one name in this log, and counting them as two would report a truncation that is not there.
    private static func clipped(_ name: String) -> String {
        name.count > testNameCap ? name.prefix(testNameCap) + "…" : name
    }
}

public extension RunUsageLog {
    /// What a run's *answer* amounted to, as against the run itself.
    ///
    /// The three travel together because they are one measurement — what the filter made of the output — while the log key, the exit code, the root and the elapsed time describe the run that produced it. Each is absent rather than zero where the run is in no position to say, which is why the memberwise defaults spell the passthrough: nothing filtered, nothing printed, nothing named.
    struct Answer: Sendable {
        /// The filtered report, or `nil` where nothing was filtered.
        public let report: RunReport?

        /// How many lines the answer actually printed, or `nil` where no answer went out.
        public let lines: Int?

        /// The tests the run named as failing, or `nil` where it is in no position to name any.
        public let failedTests: [String]?

        public init(report: RunReport? = nil, lines: Int? = nil, failedTests: [String]? = nil) {
            self.report = report
            self.lines = lines
            self.failedTests = failedTests
        }
    }
}
