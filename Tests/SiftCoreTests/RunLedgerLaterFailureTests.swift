//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A red run of the same command on the same content, filed in the sibling `failed-runs.json`, outranks an older green run, and a newer green run outranks it.
@Suite(.serialized)
struct RunLedgerLaterFailureTests {
    private static let toolchain = ToolchainIdentity(description: "Apple Swift version 6.4 · Target: arm64-apple-macosx26.0")
    private static let tree = TreeKey(value: "4f2a9c1e0000000000000000000000000000abcd")
    private static var redLog: String {
        "run-20260919-143512-5e6f7a8b.log"
    }

    /// A clock reading on a whole second, as the file stores every date, so an age read back is exact.
    private static let wholeSecond = Date(timeIntervalSince1970: 1_790_000_000)

    private func ledger() throws -> RunLedger {
        try RunLedger(fileURL: TestSources.makeTempDirectory().appendingPathComponent(RunLedger.fileName))
    }

    private func record(command: String = "swift test", finishedAt: Date, log: String = "run-20260919-143012-1a2b3c4d.log", workingDirectory: String = ".") -> RunLedger.Record {
        RunLedger.Record(tree: Self.tree.value, command: command, toolchain: Self.toolchain.description, finishedAt: finishedAt, log: log, milliseconds: 103_000, workingDirectory: workingDirectory)
    }

    private func trust(_ ledger: RunLedger, now: Date) -> RunLedger.Trust {
        ledger.trust(tree: Self.tree, command: "swift test", toolchain: Self.toolchain, now: now, environment: [:])
    }

    @Test func theRedFileSitsBesideTheLedgerUnderItsOwnName() {
        let ledger = RunLedger(fileURL: URL(fileURLWithPath: "/repo/.git/sift/proved-runs.json"))

        #expect(ledger.failedRuns.fileURL.path == "/repo/.git/sift/failed-runs.json")
    }

    @Test func aRedRunAfterTheGreenOneRefusesItAndSaysWhenAndWhich() throws {
        try TemporaryDirectory.withScope {
            let ledger = try ledger()
            let now = Self.wholeSecond
            ledger.record(record(finishedAt: now.addingTimeInterval(-300)))
            ledger.failedRuns.record(record(finishedAt: now.addingTimeInterval(-120), log: Self.redLog))

            #expect(trust(ledger, now: now) == .notProved(.laterRunFailed(age: 120, log: Self.redLog)))
        }
    }

    @Test func aRedRunBeforeTheGreenOneRefusesNothing() throws {
        try TemporaryDirectory.withScope {
            let ledger = try ledger()
            let now = Self.wholeSecond
            ledger.failedRuns.record(record(finishedAt: now.addingTimeInterval(-300), log: Self.redLog))
            ledger.record(record(finishedAt: now.addingTimeInterval(-120)))

            #expect(trust(ledger, now: now) == .proved(ledger.records()[0]))
        }
    }

    @Test func aRedRunOfAnotherCommandOrDirectoryRefusesNothing() throws {
        try TemporaryDirectory.withScope {
            let ledger = try ledger()
            let now = Self.wholeSecond
            ledger.record(record(finishedAt: now.addingTimeInterval(-300)))
            ledger.failedRuns.record(record(command: "swift test --filter WidgetTests", finishedAt: now.addingTimeInterval(-60), log: Self.redLog))
            ledger.failedRuns.record(record(finishedAt: now.addingTimeInterval(-60), log: Self.redLog, workingDirectory: "Packages/Foo"))

            #expect(trust(ledger, now: now) == .proved(ledger.records()[0]))
        }
    }

    @Test func theRefusalNamesTheRedRunAndItsAgeOnOneLineAndExitsAsNotProved() {
        let answer = ProvedRunAnswer(treeKey: Self.tree, command: "swift test", trust: .notProved(.laterRunFailed(age: 180, log: Self.redLog)))
        let lines = answer.text.split(separator: "\n").map(String.init)

        #expect(lines.count == 2)
        #expect(lines[1] == "✘ not proved — a later run of swift test on this tree's content failed 3m ago (run \(Self.redLog))")
        #expect(!answer.isProved)
        #expect(!answer.cannotTell)
    }
}
