//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the classification of a mass failure against the run that was green before it: two captures of one tree — of one *build*, even — minutes apart, one red and one green.
///
/// The numbers asserted here were measured before any of the classification was written, and they are what the throwaway package the captures come from was built to reproduce: 666 failures over 210 signatures in 53 files, the commonest covering 117 of them. That order is the point — a normalisation tuned until its own output flattered it would prove nothing, so the measurement came first and the code had to land on it. `Fixtures/RunOutput/PROVENANCE.md` records both.
struct RunFailureShapeTests {
    @Test
    func everyIssueTheRunReportedIsRead() throws {
        let capture = try TestSources.runOutput(Self.red)
        let failures = try Self.failures(inCapture: Self.red)

        // Reconciles against the run's own closing count: 667 issues, one of them known — and a known issue is not a failure.
        #expect(capture.contains("failed after 6.053 seconds with 667 issues (including 1 known issue)."))
        #expect(failures.count == 666)
    }

    @Test
    func sixHundredAndSixtySixFailuresAreTwoHundredAndTenKindsOfFailure() throws {
        let shape = try Self.shape(ofCapture: Self.red, changedFiles: RunChangedFiles.of([]))

        #expect(shape.failureCount == 666)
        #expect(shape.signatureCount == 210)
        #expect(shape.fileCount == 53)
    }

    @Test
    func theTopSignatureIsNamedOnceWithItsCount() throws {
        let shape = try Self.shape(ofCapture: Self.red, changedFiles: RunChangedFiles.of([]))
        let top = try #require(shape.topSignature)

        #expect(top.signature.text == #"Expectation failed: (labels → "…").contains(expected → "…")"#)
        #expect(top.count == 117)
        #expect(shape.signatures.prefix(4).map(\.count) == [117, 60, 30, 25])
    }

    @Test
    func oneSignatureCoversManyMessagesInManyFiles() throws {
        let shape = try Self.shape(ofCapture: Self.red, changedFiles: RunChangedFiles.of([]))
        let top = try #require(shape.topSignature)
        let covered = shape.failures.filter { RunFailureSignature(message: $0.message) == top.signature }

        // What the normalisation buys: 117 failures written 40 different ways, at 9 sites in 8 files, are one thing.
        #expect(covered.count == 117)
        #expect(Set(covered.map(\.message)).count == 40)
        #expect(Set(covered.compactMap(\.location)).count == 9)
        #expect(Set(covered.compactMap(\.path)).count == 8)
    }

    @Test
    func anAddressInADumpedViewTreeIsElided() throws {
        let failures = try Self.failures(inCapture: Self.red)
        let dumped = try #require(failures.first { $0.message.contains("0x0000000114b8b600") })
        let signature = RunFailureSignature(message: dumped.message)

        #expect(signature.text.contains("0x…"))
        #expect(!signature.text.contains("0x0000000114b8b600"))
    }

    @Test
    func whitespaceRunsDoNotChangeASignature() throws {
        let failures = try Self.failures(inCapture: Self.red)
        let message = try #require(failures.first).message
        let respaced = message.replacingOccurrences(of: " ", with: "   ")

        #expect(RunFailureSignature(message: respaced) == RunFailureSignature(message: message))
    }

    @Test
    func noneOfThemLandedInAFileTheTreeHadChanged() throws {
        let shape = try Self.shape(ofCapture: Self.red, changedFiles: RunChangedFiles.of([]))

        #expect(shape.inChangedFiles == .count(0))
    }

    @Test
    func aFailureInAChangedFileIsCountedByItsFilename() throws {
        let changed = RunChangedFiles.of(["Tests/DepotKitTests/BackorderTests.swift"])
        let shape = try Self.shape(ofCapture: Self.red, changedFiles: changed)

        // The path git reports and the bare filename the log prints meet on the name alone.
        #expect(shape.inChangedFiles == .count(7))
    }

    @Test
    func anUnavailableChangedFileSignalIsNeverRenderedAsZero() throws {
        let refusal = "not a git repository (or any of the parent directories): .git"
        let shape = try Self.shape(ofCapture: Self.red, changedFiles: .unavailable(refusal))
        let measurements = try #require(shape.rendered().first)

        #expect(shape.inChangedFiles == .unavailable(refusal))
        #expect(measurements.hasSuffix("changed files unknown — \(refusal)"))
        #expect(!measurements.contains("in changed files"))
    }

    @Test
    func theBlockSaysInADozenLinesWhatTheListingNeededAHundredKilobytesFor() throws {
        let shape = try Self.shape(ofCapture: Self.red, changedFiles: RunChangedFiles.of([]))
        let block = shape.rendered()
        let listing = shape.failures.flatMap { ["  \($0.name) — \($0.location ?? "")", "    \($0.message)"] }

        #expect(block.first == "666 failures · 210 signatures · 53 files · 0 in changed files (matched by name)")
        #expect(block[1] == #"  ↳ top: Expectation failed: (labels → "…").contains(expected → "…")  ×117"#)
        // Both halves of what was withheld: the five examples stand for 247 of the 666, so the 419 the
        // block neither shows nor illustrates are counted rather than left unaccounted for under a
        // heading that has just said 666.
        #expect(block.last == "  +205 more signatures, covering 419 failures — see the raw log")
        // A few of the five shown signatures are several tests sharing one message, so naming each of
        // them past the lead costs a handful more lines than one example per signature would — still a
        // couple of kilobytes beside the hundred the listing needs.
        #expect(block.joined(separator: "\n").utf8.count < 2500)
        #expect(listing.joined(separator: "\n").utf8.count > 100_000)
    }

    /// The five examples are one per signature, commonest first — not the first five failures the run printed.
    ///
    /// Taking them in printed order put five near-identical messages under a heading announcing 210 distinct ones: a listing that contradicted the line above it and spent the whole cap proving one thing five times. The red capture is the case that shows what that costs — the five failures at the head of its log stand for **67** of the 666 between them, where the five the block chooses stand for 247.
    @Test
    func theExamplesAreOnePerSignatureAndNotFivePrintingsOfOne() throws {
        // Built the way the renderer builds it — through `RunOutputFilter`, so the examples carry the
        // arguments a parameterized case failed under, which is half of what makes an example useful.
        let report = try TestSources.runReport(Self.red)
        let shape = RunFailureShape.of(
            report.testFailures.map {
                RunFailureShape.Failure(name: $0.name, location: $0.location, message: $0.message, arguments: $0.arguments, note: $0.note)
            },
            changedFiles: .of([])
        )
        let block = shape.rendered()

        let shown = shape.signatures.prefix(RunFailureCensus.signatureCap)
        #expect(Set(shown.map(\.signature)).count == RunFailureCensus.signatureCap)
        #expect(shown.map(\.count) == [117, 60, 30, 25, 15])

        // Both of these signatures are several distinct tests sharing one message — nine of them under
        // the top signature, five under the second — past `testsCap` for both, so no single line may
        // carry the whole signature's count: each named test's line carries only what it itself failed,
        // and the tests past the cap are counted on their own line rather than folded into one of them.
        #expect(!block.contains { !$0.hasPrefix("  ↳ top:") && $0.hasSuffix("  ×117") })
        #expect(!block.contains { !$0.hasPrefix("  ↳ top:") && $0.hasSuffix("  ×60") })
        #expect(block.contains { $0.contains("testOne(expected:)") && $0.hasSuffix("  ×20") })
        #expect(block.contains { $0.contains("testTwo(expected:)") && $0.hasSuffix("  ×18") })
        #expect(block.contains { $0.contains("testThree(expected:)") && $0.hasSuffix("  ×16") })
        #expect(block.contains("    +6 more tests under this signature (63 failures)"))
        #expect(block.contains { $0.contains("theGridReflows(name:)") && $0.hasSuffix("  ×16") })
        #expect(block.contains { $0.contains("theGridReflowsAfterARotation(name:)") && $0.hasSuffix("  ×14") })
        #expect(block.contains { $0.contains("theManifestSheetNamesTheBayItStandsInAndTheAisleBeyondIt(name:)") && $0.hasSuffix("  ×12") })
        #expect(block.contains("    +2 more tests under this signature (18 failures)"))

        // And they are chosen by how many failures they stand for rather than by the order the run
        // printed them: the five at the head of this log are a different set, and the signatures under
        // them cover 67 of the 666 where the five the block chose cover 247.
        let printedOrder = shape.failures.prefix(RunFailureCensus.signatureCap).map { RunFailureSignature(message: $0.message) }
        let printedCoverage = Set(printedOrder).reduce(0) { total, signature in
            total + (shape.signatures.first { $0.signature == signature }?.count ?? 0)
        }
        #expect(Set(printedOrder) != Set(shown.map(\.signature)))
        #expect(printedCoverage == 67)
        #expect(shown.map(\.count).reduce(0, +) == 247)
    }

    /// A message, a note or a set of arguments wider than the cap is clipped, and says how much it left behind.
    ///
    /// All three are unbounded input and one is pathological in this corpus — the red capture's dumped bay, a kilobyte of nodes and addresses in a single message. That alone puts a five-line block back over a kilobyte.
    ///
    /// **The arguments are the third, and the line a cap most easily misses.** Swift Testing prints whatever `description` the argument has, so `@Test(arguments:)` over a type with a long one puts a paragraph on the example line — one line above the message the same block is careful to bound at 240 characters.
    @Test
    func aDumpedViewTreeIsClippedRatherThanReprintedWhole() throws {
        let long = String(repeating: "x", count: RunFailureCensus.wordsCap + 60)
        let clipped = "\(String(repeating: "x", count: RunFailureCensus.wordsCap))… (+60 characters — see the raw log)"
        let shape = RunFailureShape.of(
            [RunFailureShape.Failure(name: "aTest()", location: "T.swift:1:1", message: long, arguments: long, note: long)],
            changedFiles: .of([])
        )
        let block = shape.rendered()

        #expect(block.contains("  aTest() with \(clipped) — T.swift:1:1"))
        #expect(block.contains("    \(clipped)"))
        #expect(block.contains("    ↳ \(clipped) (by adjacency)"))
        #expect(block.allSatisfy { $0.count < RunFailureCensus.wordsCap + 80 })

        // An ordinary expectation is untouched — the cap is for dumps, not for messages. Which specific
        // message a signature shows now depends on which of its tests ranks lead, so this asks for that
        // rather than for one fixed message tied to whichever test used to be first.
        let ordinary = try Self.shape(ofCapture: Self.red, changedFiles: RunChangedFiles.of([])).rendered()
        #expect(ordinary.contains { $0.hasPrefix("    Expectation failed:") && !$0.contains("more characters") })
    }

    /// The `↳ top:` line prints a failure's own words too, so it is bounded like every other line in this block that does.
    ///
    /// It is the easy one to leave unbounded, because the normalisation usually shrinks what it prints: the corpus's widest top line is 85 characters, since eliding the literals a message is *about* is most of its width. A message with no literals and no numbers in it survives normalisation whole — so, unbounded, the same sentence would be clipped at ``RunFailureCensus/wordsCap`` on the example line and printed in full on the line directly above it, in a block whose stated rule is that a failure's own words are bounded in both forms.
    ///
    /// It is also load-bearing for ``RunFailureCensus/listingBudget``'s floor, which, that budget being one answer's rather than one section's, rests on a sample being the listing's own entries plus two lines that are themselves bounded. An unbounded `↳ top:` is the counter-example to that, and it is the second line of the sample.
    @Test
    func theTopSignatureIsClippedLikeTheExampleBeneathIt() throws {
        // No literals, no numbers, no addresses — the three things the normalisation elides — so the
        // signature is as wide as the message, which is what puts it past the cap.
        let words = Array(repeating: "the accessibility label of the row", count: 12).joined(separator: ", ")
        let shape = RunFailureShape.of(
            (0 ..< 12).map { RunFailureShape.Failure(name: "aTest\($0)()", location: "T.swift:1:1", message: words) },
            changedFiles: .of([])
        )
        let block = shape.rendered()
        let signature = try #require(shape.topSignature).signature.text
        let top = try #require(block.first { $0.hasPrefix("  ↳ top:") })
        let example = try #require(block.first { $0.hasPrefix("    the accessibility") })

        #expect(signature.utf8.count > RunFailureCensus.wordsCap)
        #expect(!top.contains(signature))
        // The two lines carry the same bounded text, which is the rule this block states about itself.
        #expect(top.contains(example.trimmingCharacters(in: .whitespaces)))
        #expect(top.hasSuffix("characters — see the raw log)  ×12"))
    }

    /// The cap is bytes, because the budget it has to reconcile with is bytes — and 240 graphemes of CJK is three times that.
    ///
    /// ``RunFailureCensus/listingBudget``'s floor is the argument that a sample cannot come out larger than the listing it turned down, and it is arithmetic over the widest an ordinary sample gets: five entries carrying a capped message, note and argument list. A cap in *characters* does not bound that on the input this block is built for — a note is whatever sentence an author wrote above the expectation, in whatever language they wrote it — so a five-entry sample in a wide script could reach 15 KB and overrun the 8 KB listing it had just refused, which is the one incoherence the constant was sized to prevent. On the ASCII every capture in the corpus is written in the two units are the same number, which is why no fixture here can show it; this test is the one that does.
    @Test
    func aMessageInAWideScriptIsClippedByBytesAndOnACharacterBoundary() {
        let wide = String(repeating: "測", count: 200)
        // A grapheme cluster of four emoji and three joiners — 25 bytes and one Character, so a prefix
        // of the UTF-8 taken at the cap would cut inside it.
        let family = String(repeating: "👨‍👩‍👧‍👦", count: 20)

        #expect(RunFailureCensus.clipped(wide) == String(repeating: "測", count: 80) + "… (+120 characters — see the raw log)")
        #expect(RunFailureCensus.clipped(family) == String(repeating: "👨‍👩‍👧‍👦", count: 9) + "… (+11 characters — see the raw log)")
        // What the cap means, in the unit the budget beside it is written in.
        #expect(String(repeating: "測", count: 80).utf8.count == RunFailureCensus.wordsCap)
        #expect(String(repeating: "👨‍👩‍👧‍👦", count: 10).utf8.count > RunFailureCensus.wordsCap)
    }

    @Test
    func theGreenRunFromTheSameTreeHasNothingToClassify() throws {
        let capture = try TestSources.runOutput(Self.green)
        let shape = try Self.shape(ofCapture: Self.green, changedFiles: RunChangedFiles.of([]))

        // The same tree minutes earlier: a run that passed, and still carried a known issue.
        #expect(capture.contains("** TEST EXECUTE SUCCEEDED **"))
        #expect(capture.contains("recorded a known issue"))
        #expect(shape.failureCount == 0)
        #expect(shape.rendered().isEmpty)
    }

    /// Forty distinct failures are forty names, because a sample of five over forty kinds of failure is thirty-five tests the answer never mentions.
    ///
    /// A count threshold cannot tell this run from the one below it: under one, six distinct failures are served as a sample of five and the sixth name appears nowhere, and forty are served as a sample of five and thirty-five do. What separates a run worth sampling from one worth listing is not how many failures it has but how much listing them costs — so the block renders the listing and serves it while it fits ``RunFailureCensus/listingBudget``, and every one of these forty names reaches the reader.
    @Test
    func fortyDistinctFailuresAreEachNamedRatherThanSampledAtFive() {
        let listed = Self.shape(ofFailuresNamed: Self.names(40)).rendered()

        #expect(listed.first == "40 failures · 40 signatures · 40 files · 0 in changed files (matched by name)")
        #expect(listed.count == 1 + 40 * 2)
        #expect(Self.names(40).allSatisfy { name in
            listed.contains { $0.hasPrefix("  \(name)() — ") }
        })
        // Complete: no example stands for more than itself, and nothing is withheld.
        #expect(!listed.contains { $0.contains("  ×") })
        #expect(!listed.contains { $0.contains("see the raw log") })
    }

    /// And once naming them all outgrows the budget the block measures instead, with what it withheld accounted for.
    ///
    /// The same failures, three hundred of them: the listing is over 50 KB and the answer is seven lines. This is the half a count threshold gets right, reached here by the size of the answer rather than by a count that cannot tell fifty from five.
    @Test
    func threeHundredDistinctFailuresAreMeasuredInsteadOfNamed() {
        let measured = Self.shape(ofFailuresNamed: Self.names(300)).rendered()

        #expect(measured.first == "300 failures · 300 signatures · 300 files · 0 in changed files (matched by name)")
        #expect(measured.count == 1 + RunFailureCensus.signatureCap * 2 + 1)
        #expect(measured.last == "  +295 more signatures, covering 295 failures — see the raw log")
        #expect(measured.joined(separator: "\n").utf8.count < RunFailureCensus.listingBudget)
    }

    /// Failures the framework declared and never explained all carry one message, so they collapse to one signature — and every one of their names still has to reach the answer.
    ///
    /// This is the silent half: `appendUnexplainedFailures()` gives each of them the identical sentence, so three such failures reduce to one signature, one name and a `×3`, and `withheld` says nothing because nothing was withheld *by signature*. Two test names would vanish with nothing in the answer accounting for them.
    @Test
    func failuresSharingOneMessageStillNameEveryTestWithinTheBudget() {
        let unexplained = "failed with no message of its own — see the raw log"
        let names = ["theWellIsATarget()", "aGridReflows()", "aTrendIsRead()"]
        let shape = RunFailureShape.of(
            names.map { RunFailureShape.Failure(name: $0, location: nil, message: unexplained) },
            changedFiles: .of([])
        )
        let block = shape.rendered()

        // One signature, three failures — and three names.
        #expect(shape.signatureCount == 1)
        #expect(block.first == "3 failures · 1 signature · 0 files · 0 in changed files (matched by name)")
        #expect(names.allSatisfy { block.contains("  \($0)") })
        #expect(!block.contains { $0.contains("×3") })
    }

    /// And past the floor the same run is a shape, though naming every one of them would still have fit.
    ///
    /// This and the test above are the whole rule on this side, and nothing about their size tells them apart — both listings fit ``RunFailureCensus/listingBudget`` several times over. Three failures sharing one message are three names worth more than the two lines a shape would save. Twenty of them are one problem printed twenty times, and the reader who has to scroll them is doing the deduplication the measurement line above has already done.
    @Test
    func manyFailuresSharingOneMessageAreAShapeEvenWhereNamingThemAllWouldFit() {
        let unexplained = "failed with no message of its own — see the raw log"
        let names = ["testOne()", "testTwo()", "testThree()"] + (3 ..< Self.repeated).map { "aTest\($0)()" }
        let shape = RunFailureShape.of(
            names.map { RunFailureShape.Failure(name: $0, location: nil, message: unexplained) },
            changedFiles: .of([])
        )
        let block = shape.rendered()

        // Size alone would have named every one of them, which is the point of asserting it here — and
        // the weight is the block's own, not a second estimate of an entry; see ``TestSources/listingBytes(of:)-(RunFailureShape)``.
        #expect(TestSources.listingBytes(of: shape) < RunFailureCensus.listingBudget)
        #expect(shape.signatureCount == 1)
        // Twenty distinct tests sharing one message is one signature past `testsCap`: the lead names
        // its own single failure — never the signature's whole count — the next two are named beside
        // it, and the other seventeen are counted on their own line and again in the block's own
        // accounting, since nothing past the first three was ever named.
        #expect(block.count == 8)
        #expect(!block.contains { !$0.hasPrefix("  ↳ top:") && $0.contains("×\(Self.repeated)") })
        #expect(block.contains("  testOne()"))
        #expect(block.contains("    also: testTwo()"))
        #expect(block.contains("    also: testThree()"))
        #expect(block.contains("    +17 more tests under this signature (17 failures)"))
        #expect(block.last == "  +17 more failures under the signatures above, not named here — see the raw log")
    }

    /// Past the budget the block cannot name them all, and then it says how many it counted and never named.
    ///
    /// Three hundred failures sharing one message is one signature and one example — every number reconciling, the block looking complete, and 297 names nowhere in it. ``RunFailureCensus/withheld(beyond:of:)`` is silent here by construction: it counts what fell past the signature cap, and nothing did.
    @Test
    func aMeasuredBlockAccountsForTheFailuresItCountedButNeverNamed() {
        let unexplained = "failed with no message of its own — see the raw log"
        let shape = RunFailureShape.of(
            (0 ..< 300).map { RunFailureShape.Failure(name: "aTest\($0)()", location: nil, message: unexplained) },
            changedFiles: .of([])
        )
        let block = shape.rendered()

        #expect(shape.signatureCount == 1)
        // The lead and its two named others never carry the signature's whole count between them —
        // three tests of three hundred, each naming only its own single failure.
        #expect(!block.contains { !$0.hasPrefix("  ↳ top:") && $0.hasSuffix("  ×300") })
        #expect(block.contains("    +297 more tests under this signature (297 failures)"))
        #expect(block.last == "  +297 more failures under the signatures above, not named here — see the raw log")
    }

    /// Where signatures *were* withheld the block already says it is a sample, and does not say it twice.
    @Test
    func aBlockThatWithheldSignaturesDoesNotAlsoCountTheNamesUnderThem() throws {
        let block = try Self.shape(ofCapture: Self.red, changedFiles: RunChangedFiles.of([])).rendered()

        #expect(block.last == "  +205 more signatures, covering 419 failures — see the raw log")
        #expect(!block.contains { $0.contains("not named here") })
    }

    @Test
    func aSwiftTestRunIsClassifiedThroughItsRunReport() throws {
        let report = try TestSources.runReport("swift-test-fail")
        let failures = report.testFailures.map {
            RunFailureShape.Failure(name: $0.name, location: $0.location, message: $0.message)
        }
        let shape = RunFailureShape.of(failures, changedFiles: RunChangedFiles.of([]))
        let block = shape.rendered()

        #expect(shape.failureCount == 3)
        #expect(shape.fileCount == 2)
        // Three failures, three signatures — nothing repeats, so nothing is worth calling the top of anything.
        #expect(shape.signatureCount == 3)
        #expect(!block.contains { $0.hasPrefix("  ↳ top:") })
        #expect(block.first == "3 failures · 3 signatures · 2 files · 0 in changed files (matched by name)")
        #expect(block.count == 1 + shape.failureCount * 2)
    }

    /// One parameterized test failing under three distinct arguments enough times to be chiefly repetition names every argument beside the `×N` — never one of them standing for all.
    ///
    /// `RunOutputFilter` gives each case the identical reduced message, so all six failures below are one signature and the example line used to print the first case's own argument beside `×6` — a reviewer reading that as one argument failing six times, with the other two never mentioned anywhere in the answer.
    @Test
    func aParameterizedTestsSeveralArgumentsAreAllNamedBesideTheirSharedCount() {
        var filter = RunOutputFilter(expecting: .runTally)
        for leaf in ["black", "green", "white", "black", "green", "white"] {
            filter.consume(line: #"✘ Test steeps(leaf:) recorded an issue with 1 argument leaf → "\#(leaf)" at KettleTests.swift:6:5: Expectation failed: leaf.isEmpty"#)
        }
        let report = filter.finish(exitCode: 1)
        let failures = report.testFailures.map {
            RunFailureShape.Failure(name: $0.name, location: $0.location, message: $0.message, arguments: $0.arguments, note: $0.note)
        }
        let shape = RunFailureShape.of(failures, changedFiles: .of([]))

        #expect(shape.failureCount == 6)
        #expect(shape.signatureCount == 1)
        let block = shape.rendered()

        #expect(block.contains(#"  steeps(leaf:) with leaf → "black", leaf → "green", leaf → "white" — KettleTests.swift:6:5  ×6"#))
        #expect(!block.contains { $0.contains(#"with leaf → "black" —"#) && $0.hasSuffix("  ×6") })
    }

    /// The unchanged case: one argument failing six times over — a repeated run of the same case, say — still prints that one argument beside the `×6` it earned.
    @Test
    func oneArgumentRepeatedlyFailingIsStillNamedOnceBesideItsCount() {
        var filter = RunOutputFilter(expecting: .runTally)
        for _ in 0 ..< 6 {
            filter.consume(line: #"✘ Test steeps(leaf:) recorded an issue with 1 argument leaf → "black" at KettleTests.swift:6:5: Expectation failed: leaf.isEmpty"#)
        }
        let report = filter.finish(exitCode: 1)
        let failures = report.testFailures.map {
            RunFailureShape.Failure(name: $0.name, location: $0.location, message: $0.message, arguments: $0.arguments, note: $0.note)
        }
        let shape = RunFailureShape.of(failures, changedFiles: .of([]))

        #expect(shape.failureCount == 6)
        #expect(shape.signatureCount == 1)
        let block = shape.rendered()

        #expect(block.contains(#"  steeps(leaf:) with leaf → "black" — KettleTests.swift:6:5  ×6"#))
    }

    /// Two different tests failing the same shared helper's expectation are one signature, and the second test's name and location still have to appear somewhere in the answer — the folding this guards against once named only the first and dropped the second everywhere.
    @Test
    func twoTestsSharingOneExpectationAreBothNamedUnderItsSignature() {
        var filter = RunOutputFilter(expecting: .runTally)
        for _ in 0 ..< 28 {
            filter.consume(line: "􀢄  Test everyWholeReadServedAcrossItsBreakEvenStatesItsOwnSize() recorded an issue at InPlaceSweepTests.swift:90:36: Expectation failed: closing == \"…\"")
        }
        for _ in 0 ..< 3 {
            filter.consume(line: "􀢄  Test everyWindowServedAcrossItsBreakEvenStatesItsOwnSize() recorded an issue at InPlaceSweepTests.swift:69:41: Expectation failed: closing == \"…\"")
        }
        let report = filter.finish(exitCode: 1)
        let failures = report.testFailures.map {
            RunFailureShape.Failure(name: $0.name, location: $0.location, message: $0.message, arguments: $0.arguments, note: $0.note)
        }
        let shape = RunFailureShape.of(failures, changedFiles: .of([]))

        #expect(shape.failureCount == 31)
        #expect(shape.signatureCount == 1)
        let block = shape.rendered()

        #expect(block.contains {
            $0.contains("everyWholeReadServedAcrossItsBreakEvenStatesItsOwnSize()")
                && $0.contains("InPlaceSweepTests.swift:90:36") && $0.hasSuffix("  ×28")
        })
        #expect(block.contains {
            $0.contains("everyWindowServedAcrossItsBreakEvenStatesItsOwnSize()")
                && $0.contains("InPlaceSweepTests.swift:69:41") && $0.hasSuffix("  ×3")
        })
    }

    /// Three tests sharing one signature is still within `testsCap`, so every one of them keeps its own line — the lead named by ``RunFailureShape/described(_:at:standingFor:everywhere:)``, the other two nested beneath its message.
    @Test
    func threeTestsShareOneSignatureAndAllOfThemAreNamed() {
        let failures =
            Self.failures("alpha()", "Expectation failed: same == same", at: "A.swift:1:1", count: 5)
                + Self.failures("beta()", "Expectation failed: same == same", at: "B.swift:1:1", count: 3)
                + Self.failures("gamma()", "Expectation failed: same == same", at: "C.swift:1:1", count: 2)
        let shape = RunFailureShape.of(failures, changedFiles: .of([]))
        let block = shape.rendered()

        #expect(block.contains { $0.contains("alpha()") && $0.contains("A.swift:1:1") && $0.hasSuffix("  ×5") })
        #expect(block.contains("    also: beta() — B.swift:1:1  ×3"))
        #expect(block.contains("    also: gamma() — C.swift:1:1  ×2"))
        #expect(!block.contains { $0.contains("more test") })
    }

    /// Four tests sharing one signature is past `testsCap`: the three with the most failures keep their own line, each with its own count rather than the signature's whole one, and the fourth is counted on a line of its own — under fewer than five signatures in all, so nothing here is withheld at the signature level either.
    @Test
    func fourTestsShareOneSignatureUnderFiveSignaturesTotal() {
        let failures =
            Self.failures("aA1()", "Expectation failed: alpha == alpha", at: "A1.swift:1:1", count: 5)
                + Self.failures("aA2()", "Expectation failed: alpha == alpha", at: "A2.swift:1:1", count: 3)
                + Self.failures("aA3()", "Expectation failed: alpha == alpha", at: "A3.swift:1:1", count: 2)
                + Self.failures("aA4()", "Expectation failed: alpha == alpha", at: "A4.swift:1:1", count: 1)
                + Self.failures("bB()", "Expectation failed: beta == beta", at: "B.swift:1:1", count: 6)
                + Self.failures("cC()", "Expectation failed: gamma == gamma", at: "C.swift:1:1", count: 6)
        let shape = RunFailureShape.of(failures, changedFiles: .of([]))
        #expect(shape.signatureCount == 3)
        let block = shape.rendered()

        #expect(block.contains { $0.contains("aA1()") && $0.hasSuffix("  ×5") })
        #expect(block.contains { $0.contains("aA2()") && $0.hasSuffix("  ×3") })
        #expect(block.contains { $0.contains("aA3()") && $0.hasSuffix("  ×2") })
        #expect(block.contains("    +1 more test under this signature (1 failure)"))
        #expect(!block.contains { $0.contains("aA4()") })
        // The top-signature line above is the one place ×11 — the whole signature's count — is honest;
        // no test's own line may carry it.
        #expect(!block.contains { !$0.hasPrefix("  ↳ top:") && $0.hasSuffix("  ×11") })
    }

    /// The same four tests under one signature, only now among six signatures in all — one of them past ``RunFailureCensus/signatureCap`` and withheld — so the per-signature naming past `testsCap` holds exactly the same whether or not the block is also sampling signatures.
    ///
    /// The other five signatures carry a message wide enough that a straight listing of all of them would outgrow ``RunFailureCensus/listingBudget``, which is what makes this a shape rather than a listing — the case ``RunFailureShape/measured()`` runs for, and the one the per-signature cap has to hold up in.
    @Test
    func fourTestsShareOneSignatureAmongFiveOrMoreSignatures() {
        let wide = { (word: String) in "Expectation failed: (\(String(repeating: word, count: 20))) is not what it should be" }
        let failures =
            Self.failures("aA1()", "Expectation failed: alpha == alpha", at: "A1.swift:1:1", count: 5)
                + Self.failures("aA2()", "Expectation failed: alpha == alpha", at: "A2.swift:1:1", count: 3)
                + Self.failures("aA3()", "Expectation failed: alpha == alpha", at: "A3.swift:1:1", count: 2)
                + Self.failures("aA4()", "Expectation failed: alpha == alpha", at: "A4.swift:1:1", count: 1)
                + Self.failures("bB()", wide("beta"), at: "B.swift:1:1", count: 15)
                + Self.failures("cC()", wide("gamma"), at: "C.swift:1:1", count: 12)
                + Self.failures("dD()", wide("delta"), at: "D.swift:1:1", count: 10)
                + Self.failures("eE()", wide("epsilon"), at: "E.swift:1:1", count: 8)
                + Self.failures("fF()", wide("zeta"), at: "F.swift:1:1", count: 2)
        let shape = RunFailureShape.of(failures, changedFiles: .of([]))
        #expect(shape.signatureCount == 6)
        #expect(TestSources.listingBytes(of: shape) > RunFailureCensus.listingBudget)
        let block = shape.rendered()

        #expect(block.contains { $0.contains("aA1()") && $0.hasSuffix("  ×5") })
        #expect(block.contains { $0.contains("aA2()") && $0.hasSuffix("  ×3") })
        #expect(block.contains { $0.contains("aA3()") && $0.hasSuffix("  ×2") })
        #expect(block.contains("    +1 more test under this signature (1 failure)"))
        #expect(!block.contains { $0.contains("aA4()") })
        #expect(!block.contains { !$0.hasPrefix("  ↳ top:") && $0.hasSuffix("  ×11") })
        #expect(block.last == "  +1 more signature, covering 2 failures — see the raw log")
    }

    /// One signature past `testsCap` beside one that names its single test outright: the block's own count of what it counted but never named has to add up to exactly the tests the capped signature left out — never the capped signature's whole count, and never zero because the other signature happens to be complete.
    @Test
    func aCappedSignatureBesideAFullyNamedOneStillReconciles() {
        let failures =
            Self.failures("aA1()", "Expectation failed: alpha == alpha", at: "A1.swift:1:1", count: 4)
                + Self.failures("aA2()", "Expectation failed: alpha == alpha", at: "A2.swift:1:1", count: 3)
                + Self.failures("aA3()", "Expectation failed: alpha == alpha", at: "A3.swift:1:1", count: 2)
                + Self.failures("aA4()", "Expectation failed: alpha == alpha", at: "A4.swift:1:1", count: 1)
                + Self.failures("aA5()", "Expectation failed: alpha == alpha", at: "A5.swift:1:1", count: 1)
                + Self.failures("bB()", "Expectation failed: beta == beta", at: "B.swift:1:1", count: 6)
        let shape = RunFailureShape.of(failures, changedFiles: .of([]))
        #expect(shape.failureCount == 17)
        #expect(shape.signatureCount == 2)
        let block = shape.rendered()

        #expect(block.contains("    +2 more tests under this signature (2 failures)"))
        #expect(block.contains { $0.contains("bB()") && $0.hasSuffix("  ×6") })
        #expect(block.last == "  +2 more failures under the signatures above, not named here — see the raw log")
    }

    /// Where every test under every shown signature is named — none past `testsCap`, none withheld — the block never claims it left names out.
    @Test
    func everyTestNamedPrintsNoNotNamedHereLine() {
        let failures =
            Self.failures("aA1()", "Expectation failed: alpha == alpha", at: "A1.swift:1:1", count: 5)
                + Self.failures("aA2()", "Expectation failed: alpha == alpha", at: "A2.swift:1:1", count: 4)
                + Self.failures("aA3()", "Expectation failed: alpha == alpha", at: "A3.swift:1:1", count: 3)
                + Self.failures("bB1()", "Expectation failed: beta == beta", at: "B1.swift:1:1", count: 4)
                + Self.failures("bB2()", "Expectation failed: beta == beta", at: "B2.swift:1:1", count: 3)
                + Self.failures("cC()", "Expectation failed: gamma == gamma", at: "C.swift:1:1", count: 6)
        let shape = RunFailureShape.of(failures, changedFiles: .of([]))
        #expect(shape.failureCount == 25)
        #expect(shape.signatureCount == 3)
        let block = shape.rendered()

        #expect(!block.contains { $0.contains("not named here") })
    }
}

private extension RunFailureShapeTests {
    /// Enough copies of one message that the run is chiefly repetition, while a listing of them still fits the budget — the pair of cases a size cannot tell apart.
    static let repeated = 20

    static var red: String {
        "xcodebuild-test-execute-failure-environmental"
    }

    static var green: String {
        "xcodebuild-test-execute-success"
    }

    /// `count` copies of one named failure at one location, sharing one message — the building block for a signature several tests share, each with its own count.
    static func failures(_ name: String, _ message: String, at location: String, count: Int) -> [RunFailureShape.Failure] {
        (0 ..< count).map { _ in RunFailureShape.Failure(name: name, location: location, message: message) }
    }

    /// `count` failure names, each spelled out of letters alone so the normalisation — which elides digits — cannot collapse two of them into one signature.
    static func names(_ count: Int) -> [String] {
        let letters = "abcdefghijklmnopqrstuvwxyz"
        return (0 ..< count).map { index in
            let first = letters[letters.index(letters.startIndex, offsetBy: index / 26)]
            let second = letters[letters.index(letters.startIndex, offsetBy: index % 26)]
            return "aTestNamed\(first)\(second)"
        }
    }

    static func shape(ofCapture name: String, changedFiles: RunChangedFiles) throws -> RunFailureShape {
        let failures = try failures(inCapture: name)
        return RunFailureShape.of(failures, changedFiles: changedFiles)
    }

    /// One failure per name, each in a file of its own and each with a message nothing else shares.
    static func shape(ofFailuresNamed names: some Sequence<String>) -> RunFailureShape {
        RunFailureShape.of(
            names.enumerated().map { index, name in
                RunFailureShape.Failure(
                    name: "\(name)()",
                    location: "Tests/WidgetTests/File\(index)Tests.swift:1:1",
                    message: "Expectation failed: \(name) is not what it should be"
                )
            },
            changedFiles: .of([])
        )
    }

    /// The failures a capture recorded, read straight from the transcript rather than through `RunOutputFilter`.
    ///
    /// This unit's contract starts at the failures, so the tests hand it what the capture actually holds rather than what the filter makes of it. Both issue-line forms are read, and nothing is anchored on the status glyph or on the start of the line: 186 lines of this capture carry a zero-width space before the glyph, and `xcodebuild` splices one runner's output through the middle of others.
    static func failures(inCapture name: String) throws -> [RunFailureShape.Failure] {
        var failures: [RunFailureShape.Failure] = []
        for line in try TestSources.runOutput(name).split(separator: "\n", omittingEmptySubsequences: false) {
            guard let marker = line.range(of: "recorded an issue") else {
                continue
            }
            let tail = line[marker.upperBound...]
            guard let file = tail.range(of: ".swift:"),
                  let separator = tail.range(of: ": ", range: file.upperBound ..< tail.endIndex)
            else {
                continue
            }
            let start = tail[..<file.lowerBound].lastIndex(of: " ").map { tail.index(after: $0) } ?? tail.startIndex
            let head = line[..<marker.lowerBound]
            guard let named = head.range(of: "Test ", options: .backwards) else {
                continue
            }
            failures.append(RunFailureShape.Failure(
                name: String(head[named.upperBound...]).trimmingCharacters(in: .whitespaces),
                location: String(tail[start ..< separator.lowerBound]),
                message: String(tail[separator.upperBound...])
            ))
        }
        return failures
    }
}
