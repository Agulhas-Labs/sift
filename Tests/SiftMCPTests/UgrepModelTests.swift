//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Where the `ugrep` behind Claude Code's `grep` function reads a pattern or its flags differently from the system grep, the search is refused rather than decided one way.
///
/// Verified by running each probe through the shell snapshot's `grep` function (`ugrep -G --ignore-files --hidden -I --exclude-dir=.git …`) and through `/usr/bin/grep` over the same files, and diffing both against ``ShellGrep``'s own run. The expectations below are what `ugrep` printed, so these tests hold without the Claude binary; ``theRecordedUgrepBehaviourStillHolds()`` re-checks them against `ugrep` wherever one is installed.
@Suite(.temporaryDirectories)
struct UgrepModelTests {
    /// `x.y` beside `xzy`, a line holding an `x` beside lines holding none, and every ASCII punctuation mark.
    private static let corpus = ["x.y", "xzy", "none", "a+b", "a|b", "L!R", "L$R", "L+R", "L<R", "L=R", "L>R", "L^R", "L`R", "L|R", "L~R"]

    /// `-F` holds under `ugrep` whatever dialect follows it, where the system grep takes the last one written: `grep -F -E 'x.y'` prints `x.y` alone under `ugrep` and `xzy` too under the system grep.
    @Test(arguments: [["-F", "-E"], ["-FE"], ["-F", "--extended-regexp"], ["-F", "-G"], ["--fixed-strings", "--basic-regexp"]])
    func aDialectAfterFixedStringsIsRefused(flags: [String]) {
        #expect(ShellGrep(arguments: flags + ["x.y", "File.swift"]) == nil)
    }

    /// The same dialects the other way round agree everywhere — `-F` written last is `-F` to both — and are still read.
    @Test(arguments: [["-E", "-F"], ["-EF"], ["-G", "-F"], ["-G", "-E"], ["-E", "-G"]])
    func aDialectBeforeFixedStringsIsRead(flags: [String]) throws {
        let search = try #require(ShellGrep(arguments: flags + ["x.y", "File.swift"]))

        #expect(search.options.dialect == (flags.last?.hasSuffix("F") == true ? .fixed : flags.last == "-G" ? .basic : .extended))
    }

    /// `ugrep` reads `[[:punct:]]` as Unicode punctuation, which leaves out ``$+<=>^`|~`` — nine lines of `L?R` the system grep prints and `ugrep` does not.
    @Test(arguments: ["L[[:punct:]]R", "L[^[:punct:]]R", "[[:punct:][:alpha:]]"])
    func thePunctuationClassIsRefused(pattern: String) {
        #expect(GrepPattern(pattern, options: GrepPattern.Options()) == nil)
        #expect(GrepPattern(pattern, options: GrepPattern.Options(dialect: .extended)) == nil)
    }

    /// A pattern that can match the empty string prints every line under the system grep and only the lines holding a non-empty match under `ugrep` — `x*` prints the two lines holding an `x`, `x\{0\}` prints nothing and exits 1.
    @Test(arguments: [
        (#"x*"#, GrepPattern.Dialect.basic), (#"\(x*\)"#, .basic), (#"x\{0\}"#, .basic), (#"x\?"#, .basic), (#"\b"#, .basic), (#"\<"#, .basic),
        (#"foo\|x*"#, .basic), ("q?", .extended), ("foo|x*", .extended), ("(foo)*", .extended), ("x{0,1}", .extended),
    ])
    func aPatternThatCanMatchNothingIsRefused(pattern: String, dialect: GrepPattern.Dialect) {
        #expect(GrepPattern(pattern, options: GrepPattern.Options(dialect: dialect)) == nil)
    }

    /// A pattern that can match the empty string but on which `ugrep` and the system grep print the same lines is refused all the same: the refusal is a deliberate superset, not a divergence.
    @Test(arguments: ["^x*$", "^$", "x*$"])
    func aPatternThatCanMatchNothingIsRefusedWhereBothGrepsAgree(pattern: String) {
        #expect(GrepPattern(pattern, options: GrepPattern.Options(dialect: .extended)) == nil)
    }

    /// A pattern every match of which holds a character is read as before, a starred piece beside it included.
    @Test(arguments: [(#"x*y"#, GrepPattern.Dialect.basic), ("a*b", .basic), (#"\bfoo\b"#, .basic), ("x+", .extended), ("[[:alpha:]]", .basic)])
    func aPatternThatAlwaysMatchesSomethingIsRead(pattern: String, dialect: GrepPattern.Dialect) {
        #expect(GrepPattern(pattern, options: GrepPattern.Options(dialect: dialect)) != nil)
    }

    /// Each behaviour recorded above, re-checked against `ugrep` run as the shell function runs it, and against the system grep that reads it the other way.
    @Test(.enabled(if: SystemGrep.installedUgrep != nil, "no ugrep on this machine"))
    func theRecordedUgrepBehaviourStillHolds() throws {
        let ugrep = try #require(SystemGrep.installedUgrep)
        let system = SystemGrep.system(locale: "en_US.UTF-8")
        let directory = try TemporaryDirectory.make("ugrep-model")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("corpus.txt")
        try (Self.corpus.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        #expect(try ugrep.lines(["-F", "-E"], "x.y", file) == [1])
        #expect(try system.lines(["-F", "-E"], "x.y", file) == [1, 2])
        #expect(try ugrep.lines([], "L[[:punct:]]R", file) == [6])
        #expect(try system.lines([], "L[[:punct:]]R", file).count == 10)
        #expect(try ugrep.lines([], "x*", file) == [1, 2])
        #expect(try system.lines([], "x*", file).count == Self.corpus.count)
        #expect(try ugrep.lines([], #"x\{0\}"#, file).isEmpty)
        #expect(try ugrep.lines(["-E"], "^x*$", file) == system.lines(["-E"], "^x*$", file))
        #expect(try ugrep.lines(["-x"], ".*", file) == system.lines(["-x"], ".*", file))

        // The walk: a version-control directory is skipped, a `.gitignore` above the operand is not read, and one inside it is.
        for name in UgrepSkips.versionControlDirectories {
            let versionControl = try Self.directory(["\(name)/Depot.swift": "let Depot = 1\n", "Main.swift": "let Depot = 2\n"])
            #expect(try ugrep.files("Depot", under: ".", in: versionControl) == ["Main.swift"], "\(name)")
            #expect(try system.files("Depot", under: ".", in: versionControl) == ["\(name)/Depot.swift", "Main.swift"], "\(name)")
        }
        let above = try Self.repository([".gitignore": "Gen.swift\n", "Sources/Gen.swift": "let Depot = 1\n"])
        let inside = try Self.repository(["Sources/.gitignore": "Gen.swift\n", "Sources/Gen.swift": "let Depot = 1\n", "Sources/Main.swift": "let Depot = 2\n"])
        #expect(try ugrep.files("Depot", under: "Sources", in: above) == ["Sources/Gen.swift"])
        #expect(try ugrep.files("Depot", under: "Sources", in: inside) == ["Sources/Main.swift"])
    }

    /// A tracked file an ignore rule matches holds the only match: `ugrep` skips it, prints nothing and exits 1, so the search is not answered.
    @Test func aMatchOnlyInAnIgnoredTrackedFileIsRefused() throws {
        let repo = try Self.repository([".gitignore": "Gen.swift\n", "Sources/Gen.swift": "let Depot = 1\n"])

        #expect(try Self.run(["-rn", "Depot", "."], in: repo) == .undecided("ignored"))
    }

    /// A second match in a file every grep reads is printed by `ugrep` too, so the search is answered.
    @Test func aMatchBesideTheIgnoredFileIsAnswered() throws {
        let repo = try Self.repository([
            ".gitignore": "Gen.swift\n", "Sources/Gen.swift": "let Depot = 1\n", "Sources/Main.swift": "let Depot = 2\n",
        ])

        #expect(try Self.lines(Self.run(["-rn", "Depot", "."], in: repo), in: repo) == ["Sources/Gen.swift:1", "Sources/Main.swift:1"])
    }

    /// `ugrep` skips a version-control directory named as the operand, and one met below it; a directory inside one, named as the operand, is searched.
    @Test(arguments: [".git", ".svn", ".hg", ".bzr", ".jj", ".sl"])
    func aVersionControlDirectoryIsNotAnswered(name: String) throws {
        let root = try Self.directory(["\(name)/Depot.swift": "let Depot = 1\n", "\(name)/sub/Depot.swift": "let Depot = 2\n"])

        #expect(try Self.run(["-rn", "Depot", name], in: root) == .undecided("ignored"))
        #expect(try Self.run(["-rn", "Depot", "."], in: root) == .undecided("ignored"))
        #expect(try Self.lines(Self.run(["-rn", "Depot", "\(name)/sub"], in: root), in: root) == ["\(name)/sub/Depot.swift:1"])
    }

    /// `ugrep` reads no `.gitignore` above the operand, so a rule at the repository's root leaves a search of `Sources` whole.
    @Test func aGitignoreAboveTheOperandIsNotApplied() throws {
        let repo = try Self.repository([".gitignore": "Gen.swift\n", "Sources/Gen.swift": "let Depot = 1\n"])

        #expect(try Self.lines(Self.run(["-rn", "Depot", "Sources"], in: repo), in: repo) == ["Sources/Gen.swift:1"])
    }

    /// A `.gitignore` inside the operand is read by `ugrep`, so the file it matches is skipped.
    @Test func aGitignoreInsideTheOperandIsApplied() throws {
        let repo = try Self.repository(["Sources/.gitignore": "Gen.swift\n", "Sources/Gen.swift": "let Depot = 1\n"])

        #expect(try Self.run(["-rn", "Depot", "Sources"], in: repo) == .undecided("ignored"))
    }

    /// A `.gitignore` outside any repository is still read by `ugrep`, and git reads it alike as the root of a tree of its own: the file it ignores is skipped, and the one beside it answered.
    @Test func aGitignoreOutsideARepositoryIsRead() throws {
        let root = try Self.directory(Self.outsideARepository)

        #expect(try Self.lines(Self.run(["-rn", "Depot", "."], in: root), in: root) == ["Sources/Gen.swift:1", "Sources/Main.swift:2"])
        #expect(try Self.run(["-rn", "Gizmo", "."], in: root) == .undecided("ignored"))
    }

    /// The tree the outside-a-repository test searches: a `.gitignore` ignoring one of two files holding a match, with no repository around it.
    private static let outsideARepository = [
        ".gitignore": "Gen.swift\n", "Sources/Gen.swift": "let Depot = 1\nlet Gizmo = 1\n", "Sources/Main.swift": "\nlet Depot = 2\n",
    ]

    /// An ignore rule git reads from outside the tree's `.gitignore` files — the repository's exclude file, or the file its excludes setting names — is not read by `ugrep`, so the file only it ignores is answered, a `.gitignore` on its path included.
    @Test(arguments: [false, true])
    func aRuleOnlyGitReadsIsNotApplied(inExcludesFile: Bool) throws {
        let repo = try Self.excludedOnlyByGit(inExcludesFile: inExcludesFile)

        #expect(try Self.lines(Self.run(["-rn", "Depot", "."], in: repo), in: repo) == ["Sources/Keep.swift:1"])
        #expect(try Self.lines(Self.run(["-rn", "Depot", "Sources"], in: repo), in: repo) == ["Sources/Keep.swift:1"])
    }

    /// `ugrep` still prints the file the rule-only-git-reads test answers, and outside a repository still skips what a `.gitignore` ignores.
    @Test(.enabled(if: SystemGrep.installedUgrep != nil, "no ugrep on this machine"))
    func theRecordedRulesUgrepLeavesStillHold() throws {
        let ugrep = try #require(SystemGrep.installedUgrep)

        let repos = try [false, true].map(Self.excludedOnlyByGit(inExcludesFile:))
        let outside = try Self.directory(Self.outsideARepository)

        #expect(try repos.map { try ugrep.files("Depot", under: ".", in: $0) } == [["Sources/Keep.swift"], ["Sources/Keep.swift"]])
        #expect(try repos.map { try ugrep.files("Depot", under: "Sources", in: $0) } == [["Sources/Keep.swift"], ["Sources/Keep.swift"]])
        #expect(try ugrep.files("Depot", under: ".", in: outside) == ["Sources/Main.swift"])
        #expect(try ugrep.files("Gizmo", under: ".", in: outside).isEmpty)
    }

    /// A repository whose `Sources/Keep.swift`, the one file holding `match`, is ignored by git's exclude file or by the file its excludes setting names, and by no `.gitignore`, though one lies on its path.
    private static func excludedOnlyByGit(inExcludesFile: Bool) throws -> URL {
        let repo = try repository(["Sources/.gitignore": "Other.swift\n", "Sources/Keep.swift": match])
        let gitDirectory = repo.appendingPathComponent(".git")
        if inExcludesFile {
            let rules = gitDirectory.appendingPathComponent("rules")
            try "Keep.swift\n".write(to: rules, atomically: true, encoding: .utf8)
            let config = gitDirectory.appendingPathComponent("config")
            let setting = "[core]\n\texcludesfile = \(rules.path)\n"
            try (String(contentsOf: config, encoding: .utf8) + setting).write(to: config, atomically: true, encoding: .utf8)
        } else {
            let exclude = gitDirectory.appendingPathComponent("info").appendingPathComponent("exclude")
            try FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "Keep.swift\n".write(to: exclude, atomically: true, encoding: .utf8)
        }
        return repo
    }

    /// `ugrep` honours a `.gitignore` line git's own ignore-pattern reading drops or takes literally — a leading space, a leading backslash before an ordinary character, a leading `./` — and still matches with it, so a decision resting on `git check-ignore` alone is wrong; it is refused instead.
    @Test(arguments: [" Gen.swift", "\\Gen.swift", "./Sources"])
    func aGitignoreSpellingGitReadsDifferentlyIsRefused(pattern: String) throws {
        let repo = try Self.repository([".gitignore": "\(pattern)\n", "Sources/Gen.swift": "let Depot = 1\n"])

        #expect(try Self.run(["-rn", "Depot", "."], in: repo) == .undecided("ignored"))
    }

    /// `ugrep` trims a trailing tab, vertical tab or form feed from a `.gitignore` line and matches the rest where a `[` is never closed, where git matches nothing with either, so it is refused.
    @Test(arguments: ["Gen.swift\t", "Gen.swift\u{0B}", "Gen.swift\u{0C}", "Gen.swift\t ", "Gen.swif[t"])
    func aGitignoreEndingGitReadsDifferentlyIsRefused(pattern: String) throws {
        let repo = try Self.repository([".gitignore": "\(pattern)\n", "Sources/Gen.swift": "let Depot = 1\n"])

        #expect(try Self.run(["-rn", "Depot", "."], in: repo) == .undecided("ignored"))
        if let ugrep = SystemGrep.installedUgrep {
            #expect(try ugrep.files("Depot", under: ".", in: repo).isEmpty)
        }
    }

    /// A `.gitignore` that is not UTF-8 cannot have its lines checked, so a spelling git reads differently from `ugrep` could hide in it, and every walked search under it is refused.
    @Test(arguments: ["Gen.swift\t", " Gen.swift"])
    func aGitignoreThatIsNotUTF8IsRefused(line: String) throws {
        let repo = try Self.repository(["Sources/Gen.swift": "let Depot = 1\n"])
        try (Data("# caf".utf8) + [0xE9] + Data("\n\(line)\n".utf8)).write(to: repo.appendingPathComponent(".gitignore"))

        #expect(try Self.run(["-rn", "Depot", "."], in: repo) == .undecided("ignored"))
        if let ugrep = SystemGrep.installedUgrep {
            #expect(try ugrep.files("Depot", under: ".", in: repo).isEmpty)
        }
    }

    /// git reads a `]` straight after `[`, `[!` or `[^`, and a `\]`, as part of a bracket never closed, and matches nothing with the line, where `ugrep` reads them its own way, so a `.gitignore` line holding one is refused.
    @Test(arguments: ["Gen.swif[]t", #"Gen.swif[\]t"#, "Gen.swif[!]t", "Gen.swif[^]t"])
    func aGitignoreBracketIsRefused(pattern: String) throws {
        let repo = try Self.repository([".gitignore": "\(pattern)\n", "Sources/Gen.swift": "let Depot = 1\n"])

        #expect(try Self.run(["-rn", "Depot", "."], in: repo) == .undecided("ignored"))
    }

    /// `ugrep` reads a `**` glued to a following character as matching nothing where git matches with it, so a `.gitignore` of such lines alone skips no file, and a search over the file git would ignore is answered.
    @Test(arguments: [("G?**.swift", "Gizmo.swift"), ("**[Gg]en.swift", "Gen.swift"), ("a/**b.swift", "a/xb.swift"), ("**Gen.swift", "Gen.swift"), ("G**.swift", "Gizmo.swift")])
    func aGlobGluedToDoubleStarsSkipsNothing(pattern: String, file: String) throws {
        let repo = try Self.repository([".gitignore": "\(pattern)\n", file: "let Depot = 1\n"])

        #expect(try Self.lines(Self.run(["-rn", "Depot", "."], in: repo), in: repo) == ["\(file):1"])
        if let ugrep = SystemGrep.installedUgrep {
            #expect(try ugrep.files("Depot", under: ".", in: repo) == [file])
        }
    }

    /// A glued `**` line beside a live rule is still refused, and so is a `!` line of it, where git keeps a file that `ugrep` skips.
    @Test func aGluedDoubleStarBesideALiveRuleIsStillRefused() throws {
        let beside = try Self.repository([".gitignore": "**Gen.swift\nGen.swift\n", "Gen.swift": "let Depot = 1\n"])
        let negated = try Self.repository([".gitignore": "*.swift\n!**Gen.swift\n", "Gen.swift": "let Depot = 1\n"])

        #expect(try Self.run(["-rn", "Depot", "."], in: beside) == .undecided("ignored"))
        #expect(try Self.run(["-rn", "Depot", "."], in: negated) == .undecided("ignored"))
    }

    /// A range across letter cases and a backslash before a question mark are read by git and `ugrep` alike, so the file they skip is skipped and the one beside it answered.
    @Test(arguments: ["[A-z]en.swift", "[0-z]en.swift", "Gen\\?swift"])
    func aRangeAcrossCasesOrAnEscapedQuestionMarkIsRead(pattern: String) throws {
        let repo = try Self.repository([".gitignore": "\(pattern)\n", "Gen.swift": "let Depot = 1\n", "Gen?swift": "let Depot = 2\n", "Main.swift": "let Depot = 3\n"])

        #expect(try Self.lines(Self.run(["-rn", "Depot", "."], in: repo), in: repo).contains("Main.swift:1"))
    }

    /// A `!` pattern keeps a file an earlier rule ignored, and `ugrep` reads it: an allowlist `.gitignore` answers a search matching only the kept file, and still refuses one matching a file it ignores.
    @Test func aFileAnAllowlistKeepsIsAnswered() throws {
        let repo = try Self.repository([".gitignore": "*\n!Keep.swift\n", "Keep.swift": "let Depot = 1\n", "Other.swift": "let Gizmo = 1\n"])

        #expect(try Self.lines(Self.run(["-rn", "Depot", "."], in: repo), in: repo) == ["Keep.swift:1"])
        #expect(try Self.run(["-rn", "Gizmo", "."], in: repo) == .undecided("ignored"))
    }

    /// `ugrep` matches ignore rules case-sensitively whatever `core.ignorecase` says, so a rule for `gen.swift` leaves `Gen.swift` read, where git folding case would match it.
    @Test(arguments: [true, false])
    func aRuleInAnotherCaseIsNotApplied(ignoreCase: Bool) throws {
        let repo = try Self.repository([".gitignore": "gen.swift\n", "Sources/Gen.swift": "let Depot = 1\n"], ignoreCase: ignoreCase)

        #expect(try Self.lines(Self.run(["-rn", "Depot", "."], in: repo), in: repo) == ["Sources/Gen.swift:1"])
    }

    /// A `!` pattern in another case keeps nothing for `ugrep`, so the file an earlier rule ignores stays skipped and the search is refused, where git folding case would keep it.
    @Test(arguments: [true, false])
    func aNegationInAnotherCaseKeepsNothing(ignoreCase: Bool) throws {
        let repo = try Self.repository([".gitignore": "*.swift\n!keep.swift\n", "Keep.swift": "let Depot = 1\n"], ignoreCase: ignoreCase)

        #expect(try Self.run(["-rn", "Depot", "."], in: repo) == .undecided("ignored"))
    }

    /// A `!` pattern `ugrep` reads as matching nothing — a POSIX class in brackets, a `***` — keeps a file for git that `ugrep` skips, so the search is refused.
    @Test(arguments: ["!K[[:alpha:]]ep.swift", "!Sources/***"])
    func aNegationUgrepReadsItsOwnWayIsRefused(pattern: String) throws {
        let repo = try Self.repository([".gitignore": "*.swift\n\(pattern)\n", "Sources/Keep.swift": "let Depot = 1\n"])

        #expect(try Self.run(["-rn", "Depot", "."], in: repo) == .undecided("ignored"))
    }

    /// The one line every fixture in `ignoreReadings` matches, in the one file each holds it in.
    private static var match: String {
        "let Depot = 1\n"
    }

    /// `.gitignore` files under which git reads the one file holding `match`, each searched from `operand`, with whether `ugrep` reads that file too.
    ///
    /// `ugrep` matches a pattern with a `/` inside it against the path the walk spells from the operand, so a nested `.gitignore`, or an operand spelled other than `.`, reads it differently from git in either direction: `!gen/Keep.swift` in `sub` keeps nothing, and `sub/Keep.swift` in `sub` skips a file git reads. A leading `/`, a trailing `/`, trailing spaces, a line ending in one carriage return and a byte order mark opening the file are read alike; git drops one carriage return only straight before the line feed, where `ugrep` trims every trailing space and carriage return, so any other carriage return makes git match nothing where `ugrep` skips the file. git's `?` matches one byte and `ugrep`'s one character, so the two disagree over a name holding a character of more than one byte, a decomposed one included, where `*` matches any run for both.
    private static let ignoreReadings: [(files: [String: String], search: (operand: String, read: Bool))] = [
        ([".gitignore": "*.swift\n", "sub/.gitignore": "!Keep.swift\n", "sub/Keep.swift": match], (".", true)),
        ([".gitignore": "*.swift\n", "sub/.gitignore": "!/Keep.swift\n", "sub/Keep.swift": match], (".", true)),
        ([".gitignore": "*.swift\n", "sub/.gitignore": "!/Keep.swift\n", "sub/Keep.swift": match], ("sub", true)),
        (["sub/.gitignore": "*.swift\n!/Keep.swift\n", "sub/Keep.swift": match], ("sub", true)),
        ([".gitignore": "*.swift\n", "sub/.gitignore": "!gen/Keep.swift\n", "sub/gen/Keep.swift": match], (".", false)),
        (["sub/.gitignore": "*.swift\n!gen/Keep.swift\n", "sub/gen/Keep.swift": match], ("sub", false)),
        ([".gitignore": "gen/*\n!gen/Keep.swift\n", "gen/Keep.swift": match], (".", true)),
        ([".gitignore": "*\n!*/\n!Keep.swift\n", "sub/Keep.swift": match], (".", true)),
        ([".gitignore": "*.swift\n!Keep.swift   \n", "Keep.swift": match], (".", true)),
        ([".gitignore": "**/gen/**\n!**/gen/Keep.swift\n", "a/gen/Keep.swift": match], (".", true)),
        ([".gitignore": "/*.swift\n!/Keep.swift\n", "Keep.swift": match], (".", true)),
        ([".gitignore": "*.swift\n", "sub/.gitignore": "\u{FEFF}!Keep.swift\n", "sub/Keep.swift": match], (".", true)),
        (["sub/.gitignore": "sub/Keep.swift\n", "sub/Keep.swift": match], (".", false)),
        (["sub/.gitignore": "**/sub/Keep.swift\n", "sub/Keep.swift": match], (".", false)),
        ([".gitignore": "Other.swift \r\nOther.swift\r", "Keep.swift": match], (".", true)),
        ([".gitignore": "Keep.swift\r \n", "Keep.swift": match], (".", false)),
        ([".gitignore": "Keep.swift\r\r\n", "Keep.swift": match], (".", false)),
        ([".gitignore": "Keep.swift\r\r\r\n", "Keep.swift": match], (".", false)),
        ([".gitignore": "Keep.swift \r \n", "Keep.swift": match], (".", false)),
        ([".gitignore": "Keep.swift\r ", "Keep.swift": match], (".", false)),
        (["sub/.gitignore": "Keep.swift\r \n", "sub/Keep.swift": match], (".", false)),
        ([".gitignore": "?eep.swift\n", "\u{03A9}eep.swift": match], (".", false)),
        ([".gitignore": "*.swift\n!??eep.swift\n", "\u{03A9}eep.swift": match], (".", false)),
        ([".gitignore": "*.swift\n!???eep.swift\n", "\u{20AC}eep.swift": match], (".", false)),
        ([".gitignore": "??.swift\n", "e\u{0301}.swift": match], (".", false)),
        ([".gitignore": "?/\n", "\u{03A9}/Keep.swift": match], (".", false)),
        ([".gitignore": "*.swift\n!e*.swift\n", "e\u{0301}.swift": match], (".", true)),
        ([".gitignore": "*.swift\r\n!Keep.swift\r\n", "Keep.swift": match], (".", true)),
        ([".gitignore": "*.swift\r\n!Keep.swift\r", "Keep.swift": match], (".", true)),
        ([".gitignore": "*.swift\n", "sub/.gitignore": "# kept\r\n\r\n!Keep.swift\r\n", "sub/Keep.swift": match], (".", true)),
        ([".gitignore": "Keep.swift\n", "sub/.gitignore": "Other.swift\n", "sub/Keep.swift": match], ("sub", true)),
        ([".gitignore": "sub/deep/\n", "sub/deep/.gitignore": "Other.swift\n", "sub/deep/Keep.swift": match], ("sub/deep", true)),
        (["a/.gitignore": "*.swift\n", "a/b/.gitignore": "!Keep.swift\r\n", "a/b/Keep.swift": match], ("a/b", true)),
        ([".gitignore": "Gen?.swift\n[Gg]en.swift\n", "Keep.swift": match, "Gen\u{03A9}.swift": "let Other = 1\n"], (".", true)),
        ([".gitignore": "*.swift\n![J-L]ee?.swift\n", "sub/Keep.swift": match], (".", true)),
        ([".gitignore": ":Keep.swift\n", ":Keep.swift": match], (".", false)),
        ([".gitignore": ":Keep.swift\n", "Other.swift": match], (".", true)),
    ]

    /// A search whose only match is in a file git reads is answered exactly where `ugrep` reads that file too, however the `.gitignore` files on its path keep it.
    @Test(arguments: ignoreReadings)
    func aKeptFileIsAnsweredOnlyWhereUgrepReadsIt(files: [String: String], search: (operand: String, read: Bool)) throws {
        let repo = try Self.repository(files)
        let kept = try #require(files.first { $0.value == Self.match }?.key)

        if search.read {
            #expect(try Self.lines(Self.run(["-rn", "Depot", search.operand], in: repo), in: repo) == ["\(kept):1"])
        } else {
            #expect(try Self.run(["-rn", "Depot", search.operand], in: repo) == .undecided("ignored"))
        }
    }

    /// Each ignore-rule reading recorded above, re-checked against `ugrep` run as the shell function runs it: the files it prints for a recursive search.
    @Test(.enabled(if: SystemGrep.installedUgrep != nil, "no ugrep on this machine"))
    func theRecordedIgnoreReadingStillHolds() throws {
        let ugrep = try #require(SystemGrep.installedUgrep)
        let allowlist = try Self.repository([".gitignore": "*\n!Keep.swift\n", "Keep.swift": "let Depot = 1\n", "Other.swift": "let Depot = 2\n"])
        let folded = try Self.repository([".gitignore": "gen.swift\n", "Sources/Gen.swift": "let Depot = 1\n"], ignoreCase: true)
        let foldedNegation = try Self.repository([".gitignore": "*.swift\n!keep.swift\n", "Keep.swift": "let Depot = 1\n"], ignoreCase: true)
        let posixClass = try Self.repository([".gitignore": "*.swift\n!K[[:alpha:]]ep.swift\n", "Sources/Keep.swift": "let Depot = 1\n"])
        let tripleStar = try Self.repository([".gitignore": "*.swift\n!Sources/***\n", "Sources/Keep.swift": "let Depot = 1\n"])

        #expect(try ugrep.files("Depot", under: ".", in: allowlist) == ["Keep.swift"])
        #expect(try SystemGrep.system(locale: "C").files("Depot", under: ".", in: allowlist) == ["Keep.swift", "Other.swift"])
        #expect(try ugrep.files("Depot", under: ".", in: folded) == ["Sources/Gen.swift"])
        #expect(try ugrep.files("Depot", under: ".", in: foldedNegation).isEmpty)
        #expect(try ugrep.files("Depot", under: ".", in: posixClass).isEmpty)
        #expect(try ugrep.files("Depot", under: ".", in: tripleStar).isEmpty)
        for (files, search) in Self.ignoreReadings {
            let repo = try Self.repository(files)
            let kept = files.filter { $0.value == Self.match }.map(\.key)
            #expect(try ugrep.files("Depot", under: search.operand, in: repo) == (search.read ? Set(kept) : []), "\(files) from \(search.operand)")
        }
    }

    /// One `.gitignore` line holding a `?` or a bracket, one file beside it, whether `ugrep` reads that file, and whether the model decides it rather than refusing.
    ///
    /// Measured against `ugrep` 7.8.4 and git's `check-ignore`: a `?` and a class of letters, digits, `.` and `_`, negated or not, with ranges within one case or the digits, read alike over an ASCII name; a `?` or a negated class takes one byte for git and one character for `ugrep` over a name that is not ASCII; and a `]` opening a class, a backslash inside one, a `-` after a range, a `[` never closed, a POSIX class and a character that is not ASCII in the line are each read apart, in one direction or the other. A range across cases and an escape outside a class read alike on every name measured, and are refused all the same.
    private static let wildcardReadings: [(ignore: (line: String, file: String), verdict: (read: Bool, decided: Bool))] = [
        (("Gen?.swift", "Gen1.swift"), (false, true)),
        (("Gen?.swift", "Keep.swift"), (true, true)),
        (("?eep.swift", ".eep.swift"), (false, true)),
        (("Gen?/", "Gen1/Keep.swift"), (false, true)),
        (("[Gg]en.swift", "Gen.swift"), (false, true)),
        (("[Gg]en.swift", "\u{03A9}en.swift"), (true, true)),
        (("[!a]gen.swift", "bgen.swift"), (false, true)),
        (("[^a]gen.swift", "agen.swift"), (true, true)),
        (("[a-c]gen.swift", "cgen.swift"), (false, true)),
        (("[a-c]gen.swift", "dgen.swift"), (true, true)),
        (("[A-Za-z]gen.swift", "Zgen.swift"), (false, true)),
        (("Gen[0-9].swift", "Gen1.swift"), (false, true)),
        (("[.K_]eep.swift", "_eep.swift"), (false, true)),
        (("*.swift\n!Kee?.swift", "Keep.swift"), (true, true)),
        (("*.swift\n![J-L]eep.swift", "Keep.swift"), (true, true)),
        (("*.swift\n![!a]eep.swift", "aeep.swift"), (false, true)),
        (("Gen?.swift", "Gen\u{03A9}.swift"), (false, false)),
        (("Gen?/", "Gen\u{03A9}/Keep.swift"), (false, false)),
        (("??en.swift", "\u{03A9}en.swift"), (true, false)),
        (("[!G]en.swift", "\u{03A9}en.swift"), (false, false)),
        (("*.swift\n![!a]eep.swift", "\u{03A9}eep.swift"), (true, false)),
        (("[\u{03A9}G]en.swift", "\u{03A9}en.swift"), (false, false)),
        (("[]x]", "x"), (true, false)),
        (("[]]gen.swift", "]gen.swift"), (true, false)),
        (("[!]]gen.swift", "agen.swift"), (true, false)),
        (("[!]gen.swift", "agen.swift"), (false, false)),
        ((#"[\]]gen.swift"#, "]gen.swift"), (true, false)),
        ((#"[\a]gen.swift"#, #"\gen.swift"#), (false, false)),
        (("[a-c-e]gen.swift", "dgen.swift"), (false, false)),
        (("[a-c-e]gen.swift", "-gen.swift"), (true, false)),
        (("[a", "a/Keep.swift"), (false, false)),
        (("[[:alpha:]]gen.swift", "agen.swift"), (true, false)),
        (("[A-z]gen.swift", "_gen.swift"), (false, true)),
        (("[0-z]gen.swift", "_gen.swift"), (false, true)),
        ((#"Gen\?.swift"#, "Gen?.swift"), (false, true)),
        ((#"G[\?]n.swift"#, #"G\n.swift"#), (false, false)),
        ((#"G[!\?]n.swift"#, #"G\n.swift"#), (true, false)),
        (("**gen.swift", "gen.swift"), (true, true)),
        (("G?**.swift", "Gizmo.swift"), (true, true)),
        (("a/**b.swift", "a/xb.swift"), (true, true)),
        (("a?**/f.swift", "ab/c/f.swift"), (false, false)),
        (("a[b]**/f.swift", "ab/c/f.swift"), (false, false)),
        (("a/?**/f.swift", "a/b/c/f.swift"), (false, false)),
        (("ab**/f.swift", "ab/c/f.swift"), (false, false)),
        (("a/**/f.swift", "a/b/c/f.swift"), (false, true)),
    ]

    /// A `.gitignore` line holding a `?` or a bracket is decided exactly as `ugrep` reads it wherever git and `ugrep` read it alike, and refused, never decided, wherever they part.
    @Test(arguments: wildcardReadings)
    func aWildcardIsDecidedOnlyWhereGitAndUgrepReadItAlike(ignore: (line: String, file: String), verdict: (read: Bool, decided: Bool)) throws {
        let root = try Self.directory([".gitignore": ignore.line + "\n", ignore.file: Self.match])

        let decision = UgrepSkips.readsOne(of: [root.appendingPathComponent(ignore.file).path], under: root.path, spelled: ".")

        #expect(decision == (verdict.decided ? verdict.read : nil))
    }

    /// Each wildcard reading recorded above, re-checked against `ugrep` run as the shell function runs it: whether it reads the one file.
    @Test(.enabled(if: SystemGrep.installedUgrep != nil, "no ugrep on this machine"))
    func theRecordedWildcardReadingStillHolds() throws {
        let ugrep = try #require(SystemGrep.installedUgrep)
        for (ignore, verdict) in Self.wildcardReadings {
            let root = try Self.directory([".gitignore": ignore.line + "\n", ignore.file: Self.match])
            #expect(try ugrep.files("Depot", under: ".", in: root) == (verdict.read ? [ignore.file] : []), "\(ignore.line) over \(ignore.file)")
        }
    }

    /// A recursive search given no path is the search of the working directory, read as the operand `.` is and printing the lines the system grep prints there.
    @Test func aRecursiveSearchWithNoPathIsTheWorkingDirectorysSearch() throws {
        let repo = try Self.repository(Self.noPathTree)
        let modelled = try Self.lines(Self.run(["-rn", "Depot"], in: repo), in: repo)

        #expect(modelled.sorted() == ["Other/Keep.swift:1", "Sources/Gen.swift:1", "Sources/Main.swift:1"])
        #expect(try modelled == Self.lines(Self.run(["-rn", "Depot", "."], in: repo), in: repo))
        #expect(try Set(modelled) == SystemGrep.system(locale: "C").printed(["-rn", "Depot"], in: repo))
    }

    /// `ugrep`, given no path and an empty standard input, prints what it prints for `.`, the ignore rules the working directory holds applied.
    ///
    /// It reads its standard input as well as the tree, so the two agree only because nothing is written to that input, as nothing is by the Bash tool to a pipeline's first stage, the one stage ever answered.
    @Test(.enabled(if: SystemGrep.installedUgrep != nil, "no ugrep on this machine"))
    func theRecordedNoPathReadingStillHolds() throws {
        let ugrep = try #require(SystemGrep.installedUgrep)
        let repo = try Self.repository(Self.noPathTree)

        #expect(try ugrep.printed(["-rn", "Depot"], in: repo) == ["Other/Keep.swift:1", "Sources/Main.swift:1"])
        #expect(try ugrep.printed(["-rn", "Depot"], in: repo) == ugrep.printed(["-rn", "Depot", "."], in: repo))
        #expect(try ugrep.printed(["-Rn", "Depot"], in: repo) == ugrep.printed(["-rn", "Depot", "."], in: repo))
    }

    /// A tree whose one ignored file holds a match beside two that every grep reads.
    private static let noPathTree = [
        ".gitignore": "Gen.swift\n", "Sources/Gen.swift": "let Depot = 1\n", "Sources/Main.swift": "let Depot = 2\n",
        "Other/Keep.swift": "let Depot = 3\n",
    ]

    /// A directory holding `files`, removed with the test case's scope.
    private static func directory(_ files: [String: String]) throws -> URL {
        let root = try TemporaryDirectory.make("ugrep-model").appendingPathComponent("tree")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    /// A git repository holding `files`, every one of them tracked, ignored ones included, with `core.ignorecase` set to the case flag where one is given.
    private static func repository(_ files: [String: String], ignoreCase: Bool? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        let root = try directory(files)
        let configuring = ignoreCase.map { [["config", "core.ignorecase", "\($0)"]] } ?? []
        for arguments in [["init", "-q", "."]] + configuring + [["add", "-f", "."]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = root
            process.environment = ProcessEnvironment.withoutGit()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0, sourceLocation: sourceLocation)
        }
        return root
    }

    private static func run(_ arguments: [String], in root: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> ShellGrep.Outcome {
        try #require(ShellGrep(arguments: arguments), sourceLocation: sourceLocation).run(in: root.path)
    }

    /// Each printed line as `path:line`, the path relative to `root`, however the walk spelled the directories above it.
    private static func lines(_ outcome: ShellGrep.Outcome, in root: URL) -> [String] {
        guard case let .printed(lines) = outcome else { return [] }
        let marker = "/\(root.lastPathComponent)/"
        return lines.map { "\($0.file.components(separatedBy: marker).last ?? $0.file):\($0.line)" }
    }
}
