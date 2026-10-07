//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A green and a red each write both of ``RunLedger``'s files under the one lock they share, and a green that reaches the lock after a red that finished later than it neither stands nor clears that red.
@Suite(.serialized)
struct RunLedgerOneLockTests {
    private static let toolchain = ToolchainIdentity(description: "Apple Swift version 6.4 · Target: arm64-apple-macosx26.0")
    private static let tree = TreeKey(value: "4f2a9c1e0000000000000000000000000000abcd")

    /// A clock reading on a whole second, as the file stores every date.
    private static let wholeSecond = Date(timeIntervalSince1970: 1_790_000_000)

    private func record(finishedAt: Date) -> RunLedger.Record {
        RunLedger.Record(tree: Self.tree.value, command: "swift test", toolchain: Self.toolchain.description, finishedAt: finishedAt, log: nil, milliseconds: 103_000, workingDirectory: ".")
    }

    @Test func aGreenFiledAfterALaterRedIsNotAProof() throws {
        try TemporaryDirectory.withScope {
            let ledger = try RunLedger(fileURL: TestSources.makeTempDirectory().appendingPathComponent(RunLedger.fileName))
            let now = Self.wholeSecond
            ledger.recordFailure(record(finishedAt: now.addingTimeInterval(-100)))

            ledger.recordGreen(record(finishedAt: now.addingTimeInterval(-110)))

            #expect(ledger.records().isEmpty)
            #expect(ledger.failedRuns.records().count == 1)
            #expect(ledger.trust(tree: Self.tree, command: "swift test", toolchain: Self.toolchain, now: now, environment: [:]) == .notProved(.laterRunFailed(age: 100, log: nil)))
        }
    }

    /// The file keeps whole seconds, so a red that finished after the green inside one second is stored dated before it, and the green, compared by its fraction, would clear it.
    @Test func aGreenFiledAfterALaterRedInTheSameSecondIsNotAProof() throws {
        try TemporaryDirectory.withScope {
            let ledger = try RunLedger(fileURL: TestSources.makeTempDirectory().appendingPathComponent(RunLedger.fileName))
            let second = Self.wholeSecond.addingTimeInterval(-100)
            ledger.recordFailure(record(finishedAt: second.addingTimeInterval(0.4)))
            #expect(ledger.failedRuns.records().map(\.finishedAt) == [second])

            ledger.recordGreen(record(finishedAt: second.addingTimeInterval(0.2)))

            #expect(ledger.records().isEmpty)
            #expect(ledger.failedRuns.records().count == 1)
            #expect(!ledger.trust(tree: Self.tree, command: "swift test", toolchain: Self.toolchain, now: Self.wholeSecond, environment: [:]).isProved)
        }
    }

    /// A red and a green inside one second cannot be ordered from the file, so the green that followed the red is refused too.
    @Test func aGreenAfterARedInTheSameSecondIsNotAProof() throws {
        try TemporaryDirectory.withScope {
            let ledger = try RunLedger(fileURL: TestSources.makeTempDirectory().appendingPathComponent(RunLedger.fileName))
            let second = Self.wholeSecond.addingTimeInterval(-100)
            ledger.recordFailure(record(finishedAt: second.addingTimeInterval(0.2)))

            ledger.recordGreen(record(finishedAt: second.addingTimeInterval(0.4)))

            #expect(ledger.records().isEmpty)
            #expect(ledger.failedRuns.records().count == 1)
            #expect(!ledger.trust(tree: Self.tree, command: "swift test", toolchain: Self.toolchain, now: Self.wholeSecond, environment: [:]).isProved)
        }
    }

    @Test func aGreenInALaterSecondThanTheRedClearsItAndProves() throws {
        try TemporaryDirectory.withScope {
            let ledger = try RunLedger(fileURL: TestSources.makeTempDirectory().appendingPathComponent(RunLedger.fileName))
            let second = Self.wholeSecond.addingTimeInterval(-100)
            ledger.recordFailure(record(finishedAt: second.addingTimeInterval(0.2)))

            ledger.recordGreen(record(finishedAt: second.addingTimeInterval(1.3)))

            #expect(ledger.failedRuns.records().isEmpty)
            #expect(ledger.trust(tree: Self.tree, command: "swift test", toolchain: Self.toolchain, now: Self.wholeSecond, environment: [:]).isProved)
        }
    }

    /// Every writer of either file, ``RunLedger/failedRuns`` written on its own included, takes the ledger's one lock file.
    @Test func bothLedgersTakeOneLockFile() throws {
        try TemporaryDirectory.withScope {
            let directory = try TestSources.makeTempDirectory()
            let ledger = RunLedger(fileURL: directory.appendingPathComponent(RunLedger.fileName))
            let now = Self.wholeSecond
            ledger.recordFailure(record(finishedAt: now.addingTimeInterval(-100)))
            ledger.recordGreen(record(finishedAt: now.addingTimeInterval(-50)))
            ledger.failedRuns.record(record(finishedAt: now.addingTimeInterval(-40)))
            ledger.failedRuns.forget(runOf: record(finishedAt: now))

            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".lock") }
            #expect(names == [RunLedger.fileName + ".lock"])
        }
    }
}

private extension RunLedger.Trust {
    var isProved: Bool {
        if case .proved = self {
            return true
        }
        return false
    }
}
