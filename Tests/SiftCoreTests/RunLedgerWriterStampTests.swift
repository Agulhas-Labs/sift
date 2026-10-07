//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A green record an older sift wrote or rewrote proves nothing: such a sift clears a red whatever its date, and every record it writes loses the writer stamp.
@Suite(.serialized)
struct RunLedgerWriterStampTests {
    private static let toolchain = ToolchainIdentity(description: "Apple Swift version 6.4 · Target: arm64-apple-macosx26.0")
    private static let tree = TreeKey(value: "4f2a9c1e0000000000000000000000000000abcd")

    /// A clock reading on a whole second, as the file stores every date.
    private static let wholeSecond = Date(timeIntervalSince1970: 1_790_000_000)

    private func record(finishedAt: Date) -> RunLedger.Record {
        RunLedger.Record(tree: Self.tree.value, command: "swift test", toolchain: Self.toolchain.description, finishedAt: finishedAt, log: nil, milliseconds: 103_000, workingDirectory: ".")
    }

    private func olderRecord(finishedAt: Date) -> OlderRecord {
        OlderRecord(tree: Self.tree.value, command: "swift test", toolchain: Self.toolchain.description, finishedAt: finishedAt, log: nil, milliseconds: 103_000, checkout: nil, workingDirectory: ".")
    }

    private func trust(_ ledger: RunLedger) -> RunLedger.Trust {
        ledger.trust(tree: Self.tree, command: "swift test", toolchain: Self.toolchain, now: Self.wholeSecond, environment: [:])
    }

    /// What an older sift does with a green run: the file rewritten whole through its own coding with the green at its head, then every red of that run dropped whatever its date.
    private func olderSiftFiles(green: OlderRecord, in ledger: RunLedger) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let kept = try (try? Data(contentsOf: ledger.fileURL)).map { try decoder.decode([OlderRecord].self, from: $0) } ?? []
        try encoder.encode([green] + kept).write(to: ledger.fileURL, options: .atomic)
        let reds = try decoder.decode([OlderRecord].self, from: Data(contentsOf: ledger.failedRuns.fileURL))
        try encoder.encode(reds.filter { $0.tree != green.tree || $0.command != green.command }).write(to: ledger.failedRuns.fileURL, options: .atomic)
    }

    @Test func aGreenFiledByThisSiftIsStampedAndProves() throws {
        try TemporaryDirectory.withScope {
            let ledger = try RunLedger(fileURL: TestSources.makeTempDirectory().appendingPathComponent(RunLedger.fileName))

            ledger.recordGreen(record(finishedAt: Self.wholeSecond.addingTimeInterval(-120)))

            let text = try String(contentsOf: ledger.fileURL, encoding: .utf8)
            #expect(text.contains("\"writerFormat\""))
            #expect(trust(ledger) == .proved(ledger.records()[0]))
        }
    }

    @Test func aGreenAnOlderSiftFiledOverALaterRedIsNotAProof() throws {
        try TemporaryDirectory.withScope {
            let ledger = try RunLedger(fileURL: TestSources.makeTempDirectory().appendingPathComponent(RunLedger.fileName))
            ledger.recordFailure(record(finishedAt: Self.wholeSecond.addingTimeInterval(-100)))

            try olderSiftFiles(green: olderRecord(finishedAt: Self.wholeSecond.addingTimeInterval(-110)), in: ledger)

            #expect(ledger.failedRuns.records().isEmpty)
            #expect(ledger.records().count == 1)
            #expect(trust(ledger) == .notProved(.noRecord))
            #expect(ledger.lastGreen(of: "swift test") == nil)
        }
    }

    /// A green this sift filed loses its stamp when an older sift rewrites the file around it, and no longer proves.
    @Test func aStampedGreenAnOlderSiftRewroteIsNotAProof() throws {
        try TemporaryDirectory.withScope {
            let ledger = try RunLedger(fileURL: TestSources.makeTempDirectory().appendingPathComponent(RunLedger.fileName))
            ledger.recordFailure(record(finishedAt: Self.wholeSecond.addingTimeInterval(-300)))
            ledger.recordGreen(record(finishedAt: Self.wholeSecond.addingTimeInterval(-120)))
            #expect(trust(ledger) == .proved(ledger.records()[0]))

            let build = OlderRecord(
                tree: Self.tree.value, command: "swift build", toolchain: Self.toolchain.description,
                finishedAt: Self.wholeSecond.addingTimeInterval(-60), log: nil, milliseconds: 1000, checkout: nil, workingDirectory: "."
            )
            try olderSiftFiles(green: build, in: ledger)

            #expect(ledger.records().count == 2)
            #expect(trust(ledger) == .notProved(.noRecord))
        }
    }
}

private extension RunLedgerWriterStampTests {
    /// A record as a sift from before the writer stamp codes it: its synthesized coding knows these fields and no others.
    struct OlderRecord: Codable {
        let tree: String
        let command: String
        let toolchain: String
        let finishedAt: Date
        let log: String?
        let milliseconds: Int
        let checkout: String?
        let workingDirectory: String?
    }
}
