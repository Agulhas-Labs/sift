//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// What an index call was asked about, read from its arguments.
///
/// One place rather than two, because the usage log and the transcript scan both have to name a call and a report that named the same call differently in its log and its audit would be a report you have to reconcile before you can use it.
///
/// The key the calling tool itself reads comes first (``ArgumentAlias/readArgument``): `digest`'s `target:`, `where`'s `symbol:`, `strings`' and `search`'s `query:`. Another key sent beside it is something the tool never read, so naming the call by it would name a different call from the one answered — `strings symbol:"Engine" text:"Save changes"` searches for "Save changes", `where symbol:A target:B` resolves A, and `search query:"kind:struct" symbol:"Foo"` searched for `kind:struct`. Past that the order is fixed: `target`, `symbol`, `concept`, `query`, `path`, `text` — a fallback for a call missing its tool's own key, named by whatever it sent instead.
///
/// `concept` is read for a tool this server no longer serves. Transcripts and usage lines recorded while it did still carry those calls, and this reads what a call was *asked about* — dropping the key would leave a real call in the audit with no target beside it.
///
/// The usage log and the transcript scan both hand this a call as the server resolved it (``ArgumentAlias/resolved(tool:arguments:)``), so a healed call is named by the argument it was healed into on both. `path` and `text`, the two donor keys healed by what they carry rather than by name shape, are checked last for what the healing leaves behind: a call that sent one where nothing reads it, still named by what it was asked about. The `PreToolUse` hook's slip, and the claim that matches it, read a call as it was sent instead — before any healing — and name it through this too, with the same tool, so a slip and its claim agree with each other.
public struct IndexCallTarget {
    /// Each key is tested for a *string*, not merely for presence.
    ///
    /// `??` down the chain would stop at the first key that existed at all, so `digest target:5 symbol:"ParcelGateway"` would log no target though one was named — and the audit's failure rows read the same answer as the usage log.
    ///
    /// A `digest` that named its targets only under `targets:` is named by them joined with a space — one string, because this is what tells one call from another where a call has to be matched (the hook's slip against the server's claim of it, a failure against its reason), and both ends compute it from the same arguments.
    public static func of(_ arguments: [String: Any]) -> String? {
        for key in ["target", "symbol", "concept", "query"] {
            if let value = arguments[key] as? String {
                return value
            }
        }
        if let several = arguments["targets"] as? [String], !several.isEmpty {
            return several.joined(separator: " ")
        }
        return nil
    }

    /// The tool-aware form: the key the calling tool itself reads comes first (``ArgumentAlias/readArgument``), before the fixed fallback order — so a call is named by what its own tool actually read, and `path`/`text`, the two donor keys healed by what they carry rather than by name shape, still name a call that sent one where nothing reads it.
    public static func of(_ arguments: [String: Any], tool: String) -> String? {
        let own = ArgumentAlias.readArgument[tool].map { [$0] } ?? []
        for key in own + ["target", "symbol", "concept", "query", "path", "text"] {
            if let value = arguments[key] as? String {
                return value
            }
        }
        if let several = arguments["targets"] as? [String], !several.isEmpty {
            return several.joined(separator: " ")
        }
        return nil
    }

    /// Whether the call asked about Markdown documents and nothing else — the one answer this tool gives that is no Swift lookup, and so is counted on neither side of the index's share (``SiftMCP/ReadAdvice``).
    ///
    /// Asked of the name a call is remembered by rather than of its arguments, so the same question is answered the same way at the call, which must not enter the share, and at a failure of that call, which must not take back out of the share a lookup that never entered it.
    ///
    /// Only `digest` answers a document, so only `digest` is asked: a `strings` or a `search` whose query happens to end in `.md` is a search of Swift source for that text, and counting it out would be counting the tool's own subject out.
    ///
    /// A several-target call is one string joined by spaces (``of(_:tool:)``), so it is read whole first — which is how a document whose own path holds a space is named — and then by its parts. A call naming a document *and* Swift source is a Swift lookup like any other: it asked the index about Swift, and the answer it got back was the index's to give.
    public static func namesOnlyDocuments(_ target: String?, tool: String) -> Bool {
        guard tool == "digest", let target, !target.isEmpty else { return false }
        if MarkdownOutline.names(target) {
            return true
        }
        let parts = target.split(separator: " ")
        return parts.count > 1 && parts.allSatisfy { MarkdownOutline.names(String($0)) }
    }

    /// Whether a Bash command asks `digest` about a Markdown document — the CLI form of the call above, which the share leaves out on both sides exactly as it leaves out the matching MCP call.
    ///
    /// Asked beside the scan's own reading of an index CLI call rather than folded into it, because that reading has a second caller: a refusal's follow-up, where reaching for `sift digest <doc>.md` is the advice being taken and has to go on reading as taken.
    ///
    /// Any `.md` in the invocation is enough. A shell line carries no structure to tell a target from a flag's value — `--root /work` and the path it names are one list of words — so the exact question ``namesOnlyDocuments(_:tool:)`` asks of an MCP call's arguments cannot be asked here; erring towards leaving the call out under-counts the numerator, which is the direction that branch is already allowed to err in and never the one that flatters the share.
    public static func documentDigest(inCommand command: String) -> Bool {
        for segment in ShellSyntax.executedSegments(of: command) {
            let query = ShellQuery(segment)
            guard query.invokesSift, let siftIndex = query.invocation.firstIndex(where: {
                URL(fileURLWithPath: $0).lastPathComponent == "sift"
            }) else { continue }
            let arguments = query.invocation[(siftIndex + 1)...]
            guard arguments.first(where: { !$0.hasPrefix("-") }) == "digest" else { continue }
            if arguments.contains(where: MarkdownOutline.names) {
                return true
            }
        }
        return false
    }

    /// The targets each `sift digest` in a Bash command run from `directory` asks for, read statement by statement as the form without a directory reads them, each with the directory it runs in.
    ///
    /// That directory is `directory` moved by the literal `cd`s in front of the call, so `cd /work && sift digest X` is answered from the repository `/work` is in, as the CLI's own log line records it. A line that moves nowhere is read from `directory` whatever its shape.
    ///
    /// A digest whose directory a move on the line leaves unknown — a subshell, `pushd`, `cd -`, a substitution, a pipe the move is in, or a statement behind `||` — names nothing: crediting `directory` could record the digest of another repository's file against this one's, and a digest left out costs one answered read, never a wrong suppression.
    public static func cliDigests(inCommand command: String, from directory: String?) -> [(directory: String?, asked: (root: String?, target: String))] {
        let placed = InPlaceShape.statementDirectories(of: command, from: directory, requiringDirectories: false)
        guard command.contains(movesAnywhere) else {
            return (placed ?? [(command, directory)]).flatMap { statement, runsIn in cliDigests(inCommand: statement).map { (runsIn ?? directory, $0) } }
        }
        return (placed ?? []).flatMap { statement, runsIn in
            runsIn.map { runsIn in cliDigests(inCommand: statement).map { (runsIn, $0) } } ?? []
        }
    }

    /// A `cd`, `pushd` or `popd` word anywhere on a line, quoted, substituted or opening a subshell included: where a line holds none, every statement on it runs where the line does.
    nonisolated(unsafe) static let movesAnywhere = #/(?:^|[\s;&|(`{])(?:cd|pushd|popd)(?=$|[\s;&|)`}])/#

    /// The targets each `sift digest` in a Bash command asks for, with the `--root` it names, or `nil` where it names none and the caller's own repository answers.
    ///
    /// Read off the invocation as the CLI's parser reads it: a word after `digest` is a target unless it is a flag, and `--root`, `--offset` and `--at` take the word after them as their value. The advice hook records these as digests the context has been served (``AdviceLedger/digests(session:)``).
    ///
    /// A call carrying `--at` is left out entirely — it answers a past revision, never the working file its target names, so crediting that target as digested here would be as wrong as ``TranscriptScan``'s `weighsSource` crediting one; recording nothing is the safe direction.
    ///
    /// Cut at the first unquoted redirection exactly as the lookups read off the same command are — `sift digest Zed > /tmp/Engine.txt` names one target, `Zed`, never the file the shell sends its output to.
    public static func cliDigests(inCommand command: String) -> [(root: String?, target: String)] {
        var found: [(root: String?, target: String)] = []
        for segment in ShellSyntax.executedSegments(of: command) {
            let query = ShellQuery(segment)
            guard query.invokesSift, let siftIndex = query.invocation.firstIndex(where: {
                URL(fileURLWithPath: $0).lastPathComponent == "sift"
            }) else { continue }
            let cut = query.rawInvocation[(siftIndex + 1)...].prefix { $0.firstMatch(of: /^(\d*|&)[<>]/) == nil }.count
            var words = Array(query.invocation[(siftIndex + 1)...].prefix(cut))
            guard let subcommand = words.firstIndex(where: { !$0.hasPrefix("-") }), words[subcommand] == "digest" else { continue }
            words.remove(at: subcommand)
            var root: String?
            var targets: [String] = []
            var atRevision = false
            var index = 0
            while index < words.count {
                let word = words[index]
                if word == "--root" || word == "--offset" || word == "--at" {
                    if word == "--root", index + 1 < words.count {
                        root = words[index + 1]
                    }
                    if word == "--at" {
                        atRevision = true
                    }
                    index += 2
                    continue
                }
                if word.hasPrefix("--root=") {
                    root = String(word.dropFirst("--root=".count))
                } else if word.hasPrefix("--at=") {
                    atRevision = true
                } else if !word.hasPrefix("-") {
                    targets.append(word)
                }
                index += 1
            }
            guard !atRevision else { continue }
            found += targets.map { (root, $0) }
        }
        return found
    }

    /// The words after the binary of each `sift digest`, `where`, `search` or `strings` a Bash command runs — the argv that subcommand will be started with, which is what the hook's slip for it is named by (``CallAttribution/note(session:agent:arguments:)``).
    ///
    /// Read through the same unquoting every other reading of a shell line uses, and cut at the first redirection, whose operator and destination the shell consumes before the binary sees its argv. A word the shell rewrites — a variable, a glob — reads differently here from the argv it becomes, and that lookup's slip goes unclaimed, which leaves its line exactly as it would be with no hook at all.
    ///
    /// The cut is read off ``ShellQuery/rawInvocation``, quotes and all, so a redirection is only ever an *unquoted* one — `sift strings "<Settings>"` keeps its whole argv, because a quoted word opens with the quote character and never matches the operator, while an actual `sift where A > log` still cuts at `>`.
    ///
    /// **Every `sift` statement on the line files, even one a preceding statement's `&&`/`||` keeps the shell from ever starting.** `false && sift where A` files a slip for a lookup that never ran, exactly the exposure a denied MCP call already has (``CallAttribution``): unclaimed, it expires after the claim window, and an identical lookup from another context inside that window can claim it instead. Skipping a `sift` statement whenever its predecessor could have failed trades a rare mis-attribution for a common non-attribution — `cd /work && sift digest X`, the commonest shape a subagent writes, is skipped along with it.
    public static func cliLookups(inCommand command: String) -> [[String]] {
        ShellSyntax.executedSegments(of: command).compactMap { segment in
            let query = ShellQuery(segment)
            guard query.invokesSift else { return nil }
            let cut = query.rawInvocation.dropFirst().prefix { $0.firstMatch(of: /^(\d*|&)[<>]/) == nil }.count
            let words = Array(query.invocation.dropFirst().prefix(cut))
            guard let subcommand = words.first(where: { !$0.hasPrefix("-") }),
                  ["digest", "where", "search", "strings"].contains(subcommand)
            else { return nil }
            return words
        }
    }

    /// Every target a call named, one element each: `digest`'s `target` and then its `targets`, or the one name `of(_:)` reads for any other call.
    ///
    /// What the usage log records and the audit credits, where `of(_:)` is only what a call is matched by — several targets written as one string would be tallied as one name that nothing ever asked for.
    public static func all(_ arguments: [String: Any]) -> [String] {
        guard let several = arguments["targets"] as? [String], !several.isEmpty else {
            return of(arguments).map { [$0] } ?? []
        }
        return ((arguments["target"] as? String).map { [$0] } ?? []) + several
    }

    /// The tool-aware form of ``all(_:)``: the single-target case reads the calling tool's own key first, exactly as ``of(_:tool:)`` does, so `where symbol:A target:B` is named by `A` — what `where` actually resolves — and not by a `target` it never read.
    public static func all(_ arguments: [String: Any], tool: String) -> [String] {
        guard let several = arguments["targets"] as? [String], !several.isEmpty else {
            return of(arguments, tool: tool).map { [$0] } ?? []
        }
        return ((arguments["target"] as? String).map { [$0] } ?? []) + several
    }
}
