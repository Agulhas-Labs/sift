//
// Copyright © Agulhas Labs
//

/// The one-line freshness header every query answer opens with — the header never claims more than it knows (Docs/Design.md §2).
public struct Freshness: Sendable {
    /// Which checkout the rest of this line is about — the subject the other three fields are facts *of*.
    ///
    /// First, because that is what it is. `head:`, `dirty:` and `parse_errors:` are all measurements of one tree, and a header that stated them without naming the tree would let two different checkouts of one repository produce identical headers — which is how a subagent can be served its parent's answers and see nothing wrong.
    public let tree: WorkingTree
    public let headShort: String
    public let dirtyCount: Int
    public private(set) var parseErrorFiles: Int
    /// The semantic axis for THIS response; queries that never touched the store say so.
    public var semantic: SemanticAxis = .syntacticOnly
    /// The files this answer found changed under their rows although `git status` did not list them, reparsed from the live file before it was rendered.
    public var reparsedPaths: [String] = []
    /// The files this answer found changed the same way but could not reparse, so their old rows still stand.
    public var unreparsedPaths: [String] = []

    /// What `head:` says where the repository has no commit yet.
    public static var unbornHead: String {
        "unborn"
    }

    public var headerLine: String {
        "\(WorkingTree.fieldOpening)\(tree.rendered)\(WorkingTree.fieldSeparator)head: \(headShort)  \(movementFields)  semantic: \(semantic.rendered)"
    }

    /// The two fields saying how far the tree has moved from `head:` and what could not be read, or the one word `clean` for both.
    ///
    /// `clean` is a claim and not a default: it is written only for a revision that exists, a dirty count of zero with no file reparsed from outside git's list, and a parse-error count of zero. Anything short of that prints both fields, so a header never says `clean` about a tree it did not measure to be one (Docs/AnswerContract.md §1).
    private var movementFields: String {
        if headShort != Self.unbornHead, dirtyCount == 0, parseErrorFiles == 0, reparsedPaths.isEmpty, unreparsedPaths.isEmpty {
            return "clean"
        }
        return "dirty: \(dirtyCount)\(reparsedNote)  parse_errors: \(parseErrorFiles)"
    }

    /// This header naming `paths` as reparsed from the live file, for a face framing a digest that carries them (``MeasuredAnswer/reparsedPaths``).
    public func noting(reparsed paths: [String], unreparsed unreparsedPaths: [String] = []) -> Freshness {
        var noted = self
        noted.reparsedPaths = paths
        noted.unreparsedPaths = unreparsedPaths
        return noted
    }

    /// This header naming `paths` as reparsed and `unreparsedPaths` as not, with the parse-error count read after those reparses.
    public func noting(reparsed paths: [String], unreparsed unreparsedPaths: [String], parseErrorFiles count: Int) -> Freshness {
        var noted = noting(reparsed: paths, unreparsed: unreparsedPaths)
        noted.parseErrorFiles = count
        return noted
    }

    /// This header carrying what `answer` found while it read its source: the files it reparsed or could not, and the parse-error count as the reparse left it.
    public func noting(_ answer: MeasuredAnswer) -> Freshness {
        var noted = noting(reparsed: answer.reparsedPaths, unreparsed: answer.unreparsedPaths)
        noted.parseErrorFiles = answer.parseErrorFiles ?? parseErrorFiles
        return noted
    }

    /// The `dirty:` count's addendum naming each reparsed file, single-spaced inside so it never reads as a field of its own.
    private var reparsedNote: String {
        guard !reparsedPaths.isEmpty || !unreparsedPaths.isEmpty else { return "" }
        var clauses: [String] = []
        if !reparsedPaths.isEmpty {
            let files = reparsedPaths.count == 1 ? "file" : "files"
            clauses.append("reparsed from the live \(files): \(reparsedPaths.joined(separator: ", "))")
        }
        if !unreparsedPaths.isEmpty {
            clauses.append("could not be reparsed: \(unreparsedPaths.joined(separator: ", "))")
        }
        return " (+\(reparsedPaths.count + unreparsedPaths.count) not in git status, \(clauses.joined(separator: "; ")))"
    }

    /// The header for an answer read live from the working tree rather than from stored rows — `search` and `strings`.
    ///
    /// The tree and nothing else. `head:`, `dirty:` and `parse_errors:` describe the index, which these two never open, so stating them would mean bringing an index up to date for a line about something the answer did not use. What such an answer does need is its subject: without it a subagent in a worktree could not tell which checkout a search had been run over, which is the one question the `tree:` field exists to settle. No semantic axis either, since nothing here consults the build's store.
    public static func liveHeaderLine(tree: WorkingTree) -> String {
        "\(WorkingTree.fieldOpening)\(tree.rendered)\(WorkingTree.fieldSeparator)source: working tree, read live — nothing stored to go stale"
    }

    /// `answer` with `notes` placed directly under its header line.
    ///
    /// The header leads every answer (Docs/AnswerContract.md §1), and a note is no exception to that: an adopted root or an argument read under another key is a remark *about* the answer, and a reader who has learned to find the tree on line one should not have to hunt for it on line two. `answer` must open with its header, which every answer the four query tools build does.
    public static func placing(_ notes: [String?], under answer: String) -> String {
        let present = notes.compactMap(\.self)
        guard !present.isEmpty else { return answer }
        let parts = answer.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return ([parts[0]] + present + parts.dropFirst()).joined(separator: "\n")
    }
}
