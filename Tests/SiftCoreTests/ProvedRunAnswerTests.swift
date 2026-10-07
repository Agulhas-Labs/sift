//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

struct ProvedRunAnswerTests {
    private static let tree = TreeKey(value: "4f2a9c1e0000000000000000000000000000abcd")

    private func answer(_ trust: RunLedger.Trust, now: Date = Date()) -> ProvedRunAnswer {
        ProvedRunAnswer(treeKey: Self.tree, command: "swift test", trust: trust, now: now)
    }

    @Test func theTrustedAnswerNamesTheRunItStandsOnAndWhatItCannotSee() {
        let now = Date()
        let record = RunLedger.Record(
            tree: Self.tree.value,
            command: "swift test",
            toolchain: "Apple Swift version 6.4",
            finishedAt: now.addingTimeInterval(-180),
            log: "run-20260919-143012-1a2b3c4d.log",
            milliseconds: 103_000
        )
        let answered = answer(.proved(record), now: now)

        #expect(answered.isProved)
        let lines = answered.text.split(separator: "\n").map(String.init)

        #expect(lines[0] == "tree-content: 4f2a9c1e0000  command: swift test")
        #expect(lines[1].hasPrefix("✔ proved — swift test passed 3m ago"))
        #expect(lines[2].contains("run-20260919-143012-1a2b3c4d.log"))
        #expect(lines[2].contains("103s"))
        #expect(lines[3].contains("not covered"))
        #expect(lines[3].contains("60m"))
    }

    /// The ledger is shared by every worktree of a repository, so the run a proof stands on may be another checkout's, and the receipt says which.
    @Test func theTrustedAnswerNamesTheCheckoutTheRunHappenedIn() {
        let now = Date()
        let record = RunLedger.Record(
            tree: Self.tree.value,
            command: "swift test",
            toolchain: "Apple Swift version 6.4",
            finishedAt: now.addingTimeInterval(-180),
            log: "run-20260919-143012-1a2b3c4d.log",
            milliseconds: 103_000,
            checkout: "/work/orchard/proving"
        )
        let lines = answer(.proved(record), now: now).text.split(separator: "\n").map(String.init)

        #expect(lines[2].hasPrefix("  run run-20260919-143012-1a2b3c4d.log in /work/orchard/proving, which took 103s"))
    }

    @Test func eachRefusalSaysWhichItIs() {
        #expect(!answer(.notProved(.noRecord)).isProved)
        #expect(answer(.notProved(.noRecord)).text.contains("no green run of swift test is recorded for this tree's content"))
        #expect(answer(.notProved(.noRecordHere(here: ".", recorded: ["Packages/Foo"]))).text.contains("no green run of swift test is recorded for this tree's content from the repository root; one is recorded only from Packages/Foo"))
        #expect(answer(.notProved(.otherToolchain(recorded: "Apple Swift version 6.3"))).text.contains("ran under Apple Swift version 6.3"))
        #expect(answer(.notProved(.tooOld(age: 7200))).text.contains("is 2h old"))
        #expect(answer(.notProved(.aheadOfTheClock)).text.contains("dated after the clock"))
        #expect(answer(.notProved(.switchedOff)).text.contains("SIFT_RUN_LEDGER=0"))
        #expect(answer(.notProved(.cannotAsk("this is not a git repository"))).text.contains("could not be put: this is not a git repository"))
    }

    @Test func aTreeWithNoKeyStillNamesWhatTheAnswerIsAbout() {
        let answered = ProvedRunAnswer(treeKey: nil, command: "swift test", trust: .notProved(.cannotAsk("git would not hash this working tree")))

        #expect(answered.text.hasPrefix("tree-content: unreadable  command: swift test"))
        #expect(!answered.isProved)
    }

    /// A tree with no record of its own is measured against the last green run: ten changed paths named and the rest counted, or the age alone where git could not compare the trees.
    @Test func aTreeWithNoRecordSaysWhatMovedSinceTheLastGreenRun() {
        let now = Date()
        let last = RunLedger.Record(tree: "0123456789ab", command: "swift test", toolchain: "t", finishedAt: now.addingTimeInterval(-120), log: nil, milliseconds: 1)
        let paths = (1 ... 12).map { "Sources/Gizmo\($0).swift" }
        let listed = ProvedRunAnswer(treeKey: Self.tree, command: "swift test", trust: .notProved(.noRecord), now: now, lastGreen: last, changedSinceLastGreen: paths)
        let unknown = ProvedRunAnswer(treeKey: Self.tree, command: "swift test", trust: .notProved(.noRecord), now: now, lastGreen: last)
        let otherReason = ProvedRunAnswer(treeKey: Self.tree, command: "swift test", trust: .notProved(.tooOld(age: 7200)), now: now, lastGreen: last, changedSinceLastGreen: paths)

        #expect(listed.text.contains("last green run 2m ago on a tree that differs in 12 files: \(paths.prefix(10).joined(separator: ", ")) +2 more"))
        #expect(unknown.text.contains("last green run 2m ago on a different tree (files unknown: git no longer holds the tree it ran on)"))
        #expect(!otherReason.text.contains("last green run"))
    }

    /// From a nested package directory with no green run of its own and no other run to measure against, the answer names that directory — "on this repository" alone would be false, since the repository does hold a green run, just not from here.
    @Test func noGreenRunAtAllNamesTheDirectoryItLookedIn() {
        let root = ProvedRunAnswer(treeKey: Self.tree, command: "swift test", trust: .notProved(.noRecord))
        let sub = ProvedRunAnswer(treeKey: Self.tree, command: "swift test", trust: .notProved(.noRecord), workingDirectory: "Sub")

        #expect(root.text.contains("no green run of swift test recorded on this repository\n") || root.text.hasSuffix("no green run of swift test recorded on this repository"))
        #expect(sub.text.contains("no green run of swift test recorded on this repository from Sub"))
    }

    /// `switchedOff` and `cannotAsk` are the ledger unable to be asked at all — a run cannot turn either into a record — so a caller branches on `cannotTell` rather than treating them as an ordinary "no record".
    @Test func switchedOffAndCannotAskCannotBeToldApart() {
        #expect(answer(.notProved(.switchedOff)).cannotTell)
        #expect(answer(.notProved(.cannotAsk("this is not a git repository"))).cannotTell)
        #expect(!answer(.notProved(.noRecord)).cannotTell)
        #expect(!answer(.proved(RunLedger.Record(tree: Self.tree.value, command: "swift test", toolchain: "t", finishedAt: Date(), log: nil, milliseconds: 1))).cannotTell)
    }
}
