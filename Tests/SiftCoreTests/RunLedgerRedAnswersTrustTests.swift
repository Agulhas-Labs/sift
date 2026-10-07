//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A red run deletes the green it contradicts, so a gate asking afterwards must hear of the failure rather than that no green exists.
@Suite(.serialized)
struct RunLedgerRedAnswersTrustTests {
    private static let toolchain = ToolchainIdentity(description: "Apple Swift version 6.4 · Target: arm64-apple-macosx26.0")
    private static let tree = TreeKey(value: "4f2a9c1e0000000000000000000000000000abcd")
    private static let wholeSecond = Date(timeIntervalSince1970: 1_790_000_000)

    private func record(finishedAt: Date, log: String?, workingDirectory: String = ".") -> RunLedger.Record {
        RunLedger.Record(tree: Self.tree.value, command: "swift test", toolchain: Self.toolchain.description, finishedAt: finishedAt, log: log, milliseconds: 103_000, workingDirectory: workingDirectory)
    }

    private func trust(of ledger: RunLedger) -> RunLedger.Trust {
        ledger.trust(tree: Self.tree, command: "swift test", toolchain: Self.toolchain, now: Self.wholeSecond, environment: [:])
    }

    @Test
    func aGreenThenARedAnswersTheFailureNamingItsLog() throws {
        try TemporaryDirectory.withScope {
            let ledger = try RunLedger(fileURL: TestSources.makeTempDirectory().appendingPathComponent(RunLedger.fileName))
            ledger.record(record(finishedAt: Self.wholeSecond.addingTimeInterval(-300), log: "green.log"))
            ledger.recordFailure(record(finishedAt: Self.wholeSecond.addingTimeInterval(-120), log: "red.log"))

            #expect(trust(of: ledger) == .notProved(.laterRunFailed(age: 120, log: "red.log")))
        }
    }

    @Test
    func aRedOfAnotherDirectoryIsNotThisRunsFailure() throws {
        try TemporaryDirectory.withScope {
            let ledger = try RunLedger(fileURL: TestSources.makeTempDirectory().appendingPathComponent(RunLedger.fileName))
            ledger.recordFailure(record(finishedAt: Self.wholeSecond.addingTimeInterval(-120), log: "red.log", workingDirectory: "Tools/Nested"))

            #expect(trust(of: ledger) == .notProved(.noRecord))
        }
    }
}
