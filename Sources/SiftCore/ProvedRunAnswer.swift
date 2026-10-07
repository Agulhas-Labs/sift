//
// Copyright © Agulhas Labs
//

import Foundation

/// What `sift run --proved` says: whether this tree already has this command proved green, and what that claim rests on.
///
/// It is an answer like any other (Docs/AnswerContract.md), and the two rules it turns on are §1 and §8. The header names the artifact the answer is *about* — the tree's content key and the command — because a verdict about a tree nobody can identify is a verdict about nothing. And the claim is worded no stronger than what was checked: a match is of git's view of the tree and of the toolchain's own version banner, so the answer says so, and the last line names what the key cannot see at all rather than leaving a reader to assume it was covered.
///
/// A skip is never silent: the line a gate prints is this answer, which names the run it trusts and when that run happened, so nobody has to wonder whether the gate ran.
public struct ProvedRunAnswer: Sendable {
    private let treeKey: TreeKey?
    private let command: String
    private let trust: RunLedger.Trust
    private let now: Date
    private let lastGreen: RunLedger.Record?
    private let nearestOtherProof: RunLedger.Record?
    private let changedSinceLastGreen: [String]?
    private let workingDirectory: String

    /// - Parameter lastGreen: The newest green run of this command on the repository, on whatever tree, which a tree with no record of its own is measured against — `lastGreen` is itself scoped to `workingDirectory`, the way `noRecordHere` is.
    /// - Parameter nearestOtherProof: A green run of a different command on this very tree, which a refusal names, so a proof that exists for another command is never mistaken for one for this.
    /// - Parameter changedSinceLastGreen: The paths the tree asking differs in from the one `lastGreen` ran on, or `nil` where git could not compare them.
    /// - Parameter workingDirectory: The repository-relative directory the command ran from — `"."` for the root — so *no green run recorded* can say which directory it found none in, the way `noRecordHere` already does.
    public init(treeKey: TreeKey?, command: String, trust: RunLedger.Trust, now: Date = Date(), lastGreen: RunLedger.Record? = nil, nearestOtherProof: RunLedger.Record? = nil, changedSinceLastGreen: [String]? = nil, workingDirectory: String = ".") {
        self.treeKey = treeKey
        self.command = command
        self.trust = trust
        self.now = now
        self.lastGreen = lastGreen
        self.nearestOtherProof = nearestOtherProof
        self.changedSinceLastGreen = changedSinceLastGreen
        self.workingDirectory = workingDirectory
    }
}

public extension ProvedRunAnswer {
    /// Whether the question was answered *proved* — the one bit a gate branches on, and the process's exit code.
    var isProved: Bool {
        if case .proved = trust {
            return true
        }
        return false
    }

    /// Whether the ledger could not even be asked — switched off, or missing the tree, toolchain or repository the question needs — rather than asked and coming back with no record.
    ///
    /// Neither case is a tree a run can turn into a record: the ledger stays blind to it however many times the command is run. A caller that refuses on this the way it refuses on *no record* refuses forever with advice that cannot help, so it branches here to run the command instead of asking again.
    var cannotTell: Bool {
        switch trust {
        case .notProved(.switchedOff), .notProved(.cannotAsk):
            true
        default:
            false
        }
    }

    /// The whole answer, header first.
    var text: String {
        ([header] + lines).joined(separator: "\n")
    }

    private var header: String {
        let tree = treeKey.map { "tree-content: \($0.displayValue)" } ?? "tree-content: unreadable"
        return "\(tree)  command: \(command)"
    }

    private var lines: [String] {
        switch trust {
        case let .proved(record):
            [
                "✔ proved — \(command) passed \(Self.elapsed(now.timeIntervalSince(record.finishedAt))) ago on this exact tree content, under this toolchain",
                "  \(Self.receipt(record))",
                "  not covered: anything git does not track — the build directory, this tool's own state, the environment, the machine; the record is refused past \(Self.elapsed(RunLedger.trustWindow)) for exactly that reason",
            ]
        case let .notProved(reason):
            ["✘ not proved — \(Self.explain(reason, command: command))"] + (reason == .noRecord ? [otherProof, sinceLastGreen].compactMap(\.self) : [])
        }
    }

    /// Names the green run that exists for this tree under another command, as a refusal's reason: never a ✔ line, since nothing is proved.
    private var otherProof: String? {
        guard let other = nearestOtherProof else {
            return nil
        }
        let words = other.command.split(separator: " ").map(String.init)
        let kind = words.contains { $0 == "--filter" || $0.hasPrefix("--filter=") || $0 == "--skip" || $0.hasPrefix("--skip=") } ? "filtered" : "different options"
        return "  not proved: a green run exists for `\(other.command)` (\(kind)); --proved checks `\(command)`"
    }

    /// How many changed paths the answer names before it counts the rest.
    static var listedPaths: Int {
        10
    }

    /// What moved since the last green run, for a tree the ledger has no record of — the line that says why a gate asking about it was not answered from the ledger.
    ///
    /// The usual cause is an edit made after the run: a changelog line, a lint follow-up, a patch put back after a negative gate. Naming the files is what lets the reader tell that from a change that needs the suite again.
    private var sinceLastGreen: String {
        guard let lastGreen else {
            let from = workingDirectory == "." ? "" : " from \(Self.describe(workingDirectory))"
            return "  no green run of \(command) recorded on this repository\(from)"
        }
        let age = "  last green run \(Self.elapsed(max(0, now.timeIntervalSince(lastGreen.finishedAt)))) ago"
        guard let changed = changedSinceLastGreen, !changed.isEmpty else {
            return "\(age) on a different tree (files unknown: git no longer holds the tree it ran on)"
        }
        let named = changed.prefix(Self.listedPaths).joined(separator: ", ")
        let more = changed.count > Self.listedPaths ? " +\(changed.count - Self.listedPaths) more" : ""
        return "\(age) on a tree that differs in \(changed.count) file\(changed.count == 1 ? "" : "s"): \(named)\(more)"
    }

    /// What the trusted run was, where it ran, and what standing on it saves — stated in seconds, the unit a wrapped run's own receipt is read in, and a floor rather than an estimate: a suite that ran once in this long would not run again in less.
    ///
    /// The checkout is named because the ledger is shared by every worktree of the repository, so the run trusted may be another worktree's; its transcript is under that checkout's `.sift/runs`.
    private static func receipt(_ record: Record) -> String {
        let log = record.log.map { "run \($0)" } ?? "run with no transcript kept"
        let place = record.checkout.map { " in \($0)" } ?? ""
        return "\(log)\(place), which took \(Int((Double(record.milliseconds) / 1000).rounded()))s — that much not spent again"
    }

    private static func explain(_ reason: RunLedger.Reason, command: String) -> String {
        switch reason {
        case .noRecord:
            "no green run of \(command) is recorded for this tree's content"
        case let .noRecordHere(here, recorded):
            "no green run of \(command) is recorded for this tree's content from \(describe(here)); one is recorded only from \(recorded.map(describe).joined(separator: ", "))"
        case let .otherToolchain(recorded):
            "the green run recorded for this tree ran under \(recorded), which is not the toolchain asking"
        case let .tooOld(age):
            "the green run recorded for this tree is \(elapsed(age)) old, past the \(elapsed(RunLedger.trustWindow)) a record stands for"
        case .aheadOfTheClock:
            "the green run recorded for this tree is dated after the clock reading it, so no age can be taken from it"
        case let .laterRunFailed(age, log):
            "a later run of \(command) on this tree's content failed \(elapsed(age)) ago (\(log.map { "run \($0)" } ?? "no transcript kept"))"
        case .switchedOff:
            "the ledger is switched off here (\(RunLedger.switchName)=0)"
        case let .cannotAsk(why):
            "the question could not be put: \(why)"
        }
    }

    /// A repository-relative working directory as a reader names it — the root by name, anything nested as written.
    private static func describe(_ workingDirectory: String) -> String {
        workingDirectory == "." ? "the repository root" : workingDirectory
    }

    /// A duration in the largest unit that keeps it a whole number a reader thinks in.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole < 90 {
            return "\(whole)s"
        }
        if whole < 90 * 60 {
            return "\(Int((Double(whole) / 60).rounded()))m"
        }
        return "\(Int((Double(whole) / 3600).rounded()))h"
    }
}

private extension ProvedRunAnswer {
    typealias Record = RunLedger.Record
}
