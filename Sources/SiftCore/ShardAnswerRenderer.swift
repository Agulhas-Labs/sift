//
// Copyright © Agulhas Labs
//

import Foundation

/// Turns a sharded run's `ShardReconciliation` into the answer a caller reads instead of every shard's own log.
public struct ShardAnswerRenderer: Sendable {
    /// The run's own timing, printed under the shard lines.
    private let phases: ShardPhases?
    private let devicesLine: String?
    private let crashReports: [String]
    private let sweepLines: [String]
    private let rerunCommand: String?
    /// What follows the `--only` arguments — the caller's own `-- <pass-through>`, which has to come last or `sift test` would read this line's flags as pass-through too.
    private let rerunSuffix: String?
    /// Whether the run was a SwiftPM package's: its failures are re-run with `swift test --filter` over their suites, and a shard that lost tests is diagnosed from its log.
    private let swiftPackage: Bool

    public init(
        phases: ShardPhases? = nil,
        devicesLine: String? = nil,
        crashReports: [String] = [],
        sweepLines: [String] = [],
        rerunCommand: String? = nil, rerunSuffix: String? = nil,
        swiftPackage: Bool = false
    ) {
        self.phases = phases
        self.devicesLine = devicesLine
        self.crashReports = crashReports
        self.sweepLines = sweepLines
        self.rerunCommand = rerunCommand
        self.rerunSuffix = rerunSuffix
        self.swiftPackage = swiftPackage
    }
}

extension ShardAnswerRenderer {
    public func render(_ reconciliation: ShardReconciliation, plan: ShardPlan) -> String {
        // A green package run is read for its verdict and its timing, so it is a few lines: every shard on one, and the notes under it with no log paths, since no log is worth opening.
        if swiftPackage, reconciliation.isGreen {
            let shards = reconciliation.shards.map { shard in
                "\(shard.index) — \(pluralized(shard.testCount, "test")), wall \(ShardSeconds.text(shard.wallSeconds)) (predicted \(ShardSeconds.text(shard.predictedSeconds)))"
            }
            return (headlineAndCounts(reconciliation) + ["  shards: " + shards.joined(separator: " · ")] + slowestSection(reconciliation) + notesSection(reconciliation, plan: plan))
                .joined(separator: "\n")
        }
        var sections: [[String]] = [headlineAndCounts(reconciliation)]
        sections.append(failureSection(reconciliation))
        sections.append(missingSection(reconciliation) ?? [])
        sections.append(unlistedSection(reconciliation, plan: plan))
        sections.append(undecidedSection(reconciliation))
        sections.append(reconciliation.duplicated.map(duplicationLine))
        sections.append(reconciliation.shards.flatMap(shardLines) + (phases.map { [$0.line] } ?? []))
        sections.append(slowestSection(reconciliation))
        sections.append(notesSection(reconciliation, plan: plan))
        sections.append(rerunSection(reconciliation))
        sections.append(sweepLines + (devicesLine.map { [$0] } ?? []))

        return sections
            .filter { !$0.isEmpty }
            .map { $0.joined(separator: "\n") }
            .joined(separator: "\n\n")
    }

    private func headlineAndCounts(_ reconciliation: ShardReconciliation) -> [String] {
        [headline(reconciliation), "  \(reconciliation.counts.line)"]
    }

    /// The one line every caller reads: a pass names what it covered, a failure names the worst thing first.
    private func headline(_ reconciliation: ShardReconciliation) -> String {
        guard !reconciliation.isGreen else {
            let shards = pluralized(reconciliation.shards.count, "shard")
            return "✔ sift test — \(reconciliation.counts.passed) tests passed across \(shards)"
        }
        var worst: [String] = []
        if reconciliation.counts.expected == 0 {
            worst.append("nothing expected — every planned test is conditional and reported nothing, so nothing was checked either way")
        }
        if reconciliation.counts.failed > 0 {
            worst.append("\(reconciliation.counts.failed) failed")
        }
        if reconciliation.counts.missing > 0 {
            worst.append("\(reconciliation.counts.missing) missing")
        }
        if reconciliation.counts.duplicated > 0 {
            worst.append("\(reconciliation.counts.duplicated) duplicated")
        }
        if !reconciliation.unlisted.isEmpty {
            worst.append("\(reconciliation.unlisted.count) ran but not listed")
        }
        if !reconciliation.neverListed.isEmpty {
            worst.append("\(reconciliation.neverListed.count) declared but never listed")
        }
        if reconciliation.resultsOutsideThePlan > 0 {
            worst.append("\(pluralized(reconciliation.resultsOutsideThePlan, "shard result")) outside the plan")
        }
        // A process can exit non-zero with every count clean — a crash after the last ending — and the headline still owes a reason.
        let exited = reconciliation.shards.filter { $0.exitCode != 0 }.map { String($0.index) }
        if worst.isEmpty, !exited.isEmpty {
            worst.append(exited.count == 1
                ? "shard \(exited[0]) exited non-zero with no test failed or missing — its log is on its shard line below"
                : "shards \(exited.joined(separator: ", ")) exited non-zero with no test failed or missing — their logs are on their shard lines below")
        }
        let exit = reconciliation.exitCode == 0 ? "" : " — exit \(reconciliation.exitCode)"
        return "✘ sift test — \(worst.joined(separator: " · "))\(exit)"
    }

    /// The failures, through ``RunFailureShape`` while it still has something to group them by, or their bare names once it does not — and beneath the shape, by name, every failed test no record names, so each failed test is named once.
    private func failureSection(_ reconciliation: ShardReconciliation) -> [String] {
        guard reconciliation.failures.isEmpty else {
            let shape = RunFailureShape.of(
                reconciliation.failures.map { failure in
                    RunFailureShape.Failure(
                        name: failure.name,
                        location: failure.location,
                        message: failure.message,
                        arguments: failure.arguments,
                        note: failure.note,
                        closestLine: failure.closestLine
                    )
                },
                changedFiles: .unavailable("the working tree was not consulted")
            )
            guard !reconciliation.unrecordedFailures.isEmpty else {
                return shape.rendered()
            }
            return shape.rendered() + ["failed with no failure recorded:"] + reconciliation.unrecordedFailures.map { "  \($0.enumerated)" }
        }
        return reconciliation.failed.map(\.enumerated)
    }

    /// The tests the listing never named, which no count holds: those a shard's event stream ended, then those the index declares that no shard ran.
    private func unlistedSection(_ reconciliation: ShardReconciliation, plan: ShardPlan) -> [String] {
        var lines: [String] = []
        if !reconciliation.unlisted.isEmpty {
            lines.append("ran but was not listed — `swift test list` did not name it, so no shard expected it:")
            lines.append(contentsOf: reconciliation.unlisted.map { "  \($0)" })
        }
        if !reconciliation.neverListed.isEmpty {
            lines.append("declared but never listed — the index declares it and `swift test list` did not name it, so no shard ran it:")
            lines.append(contentsOf: reconciliation.neverListed.map { "  \($0.enumerated)" })
            lines.append(contentsOf: [plan.neverListedNote].compactMap(\.self))
        }
        return lines
    }

    /// Everything the plan named and no shard reconciled, and the crash reports written while any of it happened.
    private func missingSection(_ reconciliation: ShardReconciliation) -> [String]? {
        guard !reconciliation.missing.isEmpty || !reconciliation.shortfalls.isEmpty else {
            return nil
        }
        var lines = ["missing:"]
        lines.append(contentsOf: reconciliation.missing.map { "  shard \($0.shard): \($0.test.enumerated)" })
        lines.append(contentsOf: reconciliation.shortfalls.map { "  \($0.sentence)" })
        if swiftPackage {
            lines.append(contentsOf: reconciliation.shards.filter { $0.recording.missing > 0 }.map(lossLine))
        }
        if !crashReports.isEmpty {
            lines.append("crash reports written during the run:")
            lines.append(contentsOf: crashReports.map { "  \($0)" })
        }
        return lines
    }

    /// The conditional tests that reported nothing, named beneath the missing ones in the unsharded answer's words, and apart from them the members of a group whose endings cannot say which of them ran.
    private func undecidedSection(_ reconciliation: ShardReconciliation) -> [String] {
        let lone = reconciliation.undecided.filter { !reconciliation.undecidedInGroups.contains($0) }
        var lines: [String] = []
        if !lone.isEmpty {
            lines += ["conditional and never reported — counted in neither direction:"] + lone.map { "  \($0.enumerated)" }
        }
        if !reconciliation.undecidedInGroups.isEmpty {
            lines += ["\(CountedGroup.undecidedMembersHeading):"] + reconciliation.undecidedInGroups.map { "  \($0.enumerated)" }
        }
        return lines
    }

    private func duplicationLine(_ duplication: ShardReconciliation.Duplication) -> String {
        guard !duplication.withinIteration else {
            return "\(duplication.test.enumerated) ended twice within one iteration"
        }
        let shards = duplication.shards.map(String.init).joined(separator: ", ")
        return "\(duplication.test.enumerated) ended in shards \(shards)"
    }

    private func shardLines(_ shard: ShardReconciliation.Shard) -> [String] {
        var lines = [
            "shard \(shard.index): \(shard.testCount) tests · wall \(ShardSeconds.text(shard.wallSeconds)) (predicted \(ShardSeconds.text(shard.predictedSeconds))) · tests \(ShardSeconds.text(shard.executionSeconds)) · iterations \(shard.iterations) · exit \(shard.exitCode) · \(shard.logPath)",
        ]
        if shard.wallExceedsExecution {
            lines.append("  wall clock is more than twice the tests' own time — launch, session start and bundle load are outside every test's own time")
        }
        return lines
    }

    private func slowestSection(_ reconciliation: ShardReconciliation) -> [String] {
        guard !reconciliation.slowest.isEmpty else {
            return []
        }
        return ["slowest:"] + reconciliation.slowest.map { "  \(ShardSeconds.text($0.seconds))  \($0.test.enumerated)" }
    }

    private func notesSection(_ reconciliation: ShardReconciliation, plan: ShardPlan) -> [String] {
        var lines: [String] = []
        if let lowering = plan.loweringNote, !lowering.isEmpty {
            lines.append(lowering)
        }
        if let estimate = plan.estimateNote, !estimate.isEmpty {
            lines.append(estimate)
        }
        lines.append(contentsOf: reconciliation.notes.filter { !$0.isEmpty })
        return lines
    }

    /// A failure under N-way load is not yet a failure — the same shard, run alone, may pass — so what this offers is a way to find out, not a verdict.
    private func rerunSection(_ reconciliation: ShardReconciliation) -> [String] {
        guard !reconciliation.failed.isEmpty else {
            return []
        }
        if swiftPackage {
            let filter = TestRunRequest.shellQuoted(PackageShardPlanner.filter(for: reconciliation.failed))
            return ["re-run their suites alone:", "  swift test --filter \(filter)"]
        }
        // Quoted, since an identifier ends in `()` and a shell reads that as syntax rather than as a word.
        let args = reconciliation.failed.map { TestRunRequest.shellQuoted($0.enumerated) }.joined(separator: " --only ")
        guard let rerunCommand else {
            return ["re-run just these with --shards 1:", "  --only \(args)"]
        }
        return ["re-run just these, serially:", "  \(rerunCommand) --shards 1 --only \(args)\(rerunSuffix ?? "")"]
    }

    /// Where to start on a shard that lost tests: how its process ended, whether Swift Testing finished inside it, and the log that was kept for it.
    private func lossLine(_ shard: ShardReconciliation.Shard) -> String {
        var exit = "exit \(shard.exitCode)"
        if (129 ... 159).contains(shard.exitCode) {
            let signal = shard.exitCode - 128
            exit += " (128 + signal \(signal), \(String(cString: strsignal(signal))), if it was signalled)"
        }
        let summary = if shard.closedWithRunSummary {
            "its log closes on Swift Testing's `Test run with …` line"
        } else if let unclosed = shard.unclosedSwiftTestingRun {
            "the \(ordinal(unclosed.position)) of \(unclosed.of) Swift Testing processes printed no `Test run with …` line"
        } else {
            "no Swift Testing `Test run with …` line in its log"
        }
        let log = shard.logPath.isEmpty ? "no log" : "log kept at \(shard.logPath)"
        return "  shard \(shard.index) lost \(shard.recording.missing) of \(shard.testCount): \(exit) · \(summary) · \(log)"
    }

    private func ordinal(_ position: Int) -> String {
        let suffix = switch (position % 10, position % 100) {
        case (_, 11 ... 13): "th"
        case (1, _): "st"
        case (2, _): "nd"
        case (3, _): "rd"
        default: "th"
        }
        return "\(position)\(suffix)"
    }

    private func pluralized(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
