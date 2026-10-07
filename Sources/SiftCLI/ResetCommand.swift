//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore

/// `sift reset` — delete the cache; the first troubleshooting step, always safe.
struct ResetCommand: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(commandName: "reset", abstract: "Delete .sift/ entirely: the index, which the next query rebuilds, and the logs of past runs.")
    }

    @OptionGroup var rootOptions: RootOptions

    func run() throws {
        let reset = try SiftEngine.reset(directory: rootOptions.directory)
        StandardStreams.emit(Self.line(root: reset.root, removed: reset.removed))
    }

    /// The answer, naming the repository root it looked in when there was nothing there, since that is not always the directory it was run from, and the proved-run ledger wherever one is left, since a reset keeps it on purpose.
    static func line(root: URL, removed: String?) -> String {
        let answer = removed.map { "removed \($0)/ — the next query rebuilds it" }
            ?? "nothing to remove: there is no \(SiftPaths.directoryName)/ in \(root.path)"
        return answer + keptLedger(root: root)
    }

    /// The ledger lives in the repository's shared git directory, one for every worktree, so a reset of one checkout leaves it; losing it would cost the next proof a run, never an answer.
    private static func keptLedger(root: URL) -> String {
        let ledger = RunLedger.inRepository(at: root).fileURL
        guard FileManager.default.fileExists(atPath: ledger.path) else { return "" }
        return "; kept \(ledger.path): the proved-run ledger every worktree of this repository shares, which dies with the repository (deleting it costs the next proof a run, never an answer)"
    }
}
