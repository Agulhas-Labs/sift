//
// Copyright © Agulhas Labs
//

import Foundation

/// The one-line refusals for a command whose whole effect is a file in the tree, asked of a tree nobody may write.
///
/// `index` and `reconcile` refuse through ``EngineError/treeNotWritable(_:)``; these are the same refusal for the two commands that would otherwise end in the platform's own words about a file they never needed to name.
public struct TreeWritability {
    /// Throws where `init --write` could not save `.sift.json`: the root is not writable.
    ///
    /// The save is atomic (a temporary file, then a rename), so it needs the folder and never the mode of a `.sift.json` already there.
    static func requireConfigFile(repoRoot: URL) throws {
        guard access(repoRoot.path, W_OK) == 0 else {
            throw EngineError.cannotWrite(path: repoRoot.path, doing: "there is nowhere to save \(SiftPaths.configFileName) — drop --write to print the proposal")
        }
    }

    /// Throws where `run --without` could not make the `.sift/` its set-aside lives in.
    public static func requireSetAsideStore(repoRoot: URL) throws {
        guard !SiftEngine.wouldKeepIndexInMemory(root: repoRoot) else {
            throw EngineError.cannotWrite(path: repoRoot.path, doing: "there is nowhere to set the change aside (\(SiftPaths.directoryName)/) — run the tests without --without")
        }
    }
}
