//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// `reset` leaves the proved-run ledger, which every worktree of the repository shares, so its answer names that file and why it stays rather than leaving it to be found later.
@Suite(.temporaryDirectories)
struct ResetKeptLedgerTests {
    @Test(arguments: [SiftPaths.directoryName, nil])
    func aLedgerLeftBehindIsNamedWithWhyItStays(removed: String?) throws {
        let root = try TemporaryDirectory.make("reset-ledger")
        try RunWithoutCommandTests.git(["init", "-q"], in: root)
        let ledger = RunLedger.inRepository(at: root).fileURL
        try FileManager.default.createDirectory(at: ledger.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: ledger, atomically: true, encoding: .utf8)
        let kept = "; kept \(ledger.path): the proved-run ledger every worktree of this repository shares, which dies with the repository (deleting it costs the next proof a run, never an answer)"

        let line = ResetCommand.line(root: root, removed: removed)

        #expect(line.hasSuffix(kept), "\(line)")
    }
}
