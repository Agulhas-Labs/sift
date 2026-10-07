//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// `audit --replay` lists the calls behind each still-cold rule, collapsed by shape, and only the shapes unless unredacted.
@Suite(.temporaryDirectories)
struct ReplayColdShapesTests {
    /// Three `sed` windows over two files, a grep and two over-size reads, counted the way the replay loop counts them.
    private static func constructedReplay() -> ContextReplay {
        var context = ContextReplay()
        let calls: [(rule: String, call: ReplayColdCall)] = [
            ("noLookup", ReplayColdCall(text: "sed -n 95,135p Sources/Orchard/Alpha.swift")),
            ("noLookup", ReplayColdCall(text: "sed -n 1,30p Sources/Orchard/Beta.swift")),
            ("noLookup", ReplayColdCall(text: "sed -n 95,135p Sources/Orchard/Alpha.swift")),
            ("noLookup", ReplayColdCall(text: "grep -n Catalogue Sources/Orchard/Alpha.swift")),
            ("overSize", ReplayColdCall(text: "Read /work/Orchard/Sources/Gizmo.swift", answerBytes: 14321)),
            ("overSize", ReplayColdCall(text: "Read /work/Orchard/Sources/Depot.swift", answerBytes: 23456)),
        ]
        for (rule, call) in calls {
            context.count(.stillCold(rule), day: "2026-09-20", call: call)
        }
        return context
    }

    /// Unredacted, each still-cold rule lists its shapes with their collapsed counts and up to two real calls, commonest first.
    @Test func unredactedListsEachRulesCallsCollapsedByShape() {
        let section = TranscriptReplay.render([Self.constructedReplay()], unredacted: true)

        #expect(section.contains("         4  noLookup"), "\(section)")
        #expect(
            section.contains("             3  sed -n <range> <file> — e.g. `sed -n 95,135p Sources/Orchard/Alpha.swift` · `sed -n 1,30p Sources/Orchard/Beta.swift`"),
            "\(section)"
        )
        #expect(section.contains("             1  grep -n <pattern> <file> — e.g. `grep -n Catalogue Sources/Orchard/Alpha.swift`"), "\(section)")
        let ruleRow = section.firstIndex(of: "         4  noLookup")
        #expect(ruleRow.map { section[$0 + 1].contains("sed -n <range> <file>") } == true, "the commonest shape is listed first: \(section)")
    }

    /// Redacted, a shape is all that is printed: no path, file or symbol the calls named survives.
    @Test func redactedPrintsTheShapeAndNothingItNamed() {
        let section = TranscriptReplay.render([Self.constructedReplay()], unredacted: false)
        let text = section.joined(separator: "\n")

        #expect(section.contains("             3  sed -n <range> <file>"), "\(section)")
        #expect(section.contains("             1  grep -n <pattern> <file>"), "\(section)")
        #expect(section.contains { $0.hasPrefix("             2  Read <file> — answer 14321–23456 B over the 10000 B budget") }, "\(section)")
        for named in ["Orchard", "Alpha", "Beta", "Catalogue", "Gizmo", "Depot", "/work", "95,135p", "e.g."] {
            #expect(!text.contains(named), "\(named) leaked: \(text)")
        }
    }

    /// An over-size row names how big its answers came to against the budget, and how many stopped at the search's ceiling before an answer was built.
    @Test func anOverSizeRowNamesTheAnswerSizeAgainstTheBudget() {
        let calls: [ReplayColdCall: Int] = [
            ReplayColdCall(text: "Read /work/Gizmo.swift", answerBytes: 14321): 1,
            ReplayColdCall(text: "grep -rnw Depot Sources/", answerBytes: nil): 2,
        ]
        let lines = ReplayColdShapes.lines(calls, rule: "overSize", unredacted: false)

        #expect(lines.contains("             1  Read <file> — answer 14321 B over the 10000 B budget"), "\(lines)")
        #expect(lines.contains("             2  grep -rnw <pattern> <path> — 2 stopped at the search ceiling"), "\(lines)")
    }

    /// A rule with more than ten shapes lists the ten commonest and sums the rest on one line.
    @Test func shapesPastTheTenthAreSummedOnOneLine() {
        var calls: [ReplayColdCall: Int] = [:]
        for flags in ["-a", "-b", "-c", "-d", "-e", "-f", "-g", "-h", "-i", "-j", "-k", "-l"] {
            calls[ReplayColdCall(text: "grep \(flags) Depot Gizmo.swift")] = 1
        }
        calls[ReplayColdCall(text: "grep -z Depot Gizmo.swift")] = 5
        let lines = ReplayColdShapes.lines(calls, rule: "noLookup", unredacted: false)

        #expect(lines.count == 13, "\(lines)")
        #expect(lines.first == "             5  grep -z <pattern> <file>", "\(lines)")
        #expect(lines[10] == "             3  … 3 more shapes", "\(lines)")
        #expect(Array(lines.suffix(2)) == ["          by structure — all 17 calls, the listed shapes included:", "              17  1 statement · grep · one file"], "\(lines)")
    }

    /// Fourteen shapes of compound and single command lines, so the rule has a tail: 21 calls in all.
    private static let compoundCalls: [ReplayColdCall: Int] = [
        ReplayColdCall(text: "sed -n 1,5p Alpha.swift; grep -n Depot Alpha.swift"): 4,
        ReplayColdCall(text: "grep -n Depot Alpha.swift && sed -n 1,5p Alpha.swift"): 1,
        ReplayColdCall(text: "cat Sources/Alpha.swift | sed -n 1,5p"): 3,
        ReplayColdCall(text: "sed -n 1,5p Alpha.swift Beta.swift"): 2,
        ReplayColdCall(text: "cd Sources && grep -rn Depot ."): 2,
        ReplayColdCall(text: "sift digest Alpha.swift; sed -n 1,5p Alpha.swift"): 1,
        ReplayColdCall(text: "grep -c Depot Alpha.swift; grep -l Depot Beta.swift; wc -l Gizmo.swift"): 1,
        ReplayColdCall(text: "LC_ALL=C sort Alpha.swift"): 1,
        ReplayColdCall(text: "./tools/Depot.sh Alpha.swift"): 1,
        ReplayColdCall(text: "Read /work/Alpha.swift offset=5 limit=20"): 1,
        ReplayColdCall(text: "sed -n 1,5p Alpha.swift\nsed -n 9,12p Alpha.swift"): 1,
        ReplayColdCall(text: "for f in Alpha.swift Beta.swift; do sed -n 1p $f; done"): 1,
        ReplayColdCall(text: "grep -a Depot Alpha.swift"): 1,
        ReplayColdCall(text: "grep -b Depot Alpha.swift"): 1,
    ]

    /// A rule with a tail groups every one of its calls by structure after the summed line, commonest first, eight listed and the rest summed — and prints nothing any call named.
    @Test func aRuleWithATailGroupsEveryCallByStructure() {
        let lines = ReplayColdShapes.lines(Self.compoundCalls, rule: "notAnswerable", unredacted: false)

        let header = lines.firstIndex(of: "          by structure — all 21 calls, the listed shapes included:")
        #expect(header == 11, "ten shapes and the summed line come first: \(lines)")
        #expect(
            Array(lines.dropFirst(12)) == [
                "               5  2 statements · grep+sed · one file",
                "               3  1 statement · cat · one file · piped",
                "               3  1 statement · sed · several files",
                "               2  1 statement · grep · one file",
                "               2  2 statements · cd+grep · no file",
                "               1  1 statement · Read · one file",
                "               1  1 statement · other · one file",
                "               1  1 statement · sort · one file",
                "               3  … 3 more structures",
            ],
            "\(lines)"
        )
        let text = lines.joined(separator: "\n")
        for named in ["Alpha", "Beta", "Gizmo", "Depot", "Sources", "tools", "LC_ALL", "/work"] {
            #expect(!text.contains(named), "\(named) leaked: \(text)")
        }
    }

    /// The full list `--shapes` writes names every shape and every structure of every still-cold rule, summing none, and its shape counts add up to the rule's.
    @Test func theShapeListNamesEveryShapeOfEveryRule() {
        var context = ContextReplay()
        for (call, count) in Self.compoundCalls {
            context.count(.stillCold("notAnswerable"), day: "2026-09-20", call: call, by: count)
        }
        context.count(.stillCold("noLookup"), day: "2026-09-20", call: ReplayColdCall(text: "sed -n 95,135p Sources/Alpha.swift"))
        let shapeCount = Set(Self.compoundCalls.keys.map { TranscriptAudit.CallRedaction.shape(of: $0.text) }).count
        let structureCount = Set(Self.compoundCalls.keys.map { TranscriptAudit.CallRedaction.structure(of: $0.text) }).count

        let list = TranscriptReplay.shapeList([context])

        let start = list.firstIndex(of: "        21  notAnswerable")
        let end = list.firstIndex(of: "         1  noLookup")
        let rule = list[(start ?? 0) + 1 ..< (end ?? list.count)]
        let structureRows = rule.filter { $0.contains(" statement") }
        let shapeRows = rule.filter { !$0.contains(" statement") && !$0.contains("by structure") }
        #expect(shapeCount == 14 && structureCount == 11)
        #expect(shapeRows.count == shapeCount, "\(list)")
        #expect(structureRows.count == structureCount, "\(list)")
        let counts: [Int] = shapeRows.compactMap { row in row.split(separator: " ").first.flatMap { Int($0) } }
        #expect(counts.reduce(0, +) == 21, "\(list)")
        #expect(!list.contains { $0.contains("more shapes") || $0.contains("more structures") }, "\(list)")
        #expect(list.contains("             1  sed -n <range> <file>"), "a rule with one shape is listed too: \(list)")
    }

    /// `--shapes` needs `--replay`, and with it the replay writes the full list to the file named.
    @Test func theShapesFlagWritesTheListBesideTheReport() throws {
        #expect(throws: (any Error).self) { try AuditCommand.parse(["--shapes", "shapes.txt"]) }
        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        try Data().write(to: transcript)
        let file = try TemporaryDirectory.make("shapes").appendingPathComponent("shapes.txt")

        let report = try AuditCommand.replaySection(
            projectsDirectory: transcript.deletingLastPathComponent(),
            since: nil,
            transcript: transcript.path,
            shapesFile: file,
            scratch: TemporaryDirectory.make("replay")
        )

        #expect(report.contains { $0.hasPrefix("replay — ") }, "\(report)")
        #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix("still cold — every shape of every rule"))
    }

    /// A `--shapes` path whose directory doesn't exist is refused before the replay runs, naming the path.
    @Test func aShapesPathWithNoDirectoryIsRefused() {
        #expect {
            try AuditCommand.parse(["--replay", "--shapes", "/nonexistent193/x.txt"])
        } throws: { error in
            "\(error)".contains("/nonexistent193/x.txt")
        }
    }

    /// A rule whose shapes all fit is listed as before, with no grouping after it.
    @Test func aRuleWithNoTailIsNotGrouped() {
        let lines = ReplayColdShapes.lines([ReplayColdCall(text: "sed -n 1,5p Alpha.swift; grep -n Depot Alpha.swift"): 3], rule: "notAnswerable", unredacted: false)

        #expect(lines == ["             3  sed -n <range> <file> ; grep -n <pattern> <file>"], "\(lines)")
    }

    /// A still-cold lookup counted with no call behind it never reaches the grouping, so the header names how many are missing and the header count still equals the grouping's total plus that gap.
    @Test func aRuleWithACallLessEntryNamesTheGapInTheHeader() {
        var context = ContextReplay()
        context.count(.stillCold("notHooked"), day: "2026-09-20", call: ReplayColdCall(text: "sed -n 1,5p Alpha.swift"))
        context.count(.stillCold("notHooked"), day: "2026-09-20", call: ReplayColdCall(text: "sed -n 1,5p Alpha.swift"))
        context.count(.stillCold("notHooked"), day: "2026-09-20")

        let headerLine = "\(TranscriptAudit.pad(3))  notHooked (1 without a call to group)"
        let section = TranscriptReplay.render([context], unredacted: false)
        #expect(section.contains("      " + headerLine), "\(section)")
        let groupedLine = section.first { $0.contains("sed -n <range> <file>") }
        #expect(groupedLine == "             2  sed -n <range> <file>", "the grouping's own total (2) plus the gap (1) equals the header count (3): \(section)")

        let list = TranscriptReplay.shapeList([context])
        #expect(list.contains("      " + headerLine), "\(list)")
    }

    /// Two distinct compound shapes that agree for the first 110 characters print identically where the report clips, but `complete` — the form `--shapes` writes — prints each whole, shape and example alike.
    @Test func completeModePrintsALongShapeAndExampleUnclipped() {
        let prefix = "grep " + String(repeating: "-a ", count: 60)
        let calls: [ReplayColdCall: Int] = [
            ReplayColdCall(text: prefix + "Alpha.swift"): 1,
            ReplayColdCall(text: prefix + "-q Alpha.swift"): 1,
        ]

        let clipped = ReplayColdShapes.lines(calls, rule: "notAnswerable", unredacted: true)
        let clippedShapeLines = clipped.filter { $0.contains("grep") && !$0.contains("statement") }
        #expect(Set(clippedShapeLines).count == 1, "clipped, the two distinct shapes print identically: \(clipped)")

        let complete = ReplayColdShapes.lines(calls, rule: "notAnswerable", unredacted: true, complete: true)
        let completeShapeLines = complete.filter { $0.contains("grep") && !$0.contains("statement") }
        #expect(Set(completeShapeLines).count == 2, "\(complete)")
        #expect(completeShapeLines.allSatisfy { $0.count > ReplayColdShapes.width }, "a shape and its example print past the clip width: \(complete)")
    }

    /// A call's structure counts its statements, names the words opening them, counts the distinct files it names, and marks a pipe or a sift call.
    @Test(arguments: [
        ("sed -n 1,5p Alpha.swift; grep -n Depot Alpha.swift", "2 statements · grep+sed · one file"),
        ("sed -n 1,5p Alpha.swift\nsed -n 9,12p Alpha.swift", "2 statements · sed · one file"),
        ("cat Alpha.swift | sed -n 1,5p | head -3", "1 statement · cat · one file · piped"),
        ("grep -n Depot Alpha.swift 2>/dev/null || grep -n Depot Beta.swift", "2 statements · grep · several files"),
        ("( cd Sources && sift where Depot ) ; sed -n 1,5p Gizmo.swift", "3+ statements · cd+sed · one file · with sift"),
        ("git show HEAD:Sources/Alpha.swift | sed -n 1,5p", "1 statement · git · one file · piped"),
        ("Grep pattern=Depot path=Sources/Alpha.swift", "1 statement · Grep · one file"),
        ("grep -rn Depot Sources/", "1 statement · grep · no file"),
        ("grep -n self.view Alpha.swift", "1 statement · grep · one file"),
        ("Grep pattern=A.b path=X.swift", "1 statement · Grep · one file"),
        ("grep -rn Depot --include=*.swift Sources/", "1 statement · grep · no file"),
        ("Glob pattern=**/*.swift", "1 statement · Glob · no file"),
        ("python3 - <<EOF\nimport json\nprint(1)\nEOF", "1 statement · other · no file"),
        ("grep -n Foo $(git ls-files A.swift; echo B.swift)", "1 statement · grep · several files"),
        ("find . -name '*.swift' -exec grep -l Foo {} \\; -print", "1 statement · find · no file"),
        ("for f in Alpha.swift Beta.swift; do sed -n 1,5p \"$f\"; done", "1 statement · sed · several files"),
        ("for f in Sources/*.swift; do sed -n 1,5p \"$f\"; done", "1 statement · sed · no file"),
        ("time grep -n Foo Alpha.swift", "1 statement · grep · one file"),
        ("if grep -q Foo Alpha.swift; then echo found; fi", "2 statements · echo+grep · one file"),
        ("for f in *.swift; do grep -c Foo \"$f\"; done 2>/dev/null", "1 statement · grep · no file"),
        ("while read f; do grep -n Foo \"$f\"; done < list.txt", "2 statements · grep+other · no file"),
        ("if grep -q Foo Alpha.swift; then sed -n 1p Alpha.swift; fi > out.txt", "2 statements · grep+sed · one file"),
        ("until grep -q Foo Alpha.swift; do echo waiting; done", "2 statements · echo+grep · one file"),
        (
            "if grep -q Foo Alpha.swift; then echo found; elif grep -q Bar Beta.swift; then echo other; fi",
            "3+ statements · echo+grep · several files"
        ),
        (
            "case $x in a) grep Foo A.swift;; b) sed -n 1,5p B.swift;; esac",
            "2 statements · grep+sed · several files"
        ),
        ("select f in Alpha.swift Beta.swift; do sed -n 1,5p \"$f\"; done", "1 statement · sed · several files"),
        ("function f { grep -n Foo Alpha.swift; }", "1 statement · grep · one file"),
        ("f() { grep -n Foo Alpha.swift; }", "1 statement · grep · one file"),
        ("for ((i=0;i<3;i++)); do echo $i; done", "1 statement · echo · no file"),
        ("time -p grep -n Foo Alpha.swift", "1 statement · grep · one file"),
        ("command grep -n Foo Alpha.swift", "1 statement · grep · one file"),
        ("grep -n Foo `git ls-files A.swift; echo B.swift`", "1 statement · grep · several files"),
    ])
    func aCallsStructureIsReadOffItsWords(call: String, structure: String) {
        #expect(TranscriptAudit.CallRedaction.structure(of: call) == structure)
    }

    /// A shape keeps command words, flags and operators, spells digits in a flag and every operand by its kind, and collapses a run of like operands.
    @Test(arguments: [
        ("sed -n 95,135p Sources/Gizmo.swift", "sed -n <range> <file>"),
        ("sed -n '1,$p' Gizmo.swift | head -40", "sed -n <range> <file> | head -<n>"),
        ("grep -A3 -rn \"func depot\" Sources/ 2>/dev/null", "grep -A<n> -rn <pattern> <path> 2>/dev/null"),
        ("cd /work/Orchard && cat A.swift B.swift C.swift D.swift", "cd <path> && cat <file>×4"),
        ("Read /work/Gizmo.swift offset=95 limit=40", "Read <file> offset=<n> limit=<n>"),
        ("Grep pattern=Depot path=Sources/Orchard glob=*.swift", "Grep pattern=<pattern> path=<path> glob=<file>"),
        ("git show HEAD~1:Sources/Gizmo.swift", "git show HEAD~1:<file>"),
    ])
    func aShapeNamesKindsNotNames(call: String, shape: String) {
        #expect(TranscriptAudit.CallRedaction.shape(of: call) == shape)
    }

    /// A bare `<` redirection never collapses as a run of placeholders, even four of them in a row.
    @Test func aBareRedirectionNeverCollapsesAsAPlaceholder() {
        #expect(TranscriptAudit.CallRedaction.shape(of: "< < < < x") == "< < < < <text>")
    }

    /// A `sed`/`awk` address or script, and a `grep` pattern, read as `<pattern>` — never `<path>`, because a pattern happens to hold a `/`, nor `<text>`.
    @Test(arguments: [
        ("sed -n '/Foo/,/^}/p' Gizmo.swift", "sed -n <pattern> <file>"),
        ("awk '/Foo/'", "awk <pattern>"),
    ])
    func aPatternOperandReadsAsItsOwnKind(call: String, shape: String) {
        #expect(TranscriptAudit.CallRedaction.shape(of: call) == shape)
    }

    /// A pattern handed over by a flag reads `<pattern>` wherever it stands and leaves no bare operand to be one, a value-taking flag's value is a plain value, and a redirection is never the pattern.
    @Test(arguments: [
        ("grep -A 3 Widget F.swift", "grep -A <n> <pattern> <file>"),
        ("grep -e Widget -e Depot F.swift", "grep -e <pattern> -e <pattern> <file>"),
        ("grep -n F.swift -e Widget", "grep -n <file> -e <pattern>"),
        ("grep --regexp=Widget F.swift", "grep --regexp=<pattern> <file>"),
        ("grep -f Orchard.txt -f Depot.txt F.swift", "grep -f <pattern> -f <pattern> <file>"),
        ("sed -e 's/a/b/' -e 's/c/d/' F.swift", "sed -e <pattern> -e <pattern> <file>"),
        ("awk -v n=Widget '/Depot/' F.swift", "awk -v <text> <pattern> <file>"),
        ("grep 2>&1 Widget F.swift", "grep 2>&1 <pattern> <file>"),
        ("grep Widget F.swift | grep -e Depot", "grep <pattern> <file> | grep -e <pattern>"),
    ])
    func aFlagOrRedirectionNeverMislabelsThePattern(call: String, shape: String) {
        #expect(TranscriptAudit.CallRedaction.shape(of: call) == shape)
    }

    /// `awk`'s own `-F`/`-f`, macOS `sed -i`'s backup-suffix argument, a clustered flag whose last letter takes a value, `rg`'s own `-g`/`-t`/`--type` (a glob or a type filter, never the pattern), and a long form not yet in the tables, each read the kind their value actually is rather than falling through to `<pattern>` or a stray literal.
    ///
    /// `git`'s own `-C` takes its directory only right after `git` itself: right after its own subcommand it means detect copies and takes no word after it, so a real flag right there — `--oneline` — reads as itself rather than as `-C`'s value. `sed`'s own spaced `-i` takes the next word as a backup suffix only when that word could be one: a flag or a non-empty quoted script right after it means the GNU form instead, no suffix, and the word is read as usual — the script itself, or another flag. A `.`/`:` glued straight onto a command's own flag letter — `sed -i.bak`, `awk -F:` — is glued a value the same way a letter is, even though neither character survives a flag cluster on its own, so the flag is never lost to a stray placeholder either.
    @Test(arguments: [
        ("awk -F : '{print $1}' data.txt", "awk -F <text> <pattern> <file>"),
        ("awk -f script.awk '{print}' data.txt", "awk -f <file> <pattern> <file>"),
        ("awk -F: '{print $1}' F.swift", "awk -F<text> <pattern> <file>"),
        ("sed -i '' 's/foo/bar/' work/notes", "sed -i <text> <pattern> <path>"),
        ("sed -i 's/Depot/Yard/' Sources/App/Depot.swift", "sed -i <pattern> <file>"),
        ("sed -i -e 's/a/b/' F.swift", "sed -i -e <pattern> <file>"),
        ("sed -i.bak -e 's/a/b/' F.swift", "sed -i<file> -e <pattern> <file>"),
        ("grep -n F.swift -ie Widget", "grep -n <file> -ie <pattern>"),
        ("grep --max-count 5 Widget F.swift", "grep --max-count <n> <pattern> <file>"),
        ("grep --max-count=5 stock Sources", "grep --max-count=<n> <pattern> <text>"),
        ("grep -m 5 stock Sources", "grep -m <n> <pattern> <text>"),
        ("grep --context 3 Widget F.swift", "grep --context <n> <pattern> <file>"),
        ("rg -g '*.swift' stock Sources", "rg -g <file> <pattern> <text>"),
        ("rg -t swift stock", "rg -t <text> <pattern>"),
        ("rg --type swift stock", "rg --type <text> <pattern>"),
        ("sed --expression 's/a/b/' -e 's/c/d/' F.swift", "sed --expression <pattern> -e <pattern> <file>"),
        ("git log -C --oneline", "git log -C --oneline"),
    ])
    func aFlagsValueReadsItsOwnKind(call: String, shape: String) {
        #expect(TranscriptAudit.CallRedaction.shape(of: call) == shape)
    }

    /// A known tool's own subcommand verb survives right where one is expected — the allowlist is closed per tool, so an argument that happens to spell the same word elsewhere is still redacted.
    @Test(arguments: [
        ("swift build", "swift build"),
        ("swift run", "swift run"),
        ("sift digest Gizmo", "sift digest <text>"),
        ("git log", "git log"),
        ("gh issue view", "gh issue view"),
        ("xcodebuild test", "xcodebuild test"),
    ])
    func aKnownToolsSubcommandSurvives(call: String, shape: String) {
        #expect(TranscriptAudit.CallRedaction.shape(of: call) == shape)
    }

    /// A flag's own value, or the operand of a `gh` noun that takes no verb, never survives as a subcommand however it is spelled — the first flag closes the verb positions for a tool whose flags aren't tracked, and only a verb-taking noun opens the second; `git`'s own `-C` and `--git-dir` are tracked, so each takes its value and reopens the verb position right after.
    ///
    /// An unknown flag closes those positions too, and once closed stays closed: no later word — however it is spelled, even one on the redaction allowlist elsewhere — is read as the subcommand merely for standing where one would be expected.
    @Test(arguments: [
        ("git -C status log", "git -C <text> log"),
        ("git -C /work/Orchard status", "git -C <path> status"),
        ("git --git-dir X log", "git --git-dir <text> log"),
        ("git --unknown-flag X log", "git --<text> <text> <text>"),
        ("xcodebuild -scheme archive build", "xcodebuild -scheme <text> <text>"),
        ("gh browse status", "gh browse <text>"),
        ("gh api list", "gh api <text>"),
        ("gh issue view Widget", "gh issue view <text>"),
    ])
    func aFlagValueNeverSurvivesAsASubcommand(call: String, shape: String) {
        #expect(TranscriptAudit.CallRedaction.shape(of: call) == shape)
    }

    /// A value-taking flag's own value never survives merely for sitting on the redaction allowlist elsewhere — `git -C`'s directory reads its placeholder kind even when it happens to spell a git subcommand — and a value-less flag closes the subcommand positions exactly as an unknown one does, so a word after it that would have opened the second position reads by its own kind instead, even a word — like `log` — that is safe to print unredacted elsewhere.
    @Test(arguments: [
        ("git -C log status", "git -C <text> status"),
        ("git -p log", "git -p <text>"),
    ])
    func aFlagsValueIsNeverAllowlisted(call: String, shape: String) {
        #expect(TranscriptAudit.CallRedaction.shape(of: call) == shape)
    }

    /// The subcommand gate above is narrow: it only ever drops a safe word for a tool in ``TranscriptAudit/CallRedaction/subcommandsByTool`` once that tool's own subcommand position is already closed.
    ///
    /// A word that itself closes that position — `grep` is not one of `git`'s own subcommands — reads by base rules like any other command's token, and a tool with no subcommand table at all (`xargs`, `if`, a bare `` ` ``-opened command substitution) never gates its safe words on position either.
    @Test(arguments: [
        ("xargs grep -n foo F", "xargs grep -n <text> <text>"),
        ("if grep -q Foo A.swift; then echo found; fi", "if grep -q <text> <file> ; then echo <text> ; fi"),
        ("git grep -n X -- F", "git grep -n <text> -- <text>"),
        ("echo `sed -n '1,30p' F`", "echo ` sed -n <range> <text> `"),
    ])
    func aSafeWordSurvivesOutsideASubcommandPosition(call: String, shape: String) {
        #expect(TranscriptAudit.CallRedaction.shape(of: call) == shape)
    }

    /// A name glued straight onto a short flag — `-SSecretApp`, `-eSecretRepo`, `-Xswiftc` — never rides along in the shape, and every operand after a bare `--` is text too, whatever it looks like.
    @Test(arguments: [
        "git log -SSecretApp --oneline",
        "grep -eSecretRepo Sources",
        "swift build -Xswiftc -DSecretApp",
        "grep -n -- -SecretRepo A.swift",
    ])
    func aGluedFlagValueNeverLeaksThroughTheShape(call: String) {
        let shape = TranscriptAudit.CallRedaction.shape(of: call)

        #expect(!shape.lowercased().contains("secret"))
    }

    /// The replay loop hands each still-cold lookup's call to the section: windows over two files collapse to one shape, and a withheld read carries its answer's size.
    @Test func theReplayLoopListsTheCallsBehindEachRule() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let members = (1 ... 40).map { "    func part\($0)() -> Int {\n        let count = \($0)\n        return count * 2\n    }" }
        for name in ["Alpha", "Beta", "Gizmo"] {
            try ("/// A \(name).\nstruct \(name) {\n" + members.joined(separator: "\n") + "\n}\n")
                .write(to: root.appendingPathComponent("Sources/App/\(name).swift"), atomically: true, encoding: .utf8)
        }
        try await SiftEngine(directory: root).ensureFresh()

        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let read: [String: Any] = [
            "type": "assistant",
            "sessionId": "replayed-session",
            "cwd": root.path,
            "timestamp": "2026-09-20T10:03:00Z",
            "message": ["id": "m-r1", "content": [["type": "tool_use", "id": "r1", "name": "Read", "input": ["file_path": root.appendingPathComponent("Sources/App/Gizmo.swift").path]]]],
        ]
        let lines = try [
            Self.call("sed -n 5,45p Sources/App/Alpha.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Alpha"),
            Self.call("sed -n 1,30p Sources/App/Beta.swift", id: "c2", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "struct Beta"),
            JSONSerialization.data(withJSONObject: read),
            TranscriptFixture.toolResult(id: "r1", isError: false, text: "struct Gizmo"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let section = TranscriptReplay.section(
            projectsDirectory: transcript.deletingLastPathComponent(),
            since: nil,
            transcript: transcript.path,
            unredacted: true,
            hook: FixedVerdictHook()
        )

        #expect(section.contains { $0.hasPrefix("             2  sed -n <range> <file> — e.g. ") }, "\(section)")
        #expect(section.contains { $0.hasPrefix("             1  Read <file> — answer 14321 B over the 10000 B budget — e.g. `Read /") }, "\(section)")
    }

    /// The in-place answerer tells the replay how many bytes an answer came to where it built one and then withheld it over the size budget.
    @Test func theAnswererReportsHowBigAnAnswerWithheldOverTheBudgetCameTo() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let call = try #require(InPlaceShape.match(forShell: "cat Sources/App/Depot.swift", in: root.path)?.call)
        let measured = MeasuredAnswerSize()
        let backoff = try InPlaceAnswerTests.backoff()

        let outcome = await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(call, from: root.path, timeBudget: InPlaceAnswerTests.roomy, sizeBudget: 50, backoff: backoff, oversized: measured.record)
        }

        #expect(outcome == .withheld(.overSize))
        #expect((measured.value ?? 0) > 50, "\(String(describing: measured.value))")
    }

    /// One call on a line of its own, as the harness writes it, with the session, directory and time it carries.
    private static func call(_ command: String, id: String, cwd: String, at stamp: String) throws -> Data {
        let object: [String: Any] = [
            "type": "assistant",
            "sessionId": "replayed-session",
            "cwd": cwd,
            "timestamp": stamp,
            "message": ["id": "m-\(id)", "content": [["type": "tool_use", "id": id, "name": "Bash", "input": ["command": command]]]],
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }
}

/// The glued-flag and flag-cluster rows of the shape, beside the replay tests above.
extension ReplayColdShapesTests {
    /// A name glued onto a flag never rides whole through the shape merely for lacking a capital: only a command's own value-less letters survive, a glued value reads by its flag's kind and takes no word after it, an unlisted long flag reads `--<text>`, and a digit in a glued word never keeps it.
    ///
    /// Every name in a call here is a stand-in for a private word, so none of them may appear in its shape.
    @Test(arguments: [
        ("grep -edepot Sources", "grep -e<pattern> <text>"),
        ("rg -tdepot x", "rg -t<text> <pattern>"),
        ("rg -tswift stock", "rg -t<text> <pattern>"),
        ("grep -edepote Sources", "grep -e<pattern> <text>"),
        ("grep -xyoung Sources", "grep -x<text> <pattern>"),
        ("grep -gdepot Sources", "grep -g<text> <pattern>"),
        ("grep -xorchmard", "grep -xorchm<text>"),
        ("git commit -mwip", "git commit -m<text>"),
        ("gh issue list -lbug", "gh issue list -l<text>"),
        ("ls -ladepot", "ls -la<text>"),
        ("find . -namedepot", "find <text> -n<text>"),
        ("git log -sdepot", "git log -sd<text>"),
        ("xcodebuild -depot", "xcodebuild -d<text>"),
        ("cut -dx", "cut -d<text>"),
        ("sort -depot", "sort -d<text>"),
        ("grep --depot Widget F.swift", "grep --<text> <pattern> <file>"),
        ("grep --depot=x Widget F.swift", "grep --<text>=<text> <pattern> <file>"),
        ("grep --exclude-dir=depot Widget F.swift", "grep --exclude-dir=<text> <pattern> <file>"),
        ("grep --max-count=5 Widget F.swift", "grep --max-count=<n> <pattern> <file>"),
        ("grep -edepot5 Sources", "grep -e<pattern> <text>"),
        ("grep -xdepot5 Sources", "grep -x<text> <pattern>"),
    ])
    func aGluedLowercaseFlagValueNeverLeaksThroughTheShape(call: String, shape: String) {
        let shaped = TranscriptAudit.CallRedaction.shape(of: call)

        #expect(shaped == shape)
        for word in ["depot", "young", "ard", "wip", "bug", "swift", "stock"] {
            #expect(!shaped.contains(word), "\(shaped)")
        }
    }

    /// A single-dash cluster survives whole only as a command's own value-less letters, a word the command spells its options with, or a short lowercase cluster of a command with no letter set, and every form that already read right still does.
    ///
    /// A value-less flag closes the subcommand positions exactly as an unknown one does, so the word right after it — `git -p log`'s `log` — is never read as the subcommand merely for spelling one.
    @Test(arguments: [
        ("git -C log status", "git -C <text> status"),
        ("git -p log", "git -p <text>"),
        ("grep -- W F.swift", "grep -- <text> <file>"),
        ("grep -f Depot.txt F.swift", "grep -f <pattern> <file>"),
        ("grep -rnedepot Sources", "grep -rne<pattern> <text>"),
        ("grep -ne Depot F.swift", "grep -ne <pattern> <file>"),
        ("grep -in Widget F.swift", "grep -in <pattern> <file>"),
        ("grep -rnw Widget Sources", "grep -rnw <pattern> <text>"),
        ("grep -c1-240 Widget F.swift", "grep -c<n>-<n> <pattern> <file>"),
        ("sed -nedepot F.swift", "sed -ne<pattern> <file>"),
        ("awk -Fdepot F.swift", "awk -F<text> <pattern>"),
        ("git -Cdepot status", "git -C<text> <text>"),
        ("rg -g '*.swift' stock Sources", "rg -g <file> <pattern> <text>"),
        ("ls -la", "ls -la"),
        ("sort -rnu F.swift", "sort -rnu <file>"),
        ("find . -name '*.swift'", "find <text> -name <file>"),
        ("xcodebuild -scheme Widget test", "xcodebuild -scheme <text> <text>"),
        ("head -40 F.swift", "head -<n> <file>"),
        ("git log --oneline -p", "git log --oneline -p"),
    ])
    func aClusterSurvivesOnlyAsKnownValuelessFlags(call: String, shape: String) {
        #expect(TranscriptAudit.CallRedaction.shape(of: call) == shape)
    }

    /// For every command with a letter set, and one with none, a private-looking word glued after any of its value-less letters never survives in the shape.
    @Test func aWordGluedAfterAValuelessLetterNeverSurvives() {
        let words = [
            "depot", "gadget", "jukebox", "yonder", "mulberry", "quokka", "bramble", "tundra", "pumpkin", "vortex",
            "zephyr", "kestrel", "juniper", "meadow", "bishop", "falcon", "goblin", "walnut", "pebble", "nimbus",
        ]
        var letters = ShapeFlagVocabulary.valuelessLettersByCommand
        letters["sort"] = ["r", "n"]
        for (command, set) in letters {
            for letter in set.isEmpty ? ["x"] : set {
                for word in words {
                    let shaped = TranscriptAudit.CallRedaction.shape(of: "\(command) -\(letter)\(word)")
                    #expect(!words.contains { shaped.contains($0) }, "\(command) -\(letter)\(word) → \(shaped)")
                }
            }
        }
    }
}

/// The same glued-flag and flag-cluster rows, run through the pseudonymised example the audit prints beside a shape.
extension ReplayColdShapesTests {
    /// Every row of the two shape tables above, each with the spelling its flag takes in the example text, plus rows where a pipeline's later stage decides its own flags by its own command, and rows where a dash-led word stands in a value flag's place or a redirection's target, which is never a flag cluster (its private word is checked past the first letter a flag's spelling once kept, so `-Dav<text>` counts as a leak).
    static let exampleFlagRows: [(call: String, flag: String)] = [
        ("grep -edepot Sources", "-e<text>"),
        ("rg -tdepot x", "-t<text>"),
        ("rg -tswift stock", "-t<text>"),
        ("grep -edepote Sources", "-e<text>"),
        ("grep -xyoung Sources", "-x<text>"),
        ("grep -gdepot Sources", "-g<text>"),
        ("grep -xorchmard", "-xorchm<text>"),
        ("git commit -mwip", "-m<text>"),
        ("gh issue list -lbug", "-l<text>"),
        ("ls -ladepot", "-la<text>"),
        ("find . -namedepot", "-n<text>"),
        ("git log -sdepot", "-sd<text>"),
        ("xcodebuild -depot", "-d<text>"),
        ("cut -dx", "-d<text>"),
        ("sort -depot", "-d<text>"),
        ("grep --depot Widget F.swift", "--<text>"),
        ("grep --depot=x Widget F.swift", "--<text>="),
        ("grep --exclude-dir=depot Widget F.swift", "--exclude-dir="),
        ("grep --max-count=5 Widget F.swift", "--max-count="),
        ("grep -edepot5 Sources", "-e<text>"),
        ("grep -xdepot5 Sources", "-x<text>"),
        ("git -C log status", "-C"),
        ("git -p log", "-p"),
        ("grep -- W F.swift", "--"),
        ("grep -f Depot.txt F.swift", "-f"),
        ("grep -rnedepot Sources", "-rne<text>"),
        ("grep -ne Depot F.swift", "-ne"),
        ("grep -in Widget F.swift", "-in"),
        ("grep -rnw Widget Sources", "-rnw"),
        ("grep -c1-240 Widget F.swift", "-c1-240"),
        ("sed -nedepot F.swift", "-ne<text>"),
        ("awk -Fdepot F.swift", "-F<text>"),
        ("git -Cdepot status", "-C<text>"),
        ("rg -g '*.swift' stock Sources", "-g"),
        ("ls -la", "-la"),
        ("sort -rnu F.swift", "-rnu"),
        ("find . -name '*.swift'", "-name"),
        ("xcodebuild -scheme Widget test", "-scheme"),
        ("head -40 F.swift", "-40"),
        ("git log --oneline -p", "--oneline -p"),
        ("grep -rn depot F.swift | head -5", "-rn"),
        ("grep -rn depot F.swift | head -5", "head -5"),
        ("ls -l | grep -ladepot", "-l<text>"),
        ("cat F.swift | ls -ladepot", "-la<text>"),
        ("grep -e -Rich F.swift", "-e"),
        ("grep -A -Rich F.swift", "-A"),
        ("grep -ie -Rich F.swift", "-ie"),
        ("grep -m -Lori F.swift", "-m"),
        ("rg -g -Sunil x", "-g"),
        ("rg -t -Sunil x", "-t"),
        ("git -C -Dave log", "-C"),
        ("rg x >-Sunil", ">"),
        ("grep x . >-Rich", ">"),
        ("grep -e -rich F.swift", "-e"),
        ("grep -A -rich F.swift", "-A"),
        ("rg -g -sunil x", "-g"),
        ("git -C -xsad log", "-C"),
        ("grep x . 2>-rich", "2>"),
    ]

    /// A name glued onto a flag never rides whole through the example text either: each statement's own command decides which of its flags survive, exactly as the shape reads them, and whatever is glued past them reads `<text>`.
    @Test(arguments: exampleFlagRows)
    func aGluedFlagValueNeverLeaksThroughTheExample(call: String, flag: String) {
        let text = TranscriptScan.refusedCallShape(bash: call).text
        let redacted = TranscriptAudit.CallRedaction.redactedCall(text, by: Redactor(salt: Data("test-salt".utf8)))

        #expect(redacted.contains(" \(flag)"), "\(redacted)")
        for word in ["depot", "young", "ard", "wip", "bug", "stock", "tswift", "ich", "ori", "unil", "av", "sad"] {
            #expect(!redacted.lowercased().contains(word), "\(redacted)")
        }
    }
}
