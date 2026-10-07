//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers resolving a run's failure locations to the declarations they happened in, and every way that is allowed to come up empty.
///
/// The captured corpus cannot carry these: those transcripts were taken in other repositories, so their `ChartGridTests.swift:85` names no file in this tree and nothing about them is resolvable — which is itself one of the cases below. The fixtures here are real indexed repositories built to order, on the same terms as `SemanticWhereTests`.
@Suite(.temporaryDirectories)
struct RunFailureSitesTests {
    @Test
    func aFailureLocationResolvesToTheDeclarationItSitsIn() async throws {
        let root = try await Self.indexedRepo()

        let sites = RunFailureSites.resolving(["ChartGridTests.swift:10:9"], inRepositoryAt: root)
        let declaration = try #require(sites.declaration(at: "ChartGridTests.swift:10:9"))

        #expect(declaration.name == "ChartGridTests.theGridReflowsAtAccessibilitySizes()")
        #expect(declaration.path == Self.gridPath)
        #expect(declaration.startLine == 8)
        #expect(declaration.endLine == 11)
    }

    /// The framework prints the *test's* name over a line that belongs to a helper, and only the code settles which.
    ///
    /// This is the case the whole feature is for: three tests fail, the report names three tests, and the assertion that failed is in one shared function none of the three names. A wrapper that can only read the log cannot know that; a wrapper holding the index resolves it in the same answer.
    @Test
    func anAssertionInAHelperResolvesToTheHelperAndNotToTheTestThatWasNamed() async throws {
        let root = try await Self.indexedRepo()

        let sites = RunFailureSites.resolving(["ChartGridTests.swift:22:9"], inRepositoryAt: root)
        let declaration = try #require(sites.declaration(at: "ChartGridTests.swift:22:9"))

        #expect(declaration.name == "ChartGridTests.assertLayout(at:)")
        #expect(declaration.described == "ChartGridTests.assertLayout(at:) — \(Self.gridPath):20-23")
    }

    /// Swift Testing prints a bare filename and XCTest an absolute path, and a caller may hold a third spelling; all of them name one declaration.
    @Test
    func everySpellingOfOneLocationResolvesToTheSameDeclaration() async throws {
        let root = try await Self.indexedRepo()
        let absolute = root.appendingPathComponent(Self.gridPath).path
        let spellings = ["ChartGridTests.swift:22:9", "\(absolute):22", Self.gridPath + ":22:9"]

        let sites = RunFailureSites.resolving(spellings, inRepositoryAt: root)

        #expect(Set(spellings.compactMap { sites.declaration(at: $0)?.name }) == ["ChartGridTests.assertLayout(at:)"])
    }

    /// `run` wraps a toolchain command in any directory, indexed or not, and that must not regress.
    ///
    /// **The answer it must be is stated here, rather than compared against itself.** Asserting `rendered(sites: sites) == rendered(sites: .none)` one line after proving `sites == .none` compares a pure function over two values already shown equal, which cannot fail whatever the block does. What this is written to catch is the contract in its name, so that is what it says out loud: the block a repository that resolves nothing gets is the listing, every failure named, two lines each, under the measurement line that classifies them.
    @Test
    func anUnindexedRepositoryResolvesNothingAndTheAnswerIsExactlyWhatItWas() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.gridSource, to: Self.gridPath, in: root)
        try TestSources.commitAll(in: root, message: "sources, never indexed")
        let count = Self.crowdFitting()

        let sites = RunFailureSites.resolving([Self.helperLocation], inRepositoryAt: root)
        let block = Self.rendered(failures: Self.distinct(count), sites: sites)

        #expect(sites == .none)
        #expect(sites.declaration(at: Self.helperLocation) == nil)
        // A crowd, and not the handful at which a sample of five happens to print as many lines as a
        // listing of five — which is where a block that had stopped listing altogether would come to rest.
        #expect(count > RunFailureCensus.signatureCap)
        #expect(block.first == "\(count) failures · \(count) signatures · 1 file · 0 in changed files (matched by name)")
        #expect(block.count == 1 + count * 2)
        #expect(Self.distinct(count).allSatisfy { token in block.contains { $0.hasPrefix("  aTestNamed\(token)()") } })
        #expect(!block.contains { $0.contains("(syntactic)") })
        #expect(!block.contains { $0.contains("see the raw log") })
    }

    /// There is nothing in `Helpers.swift:12` that says which `Helpers.swift`, so neither answers.
    @Test
    func aFilenameNamingTwoFilesResolvesToNeitherOfThem() async throws {
        let root = try await Self.indexedRepo(extraFiles: [
            "Tests/AlphaTests/Helpers.swift": "struct AlphaHelpers {\n    func help() {}\n}\n",
            "Tests/BetaTests/Helpers.swift": "struct BetaHelpers {\n    func help() {}\n}\n",
        ])

        let sites = RunFailureSites.resolving(["Helpers.swift:2:5", "ChartGridTests.swift:22:9"], inRepositoryAt: root)

        #expect(sites.declaration(at: "Helpers.swift:2:5") == nil)
        // The ambiguity is per filename and takes nothing else down with it.
        #expect(sites.declaration(at: "ChartGridTests.swift:22:9")?.name == "ChartGridTests.assertLayout(at:)")
    }

    /// The file most likely to hold a failure is the file just edited, and the index's stored line ranges are the one thing about it guaranteed to be behind.
    ///
    /// Nothing here reindexes: the repository is indexed once, the file is then rewritten with eight lines pushed in above it, and the resolution has to describe the code as it is on disk now. The shift is chosen so a stale answer would not merely be absent but *wrong* — line 22 was inside `assertLayout(at:)` when the index was built and is inside `theGridKeepsItsHeadings()` now, which is a confident wrong declaration attached to a real failure.
    @Test
    func aFileEditedSinceTheIndexWasBuiltResolvesAgainstWhatIsOnDiskNow() async throws {
        let root = try await Self.indexedRepo()
        let shifted = String(repeating: "// pushed down\n", count: 8) + Self.gridSource
        let (helper, test) = ("ChartGridTests.swift:30:9", "ChartGridTests.swift:22:9")
        try TestSources.write(shifted, to: Self.gridPath, in: root)

        let sites = RunFailureSites.resolving([helper, test], inRepositoryAt: root)
        let declaration = try #require(sites.declaration(at: helper))

        #expect(declaration.name == "ChartGridTests.assertLayout(at:)")
        #expect(declaration.startLine == 28)
        #expect(declaration.endLine == 31)
        // The line the helper used to hold is the test that holds it now, and never the other way round.
        #expect(sites.declaration(at: test)?.name == "ChartGridTests.theGridKeepsItsHeadings()")
    }

    /// A budget already spent is the deterministic stand-in for a machine too slow to make it: the answer goes out with no resolution, and what the repository knows decides nothing but that one line.
    ///
    /// **Stated against the resolved answer rather than against itself**, which is the comparison that has something to say. The failure it is written to catch is the tool printing *less* the *more* it knows — a crowd that lists with no index beside it being sampled with one — so the count comes from ``crowdFitting()``, the widest listing the *unresolved* form fits, and the assertion is that the resolved form is still a listing there. Taking the resolved form's own boundary would make the test unfailable: the unresolved form fits everywhere the resolved one does.
    @Test
    func anExhaustedBudgetLeavesTheAnswerExactlyAsItWas() async throws {
        let root = try await Self.indexedRepo()
        let resolved = RunFailureSites.resolving([Self.helperLocation], inRepositoryAt: root)
        let count = Self.crowdFitting()
        let failures = Self.distinct(count)

        let spent = RunFailureSites.resolving([Self.helperLocation], inRepositoryAt: root, within: -1)
        let withSites = Self.rendered(failures: failures, sites: resolved)
        let without = Self.rendered(failures: failures, sites: spent)

        #expect(spent == .none)
        #expect(count > RunFailureCensus.signatureCap)
        // Both are the listing, and what resolution adds is one line to each entry and nothing else.
        #expect(Self.distinct(count).allSatisfy { token in without.contains { $0.hasPrefix("  aTestNamed\(token)()") } })
        #expect(withSites.first == "\(count) failures · \(count) signatures · 1 file · 0 in changed files (matched by name)")
        #expect(withSites.count == 1 + count * 3)
        #expect(without.first == withSites.first)
        #expect(without.count == 1 + count * 2)
        #expect(!without.contains { $0.contains("(syntactic)") })
        #expect(withSites.filter { $0.hasPrefix("    in ") }.count == count)
    }

    /// The same run takes the same form whether or not the repository resolved anything — resolution adds lines to an answer and never takes one away.
    ///
    /// **The invariant, asserted directly, because it is what the whole separation of measuring from printing is for.** Reproduced on a package of 80 distinct failing tests in one file: with no index beside the log all 80 were named, and after a `sift digest .` the same command sampled to five and withheld 70 test names — the tool printing *less* the more it knew, because the `in …` line each entry gained was charged to the budget like a line the run had printed. `RunFailureSites` also gives up wholesale on its two-second deadline, so the unresolved answer is equally what a loaded machine gets: one run, two answers, decided by nothing the reader can see.
    ///
    /// Stated at the listing boundary **and one past it**, so what it says is *the same form* rather than *always a listing*: at ``crowdFitting()`` both list, at one more both measure, and in both cases the resolved answer is the unresolved one with a site line under each entry.
    @Test
    func anAnswerTakesTheSameFormWhetherOrNotTheRepositoryResolvedAnything() async throws {
        let root = try await Self.indexedRepo()
        let resolved = RunFailureSites.resolving([Self.helperLocation], inRepositoryAt: root)
        let fitting = Self.crowdFitting()

        for count in [fitting, fitting + 1] {
            let withSites = Self.rendered(failures: Self.distinct(count), sites: resolved)
            let without = Self.rendered(failures: Self.distinct(count), sites: .none)

            // Take away what the repository added and the two are the same text, line for line.
            #expect(withSites.filter { !$0.hasPrefix("    in ") } == without)
            #expect(withSites.count > without.count)
        }
        // And the forms either side of the boundary are the ones named above, so neither assertion
        // above is being satisfied by two answers that are both samples.
        #expect(Self.rendered(failures: Self.distinct(fitting), sites: resolved).count == 1 + fitting * 3)
        #expect(Self.rendered(failures: Self.distinct(fitting + 1), sites: resolved).count
            == 1 + RunFailureCensus.signatureCap * 3 + 1)
    }

    /// The lines a resolution adds are lines the answer prints, so the log it stands for is charged for them.
    ///
    /// **The receipt is what makes this a defect rather than a preference.** ``RunReportRenderer/allowance(of:beside:)`` exists so an answer is never longer than the log it replaces, and it was charged ``RunFailureCensus/Entry/charged`` — the lines the run itself printed — while the block appended ``RunFailureCensus/Entry/lines``. On an indexed checkout every listed failure gains one, so a 110-line log of 52 resolving failures was charged 105 lines, printed 162, and closed on `sift run: 110 lines in, 162 out`: the wrapper stating in its own arithmetic that it had expanded what it exists to compress, and doing so only where the repository had something to add. On a loaded machine, where the resolution is abandoned on its deadline, the same run read `110 lines in, 110 out` — so the answer's size and the receipt's honesty both swung on the weather.
    ///
    /// **The log's length is derived rather than written down**: it is exactly as long as the answer that names every failure, which is the shortest log for which listing them is still a saving and so the one place this charge decides anything.
    ///
    /// The size budget still exempts those lines, deliberately, and the line above asserting the listing over a longer log is what says so. The two bounds are not in conflict — one decides which *form* the answer takes and may not be moved by anything the reader brought with them, and this one bounds how *long* it is against the thing it replaces.
    @Test
    func theLinesTheRepositoryAddsAreChargedToTheLogTheAnswerStandsFor() async throws {
        let root = try await Self.indexedRepo()
        let sites = RunFailureSites.resolving([Self.helperLocation], inRepositoryAt: root)
        let count = 52
        let named = Self.answer(to: Self.report(failures: count, over: .max), sites: .none)
        let report = Self.report(failures: count, over: named.count)

        let resolved = Self.answer(to: report, sites: sites)

        // The listing exactly fills the log it stands for, and names every failure in it.
        #expect(Self.answer(to: report, sites: .none).count == report.totalLines)
        #expect(Self.distinct(count).allSatisfy { token in named.contains { $0.hasPrefix("  aTest\(token)()") } })
        // The size budget is not what decides this: over a log long enough to afford them, the resolved
        // answer is that same listing with one line more beneath each entry.
        #expect(Self.answer(to: Self.report(failures: count, over: 1000), sites: sites).count == named.count + count)
        // And under this log it is the shape, because an answer may not be longer than what it replaces.
        #expect(resolved.count <= report.totalLines)
        #expect(resolved.contains { $0.hasPrefix("  +\(count - RunFailureCensus.signatureCap) more signatures") })
        #expect(resolved.last == "raw: none (\(report.totalLines) lines in, \(resolved.count) out) — the raw log could not be written, so what is above is all there is")
    }

    /// The case this branch established, and the one the charge above may not cost: a red suite whose log affords the listing names every test, indexed or not.
    ///
    /// Eighty distinct failures over a 260-line log: the unresolved answer runs to 165 lines and the resolved one to 245, and both sit inside the log they stand for. Charging a resolved line against the log is a bound on length, and it must never become the defect above wearing a new hat — the tool printing fewer names the more it knows.
    @Test
    func anIndexedAndAnUnindexedRunOfOneRedSuiteBothNameEveryTest() async throws {
        let root = try await Self.indexedRepo()
        let sites = RunFailureSites.resolving([Self.helperLocation], inRepositoryAt: root)
        let report = Self.report(failures: 80, over: 260)

        let unresolved = Self.answer(to: report, sites: .none)
        let resolved = Self.answer(to: report, sites: sites)

        #expect(unresolved.last == "raw: none (260 lines in, 165 out) — the raw log could not be written, so what is above is all there is")
        #expect(resolved.last == "raw: none (260 lines in, 245 out) — the raw log could not be written, so what is above is all there is")
        #expect(resolved.filter { $0.hasPrefix("    in ") }.count == 80)
        for answer in [unresolved, resolved] {
            // A listing in both: every test named, nothing standing for more than itself, nothing withheld.
            #expect(Self.distinct(80).allSatisfy { token in answer.contains { $0.hasPrefix("  aTest\(token)()") } })
            #expect(!answer.contains { $0.contains("  ×") })
            #expect(!answer.contains { $0.hasPrefix("  +") })
        }
    }

    /// The strong claim: every failure that reduced to one signature happened inside one declaration.
    ///
    /// `×6` on its own leaves the reader's real question open — six broken tests, or one helper six tests reach through. This is the line that settles it, and it is the one thing a tool holding only the log cannot say.
    @Test
    func everyFailureOfOneSignatureInOneDeclarationIsClaimedForAllOfThem() async throws {
        let root = try await Self.indexedRepo()
        let locations = Array(repeating: "ChartGridTests.swift:22:9", count: Self.crowd)
        let sites = RunFailureSites.resolving(locations, inRepositoryAt: root)

        let block = Self.rendered(locations: locations, sites: sites)

        #expect(block.contains("    all \(Self.crowd) are in ChartGridTests.assertLayout(at:) — \(Self.gridPath):20-23 (syntactic)"))
        #expect(!block.contains { $0.hasPrefix("    in ") })
    }

    /// `all` means all, so one failure the repository could not place withdraws the claim rather than being counted out of it.
    @Test
    func oneUnresolvedFailureWithdrawsTheClaimOverAllOfThem() async throws {
        let root = try await Self.indexedRepo()
        let locations = Array(repeating: "ChartGridTests.swift:22:9", count: Self.crowd - 1) + ["SomewhereElse.swift:4:1"]
        let sites = RunFailureSites.resolving(locations, inRepositoryAt: root)

        let block = Self.rendered(locations: locations, sites: sites)

        #expect(block.contains("    in ChartGridTests.assertLayout(at:) — \(Self.gridPath):20-23 (syntactic)"))
        #expect(!block.contains { $0.contains("all \(Self.crowd) are in") })
    }

    /// The captured corpus was taken in another repository, so nothing in it resolves here — and the answer is byte-identical to the one this command already gave.
    @Test
    func aCaptureFromAnotherRepositoryResolvesNothingAndChangesNothing() async throws {
        let root = try await Self.indexedRepo()
        let report = try TestSources.runReport("xcodebuild-test-execute-failure-environmental")
        let failures = report.testFailures.map {
            RunFailureShape.Failure(name: $0.name, location: $0.location, message: $0.message, arguments: $0.arguments, note: $0.note)
        }
        let sites = RunFailureSites.resolving(report.testFailures.compactMap(\.location), inRepositoryAt: root)

        let resolved = RunFailureShape.of(failures, changedFiles: .of([]), sites: sites).rendered()
        let bare = RunFailureShape.of(failures, changedFiles: .of([])).rendered()

        #expect(resolved == bare)
        #expect(!resolved.contains { $0.contains("(syntactic)") })
    }

    /// A failure in a file this repository does not hold is not attributed to a same-named file that it does.
    ///
    /// The location was reduced to `<filename>:<line>` and its directory thrown away, so `.build/checkouts/Dep/…/ChartGridTests.swift:22` resolved to the local file of that name and printed `in ChartGridTests.assertLayout(at:) — … (syntactic)` for a failure that never touched it. The ambiguity rule cannot catch this one: it only sees filenames naming two files *inside* the index, and `.build` is never indexed. `(syntactic)` is a marker the documentation tells readers to trust as a fact about bytes on disk, so a confident wrong one is the worst answer here.
    @Test
    func aFailureOutsideTheIndexIsNotAttributedToASameNamedFileInsideIt() async throws {
        let root = try await Self.indexedRepo()
        let dependency = root.appendingPathComponent(".build/checkouts/Dep/Tests/DepTests/ChartGridTests.swift").path + ":22:9"
        let inside = "ChartGridTests.swift:22:9"

        #expect(RunFailureSites.resolving([dependency], inRepositoryAt: root).declaration(at: dependency) == nil)
        // The spelling that carries no directory is unaffected — a bare filename constrains nothing, which
        // is the whole of what Swift Testing gives and what the ambiguity rule already covers.
        #expect(RunFailureSites.resolving([inside], inRepositoryAt: root).declaration(at: inside)?.name
            == "ChartGridTests.assertLayout(at:)")
        // And where both spellings reduce to one key, the key is refused rather than served to both: one
        // declaration cannot answer for a location inside the tree and one outside it.
        let contested = RunFailureSites.resolving([dependency, inside], inRepositoryAt: root)
        #expect(contested.declaration(at: inside) == nil)
    }

    /// A location printed with a directory has to agree with the one the index holds, whether it is absolute or relative.
    ///
    /// A relative spelling is not something either framework prints — the renderer does not make one before the block measures, since a location's width would then be the reader's — but ``resolving(_:inRepositoryAt:within:)`` takes whatever a caller holds, and a directory it does carry has to place the file rather than merely name it.
    @Test
    func aRelativeLocationMustEndTheIndexedPath() async throws {
        let root = try await Self.indexedRepo()
        let agreeing = Self.gridPath + ":22:9"
        let disagreeing = "Tests/SomeOtherTests/ChartGridTests.swift:22:9"

        #expect(RunFailureSites.resolving([agreeing], inRepositoryAt: root).declaration(at: agreeing)?.name
            == "ChartGridTests.assertLayout(at:)")
        #expect(RunFailureSites.resolving([disagreeing], inRepositoryAt: root).declaration(at: disagreeing) == nil)
    }

    /// Past the file cap the work stops, and which files it stopped at is decided by how many failures name them rather than by whichever the dictionary handed over first.
    @Test
    func theFileCapKeepsTheFilesMostOfTheFailuresNameAndDoesSoTheSameWayTwice() async throws {
        let spare = 4
        var extras: [String: String] = [:]
        for index in 0 ..< (RunFailureSites.fileCap + spare) {
            extras["Tests/SpreadTests/Spread\(String(format: "%02d", index)).swift"] = "struct Spread\(index) {\n    func check() {}\n}\n"
        }
        let root = try await Self.indexedRepo(extraFiles: extras)
        // One failure each, and two in the file that sorts last — which is the one the cap would drop if
        // the order were alphabetical rather than by how much of the run each file accounts for.
        let busiest = "Spread\(String(format: "%02d", RunFailureSites.fileCap + spare - 1)).swift:2:5"
        let locations = (0 ..< (RunFailureSites.fileCap + spare)).map {
            "Spread\(String(format: "%02d", $0)).swift:2:5"
        } + [busiest]

        let sites = RunFailureSites.resolving(locations, inRepositoryAt: root)
        let again = RunFailureSites.resolving(locations, inRepositoryAt: root)

        // The busiest file survives the cap however far down the alphabet it sits, and what the cap drops
        // is exactly the tail of the rest — an order-independent implementation would drop four at random.
        #expect(sites.declaration(at: busiest)?.name == "Spread\(RunFailureSites.fileCap + spare - 1).check()")
        let dropped = locations.filter { sites.declaration(at: $0) == nil }
        #expect(dropped == (RunFailureSites.fileCap - 1 ..< RunFailureSites.fileCap + spare - 1).map {
            "Spread\(String(format: "%02d", $0)).swift:2:5"
        })
        #expect(sites == again)
    }
}

private extension RunFailureSitesTests {
    static var gridPath: String {
        "Tests/LibTests/ChartGridTests.swift"
    }

    /// Two tests that call one helper, and the helper holds the expectation — the shape the resolution exists to expose.
    ///
    /// Line numbers are load-bearing here and are asserted rather than described: `theGridReflowsAtAccessibilitySizes()` is 8-11, `theGridKeepsItsHeadings()` 13-16, and `assertLayout(at:)` 20-23.
    static var gridSource: String {
        """
        //
        // Copyright © Agulhas Labs
        //

        import Testing

        struct ChartGridTests {
            @Test
            func theGridReflowsAtAccessibilitySizes() {
                assertLayout(at: 1)
            }

            @Test
            func theGridKeepsItsHeadings() {
                assertLayout(at: 2)
            }
        }

        extension ChartGridTests {
            func assertLayout(at index: Int) {
                let labels = "\\(index)"
                _ = labels.contains("Duration")
            }
        }

        """
    }

    /// A repository holding ``gridSource`` (and anything else asked for), committed and indexed.
    static func indexedRepo(extraFiles: [String: String] = [:]) async throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(gridSource, to: gridPath, in: root)
        for (path, source) in extraFiles {
            try TestSources.write(source, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "sources")
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// Enough failures of one kind that the block gives up listing them and measures instead.
    ///
    /// `all N are in …` is a claim only the *measured* form makes, so a test of that claim has to hand the block more than it will list. Six is not enough: six failures print in a dozen lines, and the rule under this is that a block that small says more by naming every one of them than by generalising over one signature. These all carry one message, so what refuses their listing is ``RunFailureCensus/isChieflyRepetition`` — which turns on the census alone and so cannot be reached by any amount of rendering, whichever form the entries take.
    static let crowd = 64

    /// The location every failure below is printed at: line 22 of the grid fixture, which sits inside `assertLayout(at:)`.
    static var helperLocation: String {
        "ChartGridTests.swift:22:9"
    }

    /// `count` failures at one location, each with a message nothing else shares.
    ///
    /// Distinct messages so the listing is refused for its *size* if it is refused at all — a crowd of one signature is refused as repetition whatever it weighs, which is the wrong boundary for a test about how wide an entry is. Spelled out of letters, since the normalisation elides digits.
    static func distinct(_ count: Int) -> [String] {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        return (0 ..< count).map { String([letters[$0 / 26], letters[$0 % 26]]) }
    }

    /// The widest listing ``RunFailureCensus/listingBudget`` still serves, measured on the entry the budget is actually charged for.
    ///
    /// Derived rather than written down, because the number *is* the subject and it moves whenever the width of an entry does — a constant would go on passing while that moved underneath it.
    ///
    /// **Measured on the entry with nothing resolved, which is the whole point.** A listing is charged what the *run* printed, so this one number is the boundary in both forms. Taking the resolved form's boundary instead would make the test that stands on it unable to fail: at the widest count a three-line entry fits, a two-line entry fits by construction, so a block that charged for resolution would sit comfortably inside a bound derived from itself. The flip is at `count + 1`, and the case worth asserting is the resolved form still listing at `count`.
    ///
    /// The estimate comes from one rendered entry and is walked down until the block is a listing, so it is the real boundary and not an arithmetic guess at one. The floor at one is there so a rule that never converges fails the assertions that use this rather than trapping inside ``distinct(_:)``.
    static func crowdFitting() -> Int {
        // A lone failure lists with no measurement line, so what it renders is the entry alone.
        let entry = rendered(failures: distinct(1), sites: .none)
        var count = RunFailureCensus.listingBudget / entry.reduce(0) { $0 + $1.utf8.count + 1 }
        while count > 1, rendered(failures: distinct(count), sites: .none).count != 1 + entry.count * count {
            count -= 1
        }
        return count
    }

    /// A report of `count` failures, each at ``helperLocation`` with a message nothing else shares, standing in for a log of `lines`.
    ///
    /// Narrower names and messages than ``rendered(failures:sites:)``'s, because the subject of the tests that use this is the *log's* bound and the size budget has to stay well clear of it: eighty entries at the wider spelling come to 9 KB and would be refused on their size, which is a different rule than the one under test.
    static func report(failures count: Int, over lines: Int) -> RunReport {
        RunReport(
            errors: [],
            warnings: [],
            testFailures: distinct(count).map {
                RunTestFailure(name: "aTest\($0)()", location: helperLocation, message: "the \($0) precondition does not hold")
            },
            summaryLines: [],
            contract: .runTally,
            verdict: nil,
            tally: nil,
            totalLines: lines
        )
    }

    /// That report as the whole answer a caller reads, with whatever this checkout resolved printed beneath each failure.
    static func answer(to report: RunReport, sites: RunFailureSites) -> [String] {
        RunReportRenderer(
            kind: .swiftTest,
            workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"),
            changedFiles: .of([]),
            sites: sites
        )
        .render(report, exitCode: 1, logURL: nil)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    }

    /// The classification block for `crowd` failures sharing one message, at `locations`.
    static func rendered(
        locations: [String] = Array(repeating: RunFailureSitesTests.helperLocation, count: RunFailureSitesTests.crowd),
        sites: RunFailureSites
    ) -> [String] {
        let failures = locations.map {
            RunFailureShape.Failure(name: "aTest()", location: $0, message: "Expectation failed: labels.contains(expected)")
        }
        return RunFailureShape.of(failures, changedFiles: .of([]), sites: sites).rendered()
    }

    /// The classification block for one failure per token in `failures`, all at ``helperLocation`` and each with its own message.
    static func rendered(failures: [String], sites: RunFailureSites) -> [String] {
        let failures = failures.map {
            RunFailureShape.Failure(
                name: "aTestNamed\($0)()",
                location: helperLocation,
                message: "Expectation failed: the \($0) labels do not contain the expected"
            )
        }
        return RunFailureShape.of(failures, changedFiles: .of([]), sites: sites).rendered()
    }
}
