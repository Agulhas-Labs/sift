//
// Copyright © Agulhas Labs
//

import Foundation
import RegexBuilder
import SiftCore

/// A call to make instead of the lookup that was about to happen, and what it gives back.
///
/// Shared by every advisor rather than owned by one, because the refusal text is written once and must read the same whichever kind of lookup produced it. `yields` exists so the advice is a trade rather than an instruction: a model told only "use digest" has no way to tell whether that answers its question.
public struct IndexSuggestion: Equatable, Sendable {
    /// The call, written as it would be typed: `digest SummaryState.refresh()`.
    public let call: String
    /// What that call returns, in one clause.
    public let yields: String
    /// The symbols the advised call stands on, when it names any — what the hook verifies against the index before denying anything on the strength of them.
    ///
    /// More than one where the call is one `where` per name of an alternation.
    public let symbols: [String]
    /// The line the advice opens with, naming what is on offer.
    ///
    /// Carried on the suggestion rather than written into the hook's template because not every suggestion trades a text match for a resolved one: `sift run` opens no file and answers the same question the command already asked, so an opening line about not opening files would be describing something else.
    public let offer: String
    /// What re-running the command anyway is legitimately *for*.
    ///
    /// Stated with an example rather than merely permitted, so the escape hatch reads as one. A model that infers the call is unavailable works around the block — reading the file whole, or by another route — which is a worse outcome than the command it replaced.
    public let escapeHatch: String

    public init(
        call: String,
        yields: String,
        symbol: String? = nil,
        offer: String = Self.lookupOffer,
        escapeHatch: String = ""
    ) {
        self.init(call: call, yields: yields, symbols: symbol.map { [$0] } ?? [], offer: offer, escapeHatch: escapeHatch)
    }

    public init(call: String, yields: String, symbols: [String], offer: String = Self.lookupOffer, escapeHatch: String = "") {
        self.call = call
        self.yields = yields
        self.symbols = symbols
        self.offer = offer
        self.escapeHatch = escapeHatch
    }

    /// The first symbol the call stands on — the only one, except for an alternation's.
    public var symbol: String? {
        symbols.first
    }

    /// The framing every lookup suggestion is delivered in — a text match traded for a resolved answer.
    public static var lookupOffer: String {
        "sift \(lookupOfferSuffix)"
    }

    /// The offer line without the tool's name, which is the part a transcript written under the old name still says verbatim.
    ///
    /// Split out because the transcript scan has to recognise a refusal it did not write — see `TranscriptScan.lookupOfferSuffix`.
    public static var lookupOfferSuffix: String {
        "answers this without opening the file:"
    }

    /// What a lookup held back with a pointer opens with — the part the transcript scan recognises it by, which no answered refusal's opening line and no refusal's offer line contains.
    public static var heldBackStem: String {
        "sift held this lookup back — already called in this context:"
    }

    /// What a lookup held back at calls the hook alone made opens with: they were answered in place beside the lookup, never called by the context.
    public static var answeredBesideStem: String {
        "sift held this lookup back — already answered beside this:"
    }

    /// The reason a lookup is held back with, naming the calls already made: each in backticks, joined by `, `.
    ///
    /// The calls' answers are not in it. They arrive in the same batch of results, which is why the pointer costs no round trip.
    ///
    /// `hookMade` is the subset of `calls` the hook made itself. Where every call is one, the line opens with ``answeredBesideStem``; where none is, with ``heldBackStem``; where some are, the context's own calls are named under ``heldBackStem`` and the hook's follow in a second sentence, so the line never says the context called what it did not.
    public static func heldBackReason(calls: [String], hookMade: Set<String> = []) -> String {
        func named(_ calls: [String]) -> String {
            calls.map { "`\($0)`" }.joined(separator: ", ")
        }
        let own = calls.filter { !hookMade.contains($0) }
        let hooks = calls.filter { hookMade.contains($0) }
        let tail = "Re-run the identical command for the raw output."
        if own.isEmpty {
            return "\(answeredBesideStem) \(named(hooks)), whose answer covers it. \(tail)"
        }
        let beside = hooks.isEmpty ? "" : " Also answered beside this: \(named(hooks))."
        return "\(heldBackStem) \(named(own)), whose answer covers it.\(beside) \(tail)"
    }
}

public extension IndexSuggestion {
    /// The call that answers a search for `symbol` within `file`, where a nil file means the search was not confined to one.
    ///
    /// The four outcomes here are the whole mapping, and it is drawn from what transcripts hold rather than from the tool surface. Most lookups that go around the index are shell commands, and nearly all of those are one of three shapes: `sed -n 'A,Bp' File.swift` (a ranged read done by hand), `grep -n Symbol File.swift` (one member's source), and `grep -rn Symbol Dir/` (a symbol's definition and its uses).
    ///
    /// Kept here rather than in either advisor because the `Grep` tool asks the identical question with different arguments, and a model refused at the shell that reaches for `Grep` instead must meet the same answer — otherwise the refusal has taught it a detour rather than a habit.
    ///
    /// With neither a name nor one file behind it the call is `search` alone: still built, because the miss happened and the audit files it under `search`, but ``namesATarget`` is false and the hook does not refuse on it. A *search* with no one file behind it is ``forSweep(pattern:)``'s.
    ///
    /// Only a name is a symbol and only a file a digest can be asked for is a file (``digestTarget(for:)``). A pattern that reached either slot — a bracket class, an escape, an empty stem — is set aside rather than written into the call, so what remains is the lookup as though it had not been there.
    static func forLookup(
        symbol: String?,
        file: String?,
        memberExists: (String, String) -> Bool = { _, _ in true }
    ) -> IndexSuggestion {
        let symbol = symbol.flatMap { isName($0) ? $0 : nil }
        // A glob stands for many files and a bare extension for none, so neither is a file to digest: the
        // search they bound is a sweep.
        let target = file.flatMap(digestTarget(for:))
        guard let symbol else {
            guard let target else {
                return IndexSuggestion(call: "search", yields: shapeYield)
            }
            return IndexSuggestion(
                call: "digest \(target)",
                yields: "every member with its exact line range, so the read that follows is a ranged one"
            )
        }

        // A pattern that already spells its own `Type.member` path names its own type, which is never
        // recombined with an unrelated file's stem — a bare word never invents a type, but a dotted symbol
        // offers the member only where the index holds it, and the type alone otherwise.
        if let dot = symbol.lastIndex(of: ".") {
            let type = String(symbol[..<dot])
            let member = String(symbol[symbol.index(after: dot)...])
            guard memberExists(member, type) else {
                return IndexSuggestion(
                    call: "where \(type)",
                    yields: "its declaration, extensions, conformers, callers and overrides, with exact line ranges",
                    symbol: type
                )
            }
            return IndexSuggestion(
                call: "where \(symbol)",
                yields: "its declaration, extensions, conformers, callers and overrides, with exact line ranges",
                symbol: symbol
            )
        }

        // A member is asked for through its file's stem, so a file whose stem is not a name has none to ask
        // through, and the name alone is the lookup.
        guard let stem = target, isName(stem) else {
            return IndexSuggestion(
                call: "where \(symbol)",
                yields: "its declaration, extensions, conformers, callers and overrides, with exact line ranges",
                symbol: symbol
            )
        }
        // `grep "struct RangeBounds" RangeBounds.swift` is looking for the type, not for a member of
        // it, and `digest RangeBounds.RangeBounds` resolves to nothing.
        guard symbol != stem else {
            return IndexSuggestion(
                call: "digest \(symbol)",
                yields: "its declaration surface — every member with its exact line range",
                symbol: symbol
            )
        }
        // Never offered unless the index holds `symbol` as a member of `stem` — otherwise the call cannot
        // answer, and the type-level digest is what is actually there.
        //
        // The fallback still stands on the word that was searched for, never on the stem it fell back to.
        // What decides whether a denial goes out is whether any index could answer for the name the caller
        // went looking for (`AdvisableName`, in `PreToolUseCommand.lookup`), and a suggestion standing on
        // nothing walks past that gate: a comment word, a log key, a local — none of them declarations —
        // would each earn a denial offering a digest that cannot say whether the file so much as mentions
        // them. The scan scores the same search out of the share on that same name, so dropping it here
        // would also split the two ends over one command.
        guard memberExists(symbol, stem) else {
            return IndexSuggestion(
                call: "digest \(stem)",
                yields: "every member with its exact line range, so the read that follows is a ranged one",
                symbol: symbol
            )
        }
        return IndexSuggestion(
            call: "digest \(stem).\(symbol)",
            yields: "that member's current source — and the candidate list, if the name is not a member of it",
            symbol: symbol
        )
    }

    /// The call that answers a search of one file for `pattern`: ``forLookup(symbol:file:)`` for the name it stands on — and where it stands on no one name but alternates between several, the file's digest carrying those names as the symbols it stands on.
    ///
    /// The digest is the answer either way. What the names add is the judgement a sweep for the same alternation already meets, so the two cannot differ on it: a search for words no index declares is a search for text, which the hook withholds when none of the names is declared (`AdvisableName`, in `PreToolUseCommand.lookup`) and the scan scores out of the share on the same names — as both do for `grep -rn "a\|b" Sources`. One declared name among them keeps the digest, which is what the file's shape answers.
    ///
    /// **Nothing arrives here through the hook in that shape, and the paragraph above is a rule about the reading rather than a path anything takes.** An alternation confined to the files a search names outright is withheld a rule earlier, on the price of the offer rather than on the names (``TextSearch/Reason/severalNames``), and a search naming one file is such a search — so `grep -n "waitForExit\|temporaryLog" RunLauncher.swift` never reaches the declaredness gate at all. Nor is any name search whose every operand is a named Swift file answered: the hook lets it run as written, whether it names one file, several, a glob or searches them recursively, because a name's `where` is about the whole tree and not about the files named. The one search of a member's declaration over such files is answered file by file, and a tree searched with a Swift file named beside it is withheld unchecked. This branch stands for what the advisor reads and for what would be offered if those rules ever stood aside.
    static func forSearch(
        pattern: String?,
        symbol: String?,
        file: String,
        memberExists: (String, String) -> Bool = { _, _ in true }
    ) -> IndexSuggestion {
        let lookup = forLookup(symbol: symbol, file: file, memberExists: memberExists)
        guard symbol == nil, let pattern, case let .names(names) = SweepPattern.reading(of: pattern) else { return lookup }
        let named = names.filter(isName)
        guard !named.isEmpty else { return lookup }
        return IndexSuggestion(call: lookup.call, yields: lookup.yields, symbols: named)
    }

    /// What `digest` is asked for to serve the file at `path`: its stem where that is a name, otherwise the file's own name, and otherwise the path itself — each of which `digest` resolves as the file.
    ///
    /// The stem is the form a type shares with the file that declares it, so it is the call people already know, and a name is a Swift identifier in any script (`Café`, `Über`). A stem that is not a name — `Date+Formatting` — names no symbol, so asked for by stem it answers "no symbol named"; asked for by `Date+Formatting.swift` it answers with the file. A name with a space in it is not one word of a call, so that file is asked for by the path it was read at. `nil` for a glob, which stands for many files, and for a path no call can carry: what a regex leaves when it is taken for a path — `[A-Za-z0-9_]+\` — is not a file anyone can digest.
    ///
    /// **One definition for both ends.** The hook refuses a whole read only where this names a target (`ReadAdvice`), and the scan scores a whole read of a file it names no target for out of the share, so a file the hook would never refuse a read of is never counted as a miss for it.
    static func digestTarget(for path: String) -> String? {
        guard !SwiftSourcePath.isGlob(path) else { return nil }
        let stem = stem(of: path)
        if isName(stem) {
            return stem
        }
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if name.wholeMatch(of: swiftFileName) != nil {
            return name
        }
        return path.wholeMatch(of: swiftFilePath) == nil ? nil : path
    }

    /// What `digest` is asked for to serve the Markdown document at `path`: **the path itself, always**, since a `.md` target is read live from disk by its exact path — repo-relative or absolute under the root.
    ///
    /// No stem and no bare file name, unlike ``digestTarget(for:)``. A document is not a symbol, so there is nothing for a stem to resolve to, and `digest Design.md` answers about a document at the repository root rather than the `Docs/Design.md` that was read — a miss offered as though it were the answer, which costs the caller the round trip the advice was meant to save.
    ///
    /// `nil` where the path is not one a call can carry: a glob, a pattern read as a path, a name with a character no file name holds. The same property ``isCallable(_:by:)`` asks, through the same expression, so the hook never withholds advice this built nor offers a target it would refuse.
    static func documentTarget(for path: String) -> String? {
        path.wholeMatch(of: markdownFilePath) == nil ? nil : path
    }

    /// The call that answers a sweep for `pattern` — a search with no one file behind it — by ``SweepPattern``'s reading.
    ///
    /// A name is `where` for it, and an alternation of names one `where` per name, each on a line of its own — with prose beside the names too, since the answer standing in for this offer names the prose it leaves to a search (``SweepPattern/partial(names:prose:)``). A shape is the `search` query that asks it. A pattern no index call answers gets `search` alone, which names no target: the hook withholds it and the scan scores it out of the share, on that one property.
    static func forSweep(pattern: String?, memberExists: (String, String) -> Bool = { _, _ in true }) -> IndexSuggestion {
        switch pattern.map(SweepPattern.reading(of:)) ?? .text {
        case let .names(names), let .partial(names, _):
            .forNames(names, memberExists: memberExists)
        case let .shape(query):
            IndexSuggestion(call: "search \(query)", yields: shapeYield)
        case .text:
            IndexSuggestion(call: "search", yields: shapeYield)
        }
    }

    /// One `where` per name, each on a line of its own — at most ``callCap`` of them, and a line counting the rest.
    ///
    /// The hook shows this only where every one of the names is declared, because a `where` for any other answers "no symbol named" — and an offer covering fewer names than the caller asked for is not the narrower version of this advice but a different question.
    static func forNames(_ names: [String], memberExists: (String, String) -> Bool = { _, _ in true }) -> IndexSuggestion {
        let names = names.filter(isName)
        guard names.count > 1 else {
            return .forLookup(symbol: names.first, file: nil, memberExists: memberExists)
        }
        return IndexSuggestion(
            call: capped(names.map { "where \($0)" }, counting: "name"),
            yields: "each name's declaration, extensions, conformers, callers and overrides — one call per name, because a search for several is that many questions",
            symbols: names
        )
    }

    /// One `digest` per file a read names — at most ``callCap`` of them, and a line counting the rest.
    ///
    /// A read of several files is several reads, and each is the shape `digest` replaces. A path no digest can be asked for is left out, and a read of nothing but those offers no call.
    static func forFiles(_ files: [String]) -> IndexSuggestion {
        var seen = Set<String>()
        let targets = files.compactMap(digestTarget(for:)).filter { seen.insert($0).inserted }
        guard !targets.isEmpty else {
            return .forLookup(symbol: nil, file: nil)
        }
        return IndexSuggestion(
            call: capped(targets.map { "digest \($0)" }, counting: "file"),
            yields: "each file's members with their exact line ranges, so the reads that follow are ranged ones"
        )
    }

    /// The call for a read of every file a glob matches: the module those files belong to, or the repo overview.
    ///
    /// The module is read off the path by the SwiftPM layout — `Sources/<Module>/` or `Tests/<Module>/` — which needs no index to resolve. A glob whose directory says nothing that way gets `digest .`, whose answer lists the modules to choose from.
    static func forGlob(_ glob: String) -> IndexSuggestion {
        let directories = glob.split(separator: "/").dropLast().map(String.init)
        let module = directories.indices.dropLast().first { ["Sources", "Tests"].contains(directories[$0]) }
            .map { directories[$0 + 1] }
            .flatMap { isName($0) ? $0 : nil }
        guard let module else {
            return IndexSuggestion(
                call: "digest .",
                yields: "the repo overview — every module with its file and declaration counts, then `digest <Module>` for the one that matters"
            )
        }
        return IndexSuggestion(
            call: "digest \(module)",
            yields: "every declaration in the module the glob reads, with its file and line range"
        )
    }

    /// The most calls one suggestion lists; the rest are counted rather than listed.
    static var callCap: Int {
        5
    }

    /// `calls`, one per line, cut to ``callCap`` with a closing line saying how many were left out.
    private static func capped(_ calls: [String], counting noun: String) -> String {
        guard calls.count > callCap else {
            return calls.joined(separator: "\n")
        }
        let omitted = calls.count - callCap
        return (calls.prefix(callCap) + ["… and \(omitted) more \(noun)\(omitted == 1 ? "" : "s") left out"]).joined(separator: "\n")
    }

    /// What `search` gives back.
    private static var shapeYield: String {
        "declarations by shape — kind: attr: name: calls: uses: has: — which a text match cannot express"
    }

    /// Whether the call names what it is to be run on, in a form the tool can be asked about.
    ///
    /// Every index call takes an argument, so a verb standing alone is not a call anyone can make: it names a tool rather than an answer, and a refusal offering one asks the caller to write the query the advisor could not. Nor is a call whose argument is what a pattern left behind — `digest [A-Za-z0-9_]+\`, `digest *.Split` — which costs the caller a round trip to learn it answers nothing. So every line of the call is held to what its tool accepts (``isCallable(_:by:)``), and one that fails makes the whole suggestion untargeted: withheld by the hook, and scored out of the share by the scan, which ask this same property.
    ///
    /// A wrapping is the caller's own command line rather than an index call, so it always names what it runs.
    var namesATarget: Bool {
        guard offer == Self.lookupOffer else {
            return call.split(separator: " ").count > 1
        }
        let lines = call.split(separator: "\n").filter { !$0.hasPrefix("… and ") }
        return !lines.isEmpty && lines.allSatisfy { line in
            let words = line.split(separator: " ", maxSplits: 1).map(String.init)
            return words.count == 2 && Self.isCallable(words[1], by: words[0])
        }
    }

    /// The file paths the offered calls name as their targets — the calls that can only be answered where that exact path has a repository to be rooted at.
    ///
    /// **A path target and a name target are answered by different routes, which is why only one of them is a claim about a tree.** `digest View` and `where View` are looked up in whatever index the caller's own root resolves to, so they are calls that can be made wherever the caller is standing. `digest Docs/Design.md` and `digest /x/Sources/My View.swift` are read at that path under a root, so a path standing outside every repository leaves them with nothing to resolve — which the hook reads as an offer it must not make (``SiftCLI/PreToolUseCommand/lookup(command:payload:in:noting:digested:couldAnswer:)``).
    ///
    /// A Markdown target is always one: ``documentTarget(for:)`` names a document by its path and nothing else. A Swift target rarely is — a stem or a bare file name is a name the index resolves — and the rule is the same for the ones that are.
    var pathTargets: [String] {
        calls.compactMap { line in
            let words = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard words.count == 2, words[0] == "digest", Self.namesAPath(words[1]) else { return nil }
            return words[1]
        }
    }

    /// The calls this offer is made of, one per line of ``call`` — several `where`s for an alternation of names, one for everything else.
    ///
    /// The offer's side of the comparison the ledger makes before it refuses (``AdviceLedger/decide(session:command:offering:)``). A capped offer's closing `… and N more` line is kept as a call of its own rather than filtered out, unlike ``namesATarget``: it stands for calls this cannot name, so an offer carrying one can never be proven to say nothing new.
    ///
    /// A wrapping is a command line rather than an index call and can never match a call made, so it costs one set lookup that always misses — cheaper than a shape test to skip it.
    var calls: [String] {
        call.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// The calls an index tool's own payload made, spelled the way ``call`` spells one — `where SimilarTarget`, `digest Gizmo` — or nothing for anyone else's tool.
    ///
    /// **One spelling for both sides, which is the whole of what makes the comparison exact.** An offer is rendered text and a call made is a tool name with arguments; normalised here to the offer's spelling, and whitespace-collapsed by the ledger on the way in and out, they are one string or they are two different calls.
    ///
    /// One element per target, so a `digest` given several answers for each of them — joined into one name they would match nothing, and a context that digested three files would be offered a fourth `digest` as though it had made no call at all. Read through ``IndexCallTarget/all(_:tool:)``, the tool-aware form, so a single-target call is named by the key its own tool reads — `where symbol:A target:B` resolves `A`, not the `target` it never looked at.
    ///
    /// A tool call is read only for this server's MCP tools. Taking the advice from Bash (`sift where SimilarTarget`) is read through `command`, below, and only in a plain spelling: a context whose transcript records the server gone is offered the CLI spelling (``cliCall``), which is not the string a tool call is offered.
    ///
    /// `root` pins the spelling to the repository the call actually ran against — the caller's resolved root, whether stated on the call or read off its own working directory. Without it, a call made against one repository would read as circular for the identical question asked of a completely different one: `RepositoryIndex` is scoped to a repository "never to the machine", and a call this remembers has to be too.
    ///
    /// `command` is the shell text of a Bash call, whose own calls through the CLI count too, spelled the same: a `where` or a `digest` of plain targets, one call per target. A command with a `cd`, `pushd` or `popd` contributes none, nor one with a pipe, a redirection, a chain of statements or a trailing `&` (``runsAlone(_:)``), and neither does a call carrying any flag (`--root`, `--refs`, `--at`): the spelling a flag changes is not one a suggestion can be compared with, so it is not recorded as made.
    static func callsMade(toolName: String?, input: [String: Any], command: String? = nil, root: String?) -> [String] {
        var calls: [String] = []
        if let toolName, let tool = IndexToolName.tool(named: toolName) {
            calls = IndexCallTarget.all(input, tool: tool).map { "\(tool) \($0)" }
        }
        // A move can put the call in another repository, which the root it is spelled at would then misname.
        if let command, !command.contains(IndexCallTarget.movesAnywhere), runsAlone(command) {
            calls += IndexCallTarget.cliLookups(inCommand: command).flatMap { words -> [String] in
                guard let verb = words.first, ["where", "digest"].contains(verb), !words.contains(where: { $0.hasPrefix("-") }) else { return [] }
                return words.dropFirst().map { "\(verb) \($0)" }
            }
        }
        return rooted(calls, at: root)
    }

    /// Whether `command` is one plain statement: no pipe, no chaining, no redirection and no trailing `&`.
    ///
    /// A call whose output is cut, redirected or run beside other statements has an answer that is not the whole one, so it is not a call made. Read through ``ShellSyntax``, which knows a quoted `|` or `>` from a real one.
    static func runsAlone(_ command: String) -> Bool {
        let statements = ShellSyntax.executedStatements(of: command)
        guard statements.count == 1, ShellSyntax.executedSegments(of: command).count == 1,
              !ShellSyntax.runnableText(command).trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("&")
        else { return false }
        return !ShellSyntax.executableText(of: statements[0]).contains { $0 == "<" || $0 == ">" }
    }

    /// `calls`, each pinned to `root` when one is known — the same qualifier a call made and a call offered must agree on before either can say the other is circular (see ``callsMade(toolName:input:root:)``).
    ///
    /// A `nil` or empty root leaves `calls` unchanged rather than qualifying with nothing: a call whose repository could not be resolved is not thereby made to match every other call that could not resolve one either.
    static func rooted(_ calls: [String], at root: String?) -> [String] {
        guard let root, !root.isEmpty else { return calls }
        return calls.map { "\($0) @\(root)" }
    }

    /// Whether this is one call per name — a `where` for each name of an alternation, and nothing else standing on the same names.
    ///
    /// **The distinction both ends need before they judge an alternation against what the index declares.** A suggestion of this shape asks exactly as many questions as the caller did, one per branch, so it is worth only as much as the names it can still stand on. One file's digest standing on several names (``forSearch(pattern:symbol:file:memberExists:)``) is the other shape: it is a single answer that covers the file whatever the names are, so one declared name among them keeps it.
    ///
    /// Read by rebuilding the per-name call and comparing, since the shape is a property of the call rather than a case anything records. A lone name is neither shape — it is the plain lookup ``forLookup(symbol:file:memberExists:)`` builds — so it is excluded here rather than left to the comparison, which cannot tell the two apart.
    var isOneCallPerName: Bool {
        symbols.count > 1 && self == .forNames(symbols)
    }

    /// The call as it runs from Bash: every line behind the binary's name, its argument quoted where the shell would split or expand it — or the call unchanged for a wrapping, which already runs there.
    ///
    /// What an answer's opening line names once the transcript records the MCP server gone from the context (``ServerPresence``): a call nothing in the context can make is a call the answer cannot claim to have made, while the binary that answered is on the machine.
    var cliCall: String {
        guard offer == Self.lookupOffer else { return call }
        return call.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard !line.hasPrefix("… and "), let space = line.firstIndex(of: " ") else { return String(line) }
            let argument = String(line[line.index(after: space)...])
            return "sift \(line[..<space]) \(ShellWord.quoted(argument))"
        }.joined(separator: "\n")
    }

    /// Whether `tool` can be asked about `target`.
    ///
    /// `where` takes a name or a dotted path of names; `digest` takes those, the repo overview `.`, a Swift file by its own name or its path, and a Markdown document by its path; `search` takes `field:value` terms, each negatable. Everything else — a bracket class, an escape, a wildcard, an empty component — is what a regex leaves when it is read as a name, and no call answers it.
    static func isCallable(_ target: String, by tool: String) -> Bool {
        switch tool {
        case "digest":
            target == "." || isName(target) || target.wholeMatch(of: swiftFileName) != nil
                || target.wholeMatch(of: swiftFilePath) != nil || target.wholeMatch(of: markdownFilePath) != nil
        case "where":
            isName(target)
        case "search":
            target.split(separator: " ").allSatisfy { $0.wholeMatch(of: searchTerm) != nil }
        default:
            false
        }
    }

    /// Whether `target` names a file by its path — the form `digest` answers by reading that exact path under a root, rather than by a name it resolves out of the index.
    ///
    /// A `.md` target is one always, by the same test the renderer routes on: a document is read live from disk and has no name to resolve. A Swift target is one only where neither a stem nor a bare file name could carry it — `Sources/App/My View.swift`, which ``digestTarget(for:)`` falls back to the path for.
    static func namesAPath(_ target: String) -> Bool {
        if MarkdownOutline.names(target) {
            return true
        }
        guard !isName(target), target.wholeMatch(of: swiftFileName) == nil else { return false }
        return target.wholeMatch(of: swiftFilePath) != nil
    }

    /// Whether `text` is a name or a dotted path of names — `UsageWindow`, `Outer.Nested.member`, `Café`.
    ///
    /// A name is a Swift identifier, and Swift identifiers are not confined to ASCII: a letter or underscore in any script, then letters, combining marks, digits and underscores.
    static func isName(_ text: String) -> Bool {
        text.wholeMatch(of: dottedName) != nil
    }

    /// The wrapper, inserted at each toolchain statement in a line rather than in front of the line.
    ///
    /// A line is more than its build: `cd Tools/Linter && swift test` prefixed as a whole would run the wrong package's tests, so the caller splices this in at the statements it recognised and leaves the rest alone.
    static var toolchainRunPrefix: String {
        "sift run -- "
    }

    /// The call that replaces `call` — the caller's own line with ``toolchainRunPrefix`` spliced into it — routing its toolchain commands through the output filter.
    ///
    /// The only suggestion here that is not a trade of one question for another. Every other one swaps a text match for a resolved answer, which is why they are worth a round trip; this one runs the identical commands and differs only in what comes back, so its whole case is the output. That is also the reason it can be advised at all under Docs/Design.md §1's standing rejection of a hook that forces tool use: rewriting a grep into `where` answers a different question, where prefixing `swift test` answers the same one.
    ///
    /// Where the line holds statements the wrapper was not put in front of, the offer says the wrapper reaches no further than its own statement. A line whose first statement is the build opens with the wrapper, and read as a wrapping of the whole line it looks like a call that cannot run — a commit handed to the output filter — so the advice is re-run past rather than taken.
    static func forToolchainRun(_ call: String, besideOtherStatements: Bool = false) -> IndexSuggestion {
        IndexSuggestion(
            call: call,
            yields: "just the failures and the tool's own summary, with the full output kept under .sift/runs/",
            offer: besideOtherStatements
                ? "sift serves this command's failures instead of its whole log — each `sift run --` wraps only the " +
                "statement it stands in front of, and the rest of the line runs as written:"
                : "sift serves this command's failures instead of its whole log:",
            escapeHatch: "If you want the raw output anyway — a progress line, a path the filter drops, " +
                "a command this has no filter for — re-run this exact command and it will be allowed."
        )
    }

    /// A Swift file's own name, as `digest` resolves one: the characters file names are made of, in any script, and none of the ones a pattern is.
    ///
    /// `nonisolated(unsafe)` for the reason ``SwiftSourcePath/extensionExpression`` gives: `Regex` is not `Sendable`, and every caller is serial.
    nonisolated(unsafe) private static let swiftFileName = /[\p{L}\p{N}_][\p{L}\p{M}\p{N}_+\-.]*\.swift/

    /// A path to a Swift file, as `digest` resolves one: a file name that may hold spaces, behind directories that hold none of the characters a glob, an escape, an alternation or a shell expansion is made of.
    nonisolated(unsafe) private static let swiftFilePath =
        /(?:[^\/\\*?\[\]{}|$`\n\r\t]*\/)*[\p{L}\p{N}_][\p{L}\p{M}\p{N}_+\-. ]*\.swift/

    /// A path to a Markdown document, as `digest` resolves one: the Swift path's own shape, ending in `.md` in any case — the extension spelled here as `MarkdownOutline.names` reads it.
    nonisolated(unsafe) private static let markdownFilePath =
        /(?:[^\/\\*?\[\]{}|$`\n\r\t]*\/)*[\p{L}\p{N}_][\p{L}\p{M}\p{N}_+\-. ]*\.[mM][dD]/

    /// A Swift identifier in any script: a letter or underscore, then letters, combining marks, digits and underscores.
    ///
    /// The one definition of a name, read by everything that decides whether text names one — a call's target here, and a search pattern's names in `ShellQuery` and `SweepPattern` — so the hook cannot offer a call on a name the pattern reader did not see, nor the reader find a name no call accepts.
    nonisolated(unsafe) static let identifier = /[\p{L}_][\p{L}\p{M}\p{N}_]*/

    /// A name or a dotted path of names, each a Swift identifier in any script.
    nonisolated(unsafe) static let dottedName = Regex {
        identifier
        ZeroOrMore {
            "."
            identifier
        }
    }

    /// One `search` term: a field, its value, and the `!` that negates it.
    nonisolated(unsafe) private static let searchTerm = /!?[a-z]+:[\p{L}\p{N}_]+/

    /// The file name a path ends in, without its `.swift` extension — the name `digest` takes.
    static func stem(of path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.hasSuffix(".swift") ? String(name.dropLast(6)) : name
    }
}
