//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Reads a command, or a read, for the lookups the advice hook may answer with an index call itself (``InPlaceCall``).
///
/// **A shape is only a candidate; four of the six are given only where they are proven exact** (``InPlaceAnswerer``). A whole read of one Swift file is that file's digest. A grep of one file for its declarations is that file's digest, a grep of one file for a member's declaration is the source of every member it matches, and a word-anchored sweep for one name is `where --refs` for it — each answered only where the grep, run in-process over the same files, prints no line the answer does not account for.
///
/// **The other two are the deliberate exceptions, and each is the offer's own answer rather than a proof.** A tree search whose pattern reads as a name or an alternation of names (``SweepPattern``) is one plain `where` per name — exactly the call the refusal would have named — so nothing is run and nothing is proven: the hook already asserts `where` answers the search when it offers it, and a refusal that only names the call costs the context a round trip to reach the same text. Bounded by the size budget and the back-off like every other shape, and never taken where the anchored reading above already applies, which is exact. A whole read of one Markdown document is that document's heading outline, handed over on the same footing and for a reason of the same kind: nothing about a `.md` file is indexed, so there is no proof to build and the outline is what `digest` itself renders for that path.
///
/// Everything else is refused as before, with its call named rather than run: several files, a glob, a phrase, a use of a name rather than its declaration, and any search that is inverted, counted, only-matching, listing files, handed several patterns, run behind an environment assignment or sending its output anywhere but a `head` or a `tail`.
public struct InPlaceShape {
    /// The lookup inside `command` and the call that answers it in place, or `nil` where the command carries no answered shape.
    ///
    /// The lookup itself has to be the whole of its statement, so what is answered is what was asked: one pipeline whose only other stage is a `head` or a `tail` cutting the same text — which the search then applies to what it prints — with no substitution, no output to a file, no redirection but standard error's, and nothing in front of either stage's command word: an environment assignment can change what the command does (`GREP_OPTIONS=-v`), and a subshell's brace what it runs in.
    ///
    /// **Other statements may ride beside it only where they print nothing the answer leaves out**: a `cd`, a literal `echo` or `printf` label, or a `||` fallback proven silent. The answer then covers the lookup and says so (``Match/isWholeCommand``). Any other statement — an `ls`, a `sed` over a document, a search this does not answer — prints what nothing stands in for, and a refusal answering one part of the line would cost a re-run of all of it to save that part, so the match is marked (``Match/runsOtherStatements``) and the line runs.
    ///
    /// **Several reads are one match** (``Match/calls``): where every lookup of the command is a read — a `cat` or a line window of a Swift file, or a `cat` of a Markdown document beside one — each read is answered, in command order, under one header. That is the natural shape for gathering files, and every read in it asks the same kind of question. They have to resolve against one directory, no file may be read whole twice — several windows of one file share its one digest — and one Swift read at least must be among them, since the shell route classifies no document read standing alone as a lookup. Beside any other lookup a document's `cat` rides as it always has.
    ///
    /// These still refuse the whole command: a substitution anywhere in it, an `exec` anywhere in it, which replaces the shell with the command it names so that nothing after it runs, a lookup itself sitting after a `||` — a branch that would not have run — or a `||` whose tail is not proven silent (``isSilentFallback(_:)``), since a fallback that prints could add a line to the real output the in-place answer never accounts for, and a second lookup where the two are not both whole reads — the refusal names one call, and answering a different statement's question than the one it offers would be two answers to two questions with nothing saying which is which. A lookup *before* the first `||` is matched as though that tail were absent, the same ride-along the paragraph above already allows for `;`/`&&`.
    ///
    /// **A lookup the ledger has already allowed is not the question**, where the predicate passed in holds of its statement's text: its identical re-run is let through on the record of the answer it was given, so on a line with a new lookup beside it, the match is about the new one. It still prints its own output, which no answer to the new one reproduces, so the match is marked (``Match/runsOtherStatements``) and the line runs: a denial would swallow that output. The default holds of no statement, which is every line as it always was.
    public static func match(forShell command: String, in directory: String?, ridingAlong: (String) -> Bool = { _ in false }) -> Match? {
        guard !command.contains("$("), !command.contains("`") else { return nil }
        let statements = ShellSyntax.statementRanges(of: command)
        guard !statements.contains(where: { isCompoundMarker($0.statement) || replacesTheShell($0.statement) }) else { return nil }
        let joints = joints(of: command, between: statements)
        let ordinary = ordinaryMatch(command, statements: statements, joints: joints, in: directory, ridingAlong: ridingAlong)
        // A line of two lookups or more is answered whole where every statement on it can be (``CompoundLine``),
        // carrying the line as it always was read for where that answer is withheld (``Match/ordinary``).
        if let compound = CompoundLine.match(command, statements: statements, joints: joints, in: directory, ridingAlong: ridingAlong) {
            return compound.falling(backTo: ordinary)
        }
        return ordinary
    }

    /// The match a line is read as without the compound rule: its one lookup, or several reads, as the shell matcher above describes them.
    private static func ordinaryMatch(
        _ command: String,
        statements: [(statement: String, range: Range<String.Index>)],
        joints: [String],
        in directory: String?,
        ridingAlong: (String) -> Bool
    ) -> Match? {
        let scoped: ArraySlice<(statement: String, range: Range<String.Index>)>
        if let firstOr = joints.firstIndex(of: "||") {
            // A lookup before the first `||` always runs — the joint only decides whether the *tail* runs, and
            // the tail is matched as though it were absent, exactly as a `;`/`&&` ride-along already is. What
            // makes `||` different is that the tail's own turn is conditional on the lookup's exit status: a
            // fallback that prints (`|| echo none`) would add a line the in-place answer never accounts for
            // whenever the lookup fails. A tail proven silent — `true` or `:`, which never print whatever they
            // are handed — is let through as it stands, and any other only behind a lookup whose own success
            // the answer proves (``Match/fallbackFollows``).
            guard joints[..<firstOr].allSatisfy(sequences) else { return nil }
            guard statements[(firstOr + 1)...].allSatisfy({ isSilentFallback($0.statement) }) else {
                return fallbackMatch(command, statements: statements, joints: joints, firstOr: firstOr, in: directory, ridingAlong: ridingAlong)
            }
            scoped = statements[...firstOr]
        } else {
            guard joints.allSatisfy(sequences) else { return nil }
            scoped = statements[...]
        }
        var directory = directory
        // Each lookup as the match it would be alone, so what it is — its call, its directory, whether it is a
        // window — travels together.
        var found: [Match] = []
        // The lookups riding along are lookups of the line still, and a name grep beside one rides along too.
        var ridingLookups = 0
        for statement in scoped {
            if movesDirectory(statement.statement) {
                // Only into a directory that is there: a `cd` to a dangling or looping link, or to nothing, fails, and
                // the reads after it run from where the line started, or not at all behind an `&&`.
                guard let moved = changeOfDirectory(statement.statement), let resolved = resolve(moved, against: directory),
                      CompoundLine.isDirectory(resolved)
                else {
                    return nil
                }
                directory = resolved
                continue
            }
            guard let call = call(forStatement: statement.statement) else { continue }
            guard !ridingAlong(statement.statement) else {
                ridingLookups += call.call.shape == .outline ? 0 : 1
                continue
            }
            found.append(Match(
                calls: [call.call],
                directory: operandDirectory(directory, reading: statement.statement),
                isWholeCommand: false,
                windowed: [call.isWindow],
                lookups: 1,
                statements: [[statement.statement]]
            ))
        }
        // A name search that names a Swift file is a lookup only where it is the command's one lookup: beside
        // another it is dropped from the match, so the lookups left are answered without it and it runs as
        // written. The only such search that gets this far is the tree-plus-file form, whose call is withheld
        // unchecked where it stands alone. That holds whatever the ledger has allowed.
        if found.count(where: { $0.call.shape != .outline }) + ridingLookups > 1 {
            found.removeAll { isNameSearchOfNamedFiles($0.call) }
        }
        let match: Match
        if found.count > 1, found.allSatisfy({ $0.call.readPath != nil }) {
            guard let read = reads(found, statements: statements.count) else { return nil }
            match = read
        } else {
            let lookups = found.filter { $0.call.shape != .outline }
            guard lookups.count == 1, let only = lookups.first else { return nil }
            match = Match(
                calls: only.calls,
                directory: only.directory,
                isWholeCommand: statements.count == 1,
                windowed: only.windowed,
                lookups: 1,
                statements: only.statements
            )
        }
        let answered = Set(match.statements.joined())
        return match.running(others: statements.contains { !answered.contains($0.statement) && !printsNothingUnanswered($0.statement) })
    }

    /// Whether `statement`, beside a lookup answered in place, prints nothing the answer leaves out: a `cd`, a literal `echo` or `printf` whose text the command itself spells (sending its own standard error away changes nothing about it), a shell variable assignment, `export`, `unset` or `set`, or a `||` fallback proven silent.
    ///
    /// A lookup whose identical re-run the ledger already let through is not one: it prints its source.
    private static func printsNothingUnanswered(_ statement: String) -> Bool {
        guard !setsNothingVisible(statement) else { return true }
        let unredirected = droppingStandardErrorRedirect(statement)
        return movesDirectory(unredirected) || CompoundLine.printedText(of: unredirected) != nil || isSilentFallback(statement)
    }

    /// `statement` with a trailing standard-error redirect (``isStandardErrorRedirection(_:)``) dropped, since sending stderr away leaves what it prints on its own output unchanged.
    private static func droppingStandardErrorRedirect(_ statement: String) -> String {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.split(separator: " ").last, isStandardErrorRedirection(String(last)) else { return statement }
        return String(trimmed.dropLast(last.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `statement` only assigns, exports or unsets a shell variable, or sets a shell option: none of it prints anything or resolves a path the answer would need to account for.
    private static func setsNothingVisible(_ statement: String) -> Bool {
        guard let word = ShellQuery(statement).invocation.first else { return true }
        return ["export", "unset", "set"].contains(word)
    }

    /// The match for a lookup in front of a `||` whose fallback could print — `sed -n '1,30p' F.swift || find . -name F.swift` — or `nil` where the fallback could run without the answer knowing it.
    ///
    /// The fallback runs only where the list in front of the `||` fails, so the answer stands exactly where that list's success is proven, and the match hands that proof to the answer (``Match/fallbackFollows``). The list may hold `cd` moves this can follow and the one lookup, nothing else: a ride-along's exit status is not known, and a `cd` is followed only into a directory that is there on disk, since one to a dangling or looping link, or to nothing, fails and a relative read behind it would find another file or none. Every joint from the `||` on is another `||`, since a `;` or an `&&` after the fallback runs whatever the lookup did, and nothing after the last statement may background the list. A name grep standing alone is refused: its success is a line printed, and that answer runs no search to show one. The fallback itself is never read, since it never runs.
    ///
    /// **A leading `!` is refused outright.** It negates the list's exit status, so a lookup that *succeeded* reads as failed and the fallback is judged to have run when it did not — or the reverse, a lookup that failed reads as proven. Either way the status the match would stand on is not the lookup's own, so no proof can be built from it.
    ///
    /// **A pipeline's status is its last stage's, so that stage is proven to exit 0 and every stage of a window is.** A window is proven only where every stage is fully parsed (``InPlaceCall/fileDigest(path:windows:)``'s `windows` is not empty) and on ``FallbackProof``'s closed list, and a lookup piped into a cut only where the cut is on it: the read-window shape a plain digest answer is content to fall back from (``windowedRead(of:)``) is not proof enough here, because a `head -0`, an unknown option, a second operand or an `awk` body that can act fails or prints nothing the digest's lines account for, and the fallback would have run in its place.
    private static func fallbackMatch(
        _ command: String,
        statements: [(statement: String, range: Range<String.Index>)],
        joints: [String],
        firstOr: Int,
        in directory: String?,
        ridingAlong: (String) -> Bool
    ) -> Match? {
        guard let last = statements.last, joints[firstOr...].allSatisfy({ $0 == "||" }),
              command[last.range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              statements[..<firstOr].allSatisfy({ movesDirectory($0.statement) })
        else {
            return nil
        }
        var directory = directory
        for move in statements[..<firstOr] {
            guard let moved = changeOfDirectory(move.statement), let resolved = resolve(moved, against: directory),
                  CompoundLine.isDirectory(resolved)
            else {
                return nil
            }
            directory = resolved
        }
        let lookup = statements[firstOr].statement
        guard lookup.trimmingCharacters(in: .whitespacesAndNewlines).prefix(while: { !$0.isWhitespace }) != "!" else { return nil }
        guard !ridingAlong(lookup), let found = call(forStatement: lookup), found.call.shape != .outline,
              provesItsSuccess(lookup, answeredBy: found)
        else {
            return nil
        }
        // The fallback never runs, so the answer stands for every statement from the lookup on.
        return Match(
            calls: [found.call],
            directory: operandDirectory(directory, reading: lookup),
            isWholeCommand: false,
            windowed: [found.isWindow],
            lookups: 1,
            fallbackFollows: true,
            statements: [statements[firstOr...].map(\.statement)]
        )
    }

    /// Whether the statement `lookup`, answered by `found`, is proven to exit 0 wherever its answer stands, so a `||` fallback after it never runs and an `&&` after it always does.
    ///
    /// A pipeline's status is its last stage's, so a lookup piped into a cut is proven only where the cut is on ``FallbackProof``'s closed list, and a window only where every stage is fully parsed and on it. A name grep standing alone is never proven: its success is a line printed, and its answer runs no search to show one. Anything else — a whole read, or a grep whose answer is built from the lines its own search prints — is proven by its answer: a read's file is asked for at answer time, and every grep shape requires a line printed.
    static func provesItsSuccess(_ lookup: String, answeredBy found: (call: InPlaceCall, isWindow: Bool)) -> Bool {
        let stages = ShellSyntax.segments(of: lookup).map { ShellQuery($0).invocation }
        if case .symbols = found.call, stages.count < 2 {
            return false
        }
        if found.isWindow {
            guard case let .fileDigest(_, windows) = found.call, !windows.isEmpty else { return false }
            return FallbackProof.isProvenWindow(stages)
        }
        guard stages.count > 1 else { return true }
        return stages.last.map { FallbackProof.exitsZero($0, operands: 0) } ?? false
    }

    /// The match several reads are, one call per file in the order first named, or `nil` where they cannot share one answer: a directory moved between them, a file read whole twice or whole beside a window of it, or no Swift file among them.
    ///
    /// Several windows of one file are one digest: the digest answers every window of the file at once, and a second copy of it would say nothing the first did not.
    private static func reads(_ found: [Match], statements: Int) -> Match? {
        let directory = found[0].directory
        guard found.allSatisfy({ $0.directory == directory }), found.contains(where: { $0.call.shape == .read }) else { return nil }
        var files: [String] = []
        var calls: [InPlaceCall] = []
        var windowed: [Bool] = []
        var answering: [[String]] = []
        for read in found {
            let file = read.call.readPath.map { resolve($0, against: directory) ?? $0 } ?? ""
            if let earlier = files.firstIndex(of: file) {
                guard read.windowed == [true], windowed[earlier] else { return nil }
                answering[earlier] += read.statements.joined()
                // Every window's lines ride on the one digest, or none do where any window's cannot be read.
                if case let .fileDigest(path, known) = calls[earlier], case let .fileDigest(_, more) = read.call {
                    calls[earlier] = .fileDigest(path: path, windows: known.isEmpty || more.isEmpty ? [] : known + more)
                }
                continue
            }
            files.append(file)
            calls.append(read.call)
            windowed.append(contentsOf: read.windowed)
            answering.append(Array(read.statements.joined()))
        }
        return Match(
            calls: calls,
            directory: directory,
            isWholeCommand: found.count == statements,
            windowed: windowed,
            lookups: found.count,
            statements: answering
        )
    }

    /// The call that answers one statement in place, and whether the statement reads its file through a line window, or `nil` where the statement is not one of the answered shapes.
    static func call(forStatement statement: String) -> (call: InPlaceCall, isWindow: Bool)? {
        let stages = ShellSyntax.segments(of: statement).map(ShellQuery.init)
        if let window = windowedRead(of: stages) {
            return (window, true)
        }
        guard let query = stages.first, stages.count <= 2, stages.allSatisfy(\.opensOnItsCommandWord) else { return nil }
        var cut: ShellGrep.Cut?
        if stages.count == 2 {
            guard let stageCut = ShellGrep.cut(ofStage: stages[1].invocation) else { return nil }
            cut = stageCut
        }
        guard !query.writesOutputToAFile else { return nil }
        return call(for: query, cut: cut, piped: stages.count == 2).map { ($0, false) }
    }

    /// The digest that answers a line window on one Swift file as a whole read of it is answered — `sed -n '1,200p' F.swift`, `head -80 F.swift`, `cat F.swift | head -80` — or `nil` where the statement is no such window.
    ///
    /// The window is the whole statement, read the way the advisor reads it (the pipeline reading of a window ``ShellQuery`` holds), with every stage opening on its command word and printing to the terminal, so the digest stands in for exactly what the statement would have shown. A stage with an option after its file (``LineWindow/placesAnOptionAfterAnOperand``) fails on the system tools part way through, and is no window; nor is any stage not proven to run only to print (``runsOnlyToPrint(_:)``), since what it prints may be an error, or not all it does.
    private static func windowedRead(of stages: [ShellQuery]) -> InPlaceCall? {
        guard !stages.isEmpty, let path = ShellQuery.windowedReadPath(of: stages, readBy: 0), isSwiftFile(path),
              stages.allSatisfy({ $0.opensOnItsCommandWord && !$0.writesOutputToAFile }),
              !stages.contains(where: { $0.invocation.contains { !isStandardErrorRedirection($0) && isAnyRedirection($0) } })
        else {
            return nil
        }
        let window = LineWindow(stages: stages.map(\.invocation))
        guard !window.placesAnOptionAfterAnOperand, !window.hasIllegalCount, runsOnlyToPrint(stages) else { return nil }
        return .fileDigest(path: path, windows: window.isReadable ? [window] : [])
    }

    /// Whether a joint runs the next statement after the last as a plain sequence does: `;`, `&&`, or a line break, which trims to nothing.
    static func sequences(_ joint: String) -> Bool {
        joint == "&&" || joint == ";" || joint.isEmpty
    }

    /// Whether `statement` opens or closes a compound command rather than running one: a brace or a parenthesis standing alone, a keyword that only makes sense as one leg of `if`/`for`/`while`/`case`/a function body, or a `name()` definition.
    ///
    /// A line break already reads as a plain sequence (``sequences(_:)``), which is right for a run of statements gathering files and wrong for one a shell keyword or a block has cut apart: `{ cat F; } > out.txt` and a multi-line `for`/`if`/`case` both split into statements this way, and every one of them answers a different question than the whole command asked, or answers none at all. Any one of them present anywhere in the sequence takes the whole match down with it, rather than only the statement it names.
    static func isCompoundMarker(_ statement: String) -> Bool {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        if "{}()".contains(first) {
            return true
        }
        let word = trimmed.prefix { !$0.isWhitespace }
        if compoundKeywords.contains(String(word)) {
            return true
        }
        guard word.hasSuffix("()"), let opener = word.first, opener.isLetter || opener == "_" else { return false }
        return word.dropLast(2).allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// The keywords that only ever open or close a leg of a compound command: `if`/`for`/`while`/`until`/`case` and their closers, and `function`.
    private static let compoundKeywords: Set<String> = [
        "then", "do", "done", "fi", "else", "elif", "esac", "case", "while", "until", "for", "if", "function",
    ]

    /// The text between each pair of neighbouring statements — the operator that sequenced them.
    static func joints(of command: String, between statements: [(statement: String, range: Range<String.Index>)]) -> [String] {
        zip(statements, statements.dropFirst()).map { left, right in
            command[left.range.upperBound ..< right.range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The call that answers a whole read of the file at `path`: a Swift file's digest, a Markdown document's heading outline — the one call the refusal names — and `nil` for a read of anything else, which the refusal names a call for without one being run here.
    ///
    /// **A document is answered, and it is the offer's own answer rather than a proof.** A Swift read's proof is that the path resolves to a file *the index holds* (`ExactAnswer.indexedFile`, then a digest whose own header names that same file). Nothing about a `.md` file is indexed, so there is no such proof to build and no index to bring up to date: the outline is what `digest <path>.md` itself renders, read live from disk at the exact path the read named — exactly the call the refusal would have listed, so refusing only charges the context a round trip to arrive at the same text. Handed over unproven on the same footing as ``InPlaceCall/symbols(names:paths:)``.
    ///
    /// It carries a back-off shape of its own (``InPlaceCall/Shape/outline``), so a document that runs long never switches off the in-place answers of the Swift reads beside it; and a document small enough that `digest` would serve its text rather than a table of contents never reaches here at all, because `ReadAdvice` withholds the offer for it (`DigestFloor.wouldServeContent`).
    public static func call(forRead path: String) -> InPlaceCall? {
        if MarkdownOutline.names(path) {
            return .documentOutline(path: path)
        }
        return isSwiftFile(path) ? .fileDigest(path: path) : nil
    }

    /// The same, as the match a read is: a read is the lookup and nothing else, since a `Read` carries no other work to do.
    ///
    /// A ranged read of a Swift file carries its `window`, so the members its lines overlap can answer where the file's digest is over the size budget.
    public static func match(forRead path: String, in directory: String?, window: LineWindow? = nil) -> Match? {
        guard var call = call(forRead: path) else { return nil }
        if case let .fileDigest(swiftFile, _) = call, let window {
            call = .fileDigest(path: swiftFile, windows: [window])
        }
        return Match(call: call, directory: directory, isWholeCommand: true)
    }

    /// The lookup a `Grep` is, and the call that answers it in place, or `nil` where the tool's arguments carry no answered shape.
    ///
    /// **One shape reaches this surface: the names sweep**, which is the only one that needs no grep run to prove it. The proven four all rest on reproducing the caller's own search (``ShellGrep``), and a `Grep` is ripgrep behind a JSON payload rather than a command line this can re-run — so a `Grep` of one file is refused here exactly as it always was, and only the shape that hands over the offer's own answer is taken.
    ///
    /// The fields are read as ``SearchToolAdvice`` reads them to build the very offer being handed over, so the two cannot disagree about what a search is: `path` ending in `.swift` is one file and no sweep, a manifest is not indexed, a glob or a type that picks no Swift source is no search of Swift, a count prints numbers rather than the lines a `where` stands in for, and `-A`/`-B`/`-C` ask for the text around a match, which a resolved answer does not carry. `Glob` never matches — it asks which files exist, and carries no pattern for a name to be read out of.
    ///
    /// The match's directory is the search's *own* path where it names one, resolved against `directory` — the anchor the hook already roots a `Grep`'s offer on — so the answer comes from the repository the search names rather than from wherever the session happens to be standing.
    public static func match(forSearchTool tool: String, input: [String: Any], in directory: String?) -> Match? {
        guard tool == "Grep" else { return nil }
        let path = (input["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard path?.hasSuffix(".swift") != true, !(path.map(SwiftPMManifest.isManifestPath) ?? false) else { return nil }
        // A glob is a bound the answer cannot follow. `Sources/**` or `!Tests/**` narrows the search to a subtree
        // no operand names, and `!*Tests.swift` drops files a `where` answer would still list — so a `where`
        // standing in for any of them covers more than the search did, and a name found only where the glob
        // does not reach would be answered "yes" for a search that prints nothing. Only a glob picking every
        // Swift file — `*.swift`, `**/*.swift` — leaves the search where its path put it; any other declines the
        // shape, and the search runs as written.
        let glob = input["glob"] as? String ?? ""
        guard glob.isEmpty || (!glob.hasPrefix("!") && ShellQuery.coversAllSwift(glob, typeFlag: false)) else { return nil }
        let picking = glob.isEmpty ? nil : glob
        // The searched subtree is both what roots the answer and what bounds it, so it is resolved once and
        // carried in the call as well as in the match's directory: a `Grep`'s directory *is* the path it searched.
        let searched = path.flatMap { resolve($0, against: directory) }
        let type = input["type"] as? String ?? ""
        if picking == nil, !type.isEmpty, ShellQuery.selectsNoSwift(type, typeFlag: true) {
            return nil
        }
        // `-i` declines the shape here as on the shell: a case-folded search prints sites `where`, which resolves
        // the name as written, would not list.
        guard input["output_mode"] as? String != "count",
              (input["-i"] as? Bool) != true,
              !["-A", "-B", "-C"].contains(where: { input[$0] is NSNumber }),
              let pattern = input["pattern"] as? String,
              let call = symbolsCall(forPattern: pattern, paths: searched.map { [$0] } ?? [])
        else {
            return nil
        }
        return Match(call: call, directory: searched ?? directory, isWholeCommand: true)
    }

    /// The call for one pipeline stage, or `nil` where it is not one of the shapes.
    private static func call(for query: ShellQuery, cut: ShellGrep.Cut?, piped: Bool) -> InPlaceCall? {
        // Paired, not filtered separately, so a raw word never drifts from the unquoted one beside it once
        // a stderr redirection drops out of both.
        let paired = zip(query.invocation, query.rawInvocation).filter { !isStandardErrorRedirection($0.0) }
        let words = paired.map(\.0)
        guard let verb = words.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) else { return nil }
        let rest = Array(words.dropFirst())
        let rawRest = Array(paired.dropFirst().map(\.1))
        guard !rest.contains(where: isAnyRedirection) else { return nil }
        switch verb {
        case "cat":
            // A whole read, and only a whole read: a `head` after it is a window, and a flag but `-n` changes the text.
            guard !piped, rest.count == 1 || (rest.count == 2 && rest[0] == "-n"), let file = rest.last,
                  !SwiftSourcePath.isGlob(file)
            else {
                return nil
            }
            // A quoted `~` names a directory called `~`, which no read here stands in for.
            guard ShellOperand(raw: rawRest.last ?? "")?.quotesLeadingTilde != true else { return nil }
            return call(forRead: file)
        case "awk" where rest.count == 2 && ShellQuery.printsEveryLine(awkProgram: rest[0]):
            // A whole read spelled in `awk`, numbered or not, answered as the `cat -n` it prints.
            guard !piped, let file = rest.last, isSwiftFile(file) else { return nil }
            return call(forRead: file)
        case "sed", "awk":
            // A pattern range, answered only where the lines it prints prove to be one member's source.
            guard !piped, let (file, range) = RangeRead.reading(words), isSwiftFile(file) else { return nil }
            return .memberRange(file: file, range: range)
        case "grep":
            // A glob whose wildcard is quoted or escaped reaches the search as the literal path it spells, since no
            // shell expanded it; one whose quotes or escapes hold only the rest of its path, a space say, is expanded.
            let literal = zip(query.invocation, query.rawInvocation).compactMap { word, raw -> String? in
                guard let shell = ShellOperand(raw: raw) else { return word != raw && SearchOperand(path: word).isGlob ? word : nil }
                return shell.quotesAGlobCharacter && SearchOperand(path: shell.value).isGlob ? shell.value : nil
            }
            return grepCall(rest, rawArguments: rawRest, cut: cut, literal: Set(literal))
        default:
            return nil
        }
    }

    /// Whether every operand is a Swift file or a glob of them, so a search is about those files alone and no `where` of the whole tree stands in for it.
    ///
    /// The hook's gate for letting such a search run, and the audit's scan asks it of the same operands, so the two cannot disagree about which searches that is.
    static func namesOnlySwiftFiles(_ paths: [String]) -> Bool {
        paths.allSatisfy { $0.hasSuffix(".swift") }
    }

    /// The call for a `grep`'s arguments, or `nil` where a flag, the operands or the pattern leave the shapes.
    ///
    /// Context lines are allowed for a member's declaration alone: its source may hold them, and the search accounts for each one printed. A file's digest numbers declarations and nothing between them, and a sweep's references are lines, so context on either could only ever be refused.
    ///
    /// An operand among `literal` is a glob the shell passed on unexpanded, which the search reads as one file's name that is never there, so no answer speaks for it. A brace expansion (`{Uses,Gizmo}.swift`) leaves the shape the same way: the shell would have split it into several paths before the search ran, which no `where` here stands in for.
    private static func grepCall(_ arguments: [String], rawArguments: [String]? = nil, cut: ShellGrep.Cut?, literal: Set<String> = []) -> InPlaceCall? {
        guard var search = ShellGrep(arguments: arguments, rawArguments: rawArguments),
              !search.paths.contains(where: literal.contains),
              !search.paths.contains(where: SwiftSourcePath.isBraceExpansion)
        else { return nil }
        search.cut = cut
        let namesFiles = search.paths.contains { $0.hasSuffix(".swift") }
        if search.recursive, !namesFiles {
            // A whole-line search (`-x`) prints only a line that is the name alone, which a declaration site
            // almost never is, so neither reading below would answer what the search itself prints — withheld
            // before either is tried, rather than after the anchored one is proven wrong.
            guard !search.paths.isEmpty, !search.hasContext, !search.options.wholeLine else { return nil }
            // The anchored reading stays first: it is exact, and an answer that accounts for every line the
            // grep prints is worth more than the same call handed over unproven. Where that proof fails, the
            // answerer asks the same name as the names shape (``InPlaceAnswerer``), so the precise spelling is
            // never answered less than the loose one.
            if let name = anchoredName(in: search.pattern, wholeWords: search.options.wholeWords, fixed: search.options.dialect == .fixed) {
                return .references(name: name, search: search)
            }
            // A case-folded search prints sites of every casing; `where` resolves the name as written, so its
            // answer would not say what the search says. The search runs, as the anchored `-i` sweep does
            // once its proof fails (``InPlaceAnswerer``).
            guard !search.options.ignoresCase else { return nil }
            return symbolsCall(forPattern: search.pattern, paths: search.paths, search: search)
        }
        // A declaration grep of one file is that file's digest or its members' source, proven against what it
        // prints, and is asked first: only a pattern that shape does not read falls to the names below.
        let oneFile = !search.recursive && search.paths.count == 1 && search.paths.first.map(isSwiftFile) == true
        // One of the closed spellings of a grep for declaration vocabulary alone is the digest's to prove, whichever
        // of its keywords the shared vocabulary below reads.
        if oneFile, let file = search.paths.first, search.asksForDeclarationVocabulary {
            return .declarations(file: file, search: search)
        }
        if oneFile, let file = search.paths.first, let reading = declarationReading(of: search.pattern, patternWasQuoted: search.patternWasQuoted) {
            switch reading {
            case .member:
                return .members(search: search)
            case .declarations:
                return search.hasContext ? nil : .declarations(file: file, search: search)
            }
        }
        // A member grep of several Swift files, a glob of them, or one searched recursively — a file recurses into
        // nothing — is the one-file member shape asked file by file (``InPlaceAnswerer``). A search that prints
        // no file names (`-h`) or filters them (`--include`) is left as it was.
        if !search.paths.isEmpty, !search.withoutFileNames, !search.swiftOnly,
           search.paths.allSatisfy({ $0.hasSuffix(".swift") && !SwiftPMManifest.isManifestPath($0) }),
           case .member? = declarationReading(of: search.pattern, patternWasQuoted: search.patternWasQuoted)
        {
            return .members(search: search)
        }
        // A search whose every operand is a Swift file or a glob of them — one, several, recursive or not, since a
        // file recurses into nothing — is about those files alone, and a name's `where` is about the whole tree:
        // it lists the declaration and every site wherever they are, files the search never named included. No
        // `where` stands in for it; only the members shape above, answered file by file, is scoped to what it
        // names, and anything else runs as written.
        guard !namesOnlySwiftFiles(search.paths) else { return nil }
        // What is left is a recursive search of a tree with a Swift file named beside it. It builds the tree's
        // names call, bounded by the operands and carrying the search itself, and that call is withheld unchecked,
        // since the lines it prints cannot be checked against a tree's names. On a compound line that withholding decides
        // the line, so the other statements are not answered either. Context lines, a case-folded search and a
        // whole-line search (`-x`) leave it for the reasons they leave the tree's. A pattern opening on a
        // declaration's form asks for declarations, which a tree's names do not answer.
        guard search.recursive, namesFiles, !search.hasContext, !search.options.ignoresCase, !search.options.wholeLine,
              !opensADeclarationInAnyBranch(search.pattern)
        else {
            return nil
        }
        guard case let .symbols(names, paths, uncovered, proof, _)? = symbolsCall(forPattern: search.pattern, paths: search.paths, search: search) else { return nil }
        return .symbols(names: names, paths: paths, uncovered: uncovered, proof: proof, unchecked: true)
    }

    /// One plain `where` per name for a search's pattern, over the subtrees, Swift files and globs of them `paths` names, or `nil` where the pattern is anything else.
    ///
    /// `paths` is the search's own operands, spelled as the surface wrote them — relative to the command's working directory on the shell, and the `Grep`'s own `path` resolved in full, since that surface's directory *is* the path it searched. Carrying them is what keeps the answer about the tree the caller searched: they root it, and they bound it (``InPlaceAnswerer``).
    ///
    /// The reading is ``SweepPattern``'s, which is what builds the offer this hands over (``IndexSuggestion/forSweep(pattern:memberExists:)``): only a pattern that reads as names is taken, so a shape query and a phrase are refused here as they always were, and an alternation with prose beside its names carries that prose into the call, for the answer to name as left to a search. Capped at ``IndexSuggestion/callCap`` because the offer itself is — past it the refusal lists five calls and counts the rest, and an answer would have to serve names the offer never named.
    ///
    /// Whether the index declares those names is not asked here. The hook asks it a layer along, of the offer's own symbols, and withholds the whole alternation where any of them is undeclared (`PreToolUseCommand.lookup`) — so every name that reaches the answerer is one `where` speaks for.
    ///
    /// `search` is the command's own, where there is one this can re-run. A pattern spelling a metatype, a self-expression or a member through `Self` (`T.Type`, `T.self`, `Self.x`) carries it as the proof its answer is held to (``InPlaceCall/symbols(names:paths:uncovered:proof:)``), and without one — a `Grep`, which is ripgrep behind a payload — it is no candidate at all.
    static func symbolsCall(forPattern pattern: String, paths: [String], search: ShellGrep? = nil) -> InPlaceCall? {
        let needsProof = PatternReading.spellsAMetatype(pattern) || PatternReading.spellsASelfMember(pattern)
        let proof = needsProof ? search : nil
        guard proof != nil || !needsProof else { return nil }
        let (names, prose): ([String], [String])
        switch SweepPattern.reading(of: pattern) {
        case let .names(read):
            (names, prose) = (read, [])
        case let .partial(read, uncovered):
            (names, prose) = (read, uncovered)
        case .shape, .text:
            return nil
        }
        guard !names.isEmpty, names.count <= IndexSuggestion.callCap else { return nil }
        return .symbols(names: names, paths: paths, uncovered: prose, proof: proof)
    }

    /// The directory the first statement of `command` moves to with a `cd`, or `nil` where that statement is anything else or its word is computed.
    static func firstChangeOfDirectory(inShell command: String) -> String? {
        ShellSyntax.statementRanges(of: command).first.flatMap { changeOfDirectory($0.statement) }
    }

    /// Whether a statement moves where the lookup's relative paths resolve.
    ///
    /// Asked before the directory itself, so that a move this cannot follow — a computed word, a `pushd` — refuses the whole command rather than being stepped over as though it had not happened, which would answer one directory's question with another's files.
    static func movesDirectory(_ statement: String) -> Bool {
        guard let word = ShellQuery(statement).invocation.first else { return false }
        return ["cd", "pushd", "popd"].contains((word as NSString).lastPathComponent)
    }

    /// The directory a `cd` statement moves to, or `nil` where the statement is anything else, its word is computed, or it opens on a quoted or escaped `~`.
    static func changeOfDirectory(_ statement: String) -> String? {
        let query = ShellQuery(statement)
        let words = query.invocation
        guard words.count == 2, words[0] == "cd", !words[1].hasPrefix("-"), !words[1].contains("$") else { return nil }
        // A `~` the shell never expands — quoted or escaped — names a directory called `~`, not home; the real
        // `cd` fails or moves somewhere the lookups that follow never read, so the line is not the shape.
        guard ShellOperand(raw: query.rawInvocation[1])?.quotesLeadingTilde != true else { return nil }
        return (words[1] as NSString).expandingTildeInPath
    }

    /// `path` spelled out against `directory`, or `nil` where it is relative and there is nothing to resolve it against.
    static func resolve(_ path: String, against directory: String?) -> String? {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        guard let directory else { return nil }
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: directory, isDirectory: true)).standardizedFileURL.path
    }

    /// Whether `call` is a name search bounded by Swift files named outright or by a glob of them, rather than by a tree.
    private static func isNameSearchOfNamedFiles(_ call: InPlaceCall) -> Bool {
        guard case let .symbols(_, paths, _, _, _) = call else { return false }
        return paths.contains { $0.hasSuffix(".swift") }
    }

    /// One Swift source file, named outright: not a glob, and not a build manifest the index leaves out.
    private static func isSwiftFile(_ path: String) -> Bool {
        path.hasSuffix(".swift") && !SwiftSourcePath.isGlob(path) && !SwiftPMManifest.isManifestPath(path)
    }

    /// Standard error sent away — `2>/dev/null`, `2>&1` — which leaves what the command prints unchanged.
    private static func isStandardErrorRedirection(_ word: String) -> Bool {
        word == "2>/dev/null" || word == "2>&1"
    }

    /// Any other redirection, which sends the output, or takes the input, somewhere this cannot follow.
    private static func isAnyRedirection(_ word: String) -> Bool {
        word.hasPrefix("<") || word.hasPrefix(">") || word.hasPrefix("&>") || word.contains(/^[0-9]+>/)
    }

    /// Whether any stage of `statement` runs `exec`, which replaces the shell with the command it names, or `exit`, `return` or `logout`, which end it: nothing after one on the line runs, so no answer can say what the line printed.
    ///
    /// `builtin` and `command` in front, and a backslash that only defeats an alias, still run the same word.
    private static func replacesTheShell(_ statement: String) -> Bool {
        ShellSyntax.segments(of: statement).contains { segment in
            let words = ShellQuery(segment).invocation.drop { $0 == "builtin" || $0 == "command" }
            guard let word = words.first else { return false }
            let bare = word.hasPrefix("\\") ? String(word.dropFirst()) : word
            return ["exec", "exit", "return", "logout"].contains(bare)
        }
    }

    /// Whether `statement` is a `||` fallback proven never to print, whatever it is handed: `true` and `:` both ignore their arguments and always succeed, so a lookup in front of one is answered as though the fallback were not there at all.
    static func isSilentFallback(_ statement: String) -> Bool {
        let stages = ShellSyntax.segments(of: statement).map(ShellQuery.init)
        guard stages.count == 1, let verb = stages[0].invocation.first else { return false }
        return verb == "true" || verb == ":"
    }
}

public extension InPlaceShape {
    /// A lookup found inside a call, and what answering it in place would stand for.
    struct Match: Equatable, Sendable {
        /// The index call for each lookup, in command order: one, or several whole reads answered together.
        public let calls: [InPlaceCall]
        /// The directory the call's relative paths resolve against: the caller's, or the one a `cd` before the lookup moves to.
        public let directory: String?
        /// Whether the call is the whole of what was asked, or one statement of a command that carried other work too — which the answer says, so nothing the command would have printed is taken as covered when it is not.
        public let isWholeCommand: Bool

        /// Whether each call answers nothing but line windows of its file, in the order of ``calls`` — what a window of a file the context has already located is dropped on (``droppingWindows(where:)``).
        public let windowed: [Bool]
        /// How many lookups on the line the answer covers, which exceeds the calls where several windows of one file share a digest.
        public let lookups: Int
        /// Whether a `||` fallback that could print follows the lookup, so the answer stands only where the lookup's own success is proven: its file is there to read, and a grep with nothing after it prints a line.
        public let fallbackFollows: Bool
        /// The text a compound line's literal `echo`s and `printf`s print, keyed by the index in ``calls`` of the call it is printed before — ``calls``'s count for text printed after the last (``CompoundLine``).
        public let literals: [Int: String]
        /// The shell statements each call's answer stands for, in the order of ``calls``: its lookup, every other lookup whose file shares its digest, and every `||` fallback the answer proves never ran — empty for a lookup that is no shell command.
        ///
        /// What the ledger records the answer under, so the identical re-run is recognised on exactly the lookups whose answers were served, and on none the answer dropped.
        public let statements: [[String]]
        /// Whether another statement on the line prints what the answer does not reproduce — an `ls`, a search this does not answer, a lookup the answer dropped — so the line is let run rather than refused with an answer to part of it (``InPlaceAnswerer/Withholding/otherStatementsRun``).
        public private(set) var runsOtherStatements = false
        /// Held as a list of none or one, since a value cannot hold itself: see ``ordinary``.
        private var ordinaryReading: [Self]

        /// The match the line is read as without the compound rule, for a compound line whose own answer is withheld: the partial answer or several reads it always had, or `nil` where it had none, or this is no compound line.
        public var ordinary: Self? {
            ordinaryReading.first
        }

        /// The index call that answers the lookup, and the first where several reads are answered together.
        public var call: InPlaceCall {
            calls[0]
        }

        public init(call: InPlaceCall, directory: String?, isWholeCommand: Bool) {
            self.init(calls: [call], directory: directory, isWholeCommand: isWholeCommand)
        }

        public init(calls: [InPlaceCall], directory: String?, isWholeCommand: Bool) {
            self.init(calls: calls, directory: directory, isWholeCommand: isWholeCommand, windowed: calls.map { _ in false }, lookups: calls.count)
        }

        public init(
            calls: [InPlaceCall],
            directory: String?,
            isWholeCommand: Bool,
            windowed: [Bool],
            lookups: Int,
            fallbackFollows: Bool = false,
            literals: [Int: String] = [:],
            statements: [[String]] = []
        ) {
            self.calls = calls
            self.directory = directory
            self.isWholeCommand = isWholeCommand
            self.windowed = windowed
            self.lookups = lookups
            self.fallbackFollows = fallbackFollows
            self.literals = literals
            self.statements = statements
            ordinaryReading = []
        }

        /// This match, marked as leaving other statements to print what it does not reproduce where `others` holds.
        func running(others: Bool) -> Self {
            var match = self
            match.runsOtherStatements = runsOtherStatements || others
            return match
        }

        /// This match, carrying `ordinary` to fall back to where its own answer is withheld.
        func falling(backTo ordinary: Self?) -> Self {
            var match = self
            match.ordinaryReading = ordinary.map { [$0] } ?? []
            return match
        }

        /// This match as its lookups would be asked with nothing else on the line printing, for a match that leaves other statements to print (``runsOtherStatements``), or `nil` for one that does not.
        public var alone: Self? {
            guard runsOtherStatements else { return nil }
            var match = self
            match.runsOtherStatements = false
            match.ordinaryReading = []
            return match
        }

        /// This match without the calls that answer only windows of a file the predicate holds of, its path spelled out against ``directory``, or `nil` where no call is left.
        ///
        /// A window of a file the context has located is the second half of the loop the digest began: it adds nothing to the answer and does not block it, and a line of nothing else is no lookup. What is left no longer covers the whole command, so a compound line's literals, which placed the whole line's output, go with it, and the window left out prints lines the answer does not reproduce, so the line runs (``runsOtherStatements``).
        public func droppingWindows(where isLocated: (String) -> Bool) -> Match? {
            droppingWindows { path, _ in isLocated(path) }
        }

        /// This match without the calls that answer only windows of a file the predicate holds of, handed the file's path spelled out against ``directory`` and the windows the call reads it through, or `nil` where no call is left.
        public func droppingWindows(where isLocated: (String, [LineWindow]) -> Bool) -> Match? {
            droppingReads { path, windows, windowed in windowed && isLocated(path, windows) }
        }
    }
}

extension InPlaceShape {
    /// Every statement of `command` that is not itself a `cd`, with the directory it runs in once each literal `cd` before it has moved from `directory` — or `nil` where a move on the line cannot be followed.
    ///
    /// A move is followed only as a statement of its own that opens on the word `cd` and names one literal directory (``changeOfDirectory(_:)``), on a plain sequence of statements: no substitution, no compound command or subshell, and no `&` between statements. A `cd` of a computed word, `cd -`, `pushd`, a `cd` behind `builtin` or `command`, and — where the caller asks for directories on disk — a `cd` to a path that is no directory on disk are not followed, and neither is anything after them: guessing where they land would judge one file's window as another's.
    ///
    /// **The statements in front of the first `||` always run, and run where their moves put them**, whatever follows: the `||` decides only whether its tail runs. So they are placed as they would be without it. The tail runs where the list in front of it failed — a `cd` that did not happen, or a statement after it — so where it runs cannot be known, and each statement from the `||` on has no directory. A tail that moves again, or that ends the shell, leaves the whole line unfollowed, as the in-place answer refuses a line that ends the shell.
    ///
    /// A `nil` directory is a relative move with nothing to resolve it against, or a statement behind a `||`.
    static func statementDirectories(of command: String, from directory: String?, requiringDirectories: Bool) -> [(statement: String, directory: String?)]? {
        guard !command.contains("$("), !command.contains("`") else { return nil }
        let statements = ShellSyntax.statementRanges(of: command)
        let joints = joints(of: command, between: statements)
        let settled = joints.firstIndex(of: "||").map { $0 + 1 } ?? statements.count
        let tail = statements[settled...]
        guard joints.allSatisfy({ sequences($0) || $0 == "||" }),
              !statements.contains(where: { isCompoundMarker($0.statement) }),
              !tail.contains(where: { TranscriptScan.changesDirectory($0.statement) || replacesTheShell($0.statement) })
        else {
            return nil
        }
        var directory = directory
        var placed: [(statement: String, directory: String?)] = []
        for (statement, _) in statements[..<settled] {
            guard TranscriptScan.changesDirectory(statement) else {
                placed.append((statement, operandDirectory(directory, reading: statement)))
                continue
            }
            guard ShellSyntax.tokens(of: statement, stripQuotes: false).first == "cd",
                  let moved = changeOfDirectory(statement)
            else {
                return nil
            }
            if moved.hasPrefix("/") || directory != nil {
                guard let resolved = resolve(moved, against: directory), !requiringDirectories || CompoundLine.isDirectory(resolved) else { return nil }
                directory = resolved
            }
        }
        return placed + tail.map { ($0.statement, nil) }
    }

    /// The directory a statement run in `directory` reads its relative operands from: `directory` itself, or — where an operand climbs out through `..` past a symbolic link in it, so that the file system reaches a different file than the path read as written — `directory` with its links resolved.
    ///
    /// A `cd` moves through a link as written, so `directory` keeps the link's own path, but the kernel resolves an operand's `..` from where the link points: after `cd Link`, with `Link` pointing at `Other/Deep`, `../Sources/App/Shell.swift` is `Other/Sources/App/Shell.swift`, never the `Sources/App/Shell.swift` beside `Link`. Where both readings reach the same file the written one is kept, since that is how the rest of the session spells it.
    static func operandDirectory(_ directory: String?, reading statement: String) -> String? {
        guard let directory else { return nil }
        let physical = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        guard physical != directory else { return directory }
        let climbing = ShellSyntax.segments(of: statement).flatMap { ShellQuery($0).invocation }.filter { word in
            !word.hasPrefix("/") && word.split(separator: "/").contains("..")
        }
        let differs = climbing.contains { word in
            guard let written = resolve(word, against: directory), let read = resolve(word, against: physical) else { return false }
            return URL(fileURLWithPath: written).resolvingSymlinksInPath() != URL(fileURLWithPath: read).resolvingSymlinksInPath()
        }
        return differs ? physical : directory
    }

    /// Whether every stage of a window is one the system tools run to exit 0 doing nothing but print the lines it picks — on ``FallbackProof``'s closed list, or, for the stage that reads the file, an `awk` program that prints every line (``ShellQuery/printsWholeFiles``) — with every `awk` action printing each line whole (``printsWholeLines(_:)``).
    ///
    /// A window off the list can fail where it looked like a read (`head -0`, `head -c 0`, a count past the bound or not a number, an option the tool does not know, `sed -n -f 1,5p`) or act as well as print (`awk 'NR<=3 {print > "/x/y"}'`, a pipe, `system`, `getline`), and its output is then an error or a write the digest never stood for.
    static func runsOnlyToPrint(_ stages: [ShellQuery]) -> Bool {
        guard let reader = stages.first else { return false }
        let printsItsFile = FallbackProof.exitsZero(reader.invocation, operands: 1)
            || (reader.invocation.first == "awk" && reader.printsWholeFiles) || NumberedRead.numbersEveryLine(reader)
        return printsItsFile && stages.dropFirst().allSatisfy { FallbackProof.exitsZero($0.invocation, operands: 0) }
            && stages.allSatisfy { printsWholeLines($0.invocation) }
    }

    /// Whether a stage prints each line it picks whole, numbered or not: any stage but an `awk`, and an `awk` whose action, where it has one, is ``ShellQuery/awkPrintsEachLine`` or ``ShellQuery/awkPrintfsEachLine``.
    ///
    /// ``FallbackProof`` lets an action print strings, fields and line numbers, since each exits 0; but `{print "x"}`, `{print $1}` or `{print NR}` prints text the file does not hold as its lines, which no digest of the file stands in for.
    private static func printsWholeLines(_ words: [String]) -> Bool {
        guard words.first == "awk", let program = words.dropFirst().first, let open = program.firstIndex(of: "{") else { return true }
        let action = program[open...].trimmingCharacters(in: .whitespacesAndNewlines)
        return action.wholeMatch(of: ShellQuery.awkPrintsEachLine) != nil || action.wholeMatch(of: ShellQuery.awkPrintfsEachLine) != nil
    }

    /// What a declaration grep of one file asks for.
    enum DeclarationReading: Equatable {
        /// A member, by its declaration: `func signedDelta`, `static let now`, `case pending` — every member the grep matches, whatever its name turns out to be.
        case member(String)
        /// The file's declarations of the kinds the pattern names: `static\|case `, `@Test func`, `struct `.
        case declarations
    }

    /// The reading of a pattern made of Swift's declaration vocabulary, or `nil` where it names anything else — a use of a name, a phrase, a literal.
    ///
    /// Each alternative, anchors, whitespace classes and grouping set aside, has to be declaration keywords, modifiers and attributes, closing at most on the one name a declaration keyword introduces — or a column-0 closing brace (``asksForClosers(_:patternWasQuoted:)``). One alternative closing on a member's name asks for members' source; everything else of the kind asks for the file's declarations, the type-introducing keywords included, since a nested type is the file's shape rather than one member's source. Either is only what is asked: whether the answer accounts for what the grep prints is decided by running it (``InPlaceAnswerer``).
    ///
    /// `patternWasQuoted` is only ever true from a shell command's own reading of its pattern word (``ShellGrep``); a caller with no shell word behind it — a member check on a Grep tool's raw pattern — reads every `^}` as unquoted, which is the same as never accepting a bare one.
    static func declarationReading(of pattern: String, patternWasQuoted: Bool = false) -> DeclarationReading? {
        let raw = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let branches = raw.split(separator: /\\?\|/, omittingEmptySubsequences: false).map(String.init)
        var member: String?
        for branch in branches {
            // A column-0 closing brace is the end of a top-level declaration's range where the digest says it
            // is one, which the answerer proves of every such line in the file (``isCloser(_:patternWasQuoted:)``).
            if isCloser(branch, patternWasQuoted: patternWasQuoted) {
                continue
            }
            let text = branch
                .replacing(/\\[b<>]|[\^$]/, with: "")
                .replacing(/\\s[*+]?|\[\[:space:\]\][*+]?| [*+]/, with: " ")
                .replacing(/\\?[()]/, with: " ")
            let words = text.split(separator: " ").map(String.init)
            guard !words.isEmpty, words.allSatisfy({ $0.wholeMatch(of: /@?[\p{L}_][\p{L}\p{N}_]*/) != nil }) else { return nil }
            let leading = words.dropLast()
            guard leading.allSatisfy(isVocabulary), let last = words.last else { return nil }
            if isVocabulary(last) {
                continue
            }
            // A name closes an alternative only behind the keyword that declares it.
            guard let introducer = leading.last, declaringKeywords.contains(introducer) else { return nil }
            if memberKeywords.contains(introducer), branches.count == 1 {
                member = last
            }
        }
        return member.map(DeclarationReading.member) ?? .declarations
    }

    /// Whether any alternative of a declaration grep's pattern is a column-0 closing brace, `^}` or `^}$`, whose lines a digest accounts for only as the ends of its top-level declarations' ranges.
    static func asksForClosers(_ pattern: String, patternWasQuoted: Bool) -> Bool {
        pattern.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .split(separator: /\\?\|/, omittingEmptySubsequences: false)
            .contains { isCloser(String($0), patternWasQuoted: patternWasQuoted) }
    }

    /// Whether one alternative is a column-0 closing brace and nothing else: `^}`, or `^}$`.
    ///
    /// A backslash-escaped brace, `^\}` or `^\}$`, proves itself — it only ever reaches this word by surviving the shell as a literal backslash, quoted or not. A bare `^}` proves nothing on its own: unquoted, it is a zsh parse error the shell never runs (`grep -n ^} File.swift` refuses before grep sees it), so it is a candidate only where `patternWasQuoted` says the word it came from was wrapped in matching quotes.
    private static func isCloser(_ alternative: String, patternWasQuoted: Bool) -> Bool {
        if alternative == "^\\}" || alternative == "^\\}$" {
            return true
        }
        return patternWasQuoted && (alternative == "^}" || alternative == "^}$")
    }

    /// Whether one alternative of a pattern opens with a declaration's form — a keyword, a modifier or an attribute before anything else — whatever follows it: `func save(_ value: Int)`, `static let now`, `@Test func`, `import Foundation`.
    ///
    /// Wider than ``declarationReading(of:)``, which has to prove the grep's every printed line is a declaration before the hook answers in its place; this only says the search is *after* declarations, which a file's digest records, rather than after prose or a call site, which it does not (``TextSearch``). Read off the same vocabulary, so the two cannot disagree about what a declaration's form is.
    static func opensADeclaration(_ alternative: String) -> Bool {
        formWords(of: alternative).first.map(isVocabulary) ?? false
    }

    /// Whether any alternative of `pattern` opens with a declaration's form (``opensADeclaration(_:)``).
    private static func opensADeclarationInAnyBranch(_ pattern: String) -> Bool {
        pattern.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .split(separator: /\\?\|/)
            .contains { opensADeclaration(String($0).trimmingCharacters(in: CharacterSet(charactersIn: " ()"))) }
    }

    /// One alternative's words as a declaration's form is read off them: anchors set aside, a `\s*` or `[[:space:]]` read as the space it matches, and each word cut to its leading `@`, letters, digits and underscores — `^\s*final class` reads `final`, `class`.
    ///
    /// Shared with ``SweepPattern``, which reads a sweep's alternation branches for the same form and must not read it differently: a branch its own copy missed — `^final class`, `mutating func` — was taken for prose, and the name beside it dropped.
    static func formWords(of alternative: String) -> [String] {
        alternative
            .replacing(/\\[b<>]|[\^$]/, with: "")
            .replacing(/\\s[*+]?|\[\[:space:\]\][*+]?/, with: " ")
            .split(separator: " ")
            .map { String($0.prefix { $0 == "@" || $0.isLetter || $0.isNumber || $0 == "_" }) }
    }

    /// A keyword, a modifier or an attribute — a word that is part of a declaration's form rather than its name.
    static func isVocabulary(_ word: String) -> Bool {
        word.hasPrefix("@") || declaringKeywords.contains(word) || otherKeywords.contains(word)
    }

    /// The keywords that introduce a named declaration.
    private static let declaringKeywords: Set<String> = [
        "func", "var", "let", "case", "typealias", "associatedtype",
        "struct", "class", "enum", "protocol", "actor", "extension", "macro",
    ]

    /// Of those, the ones whose declaration is a member with source of its own to serve.
    private static let memberKeywords: Set<String> = ["func", "var", "let", "case", "typealias", "associatedtype"]

    /// The rest of a declaration's vocabulary: unnamed declarations, modifiers, and `import`, which a file digest carries too.
    private static let otherKeywords: Set<String> = [
        "init", "deinit", "subscript", "import", "static", "private", "fileprivate", "internal", "public", "open",
        "package", "final", "override", "mutating", "nonmutating", "nonisolated", "lazy", "weak", "unowned",
        "indirect", "required", "convenience", "dynamic", "optional",
    ]

    /// The one name a sweep's pattern is anchored to as a whole word, or `nil` where it is anything else.
    ///
    /// Anchored by `-w`, or by `\b…\b` or `\<…\>` around nothing but the name. An unanchored name matches inside every longer name that holds it, and a search for those is a question about text rather than about the one symbol `where` resolves.
    static func anchoredName(in pattern: String, wholeWords: Bool, fixed: Bool) -> String? {
        let raw = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if raw.wholeMatch(of: IndexSuggestion.identifier) != nil {
            return wholeWords ? raw : nil
        }
        guard !fixed, let match = raw.wholeMatch(of: /\\b([\p{L}_][\p{L}\p{N}_]*)\\b|\\<([\p{L}_][\p{L}\p{N}_]*)\\>/) else {
            return nil
        }
        return (match.output.1 ?? match.output.2).map(String.init)
    }
}

private extension ShellQuery {
    /// Whether the segment's first word is its command word: no environment assignment and no subshell brace in front of it.
    var opensOnItsCommandWord: Bool {
        invocation == arguments
    }
}
