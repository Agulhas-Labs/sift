//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore

/// `diff`: a structural digest of a change, for review, in place of the raw `git diff`.
///
/// CLI only, on `affected`'s and `run`'s reasoning — a range review is invoked from a shell, and every MCP tool description is paid for in every session's context whether or not that session ever calls it.
struct DiffCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "diff",
            abstract: "Which declarations a git range added, removed, or changed, what else it touched, who calls the changed signatures, and which tests reach the changed files — for review, in place of the raw git diff.",
            discussion: """
            A `--member` answer's header line ends in an address of the form `path#Type.member:line`: the file, then `#`, then the declaration's label, then `:` and the line where it sits after the change. A declaration the range removed has no after side, so its address reads `path#Type.member:before:line`, the line it held before. The line keeps two same-named overloads apart. Pass the whole address back to `--member` to name that one declaration; the ambiguity refusal lists addresses in this form for that purpose.
            """
        )
    }

    @Argument(help: "A single commit (its own change, against its first parent), A..B (the two revisions as named), or A...B (B against its merge-base with A). Omitted: the working tree against HEAD, untracked files included.")
    var range: String?

    @Option(help: "Show one changed declaration's before/after body instead of the summary — Type.member, a labeled form like Type.save(_:to:), or an address a refusal listed.")
    var member: String?

    @Option(help: "Skip this many declaration entries (pagination cursor from a truncated: marker).")
    var offset = 0

    @Flag(help: "Add the coverage the last `sift run --coverage` recorded for the working tree's change, where it measured this very tree; otherwise say it is stale or absent.")
    var coverage = false

    @OptionGroup var rootOptions: RootOptions

    /// Where the roots this run touches are recorded — the standard registry everywhere but a test.
    var registry: () -> RootsRegistry = { .standard() }

    func run() async throws {
        let (text, refused) = try await answer(registry: registry())
        StandardStreams.emit(text)
        // A range this tool will not read is a refusal, not an answer about an empty change — a script must be able
        // to tell the two apart without parsing prose.
        if refused {
            throw ExitCode(1)
        }
    }

    /// The whole answer, header first and any adopted-root note under it, and whether it is a refusal of the range.
    func answer(registry: RootsRegistry = .standard()) async throws -> (text: String, refused: Bool) {
        if coverage, range != nil || member != nil {
            throw ValidationError("sift diff --coverage shows the working tree's change against HEAD, the one a coverage run measures, so it takes no range and no --member.")
        }
        let (engine, note) = try rootOptions.makeEngine(registry: registry)
        // The range is checked before the index is brought up to date: a refusal reads nothing the index holds, so it
        // must not pay for refreshing it — and says so in its header, which names the tree and nothing stored.
        let resolvedRange: DiffRange
        do {
            resolvedRange = try DiffRange.resolve(range, git: GitContext(repoRoot: engine.repoRoot))
        } catch let refusal as DiffRange.Refusal {
            return (Freshness.placing([note], under: Freshness.liveHeaderLine(tree: engine.tree) + "\n" + refusal.message), true)
        }
        let freshness = try await engine.ensureFresh()
        let options = DiffOptions(range: resolvedRange, member: member, offset: offset)
        let text = try await engine.diff(options: options, freshness: freshness, notes: [note])
        guard coverage else {
            return (text, false)
        }
        let section = CoverageRecord.section(in: engine.repoRoot, tree: TreeKey.of(repositoryRoot: engine.repoRoot))
        return (([text] + section).joined(separator: "\n"), false)
    }
}

extension DiffCommand {
    /// Only what comes off the command line — `registry` is a seam, not an argument.
    enum CodingKeys: String, CodingKey {
        case range, member, offset, coverage, rootOptions
    }
}
