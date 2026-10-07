//
// Copyright © Agulhas Labs
//

/// Failures the engine reports with instructions rather than guesses.
public enum EngineError: Error, CustomStringConvertible, Sendable {
    /// The payload carries the registry's known roots, so a portfolio session's rootless query is taught the fix instead of just refused.
    case notAGitRepository(String, knownRoots: [String] = [])
    /// A directory the caller named (`--root`, `root:`) that is no git work tree and has no indexed one under it: refused by name, because answering from any other tree would answer a question that was not asked.
    case notAGitWorkTree(String)
    /// A structural query that could not be parsed; the payload carries the field list, so a wrong guess teaches the language instead of just failing.
    case malformedQuery(String)
    /// A rootless query whose target several indexed *repositories* match — the one case root resolution must not guess (see `RootResolver`).
    ///
    /// Worktrees of one repository are collapsed before this is reached, so every root listed here is genuinely different code.
    case foundInSeveralRoots(RootEvidence, roots: [String])
    /// A `digest` offset sent with several targets.
    ///
    /// An offset is a cursor into one answer, the one whose truncation marker handed it out; applied to every answer in the call, it would skip that many lines of each, and of all but one it is a cursor into something it was never read from.
    case offsetWithSeveralTargets(count: Int)
    /// A `digest` offset sent with a line range that resolves to several declarations — the same refusal, for the same reason, where the several answers come from one target.
    ///
    /// The way out is each truncated block's own range, which its truncation line names: those lines resolve to that one declaration, where the offset pages it. Its header's name is not the same call — for a type, the name serves the type's digest, not the rest of its source.
    case offsetAcrossSeveralDeclarations(target: String, count: Int)
    /// A `--at` revision that cannot be answered from, or a target that cannot be answered at one — the payload is the whole refusal, in git's own words where git refused.
    case revisionRefused(String)
    /// `index` or `reconcile` asked of a tree whose index is held in memory because the tree cannot be written: either would build an index and throw it away, and report it as done.
    case treeNotWritable(String)
    /// `init --write` or `run --without` asked of a tree where the file each would write cannot be made: the tree, and what that leaves the command without (``TreeWritability``).
    case cannotWrite(path: String, doing: String)

    public var description: String {
        switch self {
        case let .notAGitRepository(path, knownRoots):
            {
                let base = "\(path) is not inside a git repository — sift indexes one repo per root and needs git for its freshness contract."
                guard !knownRoots.isEmpty else { return base }
                return base + " Pass root: with one of the previously indexed roots:\n"
                    + knownRoots.map { "  \($0)" }.joined(separator: "\n")
            }()
        case let .notAGitWorkTree(path):
            "\(path) is not a git work tree — sift indexes a git work tree, so it answers nothing about this folder and will not answer from another tree in its place."
        case let .malformedQuery(detail):
            detail
        case let .foundInSeveralRoots(evidence, roots):
            "\(evidence.ambiguityPhrase) \(roots.count) indexed repositories — pass root: with the one you mean:\n"
                + roots.map { "  \($0)" }.joined(separator: "\n")
        case let .offsetWithSeveralTargets(count):
            "an offset pages one answer, and this call named \(count) targets — repeat it with only the target whose answer was truncated"
        case let .offsetAcrossSeveralDeclarations(target, count):
            "an offset pages one answer, and \(target) spans \(count) declarations — repeat it with the range the truncated declaration's own truncation line names"
        case let .revisionRefused(message):
            message
        case let .treeNotWritable(path):
            "\(path) cannot be written, so there is no stored index to build or reconcile — digest, where and status index this tree in memory on each call."
        case let .cannotWrite(path, doing):
            "\(path) cannot be written, so \(doing)."
        }
    }
}
