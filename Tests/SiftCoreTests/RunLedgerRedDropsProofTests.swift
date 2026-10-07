//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A red run filed through ``RunLedger``'s `recordFailure(_:)` deletes the green record it contradicts, so the proof cannot outlive the red when the red file trims it away.
@Suite(.serialized)
struct RunLedgerRedDropsProofTests {
    private static let toolchain = ToolchainIdentity(description: "Apple Swift version 6.4 · Target: arm64-apple-macosx26.0")
    private static let tree = TreeKey(value: "4f2a9c1e0000000000000000000000000000abcd")

    /// A clock reading on a whole second, as the file stores every date.
    private static let wholeSecond = Date(timeIntervalSince1970: 1_790_000_000)

    private func record(tree: String = Self.tree.value, command: String = "swift test", finishedAt: Date) -> RunLedger.Record {
        RunLedger.Record(tree: tree, command: command, toolchain: Self.toolchain.description, finishedAt: finishedAt, log: nil, milliseconds: 103_000, workingDirectory: ".")
    }

    @Test func aRedRunDeletesTheGreenRecordOfTheSameRunAndLeavesOthers() throws {
        try TemporaryDirectory.withScope {
            let ledger = try RunLedger(fileURL: TestSources.makeTempDirectory().appendingPathComponent(RunLedger.fileName))
            let now = Self.wholeSecond
            ledger.record(record(finishedAt: now.addingTimeInterval(-300)))
            ledger.record(record(command: "swift build", finishedAt: now.addingTimeInterval(-290)))

            ledger.recordFailure(record(finishedAt: now.addingTimeInterval(-120)))

            #expect(ledger.records().map(\.command) == ["swift build"])
            #expect(ledger.failedRuns.records().count == 1)
        }
    }

    /// The red file keeps ``RunLedger/keptRecords`` and is shared by every worktree: reds on other trees push this tree's red out inside the window, and the proof must not come back with it.
    @Test func aRedTrimmedOutOfTheRedFileLeavesNoProofBehind() throws {
        try TemporaryDirectory.withScope {
            let ledger = try RunLedger(fileURL: TestSources.makeTempDirectory().appendingPathComponent(RunLedger.fileName))
            let now = Self.wholeSecond
            ledger.record(record(finishedAt: now.addingTimeInterval(-1800)))
            ledger.recordFailure(record(finishedAt: now.addingTimeInterval(-1790)))
            for index in 0 ..< RunLedger.keptRecords + 10 {
                let other = String(format: "%040x", index + 1)
                ledger.recordFailure(record(tree: other, finishedAt: now.addingTimeInterval(TimeInterval(-1700 + index))))
            }

            #expect(!ledger.failedRuns.records().contains { $0.tree == Self.tree.value })
            #expect(ledger.trust(tree: Self.tree, command: "swift test", toolchain: Self.toolchain, now: now, environment: [:]) == .notProved(.noRecord))
        }
    }
}
