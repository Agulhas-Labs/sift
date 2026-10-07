//
// Copyright © Agulhas Labs
//

import CryptoKit
import Foundation

/// A Swift file an edit left unparseable: the content the edit left and where the parser failed on it.
///
/// The `PostToolUse` hook's check on what an agent writes, the counterpart of the `PreToolUse` hook's on what it reads. Syntax only: a type error needs a build, which no hook runs.
public struct EditParseCheck: Sendable {
    /// SHA-256 of the file's bytes as the check read them, so one content is reported once.
    public let contentHash: String
    /// The path the errors are named under: repository-relative where a root holds the file, as given otherwise.
    public let displayPath: String
    /// The errors the edit added, in source order; never empty.
    public let errors: [ParseErrorSite]
    /// How many errors the file had before the edit: zero where it parsed or where the payload did not say.
    public let preexisting: Int
    /// Whether a usable index holds the repository the file is in and the index's own inclusion rule takes the file, so the reason can say what the broken file costs its answers.
    public let indexed: Bool

    /// Errors named in ``reason`` before the rest are counted instead.
    static var shownCap: Int {
        5
    }

    /// Reads and parses `file`, naming it relative to `root` where `root` holds it; `nil` when the file cannot be read as UTF-8, parses cleanly, or has no error the edit added.
    ///
    /// Whether `root` is indexed, and what the file held before the edit, are asked only once the parse has failed, so a clean edit costs one parse. Where `prior` cannot say what the file held, every error counts as the edit's. `hunks` are the edit's patch, which says where it touched the file, whatever `prior` is.
    public static func run(file: String, root: String?, prior: EditPrior = .unknown, hunks: [EditPrior.Hunk] = []) -> EditParseCheck? {
        guard let data = FileManager.default.contents(atPath: file),
              let source = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let displayPath = root.flatMap { ReuseNudge.relativePath(of: file, under: $0) } ?? file
        var errors = FileParser.errors(inSource: source, path: displayPath)
        guard !errors.isEmpty else { return nil }
        var preexisting = 0
        if let before = prior.source(before: source) {
            let earlier = FileParser.errors(inSource: before, path: displayPath)
            preexisting = earlier.count
            errors = added(errors, in: source, beyond: earlier, in: before, hunks: hunks)
            guard !errors.isEmpty else { return nil }
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let indexed = root.map { ReadOnlyIndex.hasUsableIndex(atRoot: $0) && indexCovers(file, under: $0) } ?? false
        return EditParseCheck(contentHash: hash, displayPath: displayPath, errors: errors, preexisting: preexisting, indexed: indexed)
    }

    /// The errors in `after` that `before` does not account for, one for one: first by message, column and the text of the line each sits on, so an error the edit only moved is matched where it stands, then by message alone, so one whose line the edit touched is not counted as new.
    ///
    /// The message-only pass pairs an old error and a new one only within one of the edit's `hunks`, the new error on a line the hunk left and the old one on a line it replaced: an edit that fixes an error in one place and adds one with the same message in another is reported. Without hunks it does not run, and an error whose line the edit touched is reported.
    static func added(
        _ after: [ParseErrorSite],
        in afterSource: String,
        beyond before: [ParseErrorSite],
        in beforeSource: String,
        hunks: [EditPrior.Hunk] = []
    ) -> [ParseErrorSite] {
        let afterLines = EditPrior.lines(of: afterSource)
        let beforeLines = EditPrior.lines(of: beforeSource)
        let passes: [(ParseErrorSite, ParseErrorSite) -> Bool] = [
            { new, old in
                guard let text = lineText(of: new, in: afterLines) else { return false }
                return new.message == old.message && new.column == old.column && text == lineText(of: old, in: beforeLines)
            },
            { new, old in
                new.message == old.message && hunks.contains { $0.newRange.contains(new.line) && $0.oldRange.contains(old.line) }
            },
        ]
        var unmatched = before
        var isNew = [Bool](repeating: true, count: after.count)
        for matches in passes {
            for (index, error) in after.enumerated() where isNew[index] {
                guard let found = unmatched.firstIndex(where: { matches(error, $0) }) else { continue }
                unmatched.remove(at: found)
                isNew[index] = false
            }
        }
        return after.indices.filter { isNew[$0] }.map { after[$0] }
    }

    /// The text of the line `error` sits on, `nil` where the line is out of range, as past the last `"\n"` of a file whose lines break at a lone `"\r"`, which the parser counts and ``EditPrior/lines(of:)`` does not.
    private static func lineText(of error: ParseErrorSite, in lines: [String]) -> String? {
        lines.indices.contains(error.line - 1) ? lines[error.line - 1] : nil
    }

    /// Whether the index's inclusion rule takes `file` under `root`: the enumerator's rules, then git's ignore rules, as `digest` applies them to name a file "not indexed".
    ///
    /// The index need not hold the file yet: a new file that will be indexed is covered, and an ignored one or one under a build directory never is.
    public static func indexCovers(_ file: String, under root: String) -> Bool {
        let rootURL = URL(fileURLWithPath: root)
        guard let relative = ReuseNudge.relativePath(of: file, under: root),
              let config = try? SiftConfig.load(repoRoot: rootURL)
        else {
            return false
        }
        return FileEnumerator(repoRoot: rootURL, config: config).exclusion(of: relative) == nil
            && !GitContext(repoRoot: rootURL).ignores(relativePath: relative)
    }

    /// The feedback the model is handed on its edit: each error as `path:line:col message`, capped, then what the broken file costs until it is fixed.
    ///
    /// The index is not held back at the last good parse: a reindex stores what the parser recovered from the broken file and flags it, which is what the last sentence says where an index is there to say it about.
    public var reason: String {
        let shown = errors.prefix(Self.shownCap).map { "\(displayPath):\($0.line):\($0.column) \($0.message)" }
        let rest = errors.count > Self.shownCap ? ["and \(errors.count - Self.shownCap) more"] : []
        var ending = "The edit left \(displayPath) unparseable; fix it before going on."
        if indexed {
            ending += " Until it parses again, sift indexes only what the parser recovered from it, so answers about it may be missing declarations."
        }
        let heading = preexisting > 0
            ? "sift: syntax errors this edit added (the file had \(preexisting) before it):"
            : "sift: syntax errors after this edit:"
        return ([heading] + shown + rest + [ending]).joined(separator: "\n")
    }
}
