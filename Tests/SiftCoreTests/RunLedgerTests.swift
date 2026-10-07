//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

@Suite(.serialized)
struct RunLedgerTests {
    private static let toolchain = ToolchainIdentity(description: "Apple Swift version 6.4 · Target: arm64-apple-macosx26.0")
    private static let otherToolchain = ToolchainIdentity(description: "Apple Swift version 6.3 · Target: arm64-apple-macosx26.0")
    private static let tree = TreeKey(value: "4f2a9c1e0000000000000000000000000000abcd")

    private func ledger() throws -> RunLedger {
        try RunLedger(fileURL: TestSources.makeTempDirectory().appendingPathComponent(RunLedger.fileName))
    }

    private func record(
        tree: TreeKey = RunLedgerTests.tree,
        command: String = "swift test",
        toolchain: ToolchainIdentity = RunLedgerTests.toolchain,
        finishedAt: Date = Date(),
        milliseconds: Int = 103_000,
        workingDirectory: String? = nil
    ) -> RunLedger.Record {
        RunLedger.Record(tree: tree.value, command: command, toolchain: toolchain.description, finishedAt: finishedAt, log: "run-20260919-143012-1a2b3c4d.log", milliseconds: milliseconds, workingDirectory: workingDirectory)
    }

    private func trust(_ ledger: RunLedger, toolchain: ToolchainIdentity = RunLedgerTests.toolchain, workingDirectory: String = ".", now: Date = Date()) -> RunLedger.Trust {
        ledger.trust(tree: Self.tree, command: "swift test", toolchain: toolchain, workingDirectory: workingDirectory, now: now, environment: [:])
    }

    @Test func aGreenRunProvesTheTreeItRanOn() throws {
        try TemporaryDirectory.withScope {
            let ledger = try ledger()
            ledger.record(record())
            #expect(trust(ledger) == .proved(ledger.records()[0]))
        }
    }

    @Test func anEmptyLedgerProvesNothing() throws {
        try TemporaryDirectory.withScope {
            let empty = try ledger()
            #expect(trust(empty) == .notProved(.noRecord))
        }
    }

    /// The key is content, so a record made for other bytes is a record for another tree — which is what a changed file leaves behind.
    @Test func aRecordForAnotherTreeProvesNothing() throws {
        try TemporaryDirectory.withScope {
            let ledger = try ledger()
            ledger.record(record(tree: TreeKey(value: "9bb31c0e0000000000000000000000000000dcba")))
            #expect(trust(ledger) == .notProved(.noRecord))
        }
    }

    /// A suite run from a nested package directory is a different run from the same argv run at the repository root, even on the same tree and toolchain — so neither may stand for the other.
    @Test func aRecordFromANestedDirectoryDoesNotProveTheRootAndTheRootDoesNotProveTheNestedDirectory() throws {
        try TemporaryDirectory.withScope {
            let rootLedger = try ledger()
            let nestedLedger = try ledger()
            nestedLedger.record(record(workingDirectory: "Packages/Foo"))
            #expect(trust(nestedLedger, workingDirectory: ".") == .notProved(.noRecordHere(here: ".", recorded: ["Packages/Foo"])))
            #expect(trust(nestedLedger, workingDirectory: "Packages/Foo") == .proved(nestedLedger.records()[0]))

            rootLedger.record(record(workingDirectory: "."))
            #expect(trust(rootLedger, workingDirectory: "Packages/Foo") == .notProved(.noRecordHere(here: "Packages/Foo", recorded: ["."])))
        }
    }

    @Test func aRecordForAnotherCommandProvesNothing() throws {
        try TemporaryDirectory.withScope {
            let ledger = try ledger()
            ledger.record(record(command: "swift test --filter WidgetTests"))
            #expect(trust(ledger) == .notProved(.noRecord))
        }
    }

    @Test func aRecordFromAnotherToolchainProvesNothingAndSaysWhose() throws {
        try TemporaryDirectory.withScope {
            let ledger = try ledger()
            ledger.record(record(toolchain: Self.otherToolchain))
            #expect(trust(ledger) == .notProved(.otherToolchain(recorded: Self.otherToolchain.description)))
        }
    }

    @Test func aRecordPastTheWindowProvesNothingAndSaysHowOld() throws {
        try TemporaryDirectory.withScope {
            let ledger = try ledger()
            ledger.record(record())
            // The date a record carries is the one it was written with, which is seconds-resolution: the age
            // asserted on is taken from the stored record rather than from the clock that made it.
            let stored = try #require(ledger.records().first).finishedAt
            let age = RunLedger.trustWindow + 60
            #expect(trust(ledger, now: stored.addingTimeInterval(age)) == .notProved(.tooOld(age: age)))
            #expect(trust(ledger, now: stored.addingTimeInterval(RunLedger.trustWindow - 60)) == .proved(ledger.records()[0]))
        }
    }

    @Test func aRecordDatedAfterTheClockReadingItProvesNothing() throws {
        try TemporaryDirectory.withScope {
            let ledger = try ledger()
            ledger.record(record())
            let stored = try #require(ledger.records().first).finishedAt
            #expect(trust(ledger, now: stored.addingTimeInterval(-60)) == .notProved(.aheadOfTheClock))
        }
    }

    @Test func theSwitchTurnsTheWholeThingOff() throws {
        try TemporaryDirectory.withScope {
            let ledger = try ledger()
            ledger.record(record())
            let off = ledger.trust(tree: Self.tree, command: "swift test", toolchain: Self.toolchain, environment: [RunLedger.switchName: "0"])
            #expect(off == .notProved(.switchedOff))
            #expect(!RunLedger.isOn(environment: [RunLedger.switchName: "0"]))
            #expect(RunLedger.isOn(environment: [RunLedger.switchName: ""]))
            #expect(RunLedger.isOn(environment: [:]))
        }
    }

    @Test func theFileKeepsNoMoreThanItsBoundAndNothingExpired() throws {
        try TemporaryDirectory.withScope {
            let ledger = try ledger()
            let now = Date()
            ledger.record(record(tree: TreeKey(value: "old"), finishedAt: now.addingTimeInterval(-RunLedger.trustWindow - 60)))
            for index in 0 ..< (RunLedger.keptRecords + 5) {
                ledger.record(record(tree: TreeKey(value: "tree-\(index)"), finishedAt: now))
            }
            let kept = ledger.records()
            #expect(kept.count == RunLedger.keptRecords)
            #expect(!kept.contains { $0.tree == "old" })
        }
    }

    /// Two writers recording at once — two worktrees' green runs finishing together — lose neither's records.
    ///
    /// Each round is a fresh ledger holding no more records than the file keeps, all dated now, so the bound and the window drop nothing and every record missing afterwards was lost to the race.
    @Test func recordsWrittenFromTwoWritersAtOnceAreAllKept() throws {
        let writers = 2
        let perWriter = RunLedger.keptRecords / writers
        var lost = 0
        try TemporaryDirectory.withScope {
            for round in 0 ..< 10 {
                let ledger = try ledger()
                let now = Date()
                // Two dedicated OS threads, held at a shared start gate until both have arrived, so they
                // overlap by construction — a shared dispatch queue's own concurrent iteration can run
                // serially when its pool is busy, which would let this pass with or without the ledger's lock.
                let atTheGate = DispatchSemaphore(value: 0)
                let goSignal = DispatchSemaphore(value: 0)
                let done = DispatchGroup()
                for writer in 0 ..< writers {
                    done.enter()
                    let thread = Thread {
                        atTheGate.signal()
                        goSignal.wait()
                        for index in 0 ..< perWriter {
                            ledger.record(record(tree: TreeKey(value: "tree-\(round)-\(writer)-\(index)"), finishedAt: now))
                        }
                        done.leave()
                    }
                    thread.start()
                }
                for _ in 0 ..< writers {
                    atTheGate.wait()
                }
                for _ in 0 ..< writers {
                    goSignal.signal()
                }
                done.wait()
                let kept = Set(ledger.records().map(\.tree))
                lost += writers * perWriter - kept.count
            }
        }

        #expect(lost == 0)
    }

    @Test func aFileThatWillNotParseReadsAsAnEmptyLedger() throws {
        try TemporaryDirectory.withScope {
            let ledger = try ledger()
            try FileManager.default.createDirectory(at: ledger.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: ledger.fileURL)
            #expect(ledger.records().isEmpty)
            #expect(trust(ledger) == .notProved(.noRecord))
        }
    }

    /// A tree proved green in one worktree is proved for identical content in another worktree of the same repository, and names the checkout it was proved in; different content in that other worktree is not.
    ///
    /// The key is content, so a ledger per checkout ran the suite again for the very tree an agent's worktree had just proved, the moment the same tree was pushed from the primary checkout.
    @Test func aTreeProvedInOneWorktreeIsProvedForTheSameContentInAnother() throws {
        try TemporaryDirectory.withScope {
            let root = try TestSources.makeTempRepo()
            let proving = try TestSources.makeWorktree(of: root, named: "proving")
            let asking = try TestSources.makeWorktree(of: root, named: "asking")
            let provedKey = try #require(TreeKey.of(repositoryRoot: proving))
            let proof = RunLedger.Record(
                tree: provedKey.value,
                command: "swift test",
                toolchain: Self.toolchain.description,
                // Whole seconds, which is what the file's ISO 8601 dates keep, so the record read back is this one.
                finishedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
                log: "run-20260919-143012-1a2b3c4d.log",
                milliseconds: 103_000,
                checkout: proving.path
            )
            RunLedger.inRepository(at: proving).record(proof)

            let askingLedger = RunLedger.inRepository(at: asking)
            let sameContent = try #require(TreeKey.of(repositoryRoot: asking))
            #expect(sameContent == provedKey)
            #expect(askingLedger.trust(tree: sameContent, command: "swift test", toolchain: Self.toolchain, environment: [:]) == .proved(proof))

            try TestSources.write("struct Gizmo {}", to: "Sources/Gizmo.swift", in: asking)
            let otherContent = try #require(TreeKey.of(repositoryRoot: asking))
            #expect(otherContent != provedKey)
            #expect(askingLedger.trust(tree: otherContent, command: "swift test", toolchain: Self.toolchain, environment: [:]) == .notProved(.noRecord))
        }
    }

    /// The same relative directory proved in one worktree still stands for identical content in another worktree — the working directory is repository-relative, never a path into a particular checkout.
    @Test func aDirectoryProvedInOneWorktreeIsProvedForTheSameContentAndDirectoryInAnother() throws {
        try TemporaryDirectory.withScope {
            let root = try TestSources.makeTempRepo()
            let proving = try TestSources.makeWorktree(of: root, named: "proving")
            let asking = try TestSources.makeWorktree(of: root, named: "asking")
            let provedKey = try #require(TreeKey.of(repositoryRoot: proving))
            let proof = RunLedger.Record(
                tree: provedKey.value,
                command: "swift test",
                toolchain: Self.toolchain.description,
                finishedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
                log: "run-20260919-143012-1a2b3c4d.log",
                milliseconds: 103_000,
                checkout: proving.path,
                workingDirectory: "Packages/Foo"
            )
            RunLedger.inRepository(at: proving).record(proof)

            let askingLedger = RunLedger.inRepository(at: asking)
            let sameContent = try #require(TreeKey.of(repositoryRoot: asking))
            #expect(askingLedger.trust(tree: sameContent, command: "swift test", toolchain: Self.toolchain, workingDirectory: "Packages/Foo", environment: [:]) == .proved(proof))
            #expect(askingLedger.trust(tree: sameContent, command: "swift test", toolchain: Self.toolchain, workingDirectory: ".", environment: [:]) == .notProved(.noRecordHere(here: ".", recorded: ["Packages/Foo"])))
        }
    }

    /// A record written before this field existed decodes with `workingDirectory` absent, and stands only for a lookup asking about the repository root — never one asking about anywhere else, since an old record cannot say where it really ran.
    @Test func aRecordWithNoStoredDirectoryProvesOnlyTheRoot() throws {
        try TemporaryDirectory.withScope {
            let ledger = try ledger()
            ledger.record(record(workingDirectory: nil))
            #expect(trust(ledger, workingDirectory: ".") == .proved(ledger.records()[0]))
            #expect(trust(ledger, workingDirectory: "Packages/Foo") == .notProved(.noRecordHere(here: "Packages/Foo", recorded: ["."])))
        }
    }

    /// A green run recorded from a nested package directory does not prove a root ask, but the ✘ line names where it was recorded instead of reading as if nothing ran — and the reverse holds too.
    @Test func aRecordFromADifferentDirectoryNamesThatDirectoryInsteadOfSayingNothingRan() throws {
        try TemporaryDirectory.withScope {
            let nestedLedger = try ledger()
            let rootLedger = try ledger()
            nestedLedger.record(record(workingDirectory: "Packages/Foo"))
            #expect(trust(nestedLedger, workingDirectory: ".") == .notProved(.noRecordHere(here: ".", recorded: ["Packages/Foo"])))

            rootLedger.record(record(workingDirectory: "."))
            #expect(trust(rootLedger, workingDirectory: "Packages/Foo") == .notProved(.noRecordHere(here: "Packages/Foo", recorded: ["."])))
        }
    }
}
