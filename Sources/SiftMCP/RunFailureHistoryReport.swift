//
// Copyright © Agulhas Labs
//

import Foundation

/// Renders ``RunFailureHistory`` as the answer `sift flakes` prints — the counts, the population they are over, and the runs that could not contribute to either.
///
/// Reading and scoping `run.jsonl` belong to ``RunScan`` and the tallying to ``RunFailureHistory``; this is the text face over them, exactly as ``UsageReport`` is over ``UsageScan``, and it counts nothing for itself.
///
/// **Every number here is printed with the population it is over, and the report says out loud what it does not know.** Two lines exist for nothing else: the runs that recorded nothing about their failures, which are unknown and not zero, and the sentence saying these are counts rather than a diagnosis. Neither is decoration — a fraction with no denominator beside it and a listing with no caveat under it are how a measurement becomes a verdict on the way to being read.
public struct RunFailureHistoryReport {
    /// The rendered report for the run log at `fileURL`, or an honest empty-state line.
    ///
    /// `since` (an inclusive `YYYY-MM-DD`) and `root` narrow it, and are stated in the header when set, because a count read against the wrong population is the misreading this whole report is arranged to prevent.
    public static func render(
        fileURL: URL,
        since: String? = nil,
        root: String? = nil,
        redactor: Redactor? = nil
    ) -> String {
        let logPath = redactor == nil ? fileURL.path : Redactor.tilded(fileURL.path)
        let scope: LogScope?
        switch LogScope.resolve(root, inLogsAt: [fileURL]) {
        case let .success(resolved):
            scope = resolved
        case let .failure(problem):
            return message(for: problem, redactor: redactor)
        }
        let scan = RunScan.load(fileURL: fileURL, since: since, scope: scope, acrossWorktrees: true)
        let history = RunFailureHistory.of(scan)
        var suffix: [String] = []
        if let since {
            suffix.append("since \(since)")
        }
        if let scope {
            suffix.append("in \(redactor?.root(scope.path) ?? scope.path)")
        }
        let scoped = suffix.isEmpty ? "" : " (\(suffix.joined(separator: ", ")))"
        return (body(history, scan: scan, scoped: scoped, redactor: redactor)
            + coverage(history, redactor: redactor)
            + ["log: \(logPath)"])
            .joined(separator: "\n")
    }
}

private extension RunFailureHistoryReport {
    /// The listing, or the empty state that says which of the three kinds of nothing this is.
    ///
    /// They are three different facts and a reader acts on each differently: no runs at all in the window asked for, runs that all predate the field or could not name their failures, and runs that measured cleanly and found no test with both outcomes in them. One shared "nothing to report" would collapse a log that cannot answer the question into a log that answered it "no".
    static func body(_ history: RunFailureHistory, scan: RunScan, scoped: String, redactor: Redactor?) -> [String] {
        guard !scan.entries.isEmpty else {
            return ["no runs recorded\(scoped) — \(scan.logged) in the log overall"]
        }
        // Stated without a count, because every run in scope is then one the coverage block below is about
        // to count — and the same number under two sentences reads as two facts. Which of the two silences
        // it is has to be said here rather than left to the block: "no run has recorded which tests failed"
        // beneath a line counting runs that did exactly that is the report contradicting itself in four
        // lines, and the reader has no way to tell which sentence to believe.
        guard history.measured > 0 else {
            return [history.conflated > 0
                ? "no run\(scoped) recorded which tests failed under a kind that says which action it ran"
                : "no run\(scoped) has recorded which tests failed"]
        }
        let tiers = [history.sameTree, history.otherTrees, history.unknownTree]
        guard tiers.contains(where: { !$0.isEmpty }) else {
            return ["no test has both failed and passed\(scoped) — measured over \(counted(history.measured, "run")) that recorded which tests failed"]
        }
        // Distinct names, because one test can be listed in a known tier and in the unknown one, over two
        // different sets of runs, and is still one test.
        let tests = Set(tiers.flatMap { $0.flatMap { $0.tests.map(\.name) } }).count
        var lines = ["\(counted(tests, "test")) \(tests == 1 ? "has" : "have") both failed and passed\(scoped), over \(counted(history.measured, "run")) that recorded which tests failed"]
        // The two known tiers are stated whenever any run recorded a tree, a tier with nothing in it included:
        // "no test failed and passed on one tree" is the answer a reader of this report most wants to hear.
        let withTree = history.measured - history.treeless
        if withTree > 0 {
            lines.append("")
            lines.append("same tree — failed and passed on identical bytes under one command line, over \(counted(withTree, "run")) that recorded their tree:")
            lines += listing(history.sameTree, redactor: redactor, none: "no test both failed and passed on one tree")
            lines.append("")
            lines.append("failed only on trees, or under command lines, it never passed on:")
            lines += listing(history.otherTrees, redactor: redactor, none: "none")
            if !history.otherTrees.isEmpty {
                lines.append("  A change of bytes or of command line lies between every failure and every pass here, and a narrower command line may not have run the test at all: a deliberate red — a negative gate, a test written before its fix — looks exactly like this, and so do a regression and its fix.")
            }
        }
        if !history.unknownTree.isEmpty {
            lines.append("")
            lines.append("tree unknown — runs that recorded no tree, read together:")
            lines += listing(history.unknownTree, redactor: redactor, none: "none")
        }
        return lines
    }

    /// One tier's populations and rows, or one indented line saying it has none.
    static func listing(_ populations: [RunFailureHistory.PopulationHistory], redactor: Redactor?, none: String) -> [String] {
        guard !populations.isEmpty else {
            return ["  \(none)"]
        }
        var lines: [String] = []
        for population in populations {
            // Every key in the population, because a fold is real: `xcodebuild test` and
            // `xcodebuild test-without-building` share a denominator, and a heading naming one of them
            // over runs of both is a fraction stated against a population that never existed.
            lines.append("\(population.keys.joined(separator: ", ")) — \(counted(population.runs, "run")):")
            for test in population.tests {
                let over = test.trees.map { " on \($0 == 1 ? "one tree" : "\($0) trees")" } ?? ""
                lines.append("  \(String(test.failed).leftPadded(4)) of \(test.runs)\(over)   last \(test.lastFailed)   \(redactor?.test(test.name) ?? test.name)")
            }
        }
        return lines
    }

    /// What the report is not built on, and what the numbers above are not.
    ///
    /// The unknown count comes first because it is the one that bounds everything else: a report measured over a handful of runs beside hundreds it could not read is a different claim from the same report over nearly all of them, and only the reader can tell which they are looking at.
    static func coverage(_ history: RunFailureHistory, redactor: Redactor?) -> [String] {
        var lines: [String] = []
        if history.unrecorded > 0 {
            lines.append("")
            lines.append("\(counted(history.unrecorded, "run")) recorded nothing about which tests failed — written before the log kept them, passed through unfiltered, or failed for a reason the filter could not explain. Unknown, and counted in nothing above.")
        }
        if history.treeless > 0 {
            if lines.isEmpty {
                lines.append("")
            }
            lines.append("\(counted(history.treeless, "run")) recorded which tests failed but not the tree they ran on — written before the log kept it, past the bound on hashing one, or where git would not answer. Which tier their tests belong in is unknown, so they are counted under tree unknown and in neither tier.")
        }
        if history.incomplete > 0 {
            lines.append("\(counted(history.incomplete, "run")) named more failing tests than one log line holds, so they cannot say a test did not fail — counted in nothing above either.")
        }
        if history.conflated > 0 {
            if lines.isEmpty {
                lines.append("")
            }
            lines.append("\(counted(history.conflated, "run")) recorded which tests failed under a command kind that does not say which action it ran — written before the log kept the action, or by an invocation whose arguments left it in doubt. One key covers a build, a test and a clean alike, so how many of them could have run a given test is unknown and no fraction over them would be over a population. Counted in nothing above.")
        }
        let top = [history.sameTree, history.otherTrees, history.unknownTree].lazy.compactMap { $0.first?.tests.first }.first
        guard let test = top else {
            return lines
        }
        if lines.isEmpty {
            lines.append("")
        }
        // Spoken with the numbers directly above it rather than an invented example, because the reading
        // being warned against is the one the reader is in the middle of making about *that* row. A
        // same-tree row has already ruled out a change of bytes, so its sentence says what is left instead.
        if let trees = test.trees {
            lines.append("These are counts, not a diagnosis: a test named by \(test.failed) of \(test.runs) runs on \(trees == 1 ? "one tree" : "\(trees) trees") failed and passed on the same bytes under the same command line, so whatever decided it lies outside the files git sees — timing, order, the machine — and the log does not say which.")
        } else {
            lines.append("These are counts, not a diagnosis: a test named by \(test.failed) of \(test.runs) runs may fail at random, or may have been failing on a change that was present for exactly those \(test.failed).")
        }
        // Said once per answer, not once per row — a reader who does not already know the flag is
        // otherwise stuck with names like `test-9b3bcb` that identify nothing.
        if redactor != nil {
            lines.append("names redacted — --unredact to show them")
        }
        return lines
    }

    /// The two root refusals, in the wording `usage` already uses — said of one log here, because `flakes` reads one.
    ///
    /// The candidates are spelled the way the rest of the report spells a root: pseudonymised unless the reader asked for the real thing. A refusal is still a report, and one that printed absolute paths would be the only part of it to do so — a report promising to be safe to share, carrying every repository on the machine and the username above them.
    static func message(for problem: UsageScan.Problem, redactor: Redactor?) -> String {
        switch problem {
        case let .rootUnmatched(argument, roots):
            "nothing recorded for a root matching \(argument). Roots in the run log:\n"
                + listed(roots, redactor: redactor)
        case let .rootAmbiguous(argument, matches):
            "\(argument) matches \(matches.count) paths in the run log — name one:\n"
                + listed(matches, redactor: redactor)
        // Neither can arrive: a scope is resolved before any log is read, and the two states below are how
        // a *scan* fails. Answered rather than ignored, because a silent empty string here would read as a
        // report of nothing found.
        case .missingOrEmpty, .unreadable:
            "the run log could not be read"
        }
    }

    /// One candidate directory per line, spelled as this reader is allowed to see it.
    static func listed(_ paths: [String], redactor: Redactor?) -> String {
        LogScope.spellings(of: paths, redacted: redactor != nil)
            .map { "  \($0)" }
            .joined(separator: "\n")
    }

    static func counted(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
}
