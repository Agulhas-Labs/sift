//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// The transcript scan keys a Bash `sift digest` by the repository it ran in exactly as the advice hook's ledger does, so `audit` credits the same digests the hook let a later read through for.
@Suite(.temporaryDirectories) struct ShellDigestScanAgreementTests {
    /// Lines with several moves, a move per statement, a move the hook cannot follow, and none at all, each run from the second with `{ONE}` and `{TWO}` spelling the two repositories: the scan holds each target under the repository the ledger records it at, or nowhere where the ledger records it nowhere.
    @Test(arguments: [
        "cd {TWO} && cd {ONE} && sift digest Alpha",
        "cd / && cd {TWO} && git status && sift digest Beta",
        "cd {TWO} && sift digest Beta; cd {ONE} && sift digest Alpha",
        "cd {ONE} && sift digest Alpha; cd {TWO} && sift digest --root {ONE} Alpha",
        "(cd {TWO} && sift digest Beta)",
        "pushd {TWO} && sift digest Beta",
        "cd {TWO} || true && sift digest Beta",
        "sift digest Alpha | head -40",
    ])
    func theScanKeysAShellDigestWhereTheLedgerDoes(line: String) throws {
        let one = try MCPTestRepo.make(declaring: "Alpha")
        let two = try MCPTestRepo.make(declaring: "Beta")
        let command = line.replacingOccurrences(of: "{ONE}", with: one.path).replacingOccurrences(of: "{TWO}", with: two.path)

        let ledger = PreToolUseCommand.digestsAsked(toolName: "Bash", input: ["command": command], cwd: two.path).mapValues(Set.init)
        var state = TranscriptScanState()
        state.holdShellDigests(of: command, block: ["id": "t1"], directory: two.path)

        #expect(state.pendingShellDigests["t1"] ?? [:] == ledger)
        state.creditShellDigests(answering: "t1", block: ["id": "t1"], failed: false)
        #expect(Set(state.digests.keys) == Set(ledger.keys))
    }
}
