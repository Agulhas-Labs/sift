//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A green an older sift wrote stays unproved when this sift rewrites the file around it: the rewrite never gives it a stamp.
@Suite(.serialized)
struct RunLedgerRewriteKeepsStampTests {
    private static let toolchain = ToolchainIdentity(description: "Apple Swift version 6.4 · Target: arm64-apple-macosx26.0")
    private static let tree = TreeKey(value: "4f2a9c1e0000000000000000000000000000abcd")
    private static let wholeSecond = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func anUnstampedGreenStaysUnprovedAfterANewGreenRewritesTheFile() throws {
        try TemporaryDirectory.withScope {
            let ledger = try RunLedger(fileURL: TestSources.makeTempDirectory().appendingPathComponent(RunLedger.fileName))
            let older = UnstampedRecord(
                tree: Self.tree.value, command: "swift test", toolchain: Self.toolchain.description,
                finishedAt: Self.wholeSecond.addingTimeInterval(-120), log: nil, milliseconds: 103_000, checkout: nil, workingDirectory: "."
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode([older]).write(to: ledger.fileURL, options: .atomic)
            #expect(ledger.trust(tree: Self.tree, command: "swift test", toolchain: Self.toolchain, now: Self.wholeSecond, environment: [:]) == .notProved(.noRecord))

            ledger.recordGreen(RunLedger.Record(
                tree: Self.tree.value, command: "swift build", toolchain: Self.toolchain.description,
                finishedAt: Self.wholeSecond.addingTimeInterval(-60), log: nil, milliseconds: 1000, workingDirectory: "."
            ))

            #expect(ledger.records().count == 2)
            #expect(ledger.records().filter { $0.writerFormat != nil }.map(\.command) == ["swift build"])
            #expect(ledger.trust(tree: Self.tree, command: "swift test", toolchain: Self.toolchain, now: Self.wholeSecond, environment: [:]) == .notProved(.noRecord))
            #expect(ledger.lastGreen(of: "swift test") == nil)
        }
    }
}

private extension RunLedgerRewriteKeepsStampTests {
    /// A record as a sift from before the writer stamp codes it.
    struct UnstampedRecord: Codable {
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
