//
// Copyright © Agulhas Labs
//

import Foundation

/// A `grep` command read for everything that decides which lines it prints, and run in-process over the same files — the proof an in-place answer rests on (``InPlaceAnswerer``).
///
/// **Read narrowly, run exactly, and undecided wherever exactness is out of reach.** The reading takes the pattern, the flags that change which lines match (`-E`, `-F`, `-i`, `-w`, `-x`), the flags that change nothing about which lines print (`-n`, `-H`, `-h`, `-s`, `-I`, recursion), a context count, an `--include=*.swift` beside a recursion, and a `head`, a `tail` or a one-range `sed -n` window cutting the output; any other flag reads as nothing. The run then works out the printed lines the way grep does — context groups with their `--` separators, the cut applied to what was printed — and reports the search undecided wherever it cannot be sure: a pattern outside the common core (``GrepPattern``), a line the locale decides, a file that is not text to every grep alike, a line ending in a carriage return or a first line opening on a byte-order mark where either changes its match, a symbolic link, a file or a directory it cannot read, a tree too large to read inside the budget, or a cut across several files, whose order grep does not fix.
///
/// **The grep a shell runs is not always the same program.** Claude Code's shell runs `ugrep` behind a function named `grep`, and other shells run the system's own; the two read a file differently where it holds a NUL, opens on a byte-order mark for UTF-16 or UTF-32 — which `ugrep` decodes and prints and the system grep reads as binary — or opens on a UTF-8 byte-order mark, which `ugrep` strips and the system grep reads as text. A byte-order mark for UTF-16 or UTF-32, either endianness of either (``decodedByteOrderMarks``), is undecided before anything else is asked of it, whether or not it holds the pattern as plain bytes, since a different reading of it could still find the pattern there; a NUL with no such mark is undecided only once the bytes as written could hold the pattern at all, and a first line of the UTF-8 kind is decided with and without the mark.
///
/// A recursive search reads every regular file under its directories, hidden and ignored ones included. Some shells run grep with version-control ignore rules and others without, so what one prints is a subset of what the other does; answering only where every line of the larger set is accounted for is right under both.
public struct ShellGrep: Equatable, Sendable {
    var pattern: String
    /// Whether the shell word `pattern` came from was wrapped in matching quotes — the one fact a `^}` alternative needs to stand for a live brace zsh would otherwise refuse (``InPlaceShape/isCloser(_:patternWasQuoted:)``); false where no raw spelling was carried.
    var patternWasQuoted = false
    var options = GrepPattern.Options()
    var paths: [String] = []
    var recursive = false
    var swiftOnly = false
    var before = 0
    var after = 0
    var cut: Cut?
    /// Whether the last of `-h` and `-H` written was `-h`, which prints no file's name beside its lines.
    var withoutFileNames = false
    /// Whether the arguments are one of ``DeclarationVocabularyGrep``'s closed spellings.
    private(set) var spellsDeclarationVocabulary = false

    /// The most files a recursive search reads, and the most bytes, before it is undecided rather than slow.
    static let fileLimit = 4000
    static let byteLimit = 32 * 1024 * 1024

    /// Letters a flag cluster may hold: the regex dialect, case, words, whole lines, and the flags that change nothing about which lines print.
    private static let allowedLetters: Set<Character> = ["n", "H", "h", "s", "I", "E", "F", "G", "r", "R", "w", "i", "x"]

    /// Long flags that change nothing about which lines print, and the ones that change which lines match.
    private static let allowedLong: Set<String> = [
        "--line-number", "--with-filename", "--no-filename", "--no-messages", "--extended-regexp",
        "--fixed-strings", "--basic-regexp", "--recursive", "--dereference-recursive", "--word-regexp",
        "--ignore-case", "--line-regexp", "--color", "--colour",
    ]

    /// `grep`'s arguments read, or `nil` where a flag, a second pattern or a missing one leaves them unread, or an operand opens on a quoted `~`.
    ///
    /// `rawArguments`, aligned one-for-one with `arguments`, is the same words in the shape they were written — quotes intact — so `patternWasQuoted` can tell a pattern's word apart from the shell's own unquoted reading of it; `nil` where the caller has no raw spelling to carry (a test's literal arguments, a search built from something other than a shell command), which leaves every pattern read as unquoted.
    init?(arguments: [String], rawArguments: [String]? = nil) {
        pattern = ""
        var index = 0
        var sawPattern = false
        while index < arguments.count {
            let word = arguments[index]
            let raw = rawArguments.flatMap { index < $0.count ? $0[index] : nil } ?? word
            let next = index + 1 < arguments.count ? arguments[index + 1] : nil
            if !sawPattern, word == "--" {
                guard let next else { return nil }
                pattern = next
                patternWasQuoted = Self.isQuotedWhole(rawArguments.flatMap { index + 1 < $0.count ? $0[index + 1] : nil } ?? next)
                sawPattern = true
                index += 2
                continue
            }
            if word.hasPrefix("--") {
                guard let consumed = readLong(word, next: next) else { return nil }
                index += consumed
                continue
            }
            if word.hasPrefix("-"), word.count > 1 {
                guard let consumed = readCluster(word, next: next) else { return nil }
                index += consumed
                continue
            }
            if sawPattern {
                // A path is what the shell hands over, its escapes resolved (``ShellOperand``); a word the shell reads
                // no value for off its text stays as it was, and is never found. One opening on a quoted or escaped
                // `~` names a directory called `~`, which every later step would read as the home directory.
                let operand = rawArguments == nil ? nil : ShellOperand(raw: raw)
                guard operand?.quotesLeadingTilde != true else { return nil }
                paths.append(operand?.value ?? word)
            } else {
                pattern = word
                patternWasQuoted = Self.isQuotedWhole(raw)
                sawPattern = true
            }
            index += 1
        }
        guard sawPattern, !pattern.isEmpty else { return nil }
        spellsDeclarationVocabulary = DeclarationVocabularyGrep.accepts(arguments)
        // A recursive search given no path walks the working directory as it would the operand `.`, under `ugrep`
        // and the system grep alike. `ugrep` reads its standard input as well, which adds no line only because the
        // Bash tool writes nothing to it and only a pipeline's first stage, never one a pipe feeds, is answered; that
        // input is an idle socket rather than an empty file, so the real command prints its matches and then waits.
        if recursive, paths.isEmpty {
            paths = ["."]
        }
    }

    /// Whether `raw` is one word wrapped whole in matching single or double quotes — the shell's own proof that an unquoted `}` inside it would never have reached this argument as written.
    private static func isQuotedWhole(_ raw: String) -> Bool {
        guard raw.count >= 2, let first = raw.first, let last = raw.last, first == last else { return false }
        return first == "\"" || first == "'"
    }

    /// Whether the search prints context around its matches.
    var hasContext: Bool {
        before > 0 || after > 0
    }

    /// A long flag, and how many words it took; `nil` where it is not one this reads.
    private mutating func readLong(_ word: String, next: String?) -> Int? {
        let parts = word.split(separator: "=", maxSplits: 1).map(String.init)
        let name = parts[0]
        if Self.allowedLong.contains(name) {
            switch name {
            case "--extended-regexp", "--basic-regexp":
                // `ugrep` keeps `-F` whatever dialect follows it, where the system grep takes the last one written.
                guard options.dialect != .fixed else { return nil }
                options.dialect = name == "--extended-regexp" ? .extended : .basic
            case "--fixed-strings": options.dialect = .fixed
            case "--recursive", "--dereference-recursive": recursive = true
            case "--word-regexp": options.wholeWords = true
            case "--ignore-case": options.ignoresCase = true
            case "--line-regexp": options.wholeLine = true
            case "--no-filename": withoutFileNames = true
            case "--with-filename": withoutFileNames = false
            default: break
            }
            return 1
        }
        guard name == "--include" else { return nil }
        let value = parts.count == 2 ? parts[1] : next
        // Only the one glob whose meaning is certain in every implementation: every file named `*.swift`. It
        // filters a recursion and never starts one — without `-r` some implementations skip a directory operand
        // and others search it anyway.
        guard value == "*.swift" else { return nil }
        swiftOnly = true
        return parts.count == 2 ? 1 : 2
    }

    /// A short flag cluster, and how many words it took: allowed letters, or a context flag with its count attached or following.
    private mutating func readCluster(_ word: String, next: String?) -> Int? {
        var letters = Array(word.dropFirst())
        var consumed = 1
        // A context letter ends the cluster: its count follows it, attached or as the next word.
        if let position = letters.firstIndex(where: { "ABC".contains($0) }) {
            let context = letters[position]
            let attached = String(letters[(position + 1)...])
            let written = attached.isEmpty ? next : attached
            guard let written, !written.isEmpty, written.allSatisfy(\.isASCII), written.allSatisfy(\.isNumber),
                  let count = Int(written)
            else {
                return nil
            }
            consumed = attached.isEmpty ? 2 : 1
            if context != "A" {
                before = max(before, count)
            }
            if context != "B" {
                after = max(after, count)
            }
            letters = Array(letters[..<position])
        }
        guard letters.allSatisfy(Self.allowedLetters.contains) else { return nil }
        for letter in letters {
            switch letter {
            case "E", "G":
                // As for the long spellings: a dialect after `-F` is read two ways.
                guard options.dialect != .fixed else { return nil }
                options.dialect = letter == "E" ? .extended : .basic
            case "F": options.dialect = .fixed
            case "r", "R": recursive = true
            case "w": options.wholeWords = true
            case "i": options.ignoresCase = true
            case "x": options.wholeLine = true
            case "h": withoutFileNames = true
            case "H": withoutFileNames = false
            default: break
            }
        }
        return consumed
    }

    /// The cut a `head`, `tail` or `sed -n` window stage makes, or `nil` where the stage is anything else.
    static func cut(ofStage words: [String]) -> Cut? {
        guard let verb = words.first else { return nil }
        let options = Array(words.dropFirst())
        if verb == "sed" {
            return window(ofSed: options)
        }
        guard ["head", "tail"].contains(verb) else { return nil }
        // Digits only: `tail -n +3` starts at a line rather than keeping a count, and `head -c` counts bytes.
        let digits: (String) -> Int? = { word in
            !word.isEmpty && word.allSatisfy { $0.isASCII && $0.isNumber } ? Int(word) : nil
        }
        let count: Int? = switch options.count {
        case 0: 10
        case 1: options[0].hasPrefix("-") ? digits(String(options[0].dropFirst())) : nil
        case 2: options[0] == "-n" ? digits(options[1]) : nil
        default: nil
        }
        guard let count else { return nil }
        return verb == "head" ? .head(count) : .tail(count)
    }

    /// The printed lines a `sed -n` stage keeps — `sed -n '20,80p'` or `sed -n 5p` — or `nil` for anything else: a second script, an address that is not a line number, a command but `p`, a range that runs backwards, or a file operand, which sed would read in place of the grep's output.
    private static func window(ofSed options: [String]) -> Cut? {
        guard options.count == 2, options[0] == "-n",
              let script = options[1].wholeMatch(of: /([0-9]+)(?:,([0-9]+))?p/),
              let start = Int(script.output.1), start >= 1
        else {
            return nil
        }
        guard let end = script.output.2.map({ Int($0) }) ?? start, end >= start else { return nil }
        return .window(start ... end)
    }
}

extension ShellGrep {
    /// A `head`, `tail` or `sed -n` window on the output: the first or last so many printed lines, or the printed lines at a range of positions.
    enum Cut: Equatable, Sendable {
        case head(Int)
        case tail(Int)
        case window(ClosedRange<Int>)

        /// What it keeps of `sequence`, each element one printed line.
        func kept<Element>(_ sequence: [Element]) -> ArraySlice<Element> {
            switch self {
            case let .head(count): sequence.prefix(count)
            case let .tail(count): sequence.suffix(count)
            case let .window(positions): sequence.dropFirst(positions.lowerBound - 1).prefix(positions.count)
            }
        }

        /// Whether it keeps every one of `total` printed lines.
        func keepsAll(of total: Int) -> Bool {
            switch self {
            case let .head(count), let .tail(count): total <= count
            case let .window(positions): positions.lowerBound == 1 && total <= positions.upperBound
            }
        }
    }

    /// The most an answer can account for, checked as each file is searched, so a search whose printed lines no answer could hold stops where that becomes certain rather than reading every file to the end.
    struct Ceiling {
        /// Whether a line printed from `file` could be accounted for at all.
        let admits: (_ file: String) -> Bool
        /// The least an answer spends accounting for `lines` of `file`.
        let cost: (_ lines: [Int], _ file: String) -> Int
        /// The most it may spend.
        let budget: Int
    }
}

public extension ShellGrep {
    /// One line the search prints: the file, spelled as the search reached it, the line's number, and whether it matched or is context.
    struct PrintedLine: Hashable, Sendable {
        public let file: String
        public let line: Int
        public let matched: Bool
    }

    /// What the search prints, why that could not be worked out exactly, or why no answer could account for it.
    enum Outcome: Equatable, Sendable {
        case printed([PrintedLine])
        case undecided(String)
        /// Stopped once the ceiling it ran under could not hold what it prints — a line no answer accounts for, or more lines than the budget can name.
        case pastCeiling(Breach)
    }

    /// How a search went past its ceiling.
    enum Breach: Equatable, Sendable {
        /// A line printed from a file no answer accounts for any line of.
        case unaccounted
        /// More printed lines than an answer inside the budget could name.
        case overBudget
    }

    /// The lines this search prints, its relative paths resolved against `directory` — stopping early, where `ceiling` is given, once no answer could account for them.
    ///
    /// The ceiling is checked against every printed line before the cut only where that is every line the cut could print: with no cut, or across several files, where a cut that would drop a line leaves the search undecided anyway.
    ///
    /// A walked directory is answered only where some printed line is in a file every grep reads (``UgrepSkips``).
    ///
    /// `namedFiles` reads the operands as the Swift files a member grep names (``namedFiles(in:)``) — a glob as the files the shell expands it to, a file searched recursively as itself — served in whichever order they print, which `ugrep` varies between runs and prints with no `--` between files.
    internal func run(in directory: String?, ceiling: Ceiling? = nil, namedFiles: Bool = false) -> Outcome {
        guard let pattern = GrepPattern(pattern, options: options) else { return .undecided("pattern") }
        var files: [String] = []
        var walked: [(operand: (path: String, spelled: String), files: [String])] = []
        if namedFiles {
            guard let named = self.namedFiles(in: directory) else { return .undecided("path") }
            files = named
        }
        for path in paths where !namedFiles {
            guard let absolute = Self.absolute(path, in: directory) else { return .undecided("path") }
            switch Self.kind(of: absolute) {
            case .file where !recursive:
                // Whether a filter applies to a file named outright differs between implementations.
                guard !swiftOnly || absolute.hasSuffix(".swift") else { return .undecided("path") }
                files.append(absolute)
            case .directory where recursive:
                switch Self.files(under: absolute, swiftOnly: swiftOnly) {
                case let .found(found):
                    files += found
                    walked.append(((absolute, path), found))
                case .unlisted:
                    return .undecided("unreadable")
                case .refused:
                    return .undecided("tree")
                }
            default:
                return .undecided("path")
            }
            guard files.count <= Self.fileLimit else { return .undecided("tree") }
        }
        let acrossFiles = files.count > 1
        let ceiling = cut == nil || acrossFiles ? ceiling : nil
        // Between files, a `--` may or may not print for each boundary a context option opens — the system
        // grep prints one, `ugrep` does not — so a cut across several files has to hold with that many more
        // lines than it holds with none.
        let separatorMargin = acrossFiles && hasContext ? files.count - 1 : 0
        var printed: [Entry] = []
        var bytesRead = 0
        var spent = 0
        for file in files {
            guard let data = FileManager.default.contents(atPath: file) else { return .undecided("unreadable") }
            bytesRead += data.count
            guard bytesRead <= Self.byteLimit else { return .undecided("tree") }
            let bytes = Array(data)
            let entries: [Entry]
            if Self.cannotHold(pattern, bytes, options: options) {
                // The pattern cannot stand in these bytes under any reading a shell's grep gives them, so the
                // file prints nothing and is already decided — its encoding is never asked.
                entries = []
            } else {
                guard Self.readsAlikeEverywhere(bytes) else { return .undecided("encoding") }
                guard let found = search(bytes, in: file, with: pattern) else { return .undecided("line") }
                entries = found
            }
            // A cut across files that would drop a line is undecided once it would, however many files are left.
            if acrossFiles, let cut, !cut.keepsAll(of: printed.count + entries.count + separatorMargin) {
                return .undecided("order")
            }
            let lines = entries.compactMap(\.printedLine).map(\.line)
            if let ceiling, !lines.isEmpty {
                guard ceiling.admits(file) else { return .pastCeiling(.unaccounted) }
                spent += ceiling.cost(lines, file)
                guard spent <= ceiling.budget else { return .pastCeiling(.overBudget) }
            }
            printed += entries
        }
        let outcome = cutting(printed, separatorMargin: separatorMargin, acrossFiles: acrossFiles)
        // A walk prints more under the system grep than under `ugrep`, which skips version-control directories
        // and ignored paths: the larger set is answered only where `ugrep` prints some of it too, since a search
        // `ugrep` prints nothing for exits 1 and is never answered.
        guard case let .printed(lines) = outcome, !lines.isEmpty, !walked.isEmpty else { return outcome }
        let printedFiles = Set(lines.map(\.file))
        let readByEveryGrep = walked.contains { UgrepSkips.readsOne(of: $0.files.filter(printedFiles.contains), under: $0.operand.path, spelled: $0.operand.spelled) == true }
        return readByEveryGrep ? outcome : .undecided("ignored")
    }

    /// The files a search of named Swift files reads, spelled out in full in operand order, or `nil` where an operand is not one: a glob that expands to nothing or is spelled in a syntax only some shells read, or a path that is not a regular file.
    ///
    /// A glob is expanded as the shell expands it before grep runs, sorted and without hidden names, and read from disk now; a file searched recursively is searched as itself, which is what every grep does with a file operand under `-r`.
    func namedFiles(in directory: String?) -> [String]? {
        var files: [String] = []
        for path in paths {
            guard let absolute = Self.absolute(path, in: directory),
                  let expanded = SearchOperand(path: absolute).isGlob ? Self.expanded(absolute) : [absolute]
            else {
                return nil
            }
            for file in expanded {
                guard Self.kind(of: file) == .file, !swiftOnly || file.hasSuffix(".swift") else { return nil }
                files.append(file)
            }
        }
        return files
    }

    /// Lines out of `lines` that are matches, in order.
    static func matchedLines(_ lines: [PrintedLine]) -> [PrintedLine] {
        lines.filter(\.matched)
    }
}

private extension ShellGrep {
    /// What the search prints, before a cut: a file's line, or the `--` between context groups.
    enum Entry: Equatable {
        case line(PrintedLine)
        case separator

        /// The line this entry prints, or `nil` for a separator.
        var printedLine: PrintedLine? {
            if case let .line(line) = self {
                return line
            }
            return nil
        }
    }

    enum Kind {
        case file, directory, other
    }

    /// What a walk of a directory found: every regular file under it, a directory it could not list, or a tree it refuses.
    enum Walk: Equatable {
        case found([String])
        case unlisted
        case refused
    }

    /// The UTF-8 byte-order mark.
    static let utf8ByteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// The byte-order marks `ugrep` decodes and prints, where the system grep reads the file as binary: UTF-16 either way round, and UTF-32 big-endian.
    ///
    /// UTF-32 little-endian's `FF FE 00 00` needs no entry of its own — it opens on UTF-16 little-endian's mark, which is why a shorter mark is never a prefix of a longer one here except deliberately.
    static let decodedByteOrderMarks: [[UInt8]] = [[0xFF, 0xFE], [0xFE, 0xFF], [0x00, 0x00, 0xFE, 0xFF]]

    /// Whether `bytes` open on one of those marks (``decodedByteOrderMarks``).
    static func startsWithByteOrderMark(_ bytes: [UInt8]) -> Bool {
        decodedByteOrderMarks.contains { bytes.starts(with: $0) }
    }

    /// Whether every grep a shell may run reads `bytes` as the same lines, or as the same binary file, once a pattern that could stand in them is asked of it.
    ///
    /// A NUL makes a file binary to the system grep, which reports a match in it rather than printing lines, and is how UTF-16 and UTF-32 text is spelled; a byte-order mark for either is decoded by `ugrep`, which then prints the file's lines. Either is read differently by the two whether or not the pattern appears in the bytes as written, so neither is read further.
    static func readsAlikeEverywhere(_ bytes: [UInt8]) -> Bool {
        !bytes.contains(0) && !startsWithByteOrderMark(bytes)
    }

    /// Whether `bytes` cannot hold `pattern` under any reading a shell's grep might give them — the search's cheap first pass, checked before the encoding question is asked at all.
    ///
    /// Trusted only where a byte-order mark does not open the bytes: `ugrep` decodes a marked file before matching, so a literal absent from it as written could still stand in the text it decodes to, and the mark alone already leaves the file undecided (``readsAlikeEverywhere(_:)``). Elsewhere, an implementation that treats the bytes as binary still matches them as written, so an ASCII run every match must hold, absent from the bytes themselves, decides the file has nothing to print — its encoding is irrelevant, because no reading of it can find what the bytes do not contain.
    static func cannotHold(_ pattern: GrepPattern, _ bytes: [UInt8], options: GrepPattern.Options) -> Bool {
        guard !startsWithByteOrderMark(bytes), let literal = pattern.requiredLiteral,
              !options.ignoresCase || bytes.allSatisfy({ $0 < 0x80 })
        else { return false }
        return !GrepPattern.contains(bytes, literal, foldingCase: options.ignoresCase)
    }

    /// The printed entries of one file, or `nil` where a line of it cannot be decided — the file read alike by every grep (``readsAlikeEverywhere(_:)``), and already known to hold what `pattern` requires (``cannotHold(_:_:options:)``).
    func search(_ bytes: [UInt8], in file: String, with pattern: GrepPattern) -> [Entry]? {
        // Not UTF-8: grep reports such a file as a binary match, or skips it, or reads it in a locale nothing names.
        guard String(bytes: bytes, encoding: .utf8) != nil else { return nil }
        // A carriage return no line feed follows ends a line to the parser and the compiler, so to every line the
        // index records, but never to grep: after one, the line an answer names is not the line grep prints.
        guard !bytes.indices.contains(where: { bytes[$0] == 0x0D && ($0 + 1 == bytes.count || bytes[$0 + 1] != 0x0A) }) else { return nil }
        var lines = bytes.isEmpty ? [] : bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
        if bytes.last == 0x0A {
            lines.removeLast()
        }
        var matched: [Int] = []
        for (offset, line) in lines.enumerated() {
            guard let hit = pattern.matches(line) else { return nil }
            // A carriage return closing a line is text to some implementations and a line ending to others, and a
            // byte-order mark opening the file is stripped by some and read as text by others: the line is decided
            // only where every one of those readings of it agrees.
            var readings = [line]
            if line.last == 0x0D {
                readings.append(line.dropLast())
            }
            if offset == 0, line.starts(with: Self.utf8ByteOrderMark) {
                readings += readings.map { $0.dropFirst(Self.utf8ByteOrderMark.count) }
            }
            guard readings.dropFirst().allSatisfy({ pattern.matches($0) == hit }) else { return nil }
            if hit {
                matched.append(offset + 1)
            }
        }
        return grouped(matched, lineCount: lines.count, file: file)
    }

    /// Matches with their context, grouped as grep prints them.
    func grouped(_ matched: [Int], lineCount: Int, file: String) -> [Entry] {
        guard hasContext else {
            return matched.map { .line(PrintedLine(file: file, line: $0, matched: true)) }
        }
        let hits = Set(matched)
        var entries: [Entry] = []
        var last = 0
        for number in matched {
            let start = max(number - before, last + 1)
            let end = min(number + after, lineCount)
            guard start <= end else { continue }
            if last > 0, start > last + 1 {
                entries.append(.separator)
            }
            for line in start ... end {
                entries.append(.line(PrintedLine(file: file, line: line, matched: hits.contains(line))))
            }
            last = end
        }
        return entries
    }

    /// The printed lines after the cut: exact for one file, and undecided across several whose order grep leaves unfixed unless the cut provably keeps every one of `entries` however they are ordered — `separatorMargin` widening the total by the `--` lines a context option might add between files.
    ///
    /// With context the separators count toward the cut in some implementations and not in others, so both are worked out and the answer must hold for either.
    func cutting(_ entries: [Entry], separatorMargin: Int = 0, acrossFiles: Bool) -> Outcome {
        let lines = entries.compactMap(\.printedLine)
        guard let cut else { return .printed(lines) }
        if acrossFiles {
            return cut.keepsAll(of: entries.count + separatorMargin) ? .printed(lines) : .undecided("order")
        }
        return .printed(Self.kept(entries, by: cut))
    }

    /// What `cut` keeps of one file's entries, under either reading of its separators: counted toward the cut, as some implementations count them, or not, as others do.
    static func kept(_ entries: [Entry], by cut: Cut) -> [PrintedLine] {
        let withSeparators = cut.kept(entries).compactMap(\.printedLine)
        let without = cut.kept(entries.filter { $0 != .separator }).compactMap(\.printedLine)
        var union = withSeparators
        for line in without where !union.contains(line) {
            union.append(line)
        }
        return union.sorted { $0.line < $1.line }
    }

    /// The paths the shell expands `pattern` to, sorted, or `nil` where it expands to nothing or holds syntax that shells read differently — a `**`, a `(`, a `|`, a `^`, a `#`, a `~` or an angle bracket — for which the C library's `glob` is no stand-in.
    static func expanded(_ pattern: String) -> [String]? {
        guard !pattern.contains("**"), !pattern.contains(where: { "()|^#~<>{}".contains($0) }) else { return nil }
        var found = glob_t()
        defer { globfree(&found) }
        guard glob(pattern, 0, nil, &found) == 0, found.gl_pathc > 0 else { return nil }
        let paths = (0 ..< Int(found.gl_pathc)).compactMap { index in found.gl_pathv[index].map { String(cString: $0) } }
        return paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    static func absolute(_ path: String, in directory: String?) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        guard let directory else { return nil }
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: directory, isDirectory: true)).standardizedFileURL.path
    }

    /// A regular file, a directory, or anything else — a symbolic link included, since the implementations differ on following one.
    static func kind(of path: String) -> Kind {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType
        else {
            return .other
        }
        return switch type {
        case .typeRegular: .file
        case .typeDirectory: .directory
        default: .other
        }
    }

    /// Every regular file under `directory`, sorted — refused where the tree holds a symbolic link, a special file, or more than the search reads, and unlisted where a directory in it cannot be listed.
    ///
    /// A directory grep cannot list is an error it reports and exits 2 on, whatever it printed from the rest, so the walk stops there rather than answering from the files it could read.
    ///
    /// Walked in a release pool of its own, for ``SwiftTree``'s reason: a walk that refuses part-way leaves the enumerator holding a directory handle per level, and nothing else would release it on a thread that never drains a pool.
    static func files(under directory: String, swiftOnly: Bool) -> Walk {
        autoreleasepool { walk(under: directory, swiftOnly: swiftOnly) }
    }

    private static func walk(under directory: String, swiftOnly: Bool) -> Walk {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        var unlisted = false
        // Without a handler the enumerator passes over a directory it cannot open and carries on.
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: []) { _, _ in
            unlisted = true
            return false
        }
        guard let walker else { return .refused }
        var found: [String] = []
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            guard visited <= fileLimit * 4,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true
            else {
                return .refused
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true else { return .refused }
            let name = url.lastPathComponent
            if swiftOnly {
                // `*.swift` matches no name that is only the extension in some implementations and does in others.
                guard name != ".swift" else { return .refused }
                guard name.hasSuffix(".swift") else { continue }
            }
            found.append(url.path)
            guard found.count <= fileLimit else { return .refused }
        }
        return unlisted ? .unlisted : .found(found.sorted())
    }
}
