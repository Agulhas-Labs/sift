//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// A lookup piped into a `tee` that ends its pipeline puts in the context what the lookup alone would, so the hook and the scan judge it as though the `tee` were absent; a `tee` that edits source or keeps the lines from the context is still a write.
@Suite(.temporaryDirectories)
struct TeePassThroughTests {
    /// The line a session ran its Swift greps as: answered as the same grep without its `tee`.
    @Test
    func aGrepTeedToALogIsJudgedAsTheGrepAlone() async throws {
        let grep = "grep -rn part1 --include='*.swift' . 2>&1"
        let bare = try await Self.judged(grep)
        #expect(bare.said.first != "allowed\t\tnoLookup")
        try await Self.expectJudgedAlike(grep + " | tee $S/file.txt", grep)
    }

    /// Appending, several destinations, and a chain of them are all the same pass-through.
    @Test
    func everySpellingOfATrailingTeeIsJudgedAsTheGrepAlone() async throws {
        let grep = "grep -rn part1 Sources"
        try await Self.expectJudgedAlike(grep + " | tee -a out.txt", grep)
        try await Self.expectJudgedAlike(grep + " | tee one.txt two.txt", grep)
        try await Self.expectJudgedAlike(grep + " |& tee out.txt | tee -a all.txt", grep)
        try await Self.expectJudgedAlike(grep + " | head -5 | tee out.txt", grep + " | head -5")
    }

    /// A `tee` onto a Swift source file rewrites that file, so the line stays a write and no lookup.
    @Test
    func aTeeOntoSwiftSourceIsStillAWrite() async throws {
        let teed = try await Self.judged("grep -rn part1 --include='*.swift' . 2>&1 | tee Sources/App/Copy.swift")

        #expect(teed.said.first == "allowed\t\tnoLookup")
        #expect(ShellInspection.lookupLine("cat Sources/App/View.swift | tee Sources/App/Copy.swift", holdsSource: nil) == nil)
        #expect(ShellInspection.lookupLine("cat Sources/App/View.swift | tee copy.txt", holdsSource: nil) == "cat Sources/App/View.swift")
    }

    /// A `tee` whose own output goes to a file keeps the lines out of the context, so it is not taken out and the line keeps the write reading.
    @Test
    func aTeeWithItsOutputRedirectedIsStillAWrite() async throws {
        let teed = try await Self.judged("grep -rn part1 Sources | tee out.txt > /dev/null")

        #expect(teed.said.first == "allowed\t\tnoLookup")
    }

    /// A `tee` with a stage after it is left in place, since the in-place reading answers no pipeline with a pass-through in its middle.
    @Test
    func aTeeInTheMiddleOfAPipelineKeepsTheWriteReading() async throws {
        let teed = try await Self.judged("grep -rn part1 Sources | tee out.txt | head -5")

        #expect(teed.said.first == "allowed\t\tnoLookup")
    }

    /// An answer given in place for a teed lookup says, in its opening line, which files the `tee` did not write, as the command spells them.
    @Test
    func anAnswerSaysWhichFilesTheTeeDidNotWrite() async throws {
        let grep = "grep -n 'var body' Sources/App/Screens.swift"
        let one = try await Self.openingLine(grep + " | tee $S/out.txt")
        let two = try await Self.openingLine(grep + " | tee a.txt b.txt")
        let bare = try await Self.openingLine(grep)

        #expect(one.hasSuffix(" (not run: $S/out.txt was not written)."), "\(one)")
        #expect(two.hasSuffix(" (not run: a.txt, b.txt were not written)."), "\(two)")
        #expect(!bare.contains("not run:"), "\(bare)")
    }

    /// The clause rides after the suffix, so the calls the opening line names read back as they did, and the line still ends its sentence.
    @Test
    func theClauseLeavesTheOpeningLineReadable() {
        let line = InPlaceAnswer.openingLine(calls: ["digest Sources/App/Shell.swift", "where Shell"], teed: ["a.txt", "b.txt"])

        #expect(InPlaceAnswer.calls(inOpeningLine: line) == ["digest Sources/App/Shell.swift", "where Shell"])
        #expect(line.hasSuffix("if you wanted its raw output (not run: a.txt, b.txt were not written)."))
        #expect(!InPlaceAnswer.openingLine(calls: ["where Shell"]).contains("not run:"))
        let sized = InPlaceAnswer.openingLine(calls: ["digest Shell.swift"], rerun: (lines: 900, bytes: 40000), teed: ["a.txt"])
        #expect(sized.hasSuffix("with offset and limit (not run: a.txt was not written)."), "\(sized)")
    }

    /// A `tee` that also redirects its own stderr, hands its stdout to a process substitution, or names a backup copy of a source file is no write: the line is judged as the grep alone.
    @Test
    func teeSpellingsThatWriteNoSourceAreJudgedAsTheGrepAlone() async throws {
        let grep = "grep -rn part1 Sources"
        try await Self.expectJudgedAlike(grep + " | tee out.txt 2>/dev/null", grep)
        try await Self.expectJudgedAlike(grep + " | tee >(wc -l)", grep)
        try await Self.expectJudgedAlike(grep + " | tee Sources/A.swift.bak", grep)

        #expect(ShellInspection.passThroughTeeFiles(grep + " | tee out.txt 2>/dev/null") == ["out.txt"])
    }

    /// The scan counts the teed grep as the lookup the index lost that the grep alone is.
    @Test
    func theScanCountsATeedGrepAsTheGrepAlone() {
        let grep = "grep -n part1 /x/Sources/App/Shell.swift"
        let bare = TranscriptFixture.tally([TranscriptFixture.toolUse("Bash", input: ["command": grep])])
        let teed = TranscriptFixture.tally([TranscriptFixture.toolUse("Bash", input: ["command": grep + " 2>&1 | tee $S/out.txt"])])

        #expect(bare.cold == 1)
        #expect(teed.cold == bare.cold)
        #expect(teed.total == bare.total)
    }

    /// The line is cut at the stage before the first trailing `tee`, and every other statement is kept as written.
    @Test
    func onlyTheTrailingTeesAreTakenOut() {
        #expect(ShellInspection.withoutPassThroughTees("cd Kit && grep -rn Name . | tee a.txt; echo done") == "cd Kit && grep -rn Name .; echo done")
        #expect(ShellInspection.withoutPassThroughTees("grep -rn Name . | tee a.txt | wc -l") == "grep -rn Name . | tee a.txt | wc -l")
        #expect(ShellInspection.withoutPassThroughTees("tee a.txt < notes.txt") == "tee a.txt < notes.txt")
        #expect(ShellInspection.withoutPassThroughTees("grep -rn committee .") == "grep -rn committee .")
    }

    /// Only the substitution the shell runs is rewritten where an identical quoted copy comes earlier on the line, and the quoted text stays as written.
    @Test
    func anEarlierQuotedCopyOfASubstitutionIsLeftAsWritten() {
        let line = "echo '$(cmd | tee out.log)' ; x=$(cmd | tee out.log)"

        #expect(ShellInspection.withoutPassThroughTees(line) == "echo '$(cmd | tee out.log)' ; x=$(cmd)")
        #expect(ShellInspection.passThroughTeeFiles(line) == ["out.log"])
    }

    /// With no earlier copy the substitution is rewritten as before, and the files of several substitutions come in command order.
    @Test
    func substitutionsAreRewrittenInCommandOrder() {
        #expect(ShellInspection.withoutPassThroughTees("x=$(cmd | tee out.log)") == "x=$(cmd)")
        let line = "x=$(a | tee one.log) y=$(b | tee two.log)"

        #expect(ShellInspection.withoutPassThroughTees(line) == "x=$(a) y=$(b)")
        #expect(ShellInspection.passThroughTeeFiles(line) == ["one.log", "two.log"])
    }

    /// The files come back in the order they are written, a tee inside a substitution before the tee that ends the line around it.
    @Test
    func nestedAndSiblingSubstitutionsListFilesInWrittenOrder() {
        #expect(ShellInspection.passThroughTeeFiles("x=$(a $(b | tee f.log) | tee g.log)") == ["f.log", "g.log"])
        #expect(ShellInspection.passThroughTeeFiles("x=$(a | tee f.log) y=$(b | tee g.log)") == ["f.log", "g.log"])
        #expect(ShellInspection.passThroughTeeFiles("x=$(a $(b $(c | tee f.log) | tee g.log) | tee h.log)") == ["f.log", "g.log", "h.log"])
        #expect(ShellInspection.withoutPassThroughTees("x=$(a $(b | tee f.log) | tee g.log)") == "x=$(a $(b))")
    }
}

private extension TeePassThroughTests {
    /// The hook's verdict line on `command` in a fresh repository declaring a long `Shell` followed by the rules it logged, and the calls it hands its answerer.
    static func judged(_ command: String) async throws -> (said: [String], calls: [InPlaceCall]?) {
        let fixture = try AlreadyDigestedReadTests.Fixture()
        try fixture.lengthen()
        let result = await InPlaceAnswerTests.onItsOwnThread {
            // The judgement makes its usage log here, off the test's task, so it brings a scope of its own.
            Result { () throws -> (said: [String], calls: [InPlaceCall]?) in
                let judged = try TemporaryDirectory.withScope { try fixture.judgedThroughTheLedger(command, asFlag: true) }
                let lookup = PreToolUseCommand.lookup(command: command, payload: [:], in: fixture.repo.path, noting: fixture.suppressions, couldAnswer: { _, _ in true })
                return ([judged.line] + judged.rules, lookup.flatMap(fixture.handed))
            }
        }
        return try result.get()
    }

    /// The opening line of the answer the hook's classification of `command` is given, in a fresh indexed repository whose `Screens.swift` declares two views.
    static func openingLine(_ command: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> String {
        let fixture = try AlreadyDigestedReadTests.Fixture()
        let screens = "struct Screen: View {\n    var body: Int {\n        1\n    }\n}\n\nprivate struct Row: View {\n    var body: Int {\n        2\n    }\n}\n"
        try screens.write(to: fixture.repo.appendingPathComponent("Sources/App/Screens.swift"), atomically: true, encoding: .utf8)
        try await fixture.index()
        let match = try #require(fixture.classified(command: command, rerunIn: "s1", sourceLocation: sourceLocation).inPlace, "\(command)", sourceLocation: sourceLocation)
        let backoff = try InPlaceAnswerTests.backoff()
        let outcome = await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }
        guard case let .answered(answered) = outcome else {
            Issue.record("\(command) was not answered: \(outcome)", sourceLocation: sourceLocation)
            return ""
        }
        return String(answered.reason.prefix { $0 != "\n" })
    }

    /// Records an issue unless `teed` is judged exactly as `bare` is: the same verdict, the same rules, the same calls handed to the answerer.
    static func expectJudgedAlike(_ teed: String, _ bare: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let teedVerdict = try await judged(teed)
        let bareVerdict = try await judged(bare)
        #expect(teedVerdict.said == bareVerdict.said, "\(teed)", sourceLocation: sourceLocation)
        #expect(teedVerdict.calls == bareVerdict.calls, "\(teed)", sourceLocation: sourceLocation)
        #expect(bareVerdict.calls != nil, "\(bare)", sourceLocation: sourceLocation)
    }
}
