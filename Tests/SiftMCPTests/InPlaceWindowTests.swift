//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Line windows of a file whose digest is over the size budget, answered with the members their lines overlap rather than withheld.
@Suite(.temporaryDirectories)
struct InPlaceWindowTests {
    /// Pads every one of `lines` (1-based) in the file at `path` with a trailing comment, wide enough that the raw source of a short window is no longer dwarfed by the fixed cost of framing a refusal around it — the opening line, freshness header and closing line every bounded answer carries beside its member listing — and wide enough that the answer saves more than ``InPlaceAnswer/windowSavingFloor``, below which a window whose lines the answer does not show runs, without moving a single line number a test's assertions depend on.
    private static func widen(linesInFile path: URL, at lines: ClosedRange<Int>, width: Int = 1000) throws {
        var rows = try String(contentsOf: path, encoding: .utf8).components(separatedBy: "\n")
        let filler = String(repeating: "x", count: width)
        for line in lines where rows.indices.contains(line - 1) {
            rows[line - 1] += " // \(filler)"
        }
        try rows.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
    }

    /// The outcome for what `command` matches in `root`, on a thread of its own as the hook runs it.
    private static func outcome(_ match: InPlaceShape.Match, sizeBudget: Int = InPlaceAnswer.sizeBudget) async throws -> InPlaceAnswerer.Outcome {
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, sizeBudget: sizeBudget, backoff: backoff)
        }
    }

    /// The answer `outcome` holds, or a recorded issue.
    private static func answered(_ outcome: InPlaceAnswerer.Outcome, sourceLocation: SourceLocation = #_sourceLocation) throws -> InPlaceAnswerer.Answered {
        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        return answered
    }

    /// The whole-file answer's size for the file `match` windows, measured on a whole read of it, which the budget is set one byte under.
    private static func wholeSize(_ match: InPlaceShape.Match, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Int {
        let path = try #require(match.call.readPath, sourceLocation: sourceLocation)
        let read = try #require(InPlaceShape.match(forShell: "cat \(path)", in: match.directory), sourceLocation: sourceLocation)
        let whole = try await answered(outcome(read), sourceLocation: sourceLocation)
        #expect(whole.calls.map(\.target) == ["Sources/App/Depot.swift"], "a digest that fits is still the whole file's", sourceLocation: sourceLocation)
        return whole.reason.utf8.count
    }

    /// Two windows of one file on one line, its digest over the budget, are each answered with the members they overlap under their enclosing type, named as the lines asked for.
    @Test
    func windowsOverBudgetAreAnsweredWithTheMembersTheyOverlap() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let file = root.appendingPathComponent("Sources/App/Depot.swift")
        try Self.widen(linesInFile: file, at: 1 ... 5)
        try Self.widen(linesInFile: file, at: 50 ... 55)
        try await SiftEngine(directory: root).ensureFresh()
        let match = try #require(InPlaceShape.match(forShell: "sed -n '50,55p' Sources/App/Depot.swift && head -5 Sources/App/Depot.swift", in: root.path))
        // The padded windows outweigh the whole digest, and their members are smaller still, so the members answer
        // them where both fit the budget; a budget that fits that answer with the over-budget note in place of this
        // one is under the whole digest, which is larger than it.
        let roomy = try await Self.answered(Self.outcome(match))
        #expect(roomy.calls.map(\.target) == ["Sources/App/Depot.swift:1-5", "Sources/App/Depot.swift:50-55"])
        #expect(roomy.reason.contains(FileDigestParts.larger))
        let budget = roomy.reason.utf8.count - FileDigestParts.larger.utf8.count + "the whole digest is over the size budget".utf8.count

        let answered = try await Self.answered(Self.outcome(match, sizeBudget: budget))

        #expect(answered.calls.map(\.target) == ["Sources/App/Depot.swift:1-5", "Sources/App/Depot.swift:50-55"])
        #expect(answered.reason.hasPrefix(
            "sift answered this with `digest Sources/App/Depot.swift` (only the members of lines 1-5, 50-55 are shown; the whole digest is over the size budget) instead of running it"
        ))
        #expect(answered.reason.contains("Sources/App/Depot.swift lines 50-55 overlap:\nstruct Depot"))
        #expect(answered.reason.contains("    func stock10() -> Int  :48-52"))
        #expect(answered.reason.contains("    func stock11() -> Int  :53-57"))
        #expect(!answered.reason.contains("stock12()"))
        #expect(answered.calls.reduce(0) { $0 + $1.bytes.served } == answered.reason.utf8.count)
        #expect(try await Self.outcome(match, sizeBudget: 100) == .withheld(.overSize), "a bounded answer still over the budget is withheld")
    }

    /// A file whose members `a()`, `inner50()` and `c()` sit two levels deep — a `struct` inside an `enum` — indexed in a fresh repository, with `widened` lines padded.
    private static func nestedRepository(widened: ClosedRange<Int>) async throws -> URL {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let source = """
        /// Nested.
        enum Outer {
            struct Inner {
                func a() -> Int { 1 }
                func inner50() -> Int {
                    let a1 = 1
                    let a2 = 2
                    let a3 = 3
                    let a4 = 4
                    let a5 = 5
                    let a6 = 6
                    let a7 = 7
                    let a8 = 8
                    return a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8
                }
                func c() -> Int { 3 }
            }
        }

        """
        let file = root.appendingPathComponent("Sources/App/Nested.swift")
        try source.write(to: file, atomically: true, encoding: .utf8)
        try Self.widen(linesInFile: file, at: widened, width: 600)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// A window across members nested two levels deep — a `struct` inside an `enum` — resolves to those members, not to the mid-level container merely summarised.
    @Test
    func aWindowInAMemberNestedTwoLevelsDeepResolvesToIt() async throws {
        // Ten lines, padded, so the window's own source outweighs the compact member listing it resolves to
        // once framed — item 4 withholds a bounded answer that costs more than the source it stands in for.
        // The file is below the floor, so its whole answer is its source, never smaller than the window: the
        // members answer it at the default budget.
        let root = try await Self.nestedRepository(widened: 4 ... 13)
        let match = try #require(InPlaceShape.match(forShell: "sed -n '4,13p' Sources/App/Nested.swift", in: root.path))

        let answered = try await Self.answered(Self.outcome(match))

        #expect(answered.calls.map(\.target) == ["Sources/App/Nested.swift:4-13"])
        #expect(answered.reason.contains("the whole digest would be no smaller than these lines"))
        #expect(answered.reason.contains("        func a() -> Int  :4"))
        #expect(answered.reason.contains("        func inner50() -> Int  :5-15"))
        #expect(!answered.reason.contains("func c()"))
    }

    /// A window wholly inside one member runs: its members answer would be that member's declaration line, which the reader who chose the window already knew, so the identical re-run would follow it.
    @Test(arguments: WindowReadSpelling.allCases)
    func aWindowWhollyInsideOneMemberRuns(spelling: WindowReadSpelling) async throws {
        let root = try await Self.nestedRepository(widened: 6 ... 13)
        let match = try spelling.match(path: "Sources/App/Nested.swift", lines: 6 ... 13, in: root)

        #expect(try await Self.outcome(match) == .withheld(.linesNotShown))
    }

    /// The same window runs beside another file's window on one shell line.
    @Test
    func aWindowWhollyInsideOneMemberRunsBesideAnotherFilesWindow() async throws {
        let root = try await Self.nestedRepository(widened: 6 ... 13)
        try Self.widen(linesInFile: root.appendingPathComponent("Sources/App/Depot.swift"), at: 1 ... 5)
        try await SiftEngine(directory: root).ensureFresh()
        let match = try #require(InPlaceShape.match(forShell: "sed -n '6,13p' Sources/App/Nested.swift && head -5 Sources/App/Depot.swift", in: root.path))

        #expect(try await Self.outcome(match) == .withheld(.linesNotShown))
    }

    /// A window in no member is answered with the member nearest it, in the wording a digest of that line gives — its own several lines of trailing comment outweigh that wording, so it is not withheld on item 4's size-against-source rule.
    @Test
    func aWindowInNoMemberNamesTheNearest() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        // Six lines of padding, still inside the struct and outside every member, so their own source
        // outweighs the nearest-member wording an item-4 comparison would otherwise withhold as too small.
        let padding = (1 ... 6).map { "    // padding line \($0) kept outside every member" }.joined(separator: "\n")
        let file = root.appendingPathComponent("Sources/App/Depot.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let body = source.hasSuffix("}\n") ? String(source.dropLast(2)) : source
        try (body + padding + "\n}\n").write(to: file, atomically: true, encoding: .utf8)
        try Self.widen(linesInFile: file, at: 203 ... 208)
        try await SiftEngine(directory: root).ensureFresh()
        let match = try #require(InPlaceShape.match(forShell: "sed -n '203,208p' Sources/App/Depot.swift", in: root.path))
        let budget = try await Self.wholeSize(match) - 1

        let answered = try await Self.answered(Self.outcome(match, sizeBudget: budget))

        #expect(answered.calls.map(\.target) == ["Sources/App/Depot.swift:203-208"])
        #expect(answered.reason.contains("Sources/App/Depot.swift lines 203-208 are in Sources.Depot — struct — Sources/App/Depot.swift:2-209, but in none of its members; the nearest:"))
        #expect(answered.reason.contains("  before: digest Sources.Depot.stock40() — func — Sources/App/Depot.swift:198-202"))
    }

    /// A `Read` with `offset`/`limit` is the same window as the shell's.
    @Test
    func aRangedReadIsTheSameWindow() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let file = root.appendingPathComponent("Sources/App/Depot.swift")
        try Self.widen(linesInFile: file, at: 50 ... 55)
        try await SiftEngine(directory: root).ensureFresh()
        let match = try #require(InPlaceShape.match(forRead: "Sources/App/Depot.swift", in: root.path, window: LineWindow(offset: 50, limit: 6)))
        let budget = try await Self.wholeSize(match) - 1

        #expect(try await Self.answered(Self.outcome(match, sizeBudget: budget)).calls.map(\.target) == ["Sources/App/Depot.swift:50-55"])
    }

    /// A digest of some of a file's lines locates the file, so the ranged read that follows it is let through — but it is not the file's whole digest, so a whole read of it still needs the file's own digest.
    @Test
    func aDigestOfLinesLocatesTheFile() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let file = root.appendingPathComponent("Sources/App/Depot.swift").path
        let digests = [root.path: Set(["Sources/App/Depot.swift:50-55"])]

        #expect(DigestedFiles.isLocated(file, among: digests))
        #expect(!DigestedFiles.isDigested(file, among: digests))
    }

    /// Each window spelling is read to the lines it prints, and one this does not model to none.
    @Test(arguments: [
        ("sed -n '1,3p;7p' F.swift", [1, 2, 3, 7]),
        ("sed -n -e 5,+1p F.swift", [5, 6]),
        ("sed -n '18,$p' F.swift", [18, 19, 20]),
        ("head -n 2 F.swift", [1, 2]),
        ("tail -3 F.swift", [18, 19, 20]),
        ("cat -n F.swift | tail -n +4 | head -2", [4, 5]),
        ("tail -n +1 F.swift", Array(1 ... 20)),
        // `tail`'s own reading of `+0` is the same as `+1` — both print the whole file, a whole read rather
        // than a window of zero lines.
        ("tail -n +0 F.swift", Array(1 ... 20)),
        ("awk 'NR>=3 && NR<=4' F.swift", [3, 4]),
        ("awk 'NR==6,NR==8 {print}' F.swift", [6, 7, 8]),
    ])
    func windowsAreReadToTheirLines(command: String, lines: [Int]) {
        let window = LineWindow(stages: ShellSyntax.segments(of: command).map { ShellQuery($0).invocation })

        #expect(window.lines(inFileOf: 20) == lines)
    }

    /// A byte window after the stage reading the file is no line window: what it is handed may carry text of an earlier stage's own, so its bytes are not the file's.
    @Test
    func aByteWindowAfterTheReadIsNotRead() {
        #expect(LineWindow(stages: [["head", "-c", "900", "F.swift"]]).isReadable)
        #expect(!LineWindow(stages: [["cat", "-n", "F.swift"], ["head", "-c", "900"]]).isReadable)
        #expect(InPlaceShape.match(forShell: "cat -n Sources/App/Depot.swift | head -c 900", in: "/repo") == nil)
    }

    /// A byte count that ends part way through a line of the file is withheld rather than answered with the members of the lines it touches, which it prints only part of.
    @Test
    func aByteCountEndingInsideALineRuns() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let file = try String(contentsOf: root.appendingPathComponent("Sources/App/Depot.swift"), encoding: .utf8)
        let whole = file.split(separator: "\n", omittingEmptySubsequences: false).prefix(100).reduce(0) { $0 + $1.utf8.count + 1 }
        let match = try #require(InPlaceShape.match(forShell: "head -c \(whole - 3) Sources/App/Depot.swift", in: root.path))

        #expect(try await Self.outcome(match) == .withheld(.notExact))
    }

    /// A window the system tools fail on — an option after the file, which they open as one more file, or a digit outside ASCII in a `sed` address — prints part of the window or none of it, so it is no window and nothing is answered in place.
    @Test(arguments: [
        "head Sources/App/Depot.swift -n 20",
        "sed -n '1,\u{0665}p' Sources/App/Depot.swift",
        "sed -n 1,5p Sources/App/Depot.swift -n",
        "cat Sources/App/Depot.swift | head 5 -n 2",
        "awk 'NR<=5' Sources/App/Depot.swift -F:",
    ])
    func aWindowTheSystemToolsFailOnIsNotAnswered(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: "/repo") == nil)
    }

    /// A window the system tools refuse with an error — each run on this machine and seen to exit non-zero — is no window, so no digest stands in for the error it prints.
    @Test(arguments: [
        "head -0 Sources/App/Depot.swift",
        "head -n 0 Sources/App/Depot.swift",
        "head -n0 Sources/App/Depot.swift",
        "head --lines=0 Sources/App/Depot.swift",
        "head -c 0 Sources/App/Depot.swift",
        "head -c0 Sources/App/Depot.swift",
        "head -n -1 Sources/App/Depot.swift",
        "head -n 2147483648 Sources/App/Depot.swift",
        "head -n 1x Sources/App/Depot.swift",
        "head -q Sources/App/Depot.swift",
        "head -n 3 -c 5 Sources/App/Depot.swift",
        "head -5 -n 0 Sources/App/Depot.swift",
        "cat Sources/App/Depot.swift | head -0",
        "tail -n 99999999999999999999 Sources/App/Depot.swift",
        "tail -z Sources/App/Depot.swift",
        "tail -n 1x Sources/App/Depot.swift",
        "tail -0 -n +5 Sources/App/Depot.swift",
        "sed -n -z 1,5p Sources/App/Depot.swift",
        "sed -n --quiet 1,5p Sources/App/Depot.swift",
        "awk 'NR<=2 {print $2147483647}' Sources/App/Depot.swift",
        "awk -F '[(' 'NR<=2 {print $1}' Sources/App/Depot.swift",
        "awk 'NR<=2 {print 1/0}' Sources/App/Depot.swift",
    ])
    func aWindowTheSystemToolsRefuseIsNotAnswered(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: "/repo") == nil)
    }

    /// An `awk` window whose action does more than print — writes a file, pipes into a command, runs one, or reads another file — is no window, since the digest cannot stand in for what it did.
    @Test(arguments: [
        "awk 'NR<=3 {print > \"/x/y\"}' Sources/App/Depot.swift",
        "awk 'NR<=3 {print >> \"/x/y\"}' Sources/App/Depot.swift",
        "awk 'NR<=3 {print | \"cat\"}' Sources/App/Depot.swift",
        "awk 'NR<=3 {system(\"true\")}' Sources/App/Depot.swift",
        "awk 'NR<=3 {getline line < \"/etc/hosts\"; print}' Sources/App/Depot.swift",
        "awk 'NR<=3 {\"date\" | getline line; print}' Sources/App/Depot.swift",
        "cat Sources/App/Depot.swift | awk 'NR<=3 {print > \"/x/y\"}'",
    ])
    func aWindowThatActsIsNotAnswered(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: "/repo") == nil)
    }

    /// An `awk` window whose action prints anything but each line it picks whole, numbered or not — a string of its own, a field, a line number alone, a `printf` of anything but the line and its newline — prints text the file does not hold as its lines, so the digest cannot stand in for it.
    @Test(arguments: [
        "awk 'NR<=3 {print \"x\"}' Sources/App/Depot.swift",
        "awk 'NR<=3 {print \"x\", $0}' Sources/App/Depot.swift",
        "awk 'NR<=3 {print $0 \"x\"}' Sources/App/Depot.swift",
        "awk 'NR<=3 {print $1}' Sources/App/Depot.swift",
        "awk 'NR<=3 {print NR}' Sources/App/Depot.swift",
        "awk 'NR==2, NR==4 {print \"x\"}' Sources/App/Depot.swift",
        "awk 'NR<=3 {printf \"%s\", $0}' Sources/App/Depot.swift",
        "awk 'NR<=3 {printf $0}' Sources/App/Depot.swift",
        "cat Sources/App/Depot.swift | awk 'NR<=3 {print \"x\"}'",
        "awk 'NR<=5{print $0, $1 , \"x\"}' Sources/App/Depot.swift || echo X",
        "awk 'NR<=3 {print NR\" struct Fake {} \"$0}' Sources/App/Depot.swift",
    ])
    func aWindowThatPrintsTextOfItsOwnIsNotAnswered(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: "/repo") == nil)
    }

    /// The plain windows — a count, a numeric `sed -n`, an `awk` picking lines by number, an every-line `awk` into a count — are still answered with the file's digest.
    @Test(arguments: [
        "head -20 Sources/App/Depot.swift",
        "head -20 Sources/App/Depot.swift 2>/dev/null",
        "tail -n +5 Sources/App/Depot.swift",
        "sed -n 1,50p Sources/App/Depot.swift",
        "awk 'NR<=40' Sources/App/Depot.swift",
        "awk 'NR>=3 && NR<=9 {print NR\": \"$0}' Sources/App/Depot.swift",
        "awk 'NR<=3 {print NR\"\\t\"$0}' Sources/App/Depot.swift",
        "awk 'NR<=3 {print;}' Sources/App/Depot.swift",
        "awk 1 Sources/App/Depot.swift | head -2",
        "awk '{print NR\": \"$0}' Sources/App/Depot.swift | head -500",
        "cat -n Sources/App/Depot.swift | sed -n 5,9p",
    ])
    func aPlainWindowIsStillAnswered(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: "/repo")?.call == .fileDigest(path: "Sources/App/Depot.swift", windows: [
            LineWindow(stages: ShellSyntax.segments(of: command).map { ShellQuery($0).invocation }),
        ]))
    }

    /// Options ahead of the file, a `tail` count from a line among them, leave the window read.
    @Test(arguments: [
        ("sed -n -e 3p -e 5p F.swift", [3, 5]),
        ("tail +19 F.swift", [19, 20]),
    ])
    func optionsAheadOfTheFileAreRead(command: String, lines: [Int]) {
        let window = LineWindow(stages: ShellSyntax.segments(of: command).map { ShellQuery($0).invocation })

        #expect(window.lines(inFileOf: 20) == lines)
    }

    /// A bounded answer that costs more than the one line it stands in for — the nearest-member wording dwarfing a single closing brace — is withheld rather than handed over: serving more than the read it replaces is no saving at all.
    @Test
    func aBoundedAnswerBiggerThanItsSourceIsWithheld() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let match = try #require(InPlaceShape.match(forShell: "tail -1 Sources/App/Depot.swift", in: root.path))

        #expect(try await Self.outcome(match) == .withheld(.notSmaller))
    }

    /// A window whose member listing is itself smaller than the lines it stands for can still lose once it is framed.
    ///
    /// The opening line, freshness header and closing line it is served inside are counted too — a short window is where this shows, since the member text (a compact line naming each function it crosses) barely grows with it while the framing never shrinks. Chosen on the member text alone, this would be served anyway; framed, it costs more than the five-line read it replaces.
    @Test
    func aBoundedAnswerBiggerThanItsSourceOnceFramedIsWithheld() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let match = try #require(InPlaceShape.match(forShell: "sed -n '50,54p' Sources/App/Depot.swift", in: root.path))

        #expect(try await Self.outcome(match) == .withheld(.notSmaller))
    }

    /// A short window of a file whose digest outweighs the lines it prints runs, since the digest would cost more than the window.
    @Test
    func aWindowSmallerThanTheDigestRuns() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let match = try #require(InPlaceShape.match(forShell: "sed -n '100,119p' Sources/App/Depot.swift", in: root.path))

        #expect(try await Self.outcome(match) == .withheld(.notSmaller))
    }

    /// A window of most of a file is answered with the members it overlaps, smaller than the file's digest, and the saving is priced against the lines the window prints rather than the whole file.
    @Test
    func aWindowLargerThanTheDigestIsAnsweredAndPricedAgainstItsLines() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: 80)
        let file = root.appendingPathComponent("Sources/App/Depot.swift")
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        let window = lines[1 ..< 180].reduce(0) { $0 + $1.utf8.count + 1 }
        let match = try #require(InPlaceShape.match(forShell: "sed -n '2,180p' Sources/App/Depot.swift", in: root.path))

        let answered = try await Self.answered(Self.outcome(match))

        #expect(answered.calls.map(\.target) == ["Sources/App/Depot.swift:2-180"])
        #expect(answered.calls.map(\.bytes.source) == [window])
        #expect(answered.reason.contains("\(ByteSize.short(window)) of source → \(ByteSize.short(answered.reason.utf8.count)) served"))
    }

    /// A window of a file holding an unresolved merge conflict marker at a line start runs, whatever the digest would save.
    @Test(arguments: ["<<<<<<< HEAD", "=======", ">>>>>>> feature"])
    func aWindowOfAConflictedFileRuns(marker: String) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let file = root.appendingPathComponent("Sources/App/Depot.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        try (source + marker + "\n").write(to: file, atomically: true, encoding: .utf8)
        let match = try #require(InPlaceShape.match(forShell: "sed -n '1,9999p' Sources/App/Depot.swift", in: root.path))

        #expect(try await Self.outcome(match) == .withheld(.conflicted))
    }

    /// A ranged `Read` of a file holding a conflict marker runs as a shell window of it does, though a `Read` is never marked as a window the context could drop.
    @Test
    func aRangedReadOfAConflictedFileRuns() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let file = root.appendingPathComponent("Sources/App/Depot.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        try (source + "<<<<<<< HEAD\n=======\n>>>>>>> feature\n").write(to: file, atomically: true, encoding: .utf8)
        let match = try #require(InPlaceShape.match(forRead: "Sources/App/Depot.swift", in: root.path, window: LineWindow(offset: 1, limit: 9999)))

        #expect(try await Self.outcome(match) == .withheld(.conflicted))
    }

    /// A conflict marker in a file whose lines end in CRLF is found at its line start as it is in one whose lines end in LF.
    @Test(arguments: ["<<<<<<< HEAD", "=======", ">>>>>>> feature"])
    func aWindowOfACRLFConflictedFileRuns(marker: String) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let file = root.appendingPathComponent("Sources/App/Depot.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        try (source + marker + "\n").replacingOccurrences(of: "\n", with: "\r\n").write(to: file, atomically: true, encoding: .utf8)
        let match = try #require(InPlaceShape.match(forShell: "sed -n '1,9999p' Sources/App/Depot.swift", in: root.path))

        #expect(try await Self.outcome(match) == .withheld(.conflicted))
    }

    /// A window of every line of a CRLF file is the whole read, priced at the file's own bytes, with no empty line after its last newline.
    @Test(arguments: ["sed -n '1,9999p' Sources/App/Depot.swift", "tail -n 9999 Sources/App/Depot.swift"])
    func aWindowOfACRLFFileIsPricedAtItsOwnBytes(command: String) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: 80)
        let file = root.appendingPathComponent("Sources/App/Depot.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        try source.replacingOccurrences(of: "\n", with: "\r\n").write(to: file, atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        let bytes = try Data(contentsOf: file).count
        let match = try #require(InPlaceShape.match(forShell: command, in: root.path))

        let answered = try await Self.answered(Self.outcome(match))

        #expect(answered.calls.map(\.target) == ["Sources/App/Depot.swift"])
        #expect(answered.calls.map(\.bytes.source) == [bytes])
    }

    /// A leading UTF-8 byte-order mark shifts every line's true byte boundary three bytes later than a decode that drops the mark would compute: a `head -c` count landing on the mark's file's true line end is read to it, and the boundary the dropped mark would have computed, three bytes short of it, prints part of a line and is withheld.
    @Test
    func aBOMShiftsEveryByteBoundaryThreeBytesLater() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: 80)
        let file = root.appendingPathComponent("Sources/App/Depot.swift")
        // Each of the window's lines is padded, so what the answer saves clears the floor a window's members answer is held to.
        let source = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated()
            .map { $0.offset < 50 ? $0.element + " // " + String(repeating: "x", count: 60) : $0.element }
            .joined(separator: "\n")
        var withBOM = Data([0xEF, 0xBB, 0xBF])
        withBOM.append(contentsOf: Array(source.utf8))
        try withBOM.write(to: file)
        try await SiftEngine(directory: root).ensureFresh()

        // The boundary a decode that drops the mark would compute: the same lines, none of them counting the mark's three bytes.
        let droppedMarkBoundary = source.split(separator: "\n", omittingEmptySubsequences: false).prefix(50).reduce(0) { $0 + $1.utf8.count + 1 }
        let trueBoundary = droppedMarkBoundary + 3

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/head")
        process.arguments = ["-c", "\(trueBoundary)", file.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(printed.last == UInt8(ascii: "\n"), "trueBoundary is meant to land on the file's real line end")

        let exact = try #require(InPlaceShape.match(forShell: "head -c \(trueBoundary) Sources/App/Depot.swift", in: root.path))
        let short = try #require(InPlaceShape.match(forShell: "head -c \(droppedMarkBoundary) Sources/App/Depot.swift", in: root.path))

        let exactAnswered = try await Self.answered(Self.outcome(exact))
        #expect(!exactAnswered.calls.isEmpty)
        #expect(try await Self.outcome(short) == .withheld(.notExact))
    }
}
