//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The index call that would have answered a `Grep` or `Glob` of Swift source, and — the same question — whether one of those went around the index at all.
///
/// One type answers both because two separate answers drift. A metric that classifies a search by whether the word "swift" appears anywhere in its arguments, lowercased, counts *every* `Grep` ever made in a repo whose path holds `Sift`, and in a repo called `Depot` a `Grep` of `Sources/` for `DepotStore` is none of them — while the hook applies a careful rule the metric has never heard of. A miss one of them can see and the other cannot is either a nudge that never arrives or a number that cannot be trusted.
///
/// So a lookup *is* a suggestion here: `isSwiftLookup` is `suggestion != nil`, and there is no third state where something counts against the index but has no answer to offer. That holds for classification and the advice text; one layer up, the hook may still withhold a *built* suggestion whose symbol no index declares (`AdvisableName`, gated in `PreToolUseCommand.lookup`) — so a denial can be rarer than a counted miss, deliberately, and each withholding lands in the suppression log.
///
/// `Grep` is covered for a reason a count of `Grep` calls does not show, since a transcript can hold dozens of shell lookups and none through `Grep` at all. A model told "re-run the exact command and it will be allowed" has been handed a retry; a model that instead reaches for the tool that does the same job unrefused has been taught a detour, and the habit the refusal exists to build never forms. Its rules mirror `ShellInspection` down to the identifier gate, and ``textSearchReason(tool:input:in:)`` mirrors the shell's judgement of a search the index cannot serve, so which surface a search goes through cannot change the answer.
public struct SearchToolAdvice {
    /// The suggestion for a search tool's arguments, or `nil` when it is not a Swift lookup.
    ///
    /// Takes the raw tool input so the key names live in one place — `path` may be absent on a `Grep`, in which case it searches `directory`, exactly as a bare `grep -r` would.
    ///
    /// `memberExists` is injectable for the same reason `ShellAdvice`'s is: a caller sweeping many transcripts can hand in one memo for the whole pass rather than paying an index open per member offer. `nil`, the default every existing caller gets, asks `AdvisableName` fresh, exactly as it always has.
    public static func suggestion(
        tool: String,
        input: [String: Any],
        in directory: String? = nil,
        memberExists: ((String, String) -> Bool)? = nil
    ) -> IndexSuggestion? {
        switch tool {
        case "Grep": grepSuggestion(input, in: directory, memberExists: memberExists)
        case "Glob": globSuggestion(input)
        default: nil
        }
    }

    /// Whether this search went around the index — the same judgement, asked the other way round.
    public static func isSwiftLookup(tool: String, input: [String: Any], in directory: String? = nil) -> Bool {
        suggestion(tool: tool, input: input, in: directory) != nil
    }

    /// Which rule of ``TextSearch`` declares this search one the index could not have served, or `nil` where none does — the shell's judgement (`ShellAdvice.textSearchReason`), asked of this surface's fields.
    ///
    /// The glob narrows the path it is given, so either one confining the search to a tree no index holds is enough. The tool has no fixed-string mode, so that rule never reaches it.
    ///
    /// The tool searches a tree wherever its path is not one file, and its `-A`/`-B`/`-C` are the shell's own flags under another spelling, so a context grep meets the same verdict on either surface.
    ///
    /// A search is confined to what it names by its path *or* by its glob, as the shell's is by its operands (`ShellAdvice.Pipeline.confinedToNamedFiles`). `Grep(pattern: "printsContext|onlyMatching", glob: "Sources/SiftMCP/*.swift")` is the same search as `grep -n "printsContext|onlyMatching" Sources/SiftMCP/*.swift`, which the shell expands before `grep` ever sees it; reading the glob on one surface and not the other denied on this one what was silent on that one, for the shape whose whole objection is that the offer costs one `where` per name.
    public static func textSearchReason(tool: String, input: [String: Any], in directory: String? = nil) -> TextSearch.Reason? {
        textSearch(tool: tool, input: input, in: directory).flatMap(TextSearch.reason(for:))
    }

    /// The search ``textSearchReason(tool:input:in:)`` judges, read off this surface's fields, or `nil` where the call is no `Grep` lookup — for the audit, which asks one more question of it than the hook does (``TextSearch/namesNothingInOneFile(_:)``).
    static func textSearch(tool: String, input: [String: Any], in directory: String? = nil) -> TextSearch.Search? {
        guard tool == "Grep", suggestion(tool: tool, input: input, in: directory) != nil else {
            return nil
        }
        let path = (input["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // A glob that opens on `!` excludes the tree rather than confining the search to it — `!**/Pods/**`
        // rules `Pods` out, exactly as the shell's own `-g '!**/Pods/**'` does — so it never stands as the
        // path that narrows a search outside the indexed sources.
        let glob = (input["glob"] as? String).flatMap { $0.isEmpty || $0.hasPrefix("!") ? nil : $0 }
        let file = path.flatMap { $0.hasSuffix(".swift") ? $0 : nil }
        return TextSearch.Search(
            counting: input["output_mode"] as? String == "count",
            file: file,
            patterns: (input["pattern"] as? String).map { [$0] } ?? [],
            outsideIndexedSources: [path, glob].compactMap(\.self)
                .contains { SwiftTree.isOutsideIndexedSources($0, relativeTo: directory) },
            printsContext: ["-A", "-B", "-C"].contains { input[$0] is NSNumber },
            confinedToNamedFiles: file != nil || glob.map(namesTheFilesOfOneDirectory) == true,
            // `files_with_matches` is the tool's own default, so a call naming no mode prints file names too.
            listsFiles: (input["output_mode"] as? String ?? "files_with_matches") == "files_with_matches"
        )
    }

    /// Whether `glob` names the Swift files of one directory rather than filtering a walk of the tree.
    ///
    /// The tool has no `-r` for ``TextSearch/Search/confinedToNamedFiles`` to read, so the glob carries that distinction, and it carries it the way the tool's own matcher reads one: `*` and `?` never cross a `/`, so a glob holding a path and no `**` matches exactly the files the shell's expansion of the same text would have named. A glob with no path in it, or with `**`, floats over every directory instead — `*.swift` is `--include=*.swift` at the shell, a recursive sweep, which keeps its nudge because there the names' resolved sites are what a raw sweep cannot give.
    private static func namesTheFilesOfOneDirectory(_ glob: String) -> Bool {
        glob.contains("/") && !glob.contains("**") && SwiftSourcePath.appearsIn(glob)
    }

    private static func grepSuggestion(
        _ input: [String: Any],
        in directory: String?,
        memberExists: ((String, String) -> Bool)?
    ) -> IndexSuggestion? {
        let path = (input["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // A grep pointed INTO a build manifest is fine as it is — the index deliberately does not cover manifests.
        if let path, SwiftPMManifest.isManifestPath(path) {
            return nil
        }

        let file = path.flatMap { $0.hasSuffix(".swift") ? $0 : nil }
        let pattern = input["pattern"] as? String
        let answeredByOneCall = pattern.map(PatternReading.answeredByOneCall) == true
        // A `!` glob covering all Swift leaves it out, so the search is not of Swift source, as the shell's
        // `-g '!*.swift'` is not; one leaving out only some of it — `!*Tests.swift` — still searches the rest.
        let glob = input["glob"] as? String ?? ""
        guard !(glob.hasPrefix("!") && ShellQuery.coversAllSwift(glob, typeFlag: false)) else { return nil }
        // A search picking only other kinds of file is not of Swift source either, as the shell's `--include='*.md'`
        // is not. The glob decides when it picks files, as ripgrep lets it; the type only when no glob does.
        if file == nil {
            let type = input["type"] as? String ?? ""
            let picking = glob.isEmpty || glob.hasPrefix("!") ? nil : glob
            if let picking, ShellQuery.selectsNoSwift(picking, typeFlag: false) {
                return nil
            }
            if picking == nil, !type.isEmpty, ShellQuery.selectsNoSwift(type, typeFlag: true) {
                return nil
            }
        }

        guard namesSwift(input, path: path)
            || searchesSwiftTree(path ?? directory, in: directory, answeredByOneCall: answeredByOneCall)
        else {
            return nil
        }
        // A sweep is read as the shell's is, and a member offer is checked against the same index the shell's
        // is, so the surface a search goes through cannot change its verdict — `Grep(pattern:path:)` and the
        // `grep` that spells it are one question, and a model refused at one and waved through at the other
        // has been taught a detour rather than a habit.
        let memberExists = memberExists ?? { AdvisableName.couldAnswer(member: $0, of: $1, from: directory) }
        guard let file else {
            return .forSweep(pattern: pattern, memberExists: memberExists)
        }
        return .forSearch(
            pattern: pattern,
            symbol: pattern.flatMap { PatternReading.identifier(in: $0) },
            file: file,
            memberExists: memberExists
        )
    }

    /// A `Glob` asks which files exist, which the index answers better than a listing does — with what is *in* them.
    ///
    /// Two shapes, and the difference is the whole of it. `**/*.swift` is "what is here at all", which is the repo overview. `**/*Store.swift` is a name being hunted through file names, which is a path-scoped search — and that comes back with kinds and line ranges rather than a list of paths to then open one by one.
    private static func globSuggestion(_ input: [String: Any]) -> IndexSuggestion? {
        guard let pattern = input["pattern"] as? String, SwiftSourcePath.appearsIn(pattern) else {
            return nil
        }
        guard let fragment = nameFragment(of: pattern) else {
            return IndexSuggestion(
                call: "digest .",
                yields: "the repo overview — every module with its file and declaration counts, then `digest <Module>` for the one that matters"
            )
        }
        return IndexSuggestion(
            call: "search path:\(fragment)",
            yields: "the declarations in files whose path matches, with kinds and line ranges — not just the file names"
        )
    }

    /// The literal part of a glob's last component, or `nil` when it names no file in particular.
    private static func nameFragment(of pattern: String) -> String? {
        let last = pattern.split(separator: "/").last.map(String.init) ?? pattern
        let stem = last.hasSuffix(".swift") ? String(last.dropLast(6)) : last
        let literal = stem.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return literal.isEmpty ? nil : literal
    }

    /// Whether the arguments say "Swift" outright — a `.swift` path, a `swift` type, a glob naming the extension.
    private static func namesSwift(_ input: [String: Any], path: String?) -> Bool {
        if path?.hasSuffix(".swift") == true {
            return true
        }
        if (input["type"] as? String)?.lowercased() == "swift" {
            return true
        }
        return SwiftSourcePath.appearsIn((input["glob"] as? String) ?? "")
    }

    /// The unmarked case: a search pointed at a tree that holds Swift, for something one index call answers (``PatternReading/answeredByOneCall(_:)``).
    ///
    /// Both halves are load-bearing. Without the tree check this would fire on every `Grep` anywhere; without the pattern check it would refuse a repo-wide search for a phrase in a comment, which the index genuinely cannot serve. The pattern check reads an alternation as the several names it is and a declaration's form as the `search` that asks it, because a shape the shell's reading classifies and this one does not is a detour to be taught rather than a habit.
    private static func searchesSwiftTree(_ target: String?, in directory: String?, answeredByOneCall: Bool) -> Bool {
        guard answeredByOneCall, let target, let probe = SwiftTree.probe(relativeTo: directory) else { return false }
        return probe(target)
    }
}
