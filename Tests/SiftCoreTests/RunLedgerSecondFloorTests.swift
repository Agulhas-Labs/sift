//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A green is compared with the reds on file by its whole second, rounded down, because the file keeps a red's second the same way.
@Suite(.serialized)
struct RunLedgerSecondFloorTests {
    private static let toolchain = ToolchainIdentity(description: "Apple Swift version 6.4 · Target: arm64-apple-macosx26.0")
    private static let tree = TreeKey(value: "4f2a9c1e0000000000000000000000000000abcd")

    /// A clock reading on a whole second, as the file stores every date.
    private static let wholeSecond = Date(timeIntervalSince1970: 1_790_000_000)

    private func record(finishedAt: Date) -> RunLedger.Record {
        RunLedger.Record(tree: Self.tree.value, command: "swift test", toolchain: Self.toolchain.description, finishedAt: finishedAt, log: nil, milliseconds: 103_000, workingDirectory: ".")
    }

    private func trust(_ ledger: RunLedger) -> RunLedger.Trust {
        ledger.trust(tree: Self.tree, command: "swift test", toolchain: Self.toolchain, now: Self.wholeSecond, environment: [:])
    }

    /// Rounded to the nearest second the green at .6 would read as the next second and clear the red stored as the second before it, though the red finished later.
    @Test func aGreenAtPointSixOfTheSecondOfARedAtPointEightDoesNotClearIt() throws {
        try TemporaryDirectory.withScope {
            let ledger = try RunLedger(fileURL: TestSources.makeTempDirectory().appendingPathComponent(RunLedger.fileName))
            let second = Self.wholeSecond.addingTimeInterval(-100)
            ledger.recordFailure(record(finishedAt: second.addingTimeInterval(0.8)))

            ledger.recordGreen(record(finishedAt: second.addingTimeInterval(0.6)))

            #expect(ledger.records().isEmpty)
            #expect(ledger.failedRuns.records().count == 1)
            #expect(trust(ledger) == .notProved(.laterRunFailed(age: 100, log: nil)))
        }
    }

    @Test func aGreenStrictlyInTheNextSecondAfterARedClearsItAndProves() throws {
        try TemporaryDirectory.withScope {
            let ledger = try RunLedger(fileURL: TestSources.makeTempDirectory().appendingPathComponent(RunLedger.fileName))
            let second = Self.wholeSecond.addingTimeInterval(-100)
            ledger.recordFailure(record(finishedAt: second.addingTimeInterval(0.8)))

            ledger.recordGreen(record(finishedAt: second.addingTimeInterval(1.1)))

            #expect(ledger.failedRuns.records().isEmpty)
            #expect(trust(ledger) == .proved(ledger.records()[0]))
        }
    }
}
