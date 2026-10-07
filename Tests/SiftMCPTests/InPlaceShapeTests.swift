//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// The shapes the advice hook may answer in place, and everything it still refuses: only a command that maps onto one call with nothing guessed — and a shape is only a candidate, answered where the search it makes is proven to print nothing the answer leaves out.
@Suite(.temporaryDirectories)
struct InPlaceShapeTests {
    private static func call(_ command: String, in directory: String = "/repo") -> InPlaceCall? {
        InPlaceShape.match(forShell: command, in: directory)?.call
    }

    /// What kind of call a command maps to, and the file or name it is about.
    private static func kind(_ command: String, in directory: String = "/repo") -> String? {
        switch call(command, in: directory) {
        case let .fileDigest(path, _)?: "digest \(path)"
        case let .documentOutline(path)?: "outline \(path)"
        case let .declarations(file, _)?: "declarations \(file)"
        case let .members(search)?: "members \(search.paths.joined(separator: " "))"
        case let .references(name, _)?: "references \(name)"
        case let .symbols(names, _, _, _, _)?: "symbols \(names.joined(separator: " "))"
        case .memberRange?: "member range"
        case nil: nil
        }
    }

    /// A grep of one file for its declarations is a candidate for that file's digest.
    @Test(arguments: [
        #"grep -n 'static\|case ' Sources/App/Alpha.swift"#,
        #"grep -n "static func record\|static func detail\|private static func" Sources/App/Alpha.swift"#,
        "grep -n '@Test func' Sources/App/Alpha.swift",
        "grep -nE '^\\s*(public|private) func' Sources/App/Alpha.swift",
        "grep -n 'struct Inner' Sources/App/Alpha.swift",
        "grep -n 'import' Sources/App/Alpha.swift | head -5",
        "grep -n 'init(' Sources/App/Alpha.swift 2>/dev/null",
    ])
    func aFilesDeclarationsAreACandidateForItsDigest(command: String) {
        #expect(Self.kind(command) == "declarations Sources/App/Alpha.swift")
    }

    /// A whole read of one file is its digest.
    @Test(arguments: ["cat Sources/App/Alpha.swift", "cat -n Sources/App/Alpha.swift"])
    func aWholeReadIsTheFilesDigest(command: String) {
        #expect(Self.kind(command) == "digest Sources/App/Alpha.swift")
        #expect(InPlaceShape.call(forRead: "/repo/Sources/App/Alpha.swift") == .fileDigest(path: "/repo/Sources/App/Alpha.swift"))
    }

    /// A whole read of a Markdown document is that document's heading outline — the offer's own answer, under a back-off shape of its own, so a document never switches off the in-place answers of the Swift reads beside it.
    @Test
    func aWholeReadOfAMarkdownDocumentIsItsOutline() {
        #expect(InPlaceShape.call(forRead: "/repo/Docs/Design.md") == .documentOutline(path: "/repo/Docs/Design.md"))
        #expect(InPlaceShape.call(forRead: "/repo/Docs/DESIGN.MD") == .documentOutline(path: "/repo/Docs/DESIGN.MD"))
        #expect(InPlaceShape.match(forRead: "/repo/Docs/Design.md", in: "/repo")?.call == .documentOutline(path: "/repo/Docs/Design.md"))
        #expect(InPlaceShape.match(forRead: "/repo/Docs/Design.md", in: "/repo")?.isWholeCommand == true)
        #expect(InPlaceCall.documentOutline(path: "x").shape == .outline)
        #expect(InPlaceCall.Shape.outline.needsIndexStore == false)
        #expect(InPlaceShape.call(forRead: "/repo/Docs/notes.txt") == nil)
    }

    /// A grep of one file for a member's declaration is a candidate for the source of every member it matches — whatever type holds it, so no longer only the type the file is named for.
    @Test(arguments: [
        "grep -n 'func go' Sources/App/Alpha.swift",
        "grep -n \"func go\" -A 12 Sources/App/Alpha.swift",
        "grep -n 'static let go' -A4 Sources/App/Alpha.swift | head -20",
        "grep -n 'case go' Sources/App/Alpha.swift",
        "grep -in 'func go' Sources/App/Alpha.swift",
        "grep -n 'var body' Sources/App/Alpha+Extras.swift",
        "grep -n 'func go' Sources/App/Alpha.swift Sources/App/Beta.swift",
        "grep -rn 'func go' -A 3 Sources/App/Alpha*.swift | head -20",
        "grep -rn 'func go' Sources/App/Alpha.swift",
    ])
    func aMembersDeclarationIsACandidateForItsSource(command: String) {
        #expect(Self.kind(command)?.hasPrefix("members Sources/App/Alpha") == true)
    }

    /// A word-anchored sweep for one name is a candidate for `where --refs` of it.
    @Test(arguments: [
        #"grep -rn '\bdepot\b' Sources"#,
        #"grep -rn '\<depot\>' Sources Tests --include=*.swift"#,
        "grep -rnw depot Sources",
        "grep -rn --word-regexp depot .",
        #"grep -rn '\bdepot\b' Sources 2>/dev/null | head -40"#,
    ])
    func aWordAnchoredSweepIsACandidateForReferences(command: String) {
        #expect(Self.kind(command) == "references depot")
    }

    /// A whole-line search (`-x`) prints only a line that is the name alone, which a declaration site almost never is, so it is never answered — even combined with `-w`, or with a pattern already anchored to a whole word, which alone would be a candidate for references.
    @Test(arguments: [
        "grep -rnwx Gadget Sources",
        "grep -rn -w -x Gizmo Sources",
        "grep -rnw --line-regexp Gizmo Sources",
        #"grep -rnx '\bdepot\b' Sources"#,
        #"grep -rnx '\<Depot\>' Sources"#,
    ])
    func aWholeLineSweepCombinedWithWordAnchoringIsNeverAnswered(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: "/repo") == nil)
    }

    /// A glob written in quotes reaches the search as the literal path it spells, since no shell expanded it — including a bracket class, which is as much a glob to the search's own bound as `*` or `?` are, even though ``SwiftSourcePath/isGlob(_:)`` leaves brackets out for the different question of what one file to digest is.
    @Test(arguments: [
        "grep -n Gizmo 'Sources/App/[UV]ses.swift'",
        "grep -n Gizmo 'Sources/[B]rk/Bin.swift'",
        "grep -rn Gizmo 'Sources/[B]rk'",
    ])
    func aQuotedBracketPathIsNeverAnsweredAsAGlobOrALiteralFile(command: String) {
        #expect(Self.call(command) == nil)
    }

    /// The search a candidate carries is the command's own: its flags, and the cut its `head` or `tail` makes.
    @Test
    func theSearchCarriesTheFlagsAndTheCut() {
        guard case let .members(tail)? = Self.call("grep -n 'func save' Sources/App/Store.swift | tail -1"),
              case let .members(context)? = Self.call("grep -n -A 3 'func save' Sources/App/Store.swift"),
              case let .declarations(_, head)? = Self.call("grep -n 'static' Sources/App/Store.swift | head -n 5")
        else {
            Issue.record("expected three candidates")
            return
        }

        #expect(tail.cut == .tail(1))
        #expect(context.after == 3)
        #expect(head.cut == .head(5))
    }

    /// A leading `cd` into a named directory moves where the lookup's paths resolve, and nothing else.
    @Test
    func aLeadingChangeOfDirectoryResolvesThePaths() throws {
        let root = try TemporaryDirectory.make("cd-repo")
        let elsewhere = try TemporaryDirectory.make("cd-elsewhere")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Kit"), withIntermediateDirectories: true)

        let moved = InPlaceShape.match(forShell: "cd Kit && grep -n 'func go' Sources/App/Alpha.swift", in: root.path)

        #expect(Self.kind("cd Kit && grep -n 'func go' Sources/App/Alpha.swift", in: root.path) == "members Sources/App/Alpha.swift")
        #expect(moved?.directory == root.appendingPathComponent("Kit").path)
        #expect(InPlaceShape.match(forShell: "cd \(elsewhere.path); grep -rnw Alpha Sources", in: root.path)?.directory == elsewhere.path)
        #expect(InPlaceShape.match(forShell: "cd \"$DIR\" && grep -rnw Alpha Sources", in: root.path) == nil)
    }

    /// A `cd` opening on a `~` the shell quotes or escapes never expands it, so the real `cd` moves somewhere the lookups that follow never read; the line is refused rather than answered as though it had reached home.
    @Test(arguments: [
        "cd \"~/Sources\" && cat Sources/App/Alpha.swift",
        "cd '~/Sources' && cat Sources/App/Alpha.swift",
        "cd \\~/Sources && cat Sources/App/Alpha.swift",
    ])
    func aQuotedOrEscapedTildeChangeOfDirectoryIsRefused(command: String) throws {
        // A directory spelled `~/Sources` really is there, so only the quoted `~` refuses the line.
        let root = try TemporaryDirectory.make("tilde")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("~/Sources"), withIntermediateDirectories: true)

        #expect(Self.call(command, in: root.path) == nil)
    }

    /// A `cd` into an unquoted `~` is still read as the home directory, unchanged.
    @Test
    func anUnquotedTildeChangeOfDirectoryIsUnchanged() {
        let expected = ("~" as NSString).expandingTildeInPath

        let moved = InPlaceShape.match(forShell: "cd ~ && cat Sources/App/Alpha.swift", in: "/repo")

        #expect(moved?.directory == expected)
    }

    /// A lookup that is one statement of a command is still answered, and says it answered the lookup rather than the command.
    ///
    /// The command is denied whatever happens here, so the comparison is between an answer and a refusal carrying nothing — never between an answer and the command's own output.
    @Test(arguments: [
        "echo start; grep -n 'func go' Sources/App/Alpha.swift",
        "ls Sources/App | head; grep -n 'func go' Sources/App/Alpha.swift",
        "sed -n '1,40p' Docs/Design.md ; echo --- ; grep -n 'func go' Sources/App/Alpha.swift",
        "swift build && grep -n 'func go' Sources/App/Alpha.swift",
        "grep -n 'func go' Sources/App/Alpha.swift; echo done",
    ])
    func aLookupBesideOtherStatementsIsAnsweredForTheLookup(command: String) {
        #expect(Self.kind(command) == "members Sources/App/Alpha.swift")
        #expect(InPlaceShape.match(forShell: command, in: "/repo")?.isWholeCommand == false)
    }

    /// A lookup that is the whole command says so, which is what keeps the two openings apart.
    @Test
    func aLookupThatIsTheWholeCommandSaysSo() {
        #expect(InPlaceShape.match(forShell: "grep -n 'func go' Sources/App/Alpha.swift", in: "/repo")?.isWholeCommand == true)
        #expect(InPlaceShape.match(forRead: "/repo/Sources/App/Alpha.swift", in: "/repo")?.isWholeCommand == true)
    }

    /// Two statements the hook could answer, and nothing else on the line, are one compound line answered whole, one call each in command order.
    @Test
    func twoLookupsInOneCommandAreAnsweredWhole() {
        let match = InPlaceShape.match(forShell: "grep -n 'func go' Sources/App/Alpha.swift; cat Sources/App/Beta.swift", in: "/repo")

        #expect(match?.calls.map(\.shape) == [.members, .read])
        #expect(match?.isWholeCommand == true)
    }

    /// A lookup reached over a joint that is not a sequence is a branch that might not have run, and is refused.
    @Test
    func aLookupBehindAConditionalJointIsRefused() {
        #expect(Self.call("test -f Sources/App/Alpha.swift || grep -n 'func go' Sources/App/Alpha.swift") == nil)
    }

    /// A lookup *in front of* a `||` always runs, so it is matched as though a fallback proven silent were not there at all — `true` and `:` both ignore their arguments and never print.
    @Test(arguments: [
        "grep -n 'func go' Sources/App/Alpha.swift || true",
        "grep -n 'func go' Sources/App/Alpha.swift || :",
    ])
    func aLookupInFrontOfASilentFallbackIsAnswered(command: String) {
        #expect(Self.kind(command) == "members Sources/App/Alpha.swift")
        #expect(InPlaceShape.match(forShell: command, in: "/repo")?.isWholeCommand == false)
    }

    /// A fallback that could print is not proven silent: if the lookup finds nothing, the real command would add a line the in-place answer never accounts for, so the match leaves the lookup's success for the answer to prove (``OrFallbackTests``).
    @Test
    func aLookupInFrontOfAPrintingFallbackLeavesItsSuccessToBeProven() {
        let match = InPlaceShape.match(forShell: "grep -n 'func go' Sources/App/Alpha.swift || echo none", in: "/repo")

        #expect(match?.fallbackFollows == true)
    }

    /// A directory move this cannot follow refuses the whole command, rather than being stepped over as though the lookup's paths still resolved where they were written.
    @Test(arguments: [
        "cd \"$DIR\" && grep -rnw Alpha Sources",
        "echo start; cd \"$DIR\"; grep -rnw Alpha Sources",
        "pushd Kit; grep -n 'func go' Sources/App/Alpha.swift",
    ])
    func aDirectoryMoveThatCannotBeFollowedIsRefused(command: String) {
        #expect(Self.call(command) == nil)
    }

    /// Everything that is not one of the shapes is refused as before, with its call named rather than run.
    @Test(arguments: [
        // A file listing asks which files mention the names, which is not the lines a `where` answer stands in for.
        #"grep -rln 'Alpha\|Beta' Sources"#,
        // A phrase of ordinary words names no symbol for a `where` to resolve.
        "grep -rn 'stale index' Sources",
        // A shape query is `search`'s question, never a `where`'s.
        "grep -rn '@Test func' Sources",
        // Context around a match is text a resolved answer does not carry.
        "grep -rn Alpha Sources -A 2",
        // A use of a name, not its declaration, and a phrase.
        "grep -n 'go' Sources/App/Alpha.swift",
        "grep -n 'stale index' Sources/App/Alpha.swift",
        // Flags that print something other than the matching lines, or several patterns.
        "grep -c 'func' Sources/App/Alpha.swift",
        "grep -v 'func' Sources/App/Alpha.swift",
        "grep -o 'func [a-z]*' Sources/App/Alpha.swift",
        "grep -e 'func go' Sources/App/Alpha.swift",
        "grep -rn '\\bdepot\\b' Sources -A 2",
        #"grep -n 'static\|case ' -A 3 Sources/App/Alpha.swift"#,
        // A declaration's form across several files or a glob but a member's, a manifest, another tool.
        #"grep -n 'static\|case ' Sources/App/Alpha.swift Sources/App/Beta.swift"#,
        "grep -hn 'func go' Sources/App/*.swift",
        "grep -n 'let package' Package.swift",
        "rg -n 'func go' Sources/App/Alpha.swift",
        // Anything more than the lookup inside its own statement: output to a file, a substitution, another stage.
        "grep -n 'func go' Sources/App/Alpha.swift > found.txt",
        "grep -n \"$(printf func) go\" Sources/App/Alpha.swift",
        "grep -n 'func go' Sources/App/Alpha.swift | sort",
        "grep -n 'func go' Sources/App/Alpha.swift | tail -n +3",
    ])
    func everythingElseIsRefusedAsBefore(command: String) {
        #expect(Self.call(command) == nil)
    }

    /// A line window on one Swift file is answered with that file's digest, as a whole read of it is, in every spelling the advisor reads as a window.
    @Test(arguments: [
        "sed -n '1,200p' Sources/App/Alpha.swift",
        "sed -n '140,170p;375,405p' Sources/App/Alpha.swift",
        "head -80 Sources/App/Alpha.swift",
        "tail -n 40 Sources/App/Alpha.swift",
        "awk 'NR>=10 && NR<=40' Sources/App/Alpha.swift",
        "cat Sources/App/Alpha.swift | head -20",
        "cat -n Sources/App/Alpha.swift | sed -n '1,140p'",
        "sed -n '10,40p' Sources/App/Alpha.swift | head -5",
        "sed -n '1,30p' Sources/App/Alpha.swift 2>/dev/null",
    ])
    func aWindowOnOneSwiftFileIsAnsweredWithItsDigest(command: String) {
        #expect(Self.call(command)?.readPath == "Sources/App/Alpha.swift")
    }

    /// Windows on two files are answered together, one digest each in command order, as two whole reads are.
    @Test
    func windowsOnTwoFilesAreAnsweredTogether() {
        let match = InPlaceShape.match(forShell: "sed -n '205,330p' Sources/App/Alpha.swift; sed -n '360,420p' Sources/App/Beta.swift", in: "/repo")

        #expect(match?.calls.map(\.readPath) == ["Sources/App/Alpha.swift", "Sources/App/Beta.swift"])
    }

    /// Several windows of one file are one lookup per window, answered with that file's one digest, however the range is spelled and whichever joint sequences them.
    @Test(arguments: [
        "sed -n 18,118p Sources/App/Alpha.swift; sed -n 212,250p Sources/App/Alpha.swift; sed -n 498,509p Sources/App/Alpha.swift",
        "sed -n '18,118p' Sources/App/Alpha.swift && sed -n '212,250p' Sources/App/Alpha.swift",
        "sed -n '18,118p' Sources/App/Alpha.swift\nhead -40 Sources/App/Alpha.swift",
    ])
    func windowsOfOneFileAreOneDigest(command: String) {
        let match = InPlaceShape.match(forShell: command, in: "/repo")

        #expect(match?.calls.map(\.readPath) == ["Sources/App/Alpha.swift"])
        #expect(match?.isWholeCommand == true)
    }

    /// Windows of two files are one digest per file in the order first named, whichever joint sequences them.
    @Test(arguments: [
        "sed -n 120,160p Sources/App/Alpha.swift; sed -n 1,60p Sources/App/Beta.swift; sed -n 90,99p Sources/App/Beta.swift",
        "sed -n 30,65p Sources/App/Alpha.swift && sed -n 1,90p Sources/App/Beta.swift && sed -n 150,183p Sources/App/Beta.swift",
        "sed -n '30,65p' Sources/App/Alpha.swift\nsed -n '1,90p' Sources/App/Beta.swift\nsed -n '1,9p' Sources/App/Alpha.swift",
    ])
    func windowsOfTwoFilesAreOneDigestEach(command: String) {
        let match = InPlaceShape.match(forShell: command, in: "/repo")

        #expect(match?.calls.map(\.readPath) == ["Sources/App/Alpha.swift", "Sources/App/Beta.swift"])
    }

    /// A window beside a search is a compound line, not a line of windows, and a window whose lines a filter picks from is the search it looks like, matched as before.
    @Test
    func aWindowBesideASearchIsUnchanged() {
        let beside = InPlaceShape.match(forShell: "sed -n '1,20p' Sources/App/Alpha.swift; grep -n 'func go' Sources/App/Beta.swift", in: "/repo")
        let filtered = InPlaceShape.match(forShell: "sed -n '1,20p' Sources/App/Alpha.swift && sed -n '1,20p' Sources/App/Beta.swift | grep -n go", in: "/repo")

        #expect(beside?.calls.map(\.shape) == [.read, .members])
        #expect(beside?.isWholeCommand == true)
        #expect(filtered?.calls.map(\.readPath) == ["Sources/App/Alpha.swift"])
        #expect(filtered?.isWholeCommand == false)
        #expect(InPlaceShape.match(forShell: "sed -n '1,20p' Sources/App/Alpha.swift; cat Sources/App/Alpha.swift", in: "/repo") == nil)
    }

    /// A window is answered only where the statement is the window alone, printing to the terminal: one written to a file, one behind an assignment, one whose lines a filter picks from, or one of a document is not.
    @Test(arguments: [
        "sed -n '1,30p' Sources/App/Alpha.swift > part.txt",
        "LC_ALL=C sed -n '1,30p' Sources/App/Alpha.swift",
        "sed -n '1,30p' Sources/App/Alpha.swift | cut -c1-20",
        "sed -n '1,30p' Docs/Design.md",
    ])
    func aWindowThatIsNotTheStatementAloneIsNotAnswered(command: String) {
        #expect(Self.call(command) == nil)
    }

    /// A command with anything in front of its command word is not the lookup alone, and neither is an `--include` without a recursion.
    ///
    /// An environment assignment can change what the grep prints — the system grep honours `GREP_OPTIONS` — and a subshell what it runs in; an `--include` without `-r` searches no directory in some implementations and every one in others.
    @Test(arguments: [
        "GREP_OPTIONS=-v grep -n 'func save' Sources/App/Store.swift",
        "LC_ALL=C grep -rnw Alpha Sources",
        "GREP_COLOR=1 cat Sources/App/Alpha.swift",
        "grep -rnw Alpha Sources | POSIXLY_CORRECT=1 head -5",
        "cd Kit && GREP_OPTIONS=-v grep -n 'func go' Sources/App/Alpha.swift",
        "{ grep -n 'func go' Sources/App/Alpha.swift; }",
        "grep -nw --include=*.swift Alpha Sources",
        "grep -rni alpha Sources --include=*.swift",
    ])
    func aCommandWithAnythingInFrontOfItIsRefused(command: String) {
        #expect(Self.call(command) == nil)
    }

    /// An unanchored sweep for a name, and an alternation of names, are one plain `where` per name — the offer's own answer, given without a proof.
    ///
    /// Not case-folded: `-i` prints every casing's sites, and a `where` for the name as written lists one casing's.
    @Test(arguments: [
        ("grep -rn Alpha Sources", "symbols Alpha"),
        ("grep -rn Alpha .", "symbols Alpha"),
        ("grep -rn Alpha", "symbols Alpha"),
        (#"grep -rn 'Alpha\|Beta' Sources"#, "symbols Alpha Beta"),
        ("grep -rnE 'Alpha|Beta' Sources Tests", "symbols Alpha Beta"),
        ("grep -rn Alpha Sources 2>/dev/null | head -40", "symbols Alpha"),
    ])
    func anUnanchoredSweepForNamesIsOneWherePerName(command: String, expected: String) {
        #expect(Self.kind(command) == expected)
    }

    /// The word-anchored reading still comes first, because it is proven against what the grep prints where this one is not.
    @Test
    func anAnchoredSweepIsStillTheProvenReferencesShape() {
        #expect(Self.kind("grep -rnw Alpha Sources") == "references Alpha")
        #expect(Self.kind(#"grep -rn '\<Alpha\>' Sources"#) == "references Alpha")
    }

    /// A plain multi-line sequence of windows, with no compound opener, closer or keyword among its statements, keeps its answer.
    @Test
    func aPlainMultiLineSequenceOfWindowsIsStillAnswered() {
        let match = InPlaceShape.match(forShell: "sed -n '1,30p' Sources/App/Alpha.swift\nsed -n '40,60p' Sources/App/Beta.swift", in: "/repo")

        #expect(match?.calls.map(\.readPath) == ["Sources/App/Alpha.swift", "Sources/App/Beta.swift"])
    }

    /// A multi-line compound command is not a sequence of lookups: a window inside a `{`/`(` block, a `for`/`if`/`case` leg, or a function body is refused, whether its output is redirected, filtered, or never produced — and so is the one-line spelling of the same shape.
    @Test(arguments: [
        "{\ncat Sources/App/Alpha.swift\n} > out.txt",
        "(\ncat Sources/App/Alpha.swift\n) | grep foo",
        "{\nsed -n '1,30p' Sources/App/Alpha.swift\nsed -n '40,60p' Sources/App/Alpha.swift\n} | grep -n func",
        "for i in 1 2 3; do\n  sed -n '1,30p' Sources/App/Alpha.swift\ndone",
        "if [ -f x ]; then\n echo\nelse\n sed -n '1,30p' Sources/App/Alpha.swift\nfi",
        "show() {\n sed -n '1,30p' Sources/App/Alpha.swift\n}",
        "if true; then sed -n '1,30p' Sources/App/Alpha.swift; fi",
        "show() { sed -n '1,30p' Sources/App/Alpha.swift; }",
        "{ sed -n '1,30p' Sources/App/Alpha.swift; sed -n '40,60p' Sources/App/Alpha.swift; } > out.txt",
        "{ sed -n '1,30p' Sources/App/Alpha.swift; sed -n '40,60p' Sources/App/Alpha.swift; } | grep -n func",
    ])
    func aCompoundCommandIsNotASequenceOfLookups(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: "/repo") == nil)
    }

    /// A line ending in a pipe carries its pipeline on past the newline, blank lines and a comment included, so a search on the next line is a later stage handed what the pipe carries, and never answered.
    @Test(arguments: [
        "echo Alpha-stdin |\ngrep -rn Alpha",
        "cat notes.txt |\ngrep -rn Alpha",
        "echo x |\n\ngrep -rn Alpha",
        "echo x |  \n \n\tgrep -rn Alpha .",
        "echo x | # the names\ngrep -rn Alpha",
        "echo x |&\ngrep -rn Alpha",
        "echo x |& grep -rn Alpha",
    ])
    func aPipeEndingALineCarriesItsPipelineOn(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: "/repo") == nil)
        #expect(ShellSyntax.statements(of: command).count == 1)
    }

    /// A line ending in a sequencing operator reads as the one-line sequence does, and a pipe written as a literal ends nothing.
    @Test
    func aSequenceEndingALineReadsAsItsOneLineSpelling() {
        #expect(Self.kind("true &&\ngrep -rn Alpha .") == "symbols Alpha")
        #expect(Self.kind("true &&\ngrep -rn Alpha .") == Self.kind("true && grep -rn Alpha ."))
        #expect(Self.call("false ||\ngrep -rn Alpha .") == Self.call("false || grep -rn Alpha ."))
        #expect(Self.kind("echo x \\|\ngrep -rn Alpha .") == "symbols Alpha")
        #expect(Self.kind("grep -rn Alpha . |\nhead -40") == Self.kind("grep -rn Alpha . | head -40"))
    }
}
