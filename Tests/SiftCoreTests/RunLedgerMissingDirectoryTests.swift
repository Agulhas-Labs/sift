//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A record with no working directory is a run from the root when one run is matched against another, as it is when ``RunLedger`` answers whether a tree is proved.
@Suite(.serialized)
struct RunLedgerMissingDirectoryTests {
    private static let toolchain = ToolchainIdentity(description: "Apple Swift version 6.4 · Target: arm64-apple-macosx26.0")
    private static let tree = TreeKey(value: "4f2a9c1e0000000000000000000000000000abcd")

    /// A clock reading on a whole second, as the file stores every date.
    private static let wholeSecond = Date(timeIntervalSince1970: 1_790_000_000)

    private func record(finishedAt: Date, workingDirectory: String?) -> RunLedger.Record {
        RunLedger.Record(tree: Self.tree.value, command: "swift test", toolchain: Self.toolchain.description, finishedAt: finishedAt, log: nil, milliseconds: 103_000, workingDirectory: workingDirectory)
    }

    @Test func aRedFromTheRootDeletesAGreenFiledWithNoDirectory() throws {
        try TemporaryDirectory.withScope {
            let ledger = try RunLedger(fileURL: TestSources.makeTempDirectory().appendingPathComponent(RunLedger.fileName))
            let now = Self.wholeSecond
            ledger.record(record(finishedAt: now.addingTimeInterval(-300), workingDirectory: nil))

            ledger.recordFailure(record(finishedAt: now.addingTimeInterval(-120), workingDirectory: "."))

            #expect(ledger.records().isEmpty)
        }
    }

    @Test func aGreenFromTheRootReplacesOneFiledWithNoDirectory() throws {
        try TemporaryDirectory.withScope {
            let ledger = try RunLedger(fileURL: TestSources.makeTempDirectory().appendingPathComponent(RunLedger.fileName))
            let now = Self.wholeSecond
            ledger.record(record(finishedAt: now.addingTimeInterval(-300), workingDirectory: nil))

            ledger.record(record(finishedAt: now.addingTimeInterval(-120), workingDirectory: "."))

            #expect(ledger.records().map(\.workingDirectory) == ["."])
        }
    }
}
