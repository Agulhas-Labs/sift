//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the errors section against the build it was built for: one argument label changed, forty files calling the helper, two hundred copies of one sentence.
///
/// The capture is real — `Fixtures/RunOutput/swift-build-mass-failure.txt`, taken the way `PROVENANCE.md` describes. Its numbers are the acceptance case: 4,062 lines and 1,040 `error:` lines reduce to 200 distinct errors, and those 200 are one signature.
@Suite(.temporaryDirectories)
struct RunErrorShapeTests {
    @Test
    func twoHundredDistinctErrorsAreOneKindOfError() throws {
        let raw = try TestSources.runOutput(Self.mass)
        let shape = try Self.shape(ofCapture: Self.mass, changedFiles: RunChangedFiles.of([]))

        // Reconciles against the capture itself: the compiler printed the sentence 1,040 times, the filter deduplicated it to 200 by location, and the census reduces those 200 to what they are.
        #expect(raw.components(separatedBy: "error: ").count - 1 == 1040)
        #expect(shape.errors.count == 200)
        #expect(shape.census.signatures.count == 1)
        #expect(shape.census.fileCount == 40)
    }

    @Test
    func theBlockThatWasTwoHundredLinesIsTwo() throws {
        let shape = try Self.shape(ofCapture: Self.mass, changedFiles: RunChangedFiles.of(["Sources/Big/Helper.swift"]))
        let block = shape.rendered()

        // The helper is the file that changed, and not one of the 200 errors is in it — which for a build is the answer, not a footnote: the blast radius is everywhere except where the edit was.
        #expect(block == [
            "200 errors · 1 signature · 40 files · 0 in changed files (matched by name)",
            "  Sources/Big/Call8.swift:2:9: error: incorrect argument label in call (have '_:width:', expected '_:columns:')  ×200",
        ])
        #expect(block.joined(separator: "\n").utf8.count < 200)
        // What a full listing would cost, measured the same way.
        #expect(shape.errors.map { "  \($0.described)" }.joined(separator: "\n").utf8.count > 20000)
    }

    @Test
    func anErrorInAFileTheTreeChangedIsCountedByItsFilename() throws {
        let shape = try Self.shape(ofCapture: Self.mass, changedFiles: RunChangedFiles.of(["Sources/Big/Call8.swift"]))

        // The path git reports and the path the compiler printed meet on the name alone; that file holds five of the calls.
        #expect(shape.census.inChangedFiles == .count(5))
        #expect(try #require(shape.rendered().first).hasSuffix("5 in changed files (matched by name)"))
    }

    /// A handful of errors is still every error, in the compiler's own form, under the measurements that classify them.
    ///
    /// The measurement line stands over a listing as well as over a sample, though `2 errors · 2 signatures · 1 file` might seem to say nothing the two lines beneath it do not. It says one thing they do not: whether the two are one problem or two, which over these two answers is the difference between one missing symbol and two unrelated mistakes — and the reader who works that out by eye is doing the counting this line exists to do.
    @Test
    func aHandfulOfErrorsIsListedInFullUnderItsMeasurements() throws {
        let build = try Self.answer(ofCapture: "swift-build-failure", kind: .swiftBuild, directory: "/Users/dev/Widget", exitCode: 1)
        let duplicated = try Self.answer(ofCapture: "xcodebuild-build-failure-dup", kind: .xcodebuild, directory: "/Users/dev/Gizmo", exitCode: 65)

        #expect(build.contains("""
        2 errors · 2 signatures · 1 file · changed files unknown — the working tree was not consulted
          Sources/Widget/Broken.swift:4:9: error: cannot find 'missingSymbol' in scope
          Sources/Widget/Broken.swift:8:9: error: cannot convert return expression of type 'Int' to return type 'String'
        """))
        #expect(duplicated.contains("""
        2 errors · 2 signatures · 1 file · changed files unknown — the working tree was not consulted
          Sources/Gizmo/Gizmo.swift:4:30: error: cannot find type 'MissingWidget' in scope
          Sources/Gizmo/Gizmo.swift:6:16: error: cannot find 'MissingWidget' in scope
        """))
        // Complete, so neither answer carries a sample's disclosure or a sample's multiplier.
        #expect(!build.contains("more signature"))
        #expect(!build.contains("  ×"))
        #expect(!duplicated.contains("more signature"))
        #expect(!duplicated.contains("  ×"))
    }

    /// Eight compile errors that reduce to eight signatures are all eight listed, because there is no shape in them to report.
    ///
    /// The acceptance case for the whole rule, and a real capture: `Fixtures/RunOutput/swift-build-diverse-failure.txt`, eight unrelated mistakes in eight files. A cap of five would serve the reader some of them and a line saying the rest were withheld — every one of which has to be fixed, so the raw log has to be opened anyway, which is the entire cost this command exists to remove. The line above them still says `8 signatures`, which is exactly the reading that makes listing them right.
    @Test
    func aBuildWhoseErrorsAreAllDistinctListsEveryOneOfThem() throws {
        let shape = try Self.shape(ofCapture: Self.diverse, changedFiles: RunChangedFiles.of([]), under: "/Users/dev/Motley/")
        let block = shape.rendered()
        let raw = try TestSources.runOutput(Self.diverse).utf8.count

        #expect(block == [
            "8 errors · 8 signatures · 8 files · 0 in changed files (matched by name)",
            "  Sources/Motley/E.swift:1:36: error: cannot assign to value: 'y' is a 'let' constant",
            "  Sources/Motley/H.swift:2:36: error: incorrect argument label in call (have 'b:', expected 'a:')",
            "  Sources/Motley/C.swift:1:15: error: type 'Gamma' does not conform to protocol 'Comparable'",
            "  Sources/Motley/G.swift:2:35: error: cannot convert value of type 'String' to expected argument type '[Int]'",
            "  Sources/Motley/F.swift:2:21: error: errors thrown from here are not handled",
            "  Sources/Motley/A.swift:1:25: error: cannot convert value of type 'String' to specified type 'Int'",
            "  Sources/Motley/B.swift:1:22: error: cannot find 'undefinedSymbol' in scope",
            "  Sources/Motley/D.swift:1:33: error: cannot convert return expression of type 'Int' to return type 'String'",
        ])
        // Complete: nothing withheld, and the block is a fraction of the log it stands for.
        #expect(!block.contains { $0.contains("see the raw log") })
        #expect(block.joined(separator: "\n").utf8.count < raw / 4)
    }

    /// The form turns on the size of the listing and on nothing else — one error under the budget is listed, and the same one over it is measured.
    ///
    /// Two shapes a count could not tell apart: both hold a single error with a single signature, and what separates them is how much that error prints. This is the rule stated at its own boundary, which is the only place the arithmetic is checkable — the pair either side of it differ by one byte of message.
    @Test
    func aListingIsServedWhileItFitsTheBudgetAndMeasuredOnceItDoesNot() {
        let overhead = "  Sources/Widget/File0.swift:1:1: error: cannot find '' in scope".utf8.count
        // A lone error lists with no measurement line above it, so the entry alone meets the budget.
        let room = RunFailureCensus.listingBudget - overhead - 1

        let fitting = Self.shape(ofErrorsNamed: [String(repeating: "a", count: room)]).rendered()
        let overflowing = Self.shape(ofErrorsNamed: [String(repeating: "a", count: room + 1)]).rendered()

        #expect(fitting.count == 1)
        // The largest listing this block will ever serve. One byte short of the budget rather than on
        // it, because the budget charges every line for the newline that follows it in the answer the
        // block is spliced into, and the last line's is not inside the block.
        #expect(fitting.joined(separator: "\n").utf8.count == RunFailureCensus.listingBudget - 1)
        #expect(fitting[0].hasSuffix("' in scope"))
        // One byte more and the listing is gone; what replaces it is the clipped example, and a lone
        // error's sample leads with no measurement line either.
        #expect(overflowing.count == 1)
        #expect(overflowing[0].hasSuffix(" characters — see the raw log)"))
        #expect(overflowing.joined(separator: "\n").utf8.count < 400)
    }

    /// A compile error's signature is its own sentence, so there is no `↳ top:` line to print.
    ///
    /// The elisions are string literals, numbers and hex addresses — what a *test* failure's message is about. A compiler quotes types and names with `'…'` and this normalisation leaves those alone, so the top line would restate the example directly beneath it.
    @Test
    func theTopSignatureIsNeverNamedAboveItsOwnExample() throws {
        let shape = try Self.shape(ofCapture: Self.mass, changedFiles: RunChangedFiles.of([]))
        let top = try #require(shape.census.signatures.first)

        #expect(top.count == 200)
        #expect(top.signature.text == "incorrect argument label in call (have '_:width:', expected '_:columns:')")
        #expect(!shape.rendered().contains { $0.hasPrefix("  ↳ top:") })
    }

    /// An `Undefined symbols` block is one error whose detail is the answer, and it survives in both forms.
    @Test
    func anUndefinedSymbolsBlockKeepsItsSymbolListWhicheverFormTheBlockTakes() throws {
        let listed = try Self.answer(ofCapture: "swift-test-linkerror", kind: .swiftTest, directory: "/Users/dev/Widget", exitCode: 1)
        let crowded = Self.shape(ofErrorsNamed: Array(repeating: "alpha", count: Self.crowd), alsoLinking: true).rendered()

        #expect(listed.contains("""
          Undefined symbols for architecture arm64:
            "_widget_missing_helper", referenced from:
                Widget.callMissingHelper() -> Swift.Int in Linkless.swift.o
          ld: symbol(s) not found for architecture arm64
          clang: error: linker command failed with exit code 1 (use -v to see invocation)
        """))
        // And crowded out of a listing by a hundred compile errors it still keeps every line the linker hung under it.
        #expect(crowded.first == "\(Self.crowd + 1) errors · 2 signatures · \(Self.crowd) files · 0 in changed files (matched by name)")
        #expect(crowded.contains("  Sources/Widget/File0.swift:1:1: error: cannot find 'alpha' in scope  ×\(Self.crowd)"))
        #expect(crowded.contains("  Undefined symbols for architecture arm64:"))
        #expect(crowded.contains("    \"_widget_missing_helper\", referenced from:"))
        #expect(crowded.contains("        Widget.callMissingHelper() -> Swift.Int in Linkless.swift.o"))
        #expect(crowded.contains("  ld: symbol(s) not found for architecture arm64"))
    }

    /// A message is clipped only where the block is already a sample, because a listing's whole claim is that it is complete.
    ///
    /// The two forms are reached the way the rule says: the same 300-character message is kept whole in a listing that fits, and clipped in a block whose listing did not — here because a hundred errors stand beside it, rather than because someone counted to six.
    @Test
    func anEnormousMessageIsClippedInASampleAndKeptWholeInAListing() throws {
        // Two signatures, so the cap cannot withhold the line under test whichever way they rank.
        let long = String(repeating: "a", count: RunFailureCensus.wordsCap + 60)
        let measured = Self.shape(ofErrorsNamed: [long] + Array(repeating: "zeta", count: Self.crowd)).rendered()
        let listed = Self.shape(ofErrorsNamed: [long, "alpha"]).rendered()
        let clipped = try #require(measured.first(where: { $0.contains("aaa") }))

        #expect(clipped.hasSuffix(" characters — see the raw log)"))
        // The location leads the line, so what a clip takes is always the tail of the sentence and never where to go.
        #expect(clipped.hasPrefix("  Sources/Widget/File0.swift:1:1: error: cannot find 'aaa"))
        #expect(measured.allSatisfy { $0.count < RunFailureCensus.wordsCap + 80 })
        #expect(listed.contains("  Sources/Widget/File0.swift:1:1: error: cannot find '\(long)' in scope"))
    }

    /// Two files of one name in different directories are two files, and the field that says how far the failure spread counts them as two.
    ///
    /// A census keyed on the *filename* makes `Tests/AlphaTests/HelpersTests.swift` and `Tests/BetaTests/HelpersTests.swift` one file — the field a reader uses to judge whether a failure is localized or wide, understated twofold, with nothing on the line to say it is a name match. The `in changed files` field beside it carries `(matched by name)` because it has no choice: git prints paths and a Swift Testing issue line prints none, so that comparison can only meet on the name. This one *does* have a choice wherever the compiler printed a directory.
    @Test
    func twoFilesOfOneNameInDifferentDirectoriesAreTwoFiles() throws {
        let paths = ["Tests/AlphaTests/HelpersTests.swift", "Tests/BetaTests/HelpersTests.swift"]
        let shape = Self.shape(ofErrorsAt: paths + paths + paths, changedFiles: .of(["web/Tests/HelpersTests.swift"]))

        #expect(shape.census.fileCount == 2)
        // The reduction to a filename survives in one place: it is what the changed-files signal compares
        // on, because a name is still all the other side of that comparison has.
        #expect(shape.census.inChangedFiles == .count(6))
        #expect(try #require(shape.rendered().first).hasPrefix("6 errors · 1 signature · 2 files · "))
    }

    /// A build failure asks the working tree what it changed, rather than answering zero on its behalf — whichever form its errors take.
    ///
    /// Fetched only for test failures, the signal would leave a shaped build answer printing *0 in changed files* — a statement that git was asked and reported nothing — over a question nobody put to it. `RunChangedFiles` names that as the one reading its `.unavailable` case exists to prevent. The measurement line stands over a listing too, so two errors state the number as much as two hundred do, and the fetch has to follow the field rather than the form.
    @Test
    func aBuildFailureConsultsTheWorkingTreeRatherThanClaimingZero() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("public func call8() {}\n", to: "Sources/Big/Call8.swift", in: root)
        try TestSources.commitAll(in: root, message: "add")
        try TestSources.write("public func call8() -> Int { 1 }\n", to: "Sources/Big/Call8.swift", in: root)
        let report = try TestSources.runReport(Self.mass)
        let handful = try TestSources.runReport("swift-build-failure")

        let inRepository = RunOutcome(kind: .swiftBuild, logKey: "swift build", exitCode: 1, report: report, log: nil, repositoryRoot: root)
        let outside = RunOutcome(kind: .swiftBuild, logKey: "swift build", exitCode: 1, report: report, log: nil, repositoryRoot: nil)
        let listed = RunOutcome(kind: .swiftBuild, logKey: "swift build", exitCode: 1, report: handful, log: nil, repositoryRoot: root)

        #expect(report.testFailures.isEmpty)
        #expect(try #require(inRepository.filteredAnswer(workingDirectory: root)).text.contains("5 in changed files (matched by name)"))
        // Outside a checkout there is no number, and the answer says which rather than rounding it to zero.
        #expect(try #require(outside.filteredAnswer(workingDirectory: root)).text.contains("changed files unknown — not a git repository"))
        // And two errors print the field, so the `git` process that finds it is paid for over them too.
        #expect(try #require(listed.filteredAnswer(workingDirectory: root)).text.contains("2 errors · 2 signatures · 1 file · 0 in changed files (matched by name)"))
    }

    /// Eighty-five copies of one sentence are a shape whatever they weigh, and a rule that only weighs them lets them through at 6 KB.
    ///
    /// The case a size rule cannot see. A size measures what redundancy *costs*, never that there is any, so a listing of one signature that happens to fit would be served in full: 85 errors, 91 lines of answer, every one of them the same sentence under a measurement line that has already said `1 signature`. That is not verbosity at the margin — it is the compression this command exists for, not happening, on exactly the shape it was built for.
    @Test
    func aListingThatIsChieflyOneSentenceRepeatedIsServedAsTheShapeItHas() {
        let shape = Self.shape(ofErrorsNamed: Array(repeating: "alpha", count: Self.repeated))

        // Size alone would have served every one of them, which is the point: the budget is not what
        // refuses this listing, and nothing that measures bytes ever could be. The weight comes from
        // the block that composes listings — see ``TestSources/listingBytes(of:)-(RunErrorShape)``.
        #expect(TestSources.listingBytes(of: shape) < RunFailureCensus.listingBudget)
        #expect(shape.census.signatures.count == 1)
        #expect(shape.rendered() == [
            "\(Self.repeated) errors · 1 signature · \(Self.repeated) files · 0 in changed files (matched by name)",
            "  Sources/Widget/File0.swift:1:1: error: cannot find 'alpha' in scope  ×\(Self.repeated)",
        ])
    }

    /// The redundancy rule turns at two boundaries over the count, and each is asserted at the step either side of it.
    ///
    /// **Half the listing**, because that is the only point on the axis that is not a tuned constant: ten errors over five kinds is one copy each and still chiefly content, and the eleventh is the one that makes it chiefly copies. **And ``RunFailureCensus/signatureCap`` as the floor**, because a sample prints up to five examples: five copies of one error are five files to open and a block of five examples has nothing to compress them into, while the sixth is the first that a shape can actually stand in for.
    ///
    /// Five kinds rather than six, because six is past the rule's *third* boundary — the sample cannot show them all — and the case below is what that boundary is for. Which is also why the shape here withholds no signature: this rule only ever fires where every kind fits in the sample it falls back to.
    @Test
    func theRepetitionRuleTurnsAtHalfTheListingAndAtTheFloorUnderIt() {
        let kinds = ["alpha", "beta", "gamma", "delta", "epsilon"]
        #expect(kinds.count == RunFailureCensus.signatureCap)

        // Half: one copy of each kind is listed, and the copy that tips it past half is not.
        #expect(Self.shape(ofErrorsNamed: kinds + kinds).rendered().count == 1 + kinds.count * 2)
        let sampled = Self.shape(ofErrorsNamed: kinds + kinds + ["alpha"]).rendered()
        #expect(sampled.count == 1 + kinds.count)
        #expect(!sampled.contains { $0.contains("see the raw log") })

        // The floor: the shape cannot be smaller than the examples it prints, so it does not replace a
        // listing that is not.
        let cap = RunFailureCensus.signatureCap
        #expect(Self.shape(ofErrorsNamed: Array(repeating: "alpha", count: cap)).rendered().count == 1 + cap)
        #expect(Self.shape(ofErrorsNamed: Array(repeating: "alpha", count: cap + 1)).rendered().count == 2)
    }

    /// More kinds than a sample can show is never a shape, however lopsided the ratio — because the shape would withhold the kinds it has no room for.
    ///
    /// **The defect this rule is founded against, one kind past the case that names it.** Twenty-one errors over ten distinct symbols are more than twice as many errors as kinds and far past the floor, so those two terms alone would make them a shape: five kinds illustrated, and `zeta`, `eta`, `theta`, `iota` and `kappa` reachable only from the raw log under `+5 more signatures, covering 6 errors`. That is five separate problems, each needing its own fix, withheld from an answer whose whole purpose is to save opening the log — the same loss a fixed cap inflicts on nine errors in nine files.
    ///
    /// And nothing else would have caught it: the listing is 22 lines and well under the 8 KB budget, so both sizes accept it — which is why this test asserts that before it asserts the block. A shape is lossless only where the sample it falls back to can carry every kind, which is what ``RunFailureCensus/signatureCap`` bounds.
    @Test
    func moreKindsThanASampleCanShowAreListedHoweverMuchTheyRepeat() {
        let illustrated = ["alpha", "beta", "gamma", "delta", "epsilon"]
        let withheld = ["zeta", "eta", "theta", "iota", "kappa"]
        let shape = Self.shape(ofErrorsNamed: illustrated.flatMap { Array(repeating: $0, count: 3) } + ["zeta"] + withheld)
        let block = shape.rendered()

        #expect(shape.census.count == 21)
        #expect(shape.census.signatures.count == 10)
        // The two terms that would otherwise be the whole rule both hold, so on them alone this listing is a shape.
        #expect(shape.census.count > 2 * shape.census.signatures.count)
        #expect(shape.census.count > RunFailureCensus.signatureCap)
        // And neither size refuses it, which is why nothing else stands in front of the loss.
        #expect(block.joined(separator: "\n").utf8.count < RunFailureCensus.listingBudget)

        #expect(block.count == 1 + shape.census.count)
        #expect(withheld.allSatisfy { kind in block.contains { $0.hasSuffix("error: cannot find '\(kind)' in scope") } })
        #expect(!block.contains { $0.contains("see the raw log") })
    }
}

private extension RunErrorShapeTests {
    static var mass: String {
        "swift-build-mass-failure"
    }

    static var diverse: String {
        "swift-build-diverse-failure"
    }

    /// Enough one-line errors that listing them outgrows ``RunFailureCensus/listingBudget`` — the only thing that decides the form.
    ///
    /// Two hundred rather than a number worked back from the budget: each test that uses it asserts the measured form it expects, so a budget that moved far enough to change the answer fails the test that named it rather than passing quietly on the other branch.
    static let crowd = 200

    /// The size the case is reproduced at: 85 errors of one kind, whose listing fits ``RunFailureCensus/listingBudget`` at about 6 KB.
    static let repeated = 85

    static func shape(ofCapture name: String, changedFiles: RunChangedFiles, under prefix: String = "/Users/dev/Big/") throws -> RunErrorShape {
        let report = try TestSources.runReport(name)
        return RunErrorShape.of(report.errors.map { Self.relativised($0, under: prefix) }, changedFiles: changedFiles)
    }

    static func answer(ofCapture name: String, kind: RunCommandKind, directory: String, exitCode: Int32) throws -> String {
        let report = try TestSources.runReport(name)
        return RunReportRenderer(kind: kind, workingDirectory: URL(fileURLWithPath: directory))
            .render(report, exitCode: exitCode, logURL: nil)
    }

    /// One `cannot find 'missing' in scope` per path, each on a line of its own so nothing deduplicates, read through the filter that will feed the real thing.
    static func shape(ofErrorsAt paths: [String], changedFiles: RunChangedFiles) -> RunErrorShape {
        var filter = RunOutputFilter(expecting: .unreadable)
        for (index, path) in paths.enumerated() {
            filter.consume(line: "\(path):\(index + 1):1: error: cannot find 'missing' in scope")
        }
        return RunErrorShape.of(filter.finish().errors, changedFiles: changedFiles)
    }

    /// One `cannot find '<name>' in scope` per name, each in a file of its own, read through the filter that will feed the real thing.
    static func shape(ofErrorsNamed names: some Sequence<String>, alsoLinking: Bool = false) -> RunErrorShape {
        var filter = RunOutputFilter(expecting: .unreadable)
        for (index, name) in names.enumerated() {
            filter.consume(line: "Sources/Widget/File\(index).swift:1:1: error: cannot find '\(name)' in scope")
        }
        if alsoLinking {
            filter.consume(line: "Undefined symbols for architecture arm64:")
            filter.consume(line: "  \"_widget_missing_helper\", referenced from:")
            filter.consume(line: "      Widget.callMissingHelper() -> Swift.Int in Linkless.swift.o")
            filter.consume(line: "ld: symbol(s) not found for architecture arm64")
        }
        return RunErrorShape.of(filter.finish().errors, changedFiles: .of([]))
    }

    /// The capture's absolute paths as the renderer would state them, so the census counts the filenames a reader can see.
    static func relativised(_ diagnostic: RunDiagnostic, under prefix: String) -> RunDiagnostic {
        guard let path = diagnostic.path, path.hasPrefix(prefix) else {
            return diagnostic
        }
        return RunDiagnostic(
            severity: diagnostic.severity,
            path: String(path.dropFirst(prefix.count)),
            line: diagnostic.line,
            column: diagnostic.column,
            message: diagnostic.message,
            detail: diagnostic.detail
        )
    }
}
