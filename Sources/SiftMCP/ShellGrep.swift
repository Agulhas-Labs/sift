//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

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
    /// Whether `-n` was written, which prints each line's number beside it.
    var numbersLines = false
    /// The window of the printed lines a tool's own output limit keeps (`head_limit` and `offset`), counted in the order the walk meets them.
    ///
    /// Unlike ``cut``, which a pipe applies and which is undecided across files whose order grep leaves unfixed, this bounds the bytes weighed: the first lines the walk finds are those counted, and a search past the window needs read no further.
    var outputWindow: Cut?
    /// The most bytes of a line's own text the search prints (ripgrep's `--max-columns`), where it caps them.
    var columnLimit: Int?
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

    /// How many lines of the walk fill ``outputWindow`` so that no later file can change what it keeps: all of them where there is no window, or a cut across files that the window does not replace.
    private var windowReach: Int {
        cut == nil ? outputWindow?.reach ?? .max : .max
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
            case "--line-number": numbersLines = true
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
            case "n": numbersLines = true
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

        /// How many of the first printed lines decide what it keeps, so that no later line can change it.
        var reach: Int {
            switch self {
            case let .head(count): count
            case let .tail(count): count
            case let .window(positions): positions.upperBound
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

    /// Which ignore files bear on a recursive walk's directory.
    enum IgnoreScope: Equatable, Sendable {
        /// None: every file is visited.
        case none
        /// Those at or below the directory searched, as `ugrep --ignore-files` reads them.
        case belowOnly
        /// Those above it as well, up to the repository root, as ripgrep reads them.
        case withParents
    }

    /// The most an answer can account for, checked as each file is searched, so a search whose printed lines no answer could hold stops where that becomes certain rather than reading every file to the end.
    struct Ceiling {
        /// Whether a line printed from `file` could be accounted for at all.
        let admits: (_ file: String) -> Bool
        /// The least an answer spends accounting for `lines` of `file`.
        let cost: (_ lines: [Int], _ file: String) -> Int
        /// The most it may spend.
        let budget: Int
        /// The most bytes the search may print before it stops, its output already larger than any answer weighed against it.
        var printLimit: Int?
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
        /// Stopped once it would read more files or bytes than ``fileLimit`` and ``byteLimit`` allow, so what it prints is unknown, neither larger nor smaller than any answer.
        case pastLimit
    }

    /// How a search went past its ceiling.
    enum Breach: Equatable, Sendable {
        /// A line printed from a file no answer accounts for any line of.
        case unaccounted
        /// More printed lines than an answer inside the budget could name.
        case overBudget
        /// More bytes printed than the ceiling's print limit.
        case printsPastLimit
    }

    /// The lines this search prints, its relative paths resolved against `directory` — stopping early, where `ceiling` is given, once no answer could account for them.
    ///
    /// The ceiling is checked against every printed line before the cut only where that is every line the cut could print: with no cut, or across several files, where a cut that would drop a line leaves the search undecided anyway.
    ///
    /// A walked directory is answered only where some printed line is in a file every grep reads (``UgrepSkips``).
    ///
    /// `namedFiles` reads the operands as the Swift files a member grep names (``namedFiles(in:)``) — a glob as the files the shell expands it to, a file searched recursively as itself — served in whichever order they print, which `ugrep` varies between runs and prints with no `--` between files.
    internal func run(in directory: String?, ceiling: Ceiling? = nil, namedFiles: Bool = false) -> Outcome {
        measured(in: directory, ceiling: ceiling, namedFiles: namedFiles).outcome
    }

    /// What ``run(in:ceiling:namedFiles:)`` finds, with the bytes the search writes for the lines it prints after its cut (``printedBytes(of:text:names:)``).
    ///
    /// The bytes are those of the grep printing fewer: lines of files every grep reads, each named as `ugrep` names it below an operand of `.`. They are exact where the cut is; where a cut keeps one file's lines under either reading of its separators, they are those of the larger reading. Past a ceiling, or undecided, they are what was counted before it stopped.
    ///
    /// Where the shell's `program` is Claude Code's `ugrep`, the walk never enters a version-control directory (``UgrepSkips/versionControlDirectories``), for any search, as that `ugrep` never does (``files(under:swiftOnly:skipping:)``), and leaves out too, for any search, each binary file sift keeps in its cache directory below a walked operand (``isSiftStoreFile(_:below:)``) that opens on a NUL (``opensBinary(_:)``): its index names every name, so a search of the repository would otherwise never be worked out once sift had answered in it, and that `ugrep`, run with `-I`, prints nothing from such a file. The system grep reads both, and reports a match in the database as a line no answer stands in for, so there such a search is left to the encoding check like any other binary file.
    ///
    /// Asked to skip the cache, it leaves out every one of sift's binary cache files whatever its bytes. The text files beside them are read as any other.
    ///
    /// Asked to weigh any order, it reads on past a cut across files that would drop a line, where no context prints: the outcome is then every line any order could print, and the bytes the fewest any order prints (``leastPrinted(of:text:names:reads:)``). Such a search reads every file, so it reports a breach of the ceiling's budget only once it has, with those bytes, and asks the print limit nothing, which weighs uncut bytes.
    ///
    /// Given an ``outputWindow``, only the lines it keeps are weighed, taken in the walk's order, so the bytes stop growing once the window is full.
    ///
    /// Which ignore files the walk honours is `program`'s (``Program/ignoreScope``) unless `ignoreScope` says otherwise, as for ripgrep, which reads those above the directory too.
    ///
    /// Past the instant it is given to stop at, it reads no further file, and is undecided.
    internal func measured(in directory: String?, ceiling: Ceiling? = nil, namedFiles: Bool = false, weighsAnyOrder: Bool = false, skipsCache: Bool = false, stopsAt: DispatchTime = .distantFuture, program: Program = .current, ignoreScope: IgnoreScope? = nil) -> (outcome: Outcome, bytes: Int) {
        guard let pattern = GrepPattern(pattern, options: options) else { return (.undecided("pattern"), 0) }
        var files: [String] = []
        // Each file's name as grep prints it: the operand as written, and a walked file's path below it.
        var names: [String: String] = [:]
        var walked: [(operand: (path: String, spelled: String), files: [String])] = []
        if namedFiles {
            guard let named = self.namedFiles(in: directory) else { return (.undecided("path"), 0) }
            files = named
        }
        for path in paths where !namedFiles {
            guard let absolute = Self.absolute(path, in: directory) else { return (.undecided("path"), 0) }
            switch Self.kind(of: absolute) {
            case .file where !recursive:
                // Whether a filter applies to a file named outright differs between implementations.
                guard !swiftOnly || absolute.hasSuffix(".swift") else { return (.undecided("path"), 0) }
                files.append(absolute)
                names[absolute] = path
            case .directory where recursive:
                switch Self.files(under: absolute, swiftOnly: swiftOnly, skipping: program.skippedDirectories, ignoreScope: ignoreScope ?? program.ignoreScope, stopsAt: stopsAt) {
                case let .found(walk):
                    // The walk spells a path as the file system does (`/private/var` for `/var`), so what lies below
                    // the operand is cut from whichever spelling of it the path opens on.
                    let roots = [absolute, Self.resolved(absolute)].map { $0.hasSuffix("/") ? $0 : $0 + "/" }
                    let found = walk.filter {
                        let root = roots.first(where: $0.hasPrefix) ?? roots[0]
                        guard Self.isSiftStoreFile($0, below: root) else { return true }
                        return !skipsCache && (program == .system || !Self.opensBinary($0))
                    }
                    files += found
                    walked.append(((absolute, path), found))
                    // Below an operand of `.`, `ugrep` drops the `./` the system grep prints: the shorter spelling is counted.
                    let prefix = [".", "./"].contains(path) ? "" : path.hasSuffix("/") ? path : path + "/"
                    for file in found {
                        let root = roots.first(where: file.hasPrefix) ?? roots[0]
                        names[file] = prefix + file.dropFirst(root.count)
                    }
                case .unlisted:
                    return (.undecided("unreadable"), 0)
                case .refused:
                    return (.undecided("tree"), 0)
                case .pastLimit:
                    return (.pastLimit, 0)
                case .timedOut:
                    return (.undecided("time"), 0)
                }
            default:
                return (.undecided("path"), 0)
            }
            guard files.count <= Self.fileLimit else { return (.pastLimit, 0) }
        }
        // Names print beside the lines wherever more than one file could be searched, unless `-h` drops them.
        let printsNames = !withoutFileNames && (files.count > 1 || !walked.isEmpty)
        let fileName = { (file: String) -> String? in printsNames ? names[file] ?? file : nil }
        let acrossFiles = files.count > 1
        let ceiling = cut == nil || acrossFiles ? ceiling : nil
        // Between files, a `--` may or may not print for each boundary a context option opens — the system
        // grep prints one, `ugrep` does not — so a cut across several files has to hold with that many more
        // lines than it holds with none.
        let separatorMargin = acrossFiles && hasContext ? files.count - 1 : 0
        let readsOn = weighsAnyOrder && acrossFiles && cut != nil && !hasContext
        // Bytes are counted only over files every grep reads, a walked file `ugrep` may skip counted as unread
        // (``UgrepSkips``), so they are what the grep printing fewer prints.
        let walkedSets = walked.map { (operand: $0.operand, files: Set($0.files)) }
        var readsKnown: [String: Bool] = [:]
        func readByEveryGrep(_ file: String) -> Bool {
            if let known = readsKnown[file] {
                return known
            }
            let reads = walkedSets.allSatisfy { walk in
                !walk.files.contains(file) || UgrepSkips.readsOne(of: [file], under: walk.operand.path, spelled: walk.operand.spelled) == true
            }
            readsKnown[file] = reads
            return reads
        }
        var unordered = false
        var breach: Breach?
        var printed: [Entry] = []
        var text: [PrintedLine: Int] = [:]
        var bytesRead = 0
        var spent = 0
        var written = 0
        var windowed: [PrintedLine] = []
        // No file after a full window can change what it keeps, so none is read.
        for file in files where windowed.count < windowReach {
            guard DispatchTime.now() < stopsAt else { return (.undecided("time"), written) }
            guard let data = FileManager.default.contents(atPath: file) else { return (.undecided("unreadable"), written) }
            bytesRead += data.count
            guard bytesRead <= Self.byteLimit else { return (.pastLimit, written) }
            let bytes = Array(data)
            let entries: [Entry]
            if Self.cannotHold(pattern, bytes, options: options) {
                // The pattern cannot stand in these bytes under any reading a shell's grep gives them, so the
                // file prints nothing and is already decided — its encoding is never asked.
                entries = []
            } else {
                guard Self.readsAlikeEverywhere(bytes) else { return (.undecided("encoding"), written) }
                guard let found = search(bytes, in: file, with: pattern) else { return (.undecided("line"), written) }
                entries = found
            }
            let fileLines = entries.compactMap(\.printedLine)
            if !fileLines.isEmpty {
                let lengths = bytes.split(separator: 0x0A, omittingEmptySubsequences: false).map(\.count)
                for line in fileLines {
                    text[line] = lengths[line.line - 1]
                }
                // A `--` between files where a context option opens one, as the system grep prints it.
                if readByEveryGrep(file) {
                    if let outputWindow {
                        windowed = Array((windowed + fileLines).prefix(outputWindow.reach))
                        written = printedBytes(of: Array(outputWindow.kept(windowed)), text: text, names: fileName)
                    } else {
                        written += (hasContext && !printed.isEmpty ? 3 : 0) + printedBytes(of: fileLines, text: text, names: fileName)
                    }
                }
            }
            // A cut across files that would drop a line is undecided once it would, however many files are left.
            if acrossFiles, let cut, !cut.keepsAll(of: printed.count + entries.count + separatorMargin) {
                guard readsOn else { return (.undecided("order"), written) }
                unordered = true
            }
            let lines = fileLines.map(\.line)
            if let ceiling, breach == nil, !lines.isEmpty {
                guard ceiling.admits(file) else { return (.pastCeiling(.unaccounted), written) }
                spent += ceiling.cost(lines, file)
                if spent > ceiling.budget {
                    guard readsOn else { return (.pastCeiling(.overBudget), written) }
                    breach = .overBudget
                }
                // A cut search's uncut bytes say nothing of what it prints.
                guard cut != nil || written <= ceiling.printLimit ?? .max else { return (.pastCeiling(.printsPastLimit), written) }
            }
            printed += entries
        }
        let outcome = unordered ? .printed(printed.compactMap(\.printedLine)) : cutting(printed, separatorMargin: separatorMargin, acrossFiles: acrossFiles)
        let kept = switch outcome {
        case let .printed(lines) where unordered:
            leastPrinted(of: lines, text: text, names: fileName, reads: readByEveryGrep)
        case let .printed(lines):
            printedBytes(of: outputWindow.map { Array($0.kept(lines.filter { readByEveryGrep($0.file) })) } ?? lines.filter { readByEveryGrep($0.file) }, text: text, names: fileName)
        default:
            written
        }
        if let breach {
            return (.pastCeiling(breach), kept)
        }
        // A walk prints more under the system grep than under `ugrep`, which skips version-control directories
        // and ignored paths: the larger set is answered only where `ugrep` prints some of it too, since a search
        // `ugrep` prints nothing for exits 1 and is never answered.
        guard case let .printed(lines) = outcome, !lines.isEmpty, !walked.isEmpty else { return (outcome, kept) }
        let printedFiles = Set(lines.map(\.file))
        let readByEveryGrep = walked.contains { UgrepSkips.readsOne(of: $0.files.filter(printedFiles.contains), under: $0.operand.path, spelled: $0.operand.spelled) == true }
        return (readByEveryGrep ? outcome : .undecided("ignored"), kept)
    }

    /// The fewest bytes a cut across several files prints in any order of them, as a lower bound: the shortest of `lines`, each with its name and number, as many as the cut keeps of the lines in files every grep reads.
    ///
    /// With no context the cut keeps as many lines in any order, so no order prints fewer bytes than its shortest that many. Counting the lines kept only over files `reads` says every grep reads (``UgrepSkips``) keeps it a bound for `ugrep`, which skips ignored paths of a walked operand.
    internal func leastPrinted(of lines: [PrintedLine], text: [PrintedLine: Int], names: (String) -> String?, reads: (String) -> Bool) -> Int {
        guard let cut else { return printedBytes(of: lines, text: text, names: names) }
        let read = lines.count { reads($0.file) }
        let kept = cut.kept(Array(repeating: 0, count: read)).count
        return lines.map { printedBytes(of: [$0], text: text, names: names) }.sorted().prefix(kept).reduce(0, +)
    }

    /// The bytes grep writes for `lines`, in order: each line's file name where `names` gives one, `:` and its number under `-n`, its text of `text` bytes and its newline, and a `--` wherever a context option opens a new group.
    ///
    /// A group opens wherever lines stop running on: within one file both greps print that `--`, and between files the system grep does, which is the larger reading.
    internal func printedBytes(of lines: [PrintedLine], text: [PrintedLine: Int], names: (String) -> String?) -> Int {
        var total = 0
        var previous: PrintedLine?
        for line in lines {
            if hasContext, let previous, previous.file != line.file || line.line > previous.line + 1 {
                total += 3
            }
            let name = names(line.file).map { $0.utf8.count + 1 } ?? 0
            let number = numbersLines ? String(line.line).count + 1 : 0
            total += name + number + min(text[line] ?? 0, columnLimit ?? .max) + 1
            previous = line
        }
        return total
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

    /// What a walk of a directory found: every regular file under it, a directory it could not list, a tree it refuses, one past the file limit, or one still being walked when the search's time ran out.
    enum Walk: Equatable {
        case found([String])
        case unlisted
        case refused
        case pastLimit
        case timedOut
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

    /// Whether `file`, found walking the operand `root`, is one of the binary files sift keeps below it in a cache directory of its own (one named as sift names its own, holding its index): the index and its journal, the semantic store's caches, and the builds `sift run --without` makes.
    ///
    /// The text sift writes there — run logs, progress records, locks — is printed by any grep and counted like any other file.
    static func isSiftStoreFile(_ file: String, below root: String) -> Bool {
        let components = file.dropFirst(root.count).split(separator: "/")
        guard let cache = components.dropLast().firstIndex(of: Substring(SiftPaths.directoryName)) else { return false }
        let directory = root + components[...cache].joined(separator: "/")
        guard FileManager.default.fileExists(atPath: directory + "/" + SiftPaths.indexFileName) else { return false }
        let inside = components[(cache + 1)...]
        guard let first = inside.first.map(String.init) else { return false }
        let index = SiftPaths.indexFileName
        return inside.count == 1 ? [index, index + "-wal", index + "-shm", index + "-journal"].contains(first) : ["isdb", "without-build"].contains(first)
    }

    /// Whether `file` holds a NUL in its opening bytes and opens on no byte-order mark `ugrep` decodes: binary to the shell's `ugrep`, which under the `-I` it is always run with prints nothing from it, however far past the opening a match lies.
    ///
    /// Only the opening is read, where every one of sift's database files spells a NUL in its header; a NUL further in is not asked about, since how far into a file `ugrep` looks for one is not something this can know.
    static func opensBinary(_ file: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: file) else { return false }
        defer { try? handle.close() }
        guard let opening = try? handle.read(upToCount: 32) else { return false }
        let bytes = Array(opening)
        return bytes.contains(0) && !startsWithByteOrderMark(bytes)
    }

    /// `path` as the file system spells it, every symbolic link on it resolved, or `path` itself where it cannot be.
    static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
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

    /// Every regular file under `directory`, sorted — refused where the tree holds a symbolic link, a special file, or more than the search reads, unlisted where a directory in it cannot be listed, and timed out where the search's time runs out first.
    ///
    /// A directory grep cannot list is an error it reports and exits 2 on, whatever it printed from the rest, so the walk stops there rather than answering from the files it could read.
    ///
    /// A directory named in `skipping` is passed over, nothing in it listed or counted, as the shell's `ugrep` passes over a version-control directory.
    ///
    /// Where the `ignoreScope` reads ignore files and `directory` lies in a git work tree, only the files git lists there (``GitContext/listedFiles(under:within:)``) are visited, as `ugrep --ignore-files` visits what `.gitignore` leaves in: a directory holding none of them is not entered. A listing git cannot give, or an empty one (the operand is itself an ignored directory, which `ugrep` still searches), leaves the walk as if the flag were off.
    ///
    /// For ``IgnoreScope/belowOnly`` the paths that only a `.gitignore` above `directory` ignores are visited too (``GitContext/parentIgnoredPaths(under:within:)``), since `ugrep` reads no ignore file above the directory it searches; one it cannot get leaves the walk as if the flag were off as well.
    ///
    /// Walked in a release pool of its own, for ``SwiftTree``'s reason: a walk that refuses part-way leaves the enumerator holding a directory handle per level, and nothing else would release it on a thread that never drains a pool.
    static func files(under directory: String, swiftOnly: Bool, skipping: Set<String>, ignoreScope: IgnoreScope = .none, stopsAt: DispatchTime = .distantFuture) -> Walk {
        autoreleasepool {
            var listed: Listing?
            if ignoreScope != .none {
                let seconds = min(Double(stopsAt.uptimeNanoseconds &- DispatchTime.now().uptimeNanoseconds) / 1e9, ChildDeadline.gitBulk)
                guard stopsAt == .distantFuture || (seconds > 0 && DispatchTime.now() < stopsAt) else { return .timedOut }
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                listed = GitContext.listedFiles(under: url, within: seconds).flatMap(Listing.init)
                if ignoreScope == .belowOnly, listed != nil {
                    // A path only a `.gitignore` above the directory names is one `ugrep` still searches.
                    listed = GitContext.parentIgnoredPaths(under: url, within: seconds).flatMap { listed?.opening($0) }
                }
            }
            return walk(under: directory, swiftOnly: swiftOnly, skipping: skipping, listed: listed, stopsAt: stopsAt)
        }
    }

    /// The files git lists below a directory, and the directories that hold any of them, each relative to it.
    struct Listing {
        let files: Set<String>
        var directories: Set<String>
        /// Directories visited whole, nothing in them left out.
        var opened: Set<String> = []

        /// `nil` for an empty listing.
        init?(_ paths: [String]) {
            guard !paths.isEmpty else { return nil }
            files = Set(paths)
            var directories: Set<String> = []
            for path in paths {
                var parent = (path as NSString).deletingLastPathComponent
                while !parent.isEmpty, directories.insert(parent).inserted {
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
            self.directories = directories
        }

        /// This listing with `paths` visited as well, a trailing slash marking a directory taken whole, and the directories leading to them entered.
        func opening(_ paths: [String]) -> Listing {
            var result = self
            for path in paths {
                let path = path.hasSuffix("/") ? String(path.dropLast()) : path
                result.opened.insert(path)
                var parent = (path as NSString).deletingLastPathComponent
                while !parent.isEmpty, result.directories.insert(parent).inserted {
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
            return result
        }

        /// Whether the walk visits `relative`: git lists it, or it lies in (or is) an opened path.
        func admits(_ relative: String, isDirectory: Bool) -> Bool {
            if isDirectory ? directories.contains(relative) : files.contains(relative) {
                return true
            }
            guard !opened.isEmpty else { return false }
            var current = relative
            while !current.isEmpty {
                if opened.contains(current) {
                    return true
                }
                current = (current as NSString).deletingLastPathComponent
            }
            return false
        }
    }

    private static func walk(under directory: String, swiftOnly: Bool, skipping: Set<String>, listed: Listing?, stopsAt: DispatchTime) -> Walk {
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
        // The enumerator spells a path as the file system does (`/private/var` for `/var`).
        let prefixes = [root.path, Self.resolved(root.path)].map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        for case let url as URL in walker {
            visited += 1
            guard visited <= fileLimit * 4 else { return .pastLimit }
            guard visited % 256 != 0 || DispatchTime.now() < stopsAt else { return .timedOut }
            if let listed {
                // Git lists no directory it ignores, so one holding nothing it lists is not entered, and a file it does not list is not visited.
                let relative = prefixes.first(where: url.path.hasPrefix).map { String(url.path.dropFirst($0.count)) } ?? url.path
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if !listed.admits(relative, isDirectory: isDirectory) {
                    if isDirectory {
                        walker.skipDescendants()
                    }
                    continue
                }
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true
            else {
                return .refused
            }
            if values.isDirectory == true {
                // A directory the shell's grep never descends into is neither read nor counted toward the limits.
                if skipping.contains(url.lastPathComponent) {
                    walker.skipDescendants()
                }
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
            guard found.count <= fileLimit else { return .pastLimit }
        }
        return unlisted ? .unlisted : .found(found.sorted())
    }
}
