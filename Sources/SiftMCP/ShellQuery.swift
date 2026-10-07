//
// Copyright © Agulhas Labs
//

import Foundation
import RegexBuilder
import SiftCore

/// One pipeline segment, read for the few facts both the classifier and the advisor need from it.
///
/// It exists because two readings of the same argument list drift apart: a classifier that cannot see a directory sweep at all, beside an advisor that could not suggest anything for one if it did, and a third copy for the `Grep` tool on top. So the reading happens once, and `ShellInspection` and `ShellAdvice` differ only in what they conclude from it.
///
/// Not a shell parser — see `ShellSyntax` for the boundary. Flags are recognised by shape rather than by a table of every option `grep` and `rg` accept, which is wrong at the edges and right on everything the transcripts actually contain.
public struct ShellQuery {
    /// The segment as written, quotes intact, for matching command words against.
    public let segment: String

    /// The segment's arguments, quoted runs kept whole and unquoted.
    public let arguments: [String]

    /// ``arguments``, but with a quoted run's quotes still on it — the same tokens, in the shape they were written, so a caller can tell a quoted `<Settings>` from a real redirection reading `arguments` alone cannot.
    let rawArguments: [String]

    /// The segment with quoted literals blanked — the text command words are matched against, computed once because the hook evaluates it several times per Bash call.
    let executableText: String

    public init(_ segment: String) {
        self.segment = segment
        let tokens = ShellSyntax.argumentTokens(of: segment)
        arguments = tokens.map(\.unquoted)
        rawArguments = tokens.map(\.raw)
        executableText = ShellSyntax.executableText(of: segment)
    }
}

public extension ShellQuery {
    /// Whether this runs a command that reads file content.
    ///
    /// `sed` and `awk` only count in their printing forms; a bare `sed` is as likely to be an edit.
    var reads: Bool {
        Self.readVerbs.contains { Self.isCommandWord($0, in: executableText) }
    }

    /// The argv this segment stands for: its tokens, with leading environment assignments and a subshell's opening brace stepped over.
    ///
    /// `RunCommandKind` decides from argv and this is the one place shell text becomes argv, so the advisor and `sift run` itself judge the same command word rather than two readings of it.
    ///
    /// Anchoring on the *first* token is what makes it safe against prose. `claude -p "run swift test yourself"` arrives as one quoted argument behind `claude`, because `ShellSyntax.tokens` keeps a quoted run whole — so a verb that is not first is not a verb, and no separate masking pass is needed here.
    var invocation: [String] {
        var tokens = arguments[...]
        while let first = tokens.first, Self.precedesTheVerb(first) {
            tokens = tokens.dropFirst()
        }
        guard let head = tokens.first else { return [] }
        return [String(head.drop(while: { $0 == "(" || $0 == "{" }))] + tokens.dropFirst()
    }

    /// ``invocation``, but each word in the quotes it was written with — so a caller cutting at a redirection operator can tell one a shell would actually act on from a quoted argument that only looks like one (`sift strings "<Settings>"`).
    ///
    /// Stepped over the same leading tokens as `invocation`, off `rawArguments` instead of `arguments`, which is why the two always stay the same length: both come from the one pass `argumentTokens(of:)` makes, so a token that splits at all appears in both.
    var rawInvocation: [String] {
        var tokens = arguments[...]
        var raw = rawArguments[...]
        while let first = tokens.first, Self.precedesTheVerb(first) {
            tokens = tokens.dropFirst()
            raw = raw.dropFirst()
        }
        return Array(raw)
    }

    /// Whether this segment rewrites the files it is handed in place — `sed -i`, `perl -pi`, `ruby -pi`, `gawk -i inplace`.
    ///
    /// Read off argv rather than off a phrase, because the flag that makes the edit is usually one letter inside a cluster: `perl -0pi -e`, `perl -pi.bak`, `sed -Ei`, `sed -E -i ''`. A phrase list catches `sed -i` and `perl -i` and lets every clustered spelling through as a lookup, and a line that edits a file and then greps it to check the edit is read as the grep — refused, and the edit held up with it.
    ///
    /// The editor is found where the shell or a launcher runs it — the command word, or the first word `xargs` or `find -exec` hands a file list to — so `grep -rn perl Sources` is a search for the word, and `echo perl -pi` prints it.
    var editsInPlace: Bool {
        let argv = invocation
        let rawArgv = rawInvocation
        var segments = argv.isEmpty ? [] : [(editor: 0, end: argv.endIndex)]
        for (index, word) in argv.enumerated() where ["xargs", "-exec", "-execdir"].contains(word) {
            guard let editor = argv[(index + 1)...].firstIndex(where: { !$0.hasPrefix("-") }) else { continue }
            // `-exec`/`-execdir` end their own command at a `;` or `+` — usually written `\;`, its escaping
            // backslash kept by the tokeniser rather than stripped — and `find`'s own predicates read after
            // it: an `-iname` there is find's, never the editor's `-i`, so the scan stops there. `xargs` has
            // no such terminator: its command runs to the end of the line, or to the next `-exec`/`xargs`.
            let end = word == "xargs" ? argv.endIndex : (argv[(editor + 1)...].firstIndex { Self.endsExecClause($0) } ?? argv.endIndex)
            segments.append((editor, end))
        }
        return segments.contains { editor, end in
            let name = (argv[editor] as NSString).lastPathComponent
            return Self.editsInPlace(editor: name, options: argv[(editor + 1) ..< end], rawOptions: rawArgv[(editor + 1) ..< end])
        }
    }

    /// Whether this segment runs the tool itself, by name or by path.
    ///
    /// Only the command word counts — `grep -rn sift Sources/` is a search *for* the word, plausible in exactly the repo named after it, and exempting it would open the counted-but-never-advised divergence `ShellAdvice` forbids.
    var invokesSift: Bool {
        guard let verb = invocation.first else { return false }
        return (verb as NSString).lastPathComponent == "sift"
    }

    /// Whether the segment sends its output somewhere of the caller's choosing.
    ///
    /// A file destination (`> log`, `>> log`, `&> log`, and `>&log`, the older spelling of the last) means the output is already being managed and nothing should interrupt that. A descriptor duplication (`2>&1`, `>&2`, `>&-`) names no destination — it is the stream merge `sift run` performs itself — so it is deliberately not a redirect by this reading, and `swift test 2>&1` keeps its advice.
    ///
    /// Read from `executableText` so a `>` inside a quoted pattern is blanked before it can count.
    var redirectsOutput: Bool {
        executableText.contains(Self.fileRedirect)
    }

    /// Whether the segment sends its *standard output* to a file — the shape of a log kept to be read.
    ///
    /// Narrower than ``redirectsOutput``, which answers whether to interrupt and so counts any destination. This answers whether the caller kept the output: `2> err.txt` leaves stdout on the terminal, a `/dev/` destination (`/dev/null` above all) is output thrown away or sent back to a stream, and a process substitution (`> >(tee log)`) is a pipe — none of them is a log. Every spelling that writes a file counts: `>`, `>>`, `>|`, `1>`, `&>`, `&>>`, and `>&log`, the older spelling of `&>`.
    ///
    /// Redirections are applied left to right, the way the shell applies them, by tracking where each descriptor points: `2>f 1>&2` leaves stdout in `f`, and `>log >/dev/null` leaves it nowhere. Operators are found in `executableText`, so one inside a quoted argument does not count; the destination is read from the segment as written, since a quoted file name is blanked there.
    var writesOutputToAFile: Bool {
        let text = Array(executableText)
        let written = Array(segment)
        // Whether each descriptor points at a file; one never redirected is still the terminal.
        var intoAFile: [String: Bool] = [:]
        var index = 0
        while index < text.count {
            // `>(…)` is a process substitution: a word standing for a pipe, not a redirection.
            guard text[index] == ">", index + 1 >= text.count || text[index + 1] != "(" else {
                index += 1
                continue
            }
            let named = ShellRedirect.descriptor(before: index, in: text)
            let bothStreams = named == nil && index > 0 && text[index - 1] == "&"
            var cursor = index + 1
            // `>>` appends and `>|` overrides noclobber; each writes its file exactly as `>` does.
            if cursor < text.count, text[cursor] == ">" || text[cursor] == "|" {
                cursor += 1
            }
            let duplicates = !bothStreams && cursor < text.count && text[cursor] == "&"
            if duplicates {
                cursor += 1
            }
            index = cursor
            if duplicates, let source = ShellRedirect.duplicatedDescriptor(at: cursor, in: text) {
                // `2>&1` points a descriptor wherever another already points; `>&-` closes it.
                intoAFile[named ?? "1"] = intoAFile[source] ?? false
                continue
            }
            let kept = ShellRedirect.isAFile(ShellRedirect.word(in: written, from: cursor))
            // `&>log`, and `>&log` with no descriptor named, send both streams to the file.
            for descriptor in named.map({ [$0] }) ?? (bothStreams || duplicates ? ["1", "2"] : ["1"]) {
                intoAFile[descriptor] = kept
            }
        }
        return intoAFile["1"] ?? false
    }

    /// Whether this runs a *search*, the only kind of read that can be pointed at a directory.
    var searches: Bool {
        Self.searchVerbs.contains { Self.isCommandWord($0, in: executableText) }
    }

    /// Whether this segment asks *how many* rather than *which* — `grep -c`, `rg --count`, or a `wc` counting what came down the pipe.
    ///
    /// A count is a question about text volume, and text volume is the one thing a symbol index does not measure. The case in point: a linter's rule tests are Swift source held inside triple-quoted string literals, so `grep -c '@Test func' <rule tests>` counts the fixtures, and the `digest` offered in its place resolves *declarations* — of which there are fewer, because a declaration inside a string literal is characters rather than a declaration. The suggestion does not answer the question more cheaply; it answers a different question, and returns a different number for it.
    ///
    /// The count flag is only read on a search verb, where `-c` means count and nothing else. `head -c 900` is a byte window and is not one, which is why the flag is not looked for on every verb.
    var counts: Bool {
        if Self.isCommandWord("wc", in: executableText) {
            return true
        }
        guard searches else { return false }
        return arguments.contains { argument in
            if argument.hasPrefix("--") {
                return argument == "--count" || argument == "--count-matches"
            }
            // A cluster, so `grep -rnc` counts as surely as `grep -c`. Case matters: `-C` is context.
            guard argument.hasPrefix("-"), argument.count > 1 else { return false }
            return argument.dropFirst().allSatisfy(\.isLetter) && argument.contains("c")
        }
    }

    /// Whether the read verb is being handed inline text rather than a file — a heredoc or a here-string.
    ///
    /// `git commit -m "$(cat <<'EOF' … EOF)"` is the shape this covers: the message body is prose *about* source, so a commit describing a `grep` of a `.swift` file would read as a lookup of it. Quoted text is safe already, because segmenting strips quotes and a quoted command is not an invocation; a heredoc body is not quoted, so nothing else protects it. Text arriving on the verb's stdin is never a file being inspected.
    var suppliesInlineText: Bool {
        // Read where the shell reads operators, with quoted text blanked (`executableText`), as the heredoc
        // reader finds them: a `<<` inside a quoted pattern is characters — `grep -n "^<<<<<<<" View.swift`
        // hunts a merge's markers in a file — and read off the raw segment it made that search no lookup at all.
        executableText.contains("<<")
    }

    /// The `.swift` source paths the command is pointed at — build manifests excluded, because the index deliberately does not cover them, so reading one is never a lookup it lost.
    ///
    /// Read off the operands, so a pattern that happens to end in `.swift` is never taken for a file. A glob is not one either: it restricts the command to Swift source across however many files match, which makes it a sweep.
    var swiftFiles: [String] {
        operandPaths.filter { $0.hasSuffix(".swift") && !SwiftSourcePath.isGlob($0) && !SwiftPMManifest.isManifestPath($0) }
    }

    /// The globs among the operands that name Swift source — each a set of files rather than one.
    var swiftGlobs: [String] {
        operandPaths.filter { SwiftSourcePath.isGlob($0) && SwiftSourcePath.appearsIn($0) }
    }

    /// Whether the command walks a tree: an `-r` in any flag cluster, or an `--include`/`--exclude` filter, which only exist to bound one.
    var isRecursive: Bool {
        // A `sed` walks no tree: its `-r` asks for extended expressions. Only the stage's own command word is
        // asked, never any word among its arguments — `grep -rn sed Sources/Alpha.swift` names `sed` as a
        // pattern, not a command, and still walks the tree it is pointed at.
        guard invocation.first.map({ ($0 as NSString).lastPathComponent }) != "sed" else { return false }
        return arguments.contains { argument in
            if argument.hasPrefix("--") {
                return argument.hasPrefix("--include") || argument.hasPrefix("--exclude") || argument == "--recursive"
            }
            guard argument.hasPrefix("-"), argument.count > 1 else { return false }
            return argument.dropFirst().allSatisfy(\.isLetter) && argument.lowercased().contains("r")
        }
    }

    /// Whether a flag restricts the search to Swift, which names the language without naming a file.
    ///
    /// `rg -t swift`, `rg -g '*.swift'` and `grep --include='*.swift'` are the same intent as a `.swift` path, and each is read in every spelling the tools accept: the value joined by `=`, run into a short flag (`-tswift`), or standing as the next word (`--include '*.swift'`). A filter that *excludes* Swift — `--exclude`, `-T`, a `!` glob — says the opposite and is not one.
    var filtersToSwift: Bool {
        arguments.contains("--swift") || fileFilters.contains { !$0.excludes && $0.value.contains("swift") }
    }

    /// Whether a flag leaves *all* Swift source out of the search — `--exclude='*.swift'`, `-T swift`, `-g '!**/*.swift'`.
    ///
    /// An exclusion of all of it says the search is not of Swift source, so it is not a Swift lookup whatever the tree it sweeps holds: the directory probe that classifies an unmarked sweep would otherwise count a search that has just ruled out every file the index covers. Leaving *some* Swift out is the opposite case — `--exclude='*Tests.swift'`, `--exclude=Package.swift`, `--exclude-dir=.swiftpm` still search the rest of it, and are the lookups they were.
    var excludesSwift: Bool {
        fileFilters.contains { $0.excludes && Self.coversAllSwift($0.value, typeFlag: Self.typeFlags.contains($0.flag)) }
    }

    /// Whether the flags that pick the files searched pick only files that are not Swift — `--include='*.jsonl'`, `rg -t md`, `rg -g '*.{json,md}'`.
    ///
    /// The same verdict as ``excludesSwift``, reached from the other side: a search whose every inclusion names another kind of file is not of Swift source, whatever the tree it sweeps holds. **Every inclusion has to say so**, because they add up — `--include='*.swift' --include='*.md'` still searches the Swift — and each has to say so definitely, because a search wrongly read as no lookup leaves the share's denominator and lifts the share. So a glob counts only when it ends in a literal extension other than `swift`, or is a literal name with no extension; one that could still match a Swift file, like `*Tests*`, keeps the search the lookup it was. A type counts when it is not `swift` or the catch-all `all`, and not at all once `--type-add` has redefined what a type holds. `ag -G` takes a regular expression rather than a glob, so it is never read as one.
    var includesOnlyNonSwift: Bool {
        let tool = tool
        guard tool != .silverSearcher else { return false }
        let inclusions = fileFilters.filter { !$0.excludes }
        guard !inclusions.isEmpty else { return false }
        let typesRedefined = arguments.contains { $0.hasPrefix("--type-add") }
        return inclusions.allSatisfy { filter in
            let typeFlag = Self.typeFlags.contains(filter.flag)
            return !(typeFlag && typesRedefined) && Self.selectsNoSwift(filter.value, typeFlag: typeFlag)
        }
    }

    /// Whether a filter's value stands for every Swift source file: `swift` as a type, or a glob that is `*.swift` — behind any `**/`, after a `!`, or as one member of a brace list.
    static func coversAllSwift(_ value: String, typeFlag: Bool) -> Bool {
        let value = value.lowercased()
        if typeFlag {
            return value == "swift"
        }
        var glob = value.hasPrefix("!") ? String(value.dropFirst()) : value
        while glob.hasPrefix("**/") {
            glob.removeFirst(3)
        }
        if glob == "*.swift" {
            return true
        }
        guard glob.hasSuffix("}"), let open = glob.firstIndex(of: "{") else { return false }
        let members = glob[glob.index(after: open) ..< glob.index(before: glob.endIndex)].split(separator: ",")
        let stem = glob[..<open]
        // `*.{swift,md}` names the extension among others; `{*.swift,*.md}` names the whole glob among others.
        return members.contains { stem + $0 == "*.swift" || coversAllSwift(String($0), typeFlag: false) }
    }

    /// Whether an including filter's value picks no Swift source file at all — a type other than `swift`, or a glob every alternative of which ends in a literal extension other than `swift`.
    ///
    /// Definite or nothing: this answer takes a search out of the share, so any glob that could still match a `.swift` file is not one. Only the last path component is read, one brace list is expanded, and a literal name with no extension at all — `Makefile` — picks no Swift either.
    static func selectsNoSwift(_ value: String, typeFlag: Bool) -> Bool {
        let value = value.lowercased()
        if typeFlag {
            return !value.isEmpty && value != "swift" && value != "all"
        }
        guard !value.hasPrefix("!"), let last = value.split(separator: "/").last.map(String.init) else { return false }
        return alternatives(of: last)?.allSatisfy { alternative in
            let metacharacters: Set<Character> = ["*", "?", "[", "]", "{", "}", "\\"]
            guard let dot = alternative.lastIndex(of: ".") else {
                return !alternative.isEmpty && !alternative.contains(where: metacharacters.contains)
            }
            let suffix = alternative[alternative.index(after: dot)...]
            return !suffix.isEmpty && suffix != "swift" && !suffix.contains(where: metacharacters.contains)
        } ?? false
    }

    /// A glob component with its one brace list expanded — `*.{json,md}` is `*.json` and `*.md` — or `nil` for more braces than one list.
    private static func alternatives(of glob: String) -> [String]? {
        guard let open = glob.firstIndex(of: "{") else {
            return glob.contains("}") ? nil : [glob]
        }
        guard let close = glob[open...].firstIndex(of: "}") else { return nil }
        let prefix = glob[..<open]
        let suffix = glob[glob.index(after: close)...]
        guard !prefix.contains("}"), !suffix.contains("{"), !suffix.contains("}") else { return nil }
        return glob[glob.index(after: open) ..< close].split(separator: ",", omittingEmptySubsequences: false).map {
            String(prefix + $0 + suffix)
        }
    }

    /// The filter flags whose value is a file type rather than a glob.
    private static let typeFlags: Set<String> = ["-t", "--type", "-T", "--type-not"]

    /// Every file filter the segment carries, its value lowercased, and whether it leaves files out rather than picking them — read by the tool's own flags, since one letter means different things to each.
    private var fileFilters: [FileFilter] {
        let tool = tool
        let flags = tool.includingFilters.union(tool.excludingFilters)
        var filters: [FileFilter] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            let filter: (flag: String, value: String?)
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                filter = (String(argument[..<equals]), String(argument[argument.index(after: equals)...]))
            } else if flags.contains(argument) {
                filter = (argument, index < arguments.count ? arguments[index] : nil)
                index += 1
            } else if argument.count > 2, !argument.hasPrefix("--"), tool.attachedFilters.contains(String(argument.prefix(2))) {
                filter = (String(argument.prefix(2)), String(argument.dropFirst(2)))
            } else {
                continue
            }
            guard flags.contains(filter.flag), let value = filter.value?.lowercased() else { continue }
            filters.append(FileFilter(
                flag: filter.flag,
                value: value,
                excludes: tool.excludingFilters.contains(filter.flag) || value.hasPrefix("!")
            ))
        }
        return filters
    }

    /// Whether the read names an explicit line window rather than the whole file — `head`, `tail`, `sed -n` with a numeric address like `120,160p`, including several joined by `;`, or an `awk` program that picks its lines by number (`NR==486,NR==493`, `NR>=10 && NR<=20`).
    ///
    /// A pattern address (`sed -n '/init/p'`, `awk '/init/'`) is a search wearing a printer's clothes and does not count: it matches text, a window prints lines someone already chose.
    var windowsLines: Bool {
        if ["head", "tail"].contains(where: { Self.isCommandWord($0, in: executableText) }) {
            return true
        }
        if Self.isCommandWord("awk", in: executableText) {
            return pattern?.wholeMatch(of: Self.awkWindow) != nil
        }
        guard Self.isCommandWord("sed -n", in: executableText) else { return false }
        return Self.sedPrintsOnlyLineRanges(arguments)
    }

    /// Whether a `sed -n` invocation's arguments print line ranges and nothing else: no `-i` flag, however spelled, and every `-e`/`--expression`/`-f` script — or a bare positional one — is a print range and nothing more.
    ///
    /// Read directly off the arguments rather than off the in-place check, which only says whether `-i` appears somewhere among them: this also has to judge each script it finds — every `-e`/`--expression`/`-f` value, or a bare positional one — as a print range, which takes its own walk regardless.
    private static func sedPrintsOnlyLineRanges(_ arguments: [String]) -> Bool {
        var sawWindow = false
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let word = arguments[index]
            if word == "-i" || word.hasPrefix("-i") || word == "--in-place" || word.hasPrefix("--in-place=") {
                return false
            }
            if word == "-e" || word == "--expression" || word == "-f" {
                index += 1
                guard index < arguments.endIndex, printsLineRanges(arguments[index]) else { return false }
                sawWindow = true
            } else if word.wholeMatch(of: Self.sedWindow) != nil {
                guard printsLineRanges(word) else { return false }
                sawWindow = true
            }
            index += 1
        }
        return sawWindow
    }

    /// Whether a `sed` script is print ranges alone, each opening on a line that exists.
    ///
    /// A first address of 0 names no line: `/usr/bin/sed` prints nothing for its range and still exits 0, and GNU `sed` refuses the script, so a script holding one is read as no window at all.
    private static func printsLineRanges(_ script: String) -> Bool {
        guard script.wholeMatch(of: sedWindow) != nil else { return false }
        return script.split(separator: ";").allSatisfy { range in
            range.prefix(while: \.isNumber).contains { $0 != "0" }
        }
    }

    /// The one file a windowed read is pointed at, or `nil` when this is not a windowed single-file read.
    ///
    /// This is the shell spelling of a ranged Read, and both consumers treat it as one — the hook answers it in place with the file's digest until this context has located the file and lets it through from then on, and the transcript scan scores it guided when an index call located the file first, cold when nothing did. One definition for both, so the spelling of a window cannot change which of the two it is.
    var windowedReadPath: String? {
        guard windowsLines, !searches, swiftFiles.count == 1, readPaths.count == 1 else { return nil }
        return swiftFiles.first
    }

    /// Whether this stage prints the files it is handed whole — a `cat`, with no pattern or window of its own, or an `awk` whose program prints every line (``printsEveryLine(awkProgram:)``) — so that what reaches the terminal is whatever the stages after it keep.
    ///
    /// An `awk` counts only with no option and exactly one operand, its program — `-v ORS=' '` or a trailing `VAR=value` operand changes what prints, as `InPlaceShape`'s own `awk` shape already requires.
    var printsWholeFiles: Bool {
        if Self.isCommandWord("awk", in: executableText) {
            guard invocation.dropFirst().count == 2 else { return false }
            return pattern.map(Self.printsEveryLine(awkProgram:)) ?? false
        }
        return Self.isCommandWord("cat", in: executableText) && !searches && !windowsLines
    }

    /// The one file a pipeline reads through a line window: a window on the file itself (``windowedReadPath``), or a `cat` of one file piped into nothing but windows — `cat -n View.swift | sed -n '1,140p'`, `cat View.swift | head -80` — which prints exactly the lines those windows pick.
    ///
    /// The pipeline's reading of the ranged read, asked by both consumers of the one-stage reading — the hook judges it as a window into that file and the scan scores it as one — so the spelling a window is written in cannot change whether the hook interrupts it or how the metric counts it. Only windows may follow the `cat`: a search after it picks its lines by pattern, and is the search it looks like (`cat View.swift | grep -n stock | head -5`).
    ///
    /// A window on the file itself is one only while what follows passes its lines on (``passesOnWhatItIsHanded``): `awk 'NR>=10&&NR<=40' View.swift | cut -d: -f1` prints what the `cut` kept, not the lines the window chose, and is the filtered read ``TextSearch/Reason/filteredOutput`` names, as a search or a `cat` behind the same `cut` is.
    static func windowedReadPath(of stages: [ShellQuery], readBy reader: Int) -> String? {
        let query = stages[reader]
        let after = stages[(reader + 1)...]
        if let path = query.windowedReadPath {
            return after.allSatisfy(\.passesOnWhatItIsHanded) ? path : nil
        }
        guard query.printsWholeFiles || NumberedRead.numbersEveryLine(query), query.swiftFiles.count == 1, query.readPaths.count == 1, !after.isEmpty,
              after.allSatisfy(\.windowsWhatItIsHanded)
        else {
            return nil
        }
        return query.swiftFiles.first
    }

    /// Whether this stage passes on the lines it is handed as a window into them, changing nothing else about what reaches the terminal — a `head`, a `tail`, a numeric `sed -n`, with no pattern and no file of its own.
    ///
    /// The narrower of the two readings of what may follow a read, and the one the pipeline's ``windowedReadPath`` takes: a pipeline of nothing but these is the ranged read it stands for. What ``TextSearch/Reason/filteredOutput`` asks is the wider ``passesOnWhatItIsHanded``, which holds wherever this one does — so a stage is never a window to the ranged-read rule and a filter to the other.
    var windowsWhatItIsHanded: Bool {
        windowsLines && !searches && operandPaths.isEmpty
    }

    /// Whether this stage hands on every line it is given, in the order it was given them, so what reaches the terminal is line for line what the stage before it printed.
    ///
    /// A window into those lines (``windowsWhatItIsHanded``) is one; so are the stages that pass them through whole — a `cat` or a pager with no file of its own — and so is any of them writing what it prints to a file rather than to the terminal, whose destination is no file it reads (``readPaths``). `cat -n` numbers the lines, which neither drops one nor reorders them.
    ///
    /// The wider of the two readings of what may follow a read, and the one ``TextSearch/Reason/filteredOutput`` asks: a stage that is not one of these drops lines or reorders them — a `sort`, a `cut`, a second `grep`, an `awk` printing a field — and what it keeps is something no index answer prints. A stage that only passes the lines on keeps the read refusable, because the answer offered in its place is the answer the caller would have seen.
    ///
    /// A `tee` is a pass-through too and is deliberately not listed: a command that tees is read as a write (`ShellInspection.writes`), so it is no lookup at all and never reaches this question.
    var passesOnWhatItIsHanded: Bool {
        guard !searches, readPaths.isEmpty else { return false }
        return windowsLines || Self.passThroughVerbs.contains { Self.isCommandWord($0, in: executableText) }
    }

    /// The search pattern: the first bare argument, skipping flags and the values they consume — and `nil` for a verb that takes none, such as `cat`.
    var pattern: String? {
        operands.pattern
    }

    /// Every pattern the search applies: each one a `-e` introduces, since several are one search for any of them, or else the one pattern it was handed — empty for a verb that takes none.
    ///
    /// ``pattern`` is the first of them, which is what the advice stands on. This is for the judgements a search earns as a whole (``TextSearch``), which any one pattern among several can decide wherever it stands: `-e '"\.cache' -e vendor` hunts a string literal whichever order the two are written in.
    var patterns: [String] {
        guard let verb = verbIndex else { return [] }
        var introduced: [String] = []
        var index = verb + 1
        while index < arguments.count, arguments[index] != "--" {
            if arguments[index] == "-e" || arguments[index] == "--regexp", index + 1 < arguments.count {
                introduced.append(arguments[index + 1])
                index += 2
                continue
            }
            index += 1
        }
        return introduced.isEmpty ? pattern.map { [$0] } ?? [] : introduced
    }

    /// Every bare argument that is not the pattern — the paths the command was pointed at.
    var operandPaths: [String] {
        operands.paths
    }

    /// The paths this stage reads from: its operands up to the first redirection, whose operator and destination say where the output goes rather than what is opened.
    ///
    /// Arguments are split on whitespace and a redirection is written either apart from its destination (`> out.txt`) or joined to it (`>out.txt`, `2>&1`), so an operand carrying a `>` at all opens the redirection, and neither it nor anything after it is a path being read.
    var readPaths: [String] {
        Array(operandPaths.prefix { !$0.contains(">") })
    }

    /// The one symbol the pattern is looking for, or `nil` when it is not looking for one — read as the search applies it, so `-w` anchors a short name.
    ///
    /// An only-matching search is read strictly. `grep -o` prints what its pattern's variable part matched, and a name standing beside that part is its context rather than its subject: `grep -o 'destination: \.[a-zA-Z]*' View.swift` lists the values after a label, and lifting `destination` out of it offers `digest View.destination`, a member nobody asked for and the file may not have. There only a pattern that is nothing but one name, a declaration or a call names a symbol.
    var symbol: String? {
        appliedPattern.flatMap { PatternReading.identifier(in: $0, certain: onlyMatching) }
    }

    /// Whether the pattern is anything one index call answers — ``PatternReading/answeredByOneCall(_:)``.
    var patternAnsweredByOneCall: Bool {
        pattern.map(PatternReading.answeredByOneCall) == true
    }

    /// Whether this is a search of some other tree than the working one — a `git grep` handed a revision, or `--cached` for the staged tree.
    ///
    /// The index answers the working tree only, so these are not lookups it lost, and advising `where` against one is wrong advice — which is worse than none: a nudge that lands on `git grep … origin/<branch> -- <paths>` is rightly ignored, the ledger reads the ignoring as unheeded, and the advice goes quiet for the contexts that follow. Revisions are recognised by shape (`origin/…`, `HEAD`, a range, `@{…}`, a bare SHA, `^`/`~` suffixes) rather than by resolving them, so a plain `git grep pattern Sources` keeps its nudge.
    ///
    /// **A word standing between the pattern and a `--` is a tree whatever spells it**, because that is how git reads it: `git grep -n pat $T -- Sources` searches whatever revision `$T` holds, and `git grep pat feature -- Sources` a local branch — both refused and re-run before this read the separator. Without one, a word's shape is all there is to go on, and a locally-named branch with none of those marks is the accepted miss, in the direction that costs one grep rather than the hook's credibility.
    var searchesOtherRevision: Bool {
        guard let git = arguments.firstIndex(of: "git"),
              let verb = verbIndex, verb > git, arguments[verb] == "grep"
        else {
            return false
        }
        if arguments.contains("--cached") {
            return true
        }
        let separated = arguments[verb...].contains("--")
        var index = verb + 1
        var sawPattern = false
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                break
            }
            if argument == "-e" || argument == "--regexp" {
                sawPattern = true
                index += 2
                continue
            }
            if Tool.gitGrep.valueFlags.contains(argument) {
                index += 2
                continue
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            if !sawPattern {
                sawPattern = true
                index += 1
                continue
            }
            if separated || Self.isRevisionShaped(argument) {
                return true
            }
            index += 1
        }
        return false
    }

    /// Whether this segment reads Swift source, by three signals in ascending order of cost.
    ///
    /// The single definition both `ShellInspection` and `ShellAdvice` ask, so the classifier can never call something a miss that the advisor cannot then say anything about — a nudge that never arrives is worse than either alone.
    ///
    /// `holdsSource` resolves a path the command was pointed at, and is the only one of the three that touches the filesystem. It is reached only for a *search* — `cat Sources/` is not a thing anyone types — and only when the pattern is something one index call answers — names and nothing else, or a shape of Swift's declaration vocabulary (``PatternReading/answeredByOneCall(_:)``) — because a tree-wide grep for a phrase that is neither is a text search the index could not have served, and counting it would inflate the miss as surely as missing a real one deflates it.
    ///
    /// **What is searched decides, never what the pattern mentions.** `grep -n "Foo.swift:3[0-9]" build.log` reads a log, and `tail -f build.log | grep Foo.swift` reads a pipe; a `.swift` in the pattern is text being hunted for, not a file being opened. So the Swift test is applied to the operands and not to the segment's text.
    ///
    /// A verb out of command position is an argument, and that holds beside a substitution too. A substitution that runs is read as a command of its own (`ShellSyntax.executedSegments`), so `echo "$(grep -n func Thing.swift)"` is judged by its body and the text around it is never needed; one spelled in single quotes or behind a backslash is only characters, and reading the segment's text for it would take `echo grep '$(grep -n foo X.swift)'` for a lookup.
    func readsSwift(holdsSource: ((String) -> Bool)?) -> Bool {
        !searchesOtherRevision && readsSwiftInAnyTree(holdsSource: holdsSource)
    }

    /// Whether this segment searches another revision's tree for Swift — a lookup in every respect but the tree it reads, which no index holds.
    ///
    /// It is no lookup at either end, and the hook logs the rule that decided so (`ShellInspection.searchesAnotherRevision`).
    func searchesAnotherRevisionOfSwift(holdsSource: ((String) -> Bool)?) -> Bool {
        searchesOtherRevision && readsSwiftInAnyTree(holdsSource: holdsSource)
    }

    /// ``readsSwift(holdsSource:)`` without regard to which tree is read.
    private func readsSwiftInAnyTree(holdsSource: ((String) -> Bool)?) -> Bool {
        guard reads, !suppliesInlineText, verbIndex != nil else { return false }
        let named = operandPaths.filter(SwiftSourcePath.appearsIn)
        // A segment whose named `.swift` files are all build manifests is reading build configuration, not source — the index deliberately excludes manifests.
        if !named.isEmpty, named.allSatisfy(SwiftPMManifest.isManifestPath) {
            return false
        }
        if !named.isEmpty || filtersToSwift {
            return true
        }
        guard let holdsSource, searches, patternAnsweredByOneCall, !excludesSwift, !includesOnlyNonSwift else { return false }
        return searchedPaths.contains { holdsSource($0) }
    }

    /// The paths a search reads: its operands short of any redirection, or the working directory, spelled `.`, where a recursive `grep` names none.
    ///
    /// A flag cluster is read up to its first letter that takes a value, so the `r` of `-rnA3` makes the search recursive and the one in `-A3r` or `-erx` is that value.
    private var searchedPaths: [String] {
        guard readPaths.isEmpty, tool == .grep else { return readPaths }
        let recursive = arguments.contains { argument in
            if argument.hasPrefix("--") {
                return argument == "--recursive" || argument == "--dereference-recursive"
            }
            guard argument.hasPrefix("-") else { return false }
            let takesValue: Set<Character> = ["A", "B", "C", "D", "d", "e", "f", "m"]
            return argument.dropFirst().prefix { $0.isLetter && !takesValue.contains($0) }.contains { $0 == "r" || $0 == "R" }
        }
        return recursive ? ["."] : []
    }
}

extension ShellQuery {
    /// Every pattern this reads shell text with, built once.
    ///
    /// Built once because `range(of:options:.regularExpression)` rebuilds its matcher on each call *and* goes through `NSString`, and on the audit path string bridging and regex machinery outweigh the JSON parsing of the same transcripts several times over. Native `Regex` reads Swift's own storage. `nonisolated(unsafe)` for the reason recorded on ``SwiftSourcePath/extensionExpression``: `Regex` is not `Sendable`, and every caller of these is serial.
    nonisolated(unsafe) static let fileRedirect = />(?!&)|>&\s*[^\s0-9-]/

    /// `1,30p`, `5p`, `1,+2p`, `10,$p` — one or more, separated by semicolons.
    nonisolated(unsafe) static let sedWindow = /[0-9]+(,([0-9]+|\+[0-9]+|\$))?p(;[0-9]+(,([0-9]+|\+[0-9]+|\$))?p)*/

    /// An `awk` program whose pattern is line numbers and nothing else — one bound or two, joined by `&&` or a range comma — with or without an action after it.
    nonisolated(unsafe) static let awkWindow =
        /(?s)\s*NR\s*(?:==|>=|<=|>|<)\s*[0-9]+(?:\s*(?:&&|,)\s*NR\s*(?:==|>=|<=|>|<)\s*[0-9]+)?\s*(?:\{.*\})?\s*/

    /// A quoted separator between `NR` and `$0` that adds nothing to the line printed: spaces, a `\t` escape and the punctuation `: | - . ,`, at most four of them.
    nonisolated(unsafe) static let awkPrintSeparator = /"(?:\\t|[ :|.,\-]){1,4}"/

    /// An `awk` action that prints every line it runs on whole, numbered or not: `{print}`, `{print $0}`, `{print NR": "$0}`.
    nonisolated(unsafe) static let awkPrintsEachLine = /\{\s*print\b(?:\s+\$0|\s+NR\s*(?:"(?:\\t|[ :|.,\-]){1,4}"|,)?\s*\$0)?\s*;?\s*\}/

    /// An `awk` action that prints every line it runs on whole through `printf` — `{printf "%s\n", $0}` or `{printf("%s\n", $0)}` — which writes the line and a newline, as `print` does.
    nonisolated(unsafe) static let awkPrintfsEachLine = /\{\s*printf\s*(?:"%s\\n"\s*,\s*\$0|\(\s*"%s\\n"\s*,\s*\$0\s*\))\s*;?\s*\}/

    /// Whether an `awk` program prints every line of its input, as `cat` or `cat -n` does: `1`, or a pattern-less action that prints each line (``awkPrintsEachLine``).
    static func printsEveryLine(awkProgram program: String) -> Bool {
        let trimmed = program.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "1" || trimmed.wholeMatch(of: awkPrintsEachLine) != nil
    }

    /// A leading `VAR=` environment assignment.
    nonisolated(unsafe) static let assignment = /[A-Za-z_][A-Za-z0-9_]*=/

    /// A `~2`/`^3` revision offset at the end of a token.
    nonisolated(unsafe) static let revisionOffset = /[~^][0-9]+$/

    /// A bare abbreviated or full SHA.
    nonisolated(unsafe) static let bareSHA = /[0-9a-f]{7,40}/

    private static let readVerbs = ["grep", "egrep", "fgrep", "rg", "ag", "cat", "head", "tail", "less", "sed -n", "awk"]
    private static let searchVerbs = ["grep", "egrep", "fgrep", "rg", "ag"]

    /// The verbs that print every line they are handed, in order, where they are handed the lines rather than pointed at a file of their own — a `cat`, and the pagers a caller pipes into to read the output themselves.
    private static let passThroughVerbs = ["cat", "less", "more"]

    /// The read verbs as single tokens, for finding the verb's *position* — `sed -n` is two of them.
    private static let verbTokens: Set<String> = ["grep", "egrep", "fgrep", "rg", "ag", "cat", "head", "tail", "less", "sed", "awk", "nl"]

    /// The read verbs whose first operand is what they look for — a pattern, a script, a program — rather than a file.
    private static let patternVerbs: Set<String> = ["grep", "egrep", "fgrep", "rg", "ag", "sed", "awk"]

    /// Where the read verb sits, or `nil` when the segment runs no verb — a verb inside a quoted run arrives as part of a longer token and rightly finds nothing.
    ///
    /// **Anything in command position may run the verb after it, except a word that only prints its arguments.** Wrappers are open-ended — `sudo`, `xargs`, `watch -n 2`, `ionice -c3`, `caffeinate`, `unbuffer`, a loop's `do` — and a list of them loses every one it does not name, each a lookup that silently leaves the share. What is closed is the other side: `echo`, `printf`, `print` and `:` only print or discard their words, so `echo \" grep -n foo X.swift \"` opens nothing however much it spells a search.
    ///
    /// A leading `(` or `{` is trimmed before matching because `isCommandWord` accepts one as a verb prefix — without the trim, `(grep …)` reads as a search whose operands cannot be found, which degrades its advice to the generic form and drops its directory sweeps from the count entirely.
    var verbIndex: Int? {
        let bare = arguments.map { String($0.drop(while: { $0 == "(" || $0 == "{" })) }
        guard let command = bare.firstIndex(where: { !$0.isEmpty && $0.prefixMatch(of: Self.assignment) == nil }),
              !Self.printers.contains(bare[command])
        else {
            return nil
        }
        return bare[command...].firstIndex(where: Self.verbTokens.contains)
    }

    /// Commands that only print or discard their arguments, so a verb among them is a word and not an invocation.
    private static let printers: Set<String> = ["echo", "printf", "print", ":"]

    /// Whether `token` is `-exec`/`-execdir`'s own terminator, `;` or `+` — usually escaped as `\;`, whose backslash the tokeniser keeps rather than strips.
    private static func endsExecClause(_ token: String) -> Bool {
        let unescaped = token.hasPrefix("\\") ? String(token.dropFirst()) : token
        return unescaped == ";" || unescaped == "+"
    }

    /// Whether `editor`, handed `options`, edits its files in place.
    ///
    /// Each editor's flags are its own, and a cluster is walked letter by letter because a letter that takes a value ends the cluster there: `perl -Mstrict` loads a module whose name holds an `i`, and `sed -e 's/i/j/'` hands over a script, and neither edits anything. A value letter closing its cluster takes the next word, which is then skipped; the walk goes past a positional word — the script or a file — since `-i` can follow it, and stops only at an unquoted redirection or pipe.
    static func editsInPlace(editor: String, options: ArraySlice<String>, rawOptions: ArraySlice<String>) -> Bool {
        let valueLetters: Set<Character>
        switch editor {
        case "sed", "gsed":
            valueLetters = ["e", "f", "l"]
        case "perl":
            valueLetters = ["e", "E", "M", "m", "I", "F", "x", "d", "D", "C"]
        case "ruby":
            valueLetters = ["e", "r", "I", "F", "x", "C", "E", "K", "T", "W"]
        case "awk", "gawk":
            // gawk edits in place by loading its `inplace` extension, and by nothing else.
            let words = Array(options)
            return words.indices.contains { index in
                let word = words[index]
                if word == "-iinplace" || word == "--include=inplace" {
                    return true
                }
                return ["-i", "--include"].contains(word) && index + 1 < words.count && words[index + 1] == "inplace"
            }
        default:
            return false
        }
        var index = options.startIndex
        while index < options.endIndex {
            let word = options[index]
            if word == "--" {
                return false
            }
            // Blanked off the raw (quotes-intact) word, one index for one index since the stripped and the raw
            // words come from the one tokenising pass — an unquoted redirection stops the scan, a
            // quoted one is a script's own text (`sed 's/-> Int/-> Int?/' -i F.swift`) and must not:
            // `word` alone cannot tell the two apart, since its quotes are already gone.
            guard ShellSyntax.executableText(of: rawOptions[index]) != "|", !ShellSyntax.executableText(of: rawOptions[index]).contains(">") else { return false }
            if word.hasPrefix("--") {
                if word == "--in-place" || word.hasPrefix("--in-place=") {
                    return true
                }
                index += 1
                continue
            }
            guard word.hasPrefix("-"), word.count > 1 else {
                index += 1
                continue
            }
            let letters = Array(word.dropFirst())
            var takesNextWord = false
            for (offset, letter) in letters.enumerated() {
                if letter == "i" {
                    return true
                }
                if valueLetters.contains(letter) {
                    takesNextWord = offset == letters.count - 1
                    break
                }
            }
            index += takesNextWord ? 2 : 1
        }
        return false
    }

    /// Whether the search matches whole words only — `-w` in any flag cluster, or `--word-regexp` — which anchors its pattern exactly as `\b…\b` would.
    var matchesWholeWords: Bool {
        guard searches else { return false }
        return arguments.contains { argument in
            if argument.hasPrefix("--") {
                return argument == "--word-regexp"
            }
            guard argument.hasPrefix("-"), argument.count > 1 else { return false }
            return argument.dropFirst().allSatisfy(\.isLetter) && argument.contains("w")
        }
    }

    /// Whether the search inverts its match, printing the lines that do not hold the pattern — `-v` in any flag cluster, or `--invert-match`.
    var invertsMatch: Bool {
        guard searches else { return false }
        return arguments.contains { argument in
            if argument.hasPrefix("--") {
                return argument == "--invert-match"
            }
            guard argument.hasPrefix("-"), argument.count > 1 else { return false }
            return argument.dropFirst().allSatisfy(\.isLetter) && argument.contains("v")
        }
    }

    /// Whether the search's patterns are fixed strings rather than expressions — `-F` in any flag cluster, `--fixed-strings`, or `fgrep`, which is `grep -F` by another name.
    ///
    /// Asked of a search only, since the letter means something else to other programs: `awk -F:` sets a field separator.
    var usesFixedStrings: Bool {
        guard searches else { return false }
        if let verb = verbIndex, arguments[verb].drop(while: { $0 == "(" || $0 == "{" }) == "fgrep" {
            return true
        }
        return arguments.contains { argument in
            if argument.hasPrefix("--") {
                return argument == "--fixed-strings"
            }
            guard argument.hasPrefix("-"), argument.count > 1 else { return false }
            return argument.dropFirst().allSatisfy(\.isLetter) && argument.contains("F")
        }
    }

    /// Whether the search prints the lines around each match — `-A`, `-B`, `-C` in any flag cluster, or `--after-context`, `--before-context`, `--context`.
    ///
    /// The count may run into the cluster (`-A8`, `-nA8`) or follow as a word, so the letters end where the digits begin. Read for the letter alone, since the count decides how much context prints and nothing about whether any does; ``ShellGrep/hasContext`` reads the same flags where the count is what matters, because it runs the search.
    var printsContext: Bool {
        guard searches else { return false }
        return arguments.contains { argument in
            if argument.hasPrefix("--") {
                let name = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
                return ["--after-context", "--before-context", "--context"].contains(name)
            }
            guard argument.hasPrefix("-"), argument.count > 1 else { return false }
            return argument.dropFirst().prefix(while: \.isLetter).contains { "ABC".contains($0) }
        }
    }

    /// Whether the search prints only the text its pattern matched — `-o` in any flag cluster, or `--only-matching` — rather than the lines holding it.
    var onlyMatching: Bool {
        guard searches else { return false }
        return arguments.contains { argument in
            if argument.hasPrefix("--") {
                return argument == "--only-matching"
            }
            guard argument.hasPrefix("-"), argument.count > 1 else { return false }
            return argument.dropFirst().allSatisfy(\.isLetter) && argument.contains("o")
        }
    }

    /// The pattern as the search applies it: wrapped in word boundaries where ``matchesWholeWords`` says the flags anchor it, so a short name is read as the whole word it is.
    var appliedPattern: String? {
        pattern.map { matchesWholeWords ? #"\b\#($0)\b"# : $0 }
    }

    /// Whether a token sits in front of the verb rather than being it — a `VAR=value` assignment, or a bare subshell brace.
    private static func precedesTheVerb(_ token: String) -> Bool {
        if token.allSatisfy({ $0 == "(" || $0 == "{" }) {
            return !token.isEmpty
        }
        return token.prefixMatch(of: assignment) != nil
    }

    /// Whether a token is a git revision by its shape alone — never by resolving it, which would cost a filesystem the classifier does not have.
    ///
    /// Every clause is kept narrow enough that no path matches, because a false positive here deletes a legitimate working-tree search from the advisor *and* the audit at once: `..` is not tested at all (a relative pathspec contains it, and `git grep` rejects ranges anyway), `~`/`^` need trailing digits (`main~2`, not the backup file `Trend.swift~`), and a bare SHA must carry a digit (`defaced` is seven hex letters). The cost is the occasional revision that carries none of these marks slipping through — a bare `main^`, a tag like `v1.0.0`, an all-letter SHA — one wrong nudge each, against silently miscounting every `git grep pat ../Sources`.
    private static func isRevisionShaped(_ token: String) -> Bool {
        if token == "HEAD" || token.hasPrefix("HEAD~") || token.hasPrefix("HEAD^") {
            return true
        }
        if token.hasPrefix("origin/") || token.hasPrefix("upstream/") || token.hasPrefix("refs/") {
            return true
        }
        if token.contains("@{") || token.contains(revisionOffset) {
            return true
        }
        guard token.wholeMatch(of: bareSHA) != nil else {
            return false
        }
        return token.contains { $0.isNumber }
    }

    /// The program this segment runs, read off its verb — and `git` in front of it for `git grep`.
    var tool: Tool {
        guard let verb = verbIndex else { return .other }
        return switch String(arguments[verb].drop(while: { $0 == "(" || $0 == "{" })) {
        case "grep", "egrep", "fgrep": arguments[..<verb].contains("git") ? .gitGrep : .grep
        case "rg": .ripgrep
        case "ag": .silverSearcher
        case "sed": .sed
        case "awk": .awk
        case "head", "tail": .headOrTail
        default: .other
        }
    }

    /// Whether `verb` appears as a command word rather than inside a longer token, so `ripgrep` in a path does not read as `rg`.
    ///
    /// Scanned over UTF-8 bytes, touching no Foundation call. A regex escaped, interpolated and compiled on every call pays for the compile, and `String.range(of:)` avoids that but keeps the worse half: `range(of:)` is Foundation's and bridges to `NSString` — and a transcript's strings come out of `JSONSerialization` already backed by one, so every comparison would fetch UTF-16 units through CoreFoundation one at a time, in what is otherwise the hottest frame in the tool.
    ///
    /// Bytes are sound here because every character the boundary turns on is ASCII, and a UTF-8 continuation byte can never be mistaken for one. The boundary is what the pattern spelled: start, a pipeline character or whitespace before; whitespace or end after.
    static func isCommandWord(_ verb: String, in text: String) -> Bool {
        let haystack = text.utf8
        let needle = verb.utf8
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }

        var candidate = haystack.startIndex
        while let found = firstRange(of: needle, in: haystack, from: candidate) {
            let openedCleanly = found.lowerBound == haystack.startIndex
                || opensAWord(haystack[haystack.index(before: found.lowerBound)])
            let closedCleanly = found.upperBound == haystack.endIndex
                || isSpace(haystack[found.upperBound])
            if openedCleanly, closedCleanly {
                return true
            }
            candidate = haystack.index(after: found.lowerBound)
        }
        return false
    }

    /// The first place `needle` occurs in `haystack` at or after `start`, compared byte for byte.
    private static func firstRange(
        of needle: String.UTF8View,
        in haystack: String.UTF8View,
        from start: String.UTF8View.Index
    ) -> Range<String.UTF8View.Index>? {
        var lower = start
        while true {
            var here = lower
            var wanted = needle.startIndex
            while wanted != needle.endIndex {
                guard here != haystack.endIndex, haystack[here] == needle[wanted] else { break }
                here = haystack.index(after: here)
                wanted = needle.index(after: wanted)
            }
            if wanted == needle.endIndex {
                return lower ..< here
            }
            guard lower != haystack.endIndex else { return nil }
            lower = haystack.index(after: lower)
        }
    }

    /// Space, tab, newline or carriage return.
    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// A byte a command word may begin after: whitespace, or one of `|`, `;`, `&`, `(`.
    private static func opensAWord(_ byte: UInt8) -> Bool {
        isSpace(byte) || byte == 0x7C || byte == 0x3B || byte == 0x26 || byte == 0x28
    }

    /// The pattern and the paths, in one pass, because which is which depends on the order they appear in.
    ///
    /// `-e` is the one flag that introduces the pattern rather than consuming an unrelated value, and it is how a pattern starting with `-` is written at all.
    ///
    /// Anchored on the verb's own position, not on "the second token": `git grep -n pat origin/br` reaches its verb at index 1, and reading from 1 unconditionally makes `grep` the pattern — every `git grep` advised as `where grep`. An env-assignment prefix shifts everything one further still.
    ///
    /// **`--` ends the options, and what follows it depends on whether the pattern has been read yet.** A pattern beginning with `-` can only be written behind it or behind `-e`, so `grep -rn -- "->" Sources` is the *only* spelling of that search real `grep` accepts — and reading `->` as a flag would eat it, leaving `Sources` standing as the pattern and the command refused with `where Sources`. Where the pattern has already been read the remaining words are paths, which is `git grep -n "pat" -- Sources/Trend.swift`, so one rule serves both without either needing to know which tool it is.
    ///
    /// **Whether there is a pattern at all is the verb's to say.** A search, a `sed` script and an `awk` program come first and are what the command looks *for*, whatever they spell — `grep Foo.swift build.log` hunts a file name through a log. `cat`, `head`, `tail` and `less` take no pattern, so every word they are handed is a file.
    private var operands: (pattern: String?, paths: [String]) {
        var pattern: String?
        var paths: [String] = []
        guard let verb = verbIndex else { return (nil, []) }
        let verbWord = String(arguments[verb].drop(while: { $0 == "(" || $0 == "{" }))
        let takesPattern = Self.patternVerbs.contains(verbWord)
        let valueFlags = tool.valueFlags
        var index = verb + 1
        var optionsEnded = false
        /// A `~` the shell was told not to expand names a directory called `~` under the working directory, which `./` spells; left as `~/…` every later step would read it as the home directory.
        func path(at position: Int) -> String {
            let word = arguments[position]
            guard word.hasPrefix("~"), position < rawArguments.count, ShellOperand(raw: rawArguments[position])?.quotesLeadingTilde == true else { return word }
            return "./" + word
        }
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--", !optionsEnded {
                optionsEnded = true
                index += 1
                continue
            }
            if optionsEnded {
                if pattern == nil, takesPattern {
                    pattern = argument
                } else {
                    paths.append(path(at: index))
                }
                index += 1
                continue
            }
            if takesPattern, argument == "-e" || argument == "--regexp" {
                if pattern == nil, index + 1 < arguments.count {
                    pattern = arguments[index + 1]
                }
                index += 2
                continue
            }
            if valueFlags.contains(argument) {
                index += 2
                continue
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            // A bare number here is a flag value this failed to pair, never a pattern and never a path —
            // except for `awk`, whose own pattern may be nothing but a number: `1`, "print every line".
            // Every character of an empty string is a digit, vacuously, though it is no number — an empty pattern,
            // `grep -n "" F.swift`, would otherwise be skipped as noise and leave `F.swift` misread as
            // the pattern itself, with no path left for the file it names.
            if verbWord != "awk", !argument.isEmpty, argument.allSatisfy({ $0.isASCII && $0.isNumber }) {
                index += 1
                continue
            }
            if pattern == nil, takesPattern {
                pattern = argument
            } else {
                paths.append(path(at: index))
            }
            index += 1
        }
        return (pattern, paths)
    }
}

extension ShellQuery {
    /// One file filter a segment carries: its flag, its value lowercased, and whether it leaves files out rather than picking them.
    struct FileFilter {
        let flag: String
        let value: String
        let excludes: Bool
    }

    /// The program a segment runs, which decides which of its flags take a value.
    ///
    /// One letter means different things to each: `grep -T` puts a tab before each line and `rg -T` names a type to leave out; `ag -t` searches every text file and `rg -t` names a type to search. A flag read as taking a value it does not take swallows the word after it — which is the pattern, as often as not — so each tool's flags are its own.
    enum Tool {
        case grep, gitGrep, ripgrep, silverSearcher, sed, awk, headOrTail, other

        /// Flags whose *next* token is a value rather than the pattern — `-A 20`, `-m 1`, `--include '*.swift'`.
        ///
        /// A file filter left out of this set hands its value to the operand reader as the pattern, so `grep --include '*.swift' -rn Name Sources` searched for `*.swift` in a file called `Name` and was neither advised nor counted.
        var valueFlags: Set<String> {
            let context: Set = ["-A", "-B", "-C", "-m", "--max-count", "--after-context", "--before-context", "--context"]
            let filters = includingFilters.union(excludingFilters)
            return switch self {
            case .grep:
                context.union(filters).union(["-d", "-D", "-f", "--file", "--directories", "--devices", "--label", "--exclude-from"])
            case .gitGrep:
                context.union(["-f", "--max-depth", "--threads"])
            case .ripgrep:
                context.union(filters).union([
                    "-d", "--max-depth", "-f", "--file", "-j", "--threads", "-M", "--max-columns", "-E", "--encoding",
                    "--type-add", "--type-clear", "--ignore-file", "--pre", "--sort", "--sortr",
                ])
            case .silverSearcher:
                context.union(filters).union(["--depth", "-p", "--path-to-ignore"])
            case .sed:
                ["-f"]
            case .awk:
                ["-F", "-v", "-f"]
            case .headOrTail:
                ["-n", "-c"]
            case .other:
                []
            }
        }

        /// The flags whose value picks the files searched.
        var includingFilters: Set<String> {
            switch self {
            case .grep: ["--include"]
            case .ripgrep: ["-t", "--type", "-g", "--glob", "--iglob"]
            case .silverSearcher: ["-G", "--file-search-regex"]
            default: []
            }
        }

        /// The flags whose value names files left out.
        var excludingFilters: Set<String> {
            switch self {
            case .grep: ["--exclude", "--exclude-dir"]
            case .ripgrep: ["-T", "--type-not"]
            case .silverSearcher: ["--ignore", "--ignore-dir"]
            default: []
            }
        }

        /// The short filter flags a value may be run into — `rg -tswift`.
        var attachedFilters: Set<String> {
            switch self {
            case .ripgrep: ["-t", "-T", "-g"]
            case .silverSearcher: ["-G"]
            default: []
            }
        }
    }
}
