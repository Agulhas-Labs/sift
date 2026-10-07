//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the one line a classification block leads with when most of a run's failures read one and the same value.
///
/// The case it was written for is the red capture, and the capture is the measurement: 666 failures over 210 signatures, every signature a different sentence, and underneath all of them one empty accessibility read that ``RunFailureSignature`` elides by construction. The block said 210 kinds and named five of them; what the reader needed was that the tree was empty and the device had switched the preference off.
///
/// **Every assertion here is on the rendered block**, because that is where the claim is either made or not, and because a shape's own reading of its failures is worth nothing if the answer does not carry it.
@Suite(.temporaryDirectories)
struct RunDominantFailureTests {
    /// The capture whose signatures share nothing shares one value, and the block leads with it.
    ///
    /// The normalisation replaces every string literal with `"…"`, which is what makes `labels → ""` and `labels → "Sprockets"` one kind — so 359 of these 666 failures read an empty tree and no field of the census can say so.
    ///
    /// The capture is an `xcodebuild` run against one simulator; the restoration beside it is written here rather than taken from the capture, because restorations are read live from the device and no capture carries any. This one stands for a re-arming that found the preference off and could not put it back, which is the state that still owes the reader the command, spelled for the device it is owed for.
    @Test
    func theEmptyAccessibilityReadIsNamedWithWhatItIsConsistentWithAndWhatIsLeftToDo() throws {
        let block = try Self.shape(ofCapture: Self.red, accessibility: Self.leftOff).rendered()

        #expect(block[0] == "666 failures · 210 signatures · 53 files · 0 in changed files (matched by name)")
        #expect(block[1] == #"  ↳ top: Expectation failed: (labels → "…").contains(expected → "…")  ×117"#)
        #expect(block[2].hasPrefix(#"  ↳ 359 of 666 compare against an EMPTY accessibility read (labels → "")"#))
        #expect(block[2].contains("consistent with the simulator's accessibility preference having been off for this run"))
        #expect(block[2].hasSuffix("Re-arm it with the command in the accessibility line leading these failures, and re-run"))
    }

    /// It leads the examples rather than replacing them: every line the block printed before is still under it.
    ///
    /// A failure is identified by its name and this line carries none, so suppressing the signatures it covers would buy a few lines and cost the reader everywhere to start reading. The whole of what changes is that the first thing read is the fault.
    @Test
    func theClassLeadsTheExamplesRatherThanSuppressingThem() throws {
        let shape = try Self.shape(ofCapture: Self.red, accessibility: Self.leftOff)
        let block = shape.rendered()

        #expect(block.filter { $0.contains("EMPTY accessibility read") }.count == 1)
        #expect(block.last == "  +205 more signatures, covering 419 failures — see the raw log")
        // A signature naming several distinct tests splits its count across one line each, up to three
        // of them — the capture's own top five signatures are all several tests sharing one fault. So
        // the whole signature's count is what its own named lines add up to where it covers three tests
        // or fewer; past three, the named lines and the one line counting what was left have to.
        #expect(shape.signatures.prefix(RunFailureCensus.signatureCap).allSatisfy { signature in
            let names = Set(signature.positions.map { shape.failures[$0].name })
            let cap = 3
            let named = block.reduce(0) { total, line in
                guard !line.hasPrefix("  ↳ top:"), names.contains(where: line.contains) else {
                    return total
                }
                guard let times = line.range(of: "  ×", options: .backwards) else {
                    return total + 1
                }
                return total + (Int(line[times.upperBound...]) ?? 1)
            }
            guard names.count > cap else {
                return named == signature.count
            }
            let deficit = signature.count - named
            let remaining = names.count - cap
            return deficit > 0 && block.contains(
                "    +\(remaining) more test\(remaining == 1 ? "" : "s") under this signature (\(deficit) failure\(deficit == 1 ? "" : "s"))"
            )
        })
    }

    /// The rule generalises past accessibility: the shared value may be a timeout sentence, and then the line names the value and stops.
    ///
    /// A suite that gave up waiting prints one deadline under many different expectations — different signatures, one fault — and that is the same arithmetic as the empty tree. What it is not is a claim about a device, so the line says only what was measured.
    ///
    /// Measured on a run that did test on a simulator and did find the preference off there, so the value is the only marker withholding the clause.
    @Test
    func aSharedTimeoutSentenceIsNamedWithoutBlamingTheDevice() {
        let block = Self.shape(of: Self.timedOut, accessibility: Self.reArmed).rendered()

        #expect(block[1].hasPrefix("  ↳ top: "))
        #expect(block[2] == #"  ↳ 30 of 40 failures read one and the same value (deadline → "timed out after 120.0 seconds"), across 3 signatures"#)
    }

    /// A value only a minority reads is no class at all, and the block renders exactly as it did before there was one.
    @Test
    func aValueAMinorityReadsIsNotAClass() {
        let block = Self.shape(of: Self.mixed).rendered()

        #expect(block[0].hasPrefix("160 failures · 8 signatures · 8 files"))
        #expect(!block.contains { $0.contains("read one and the same value") || $0.contains("EMPTY accessibility read") })
        #expect(block[2].hasPrefix("  aTestNamed"))
    }

    /// A value the whole run reads through one signature is left to the `↳ top:` line, which already says it.
    ///
    /// The line exists for what a census of signatures cannot see. Where the failures are one kind the census has already seen it, and a second line beneath saying the same thing in other words is the same disclosure twice.
    @Test
    func aValueInsideOneSignatureIsLeftToTheLineThatAlreadySaysIt() {
        let shape = Self.shape(of: Array(repeating: Self.emptyTree[0], count: 20))
        let block = shape.rendered()

        #expect(shape.census.isChieflyRepetition)
        #expect(block[1].hasPrefix("  ↳ top: "))
        #expect(block[2].hasPrefix("  aTestNamed"))
    }

    /// An empty read from something that is not an accessibility tree is named and not diagnosed.
    ///
    /// Half a repository's expectations compare against a collection, and a collection coming back empty is an ordinary bug. The clause that names a cause is the one thing in this answer that could send a reader off to re-arm a simulator over a real regression, so it is withheld from every read but the one it was measured on. The line under it also shows the value is bounded by its own parentheses: `[]` rather than everything to the end of a compound expectation.
    @Test
    func anEmptyCollectionThatIsNotATreeIsNamedRatherThanDiagnosed() {
        let block = Self.shape(of: Self.emptyStock, accessibility: Self.reArmed).rendered()

        #expect(block[2] == "  ↳ 30 of 40 failures read one and the same value (stock → []), across 3 signatures")
    }

    /// And an empty tree with failures in a file this working tree has changed keeps the count and drops the cause.
    ///
    /// `0 in changed files` is one of the four markers, and it is read strictly: the reader who edited that file is the one person who does not need to be told it is not their code.
    @Test
    func anEmptyTreeTouchingAChangedFileKeepsTheCountAndDropsTheCause() {
        let block = Self.shape(
            of: Self.emptyTree,
            changedFiles: .of(["Tests/DepotKitTests/BinLabelTests.swift"]),
            accessibility: Self.reArmed
        ).rendered()

        #expect(block[0].hasSuffix("5 in changed files (matched by name)"))
        #expect(block[2] == #"  ↳ 30 of 40 failures read one and the same value (labels → ""), across 3 signatures"#)
    }

    /// The raw-log fallback builds no ``RunReportRenderer`` to ask a device note of, because there is no filtered answer for one to sit under — but the outcome it falls open from still carries the report the same detector reads, and has to be asked the same question directly rather than told there is nothing to say.
    @Test
    func theRawLogFallbackAsksTheSameDetectorAFilteredAnswerWould() throws {
        let root = try TestSources.makeTempRepo()
        let failures = Self.messages.enumerated().map { index, message in
            RunTestFailure(name: "aTestNamed\(index)()", location: "\(Self.files[index]).swift:\(index + 1):9", message: message)
        }
        // `.diagnostics` beside named failures is a shape no real invocation prints — it is what makes this
        // report fail ``RunReport/isUsable(exitCode:)`` while still carrying failures to read, which is the
        // one way to reach the raw-log branch with something for the detector to say.
        let report = RunReport(
            errors: [],
            warnings: [],
            testFailures: failures,
            summaryLines: [],
            contract: .diagnostics,
            verdict: nil,
            tally: nil,
            totalLines: 100
        )
        let outcome = RunOutcome(kind: .xcodebuild, logKey: "xcodebuild test", exitCode: 65, report: report, log: nil, repositoryRoot: root)

        #expect(outcome.filteredAnswer(workingDirectory: root) == nil)
        #expect(outcome.failuresReadEmptyTrees(workingDirectory: root, accessibility: Self.alreadyOn))
    }
}

private extension RunDominantFailureTests {
    static var red: String {
        "xcodebuild-test-execute-failure-environmental"
    }

    /// Enough files that no shape built here reads as a localised regression.
    static let files = [
        "BinLabelTests", "ChartGridTests", "ConveyorBeltTests", "HopperGaugeTests",
        "PalletTests", "BackorderTests", "GridTests", "ListingTests",
    ]

    /// Six messages reading an empty accessibility tree over three signatures, and two that read something else.
    static let messages = [
        #"Expectation failed: (labels → "").contains(bay.signage → "Sprockets")"#,
        #"Expectation failed: (labels → "").contains(crate.signage → "Rivets")"#,
        #"Expectation failed: (labels → "") == (expected → "Cogs")"#,
        #"Expectation failed: (labels → "").contains(bay.signage → "Washers")"#,
        #"Expectation failed: (labels → "").contains(crate.signage → "Dowels")"#,
        #"Expectation failed: (labels → "") == (expected → "Shims")"#,
        "Expectation failed: (stacked → 3) == (wanted → 4)",
        "Expectation failed: (marker → nil) != nil",
    ]

    /// Forty failures over those eight messages — few enough kinds that the block measures rather than lists.
    static var emptyTree: [String] {
        (0 ..< 40).map { messages[$0 % messages.count] }
    }

    /// The same arithmetic over a collection nothing says is an accessibility tree.
    static var emptyStock: [String] {
        emptyTree.map { $0.replacingOccurrences(of: #"labels → """#, with: "stock → []") }
    }

    /// Forty failures, three quarters of them waiting on one deadline, in four kinds.
    static var timedOut: [String] {
        let waiting = [
            #"Expectation failed: (deadline → "timed out after 120.0 seconds") == (arrival → "the pallet")"#,
            #"Expectation failed: (deadline → "timed out after 120.0 seconds") == (departure → "the crate")"#,
            #"Expectation failed: (deadline → "timed out after 120.0 seconds").isEmpty"#,
            "Expectation failed: (stacked → 3) == (wanted → 4)",
        ]
        return (0 ..< 40).map { waiting[$0 % waiting.count] }
    }

    /// A hundred and sixty failures over eight signatures, no value among them read by more than three in eight.
    ///
    /// Long enough that the listing outgrows ``RunFailureCensus/listingBudget`` and the block measures, which is the form the class would appear in if there were one.
    static var mixed: [String] {
        let distinct = [
            #"Expectation failed: (bay.signage → "Alpha") == (expected → "Beta")"#,
            #"Expectation failed: (bay.marker → "Alpha") != nil"#,
            #"Expectation failed: (crate.signage → "Beta") == (expected → "Alpha")"#,
            #"Expectation failed: (crate.marker → "Beta") != nil"#,
            #"Expectation failed: (pallet.signage → "Cogs") == (expected → "Shims")"#,
            #"Expectation failed: (pallet.marker → "Cogs") != nil"#,
            #"Expectation failed: (shelf.signage → "Shims") == (expected → "Cogs")"#,
            #"Expectation failed: (shelf.marker → "Shims") != nil"#,
        ]
        return (0 ..< 160).map { distinct[$0 % distinct.count] }
    }

    /// One failure per message, each in a file of its own so the spread is as wide as the run is long.
    ///
    /// `spread` is how many of the eight files the failures are dealt over, which is the marker that separates a fault crossing a whole suite from a regression localised to a corner of it.
    static func shape(
        of messages: [String],
        changedFiles: RunChangedFiles = .of([]),
        accessibility: [SimulatorAccessibility.Restoration] = [],
        spread: Int = files.count
    ) -> RunFailureShape {
        RunFailureShape.of(
            messages.enumerated().map { index, message in
                RunFailureShape.Failure(
                    name: "aTestNamed\(index)()",
                    location: "\(files[index % spread]).swift:\(index + 1):9",
                    message: message
                )
            },
            changedFiles: changedFiles,
            accessibility: accessibility
        )
    }

    /// The capture's failures as the renderer builds them, arguments and notes included.
    static func shape(ofCapture name: String, accessibility: [SimulatorAccessibility.Restoration] = []) throws -> RunFailureShape {
        let report = try TestSources.runReport(name)
        return RunFailureShape.of(
            report.testFailures.map {
                RunFailureShape.Failure(name: $0.name, location: $0.location, message: $0.message, arguments: $0.arguments, note: $0.note)
            },
            changedFiles: .of([]),
            accessibility: accessibility
        )
    }
}

// MARK: - The devices a run may have tested on

private extension RunDominantFailureTests {
    /// The one simulator these runs name, spelled as the capture's own command line spells it.
    static var udid: String {
        "00000000-0000-0000-0000-000000000000"
    }

    /// A device this run found the preference switched off on and switched back on — what an ordinary wrapped simulator run leaves behind.
    static var reArmed: [SimulatorAccessibility.Restoration] {
        [SimulatorAccessibility.Restoration(udid: udid, state: .restored)]
    }

    /// A device this run found switched off and could not switch back on, which is the only state that still owes the reader a command.
    static var leftOff: [SimulatorAccessibility.Restoration] {
        [SimulatorAccessibility.Restoration(udid: udid, state: .failed(reason: "the write was refused"))]
    }

    /// A device whose preference read on throughout — a simulator run the empty tree is not explained by.
    static var alreadyOn: [SimulatorAccessibility.Restoration] {
        [SimulatorAccessibility.Restoration(udid: udid, state: .alreadyOn)]
    }
}

// MARK: - The false alarms the clause may never raise

/// Covers the runs this clause must stay off, each of which is a plausible regression it once blamed on a device.
///
/// A line saying the simulator is at fault over a real regression is strictly worse than the unhelpful lines it replaced: it talks the reader out of a true failure and sends them to re-arm a device that was never the problem. Every case here was rendered by the committed code before these markers were added.
extension RunDominantFailureTests {
    /// A run that never put a test on a simulator is never told its simulator is at fault.
    ///
    /// Three plural nouns are all the expression test has to go on where the path does not spell out the tree, and `elements` is a collection's contents and an XML node's children far more often than it is a hosted view's. This run is a parser's, on a clean tree, over eight files — every marker the clause used to need — and it reads the general line.
    @Test
    func aRunWithNoSimulatorIsNeverToldItsSimulatorIsAtFault() {
        let block = Self.shape(of: Self.parsedTree).rendered()

        #expect(block[2] == "  ↳ 300 of 300 failures read one and the same value (document.elements → []), across 3 signatures")
    }

    /// And a simulator whose preference this run read on throughout is not blamed for the empty tree either.
    ///
    /// The device marker is a reading and not a platform: a run that tested on a simulator and found nothing switched off there has no evidence the preference explains anything, and the honest answer is the count.
    @Test
    func aDeviceThisRunFoundSwitchedOnIsNotBlamedForTheEmptyRead() {
        let block = Self.shape(of: Self.emptyTree, accessibility: Self.alreadyOn).rendered()

        #expect(block[2] == #"  ↳ 30 of 40 failures read one and the same value (labels → ""), across 3 signatures"#)
    }

    /// A committed regression in one shared provider, on a clean tree, is not a device fault.
    ///
    /// `0 in changed files` is what every run on a freshly checked-out branch reads, and what your own run reads the moment you commit — so on its own it discriminates nothing. Four kinds of failure here read one provider's empty string, the plurality of them through a name the expression test accepts, and nothing about the run says a device was ever involved.
    @Test
    func aCommittedRegressionOnACleanTreeIsNotADeviceFault() {
        let block = Self.shape(of: Self.sharedProvider).rendered()

        #expect(block[0].hasSuffix("0 in changed files (matched by name)"))
        #expect(block[2] == #"  ↳ 300 of 300 failures read one and the same value (chart.labels → ""), across 4 signatures"#)
    }

    /// A value on the far side of an `==` is what the test hoped for, and hoping for an empty string is not reading an empty tree.
    ///
    /// The framework expands both sides, so the expected value is offered to the tally exactly as the read one is. What tells them apart is which the expectation was *about*: the subject is the first expansion the framework printed, and here it is the name that read something else entirely.
    @Test
    func aValueOnTheExpectedSideDoesNotDriveTheDeviceClause() {
        let block = Self.shape(of: Self.expectedEmpty, accessibility: Self.reArmed).rendered()

        #expect(block[2] == #"  ↳ 300 of 300 failures read one and the same value (labels → ""), across 3 signatures"#)
    }

    /// A minority of compound assertions does not outvote a majority of simple ones.
    ///
    /// One `#expect(a && b)` prints two expansions of the same name, and counting occurrences rather than failures lets sixty of them outvote a hundred failures that each read the value once. It is this tally that picks the name the line prints and the accessibility test is applied to, so a wrong winner here is a wrong diagnosis one step later.
    @Test
    func oneCompoundAssertionCastsOneVoteRatherThanTwo() {
        let block = Self.shape(of: Self.compounded, accessibility: Self.reArmed).rendered()

        #expect(block[2] == #"  ↳ 160 of 160 failures read one and the same value (bay.signage → ""), across 2 signatures"#)
    }

    /// A regression localised to a corner of the suite keeps the count and drops the cause.
    ///
    /// The same forty failures over four files rather than eight: a fault that crosses a whole suite is what a device explains, and one a block could illustrate file by file is what an edit explains.
    @Test
    func anEmptyTreeInTooFewFilesKeepsTheCountAndDropsTheCause() {
        let block = Self.shape(of: Self.emptyTree, accessibility: Self.reArmed, spread: 4).rendered()

        #expect(block[0].hasPrefix("40 failures · 5 signatures · 4 files"))
        #expect(block[2] == #"  ↳ 30 of 40 failures read one and the same value (labels → ""), across 3 signatures"#)
    }

    /// A changed-file signal that could not be established is not read as zero.
    ///
    /// Git refusing to answer is not evidence that nothing was edited, and the clause rests on the reader having edited nothing.
    @Test
    func anEmptyTreeWithNoChangedFileSignalKeepsTheCountAndDropsTheCause() {
        let block = Self.shape(
            of: Self.emptyTree,
            changedFiles: .unavailable("not a git repository"),
            accessibility: Self.reArmed
        ).rendered()

        #expect(block[2] == #"  ↳ 30 of 40 failures read one and the same value (labels → ""), across 3 signatures"#)
    }

    /// A dominant `nil` is named and never diagnosed: it is what every ordinary optional lookup misses with.
    @Test
    func aDominantNilIsNamedWithoutBlamingTheDevice() {
        let block = Self.shape(of: Self.nilTree, accessibility: Self.reArmed).rendered()

        #expect(block[2] == "  ↳ 35 of 40 failures read one and the same value (labels → nil), across 4 signatures")
    }

    /// An empty dictionary is an empty read like the other two, and a tree read into one is diagnosed like any other tree.
    @Test
    func anEmptyDictionaryIsAnEmptyReadLikeTheOthers() {
        let block = Self.shape(of: Self.emptyMap, accessibility: Self.leftOff).rendered()

        #expect(block[2].hasPrefix("  ↳ 30 of 40 compare against an EMPTY accessibility read (labels → [:])"))
    }

    /// A device this run has already switched back on is not told to switch it back on.
    ///
    /// The device line leading the failures says the run re-armed that very device. A remedy beside it asks the reader to redo what the tool just did — so what the line owes them is the device's name and the one step left.
    @Test
    func aDeviceThisRunReArmedIsToldToReRunRatherThanToReArmItAgain() throws {
        let block = try Self.shape(ofCapture: Self.red, accessibility: Self.reArmed).rendered()

        #expect(block[2].hasPrefix(#"  ↳ 359 of 666 compare against an EMPTY accessibility read (labels → "")"#))
        #expect(block[2].hasSuffix("This run switched it back on for \(Self.udid), so re-run as it stands"))
        #expect(!block[2].contains(SimulatorAccessibility.command(udid: Self.udid)))
    }

    /// The whole answer carries what the shape measured, so the device reading reaches the line through the renderer that holds it.
    ///
    /// The markers are worth nothing measured somewhere the answer does not read: this is the one path that runs in anger, and without the restorations reaching the shape the motivating case loses its clause and nothing else in this suite would notice.
    @Test
    func theAnswerTheRendererServesCarriesTheClauseAndTheNoteTogether() throws {
        let report = try TestSources.runReport(Self.red)

        let answer = RunReportRenderer(
            kind: .xcodebuild,
            workingDirectory: URL(fileURLWithPath: "/Users/dev/Depot"),
            changedFiles: .of([]),
            accessibility: Self.reArmed
        )
        .render(report, exitCode: 1, logURL: nil)

        #expect(answer.contains("compare against an EMPTY accessibility read"))
        #expect(answer.contains("This run switched it back on for \(Self.udid), so re-run as it stands"))
        #expect(answer.contains("accessibility: read off on \(Self.udid) after the run; sift switched it back on"))
    }

    /// Failures that read empty trees are led by the device's own line, and the command it owes is printed once, at the head of them.
    ///
    /// Under the receipt the line is the last thing read; over a suite that failed on an empty tree it is the first thing the reader has to act on, so it moves above the failures rather than being printed twice.
    @Test(arguments: [
        (RunDominantFailureTests.leftOff, "accessibility: left off on \(RunDominantFailureTests.udid) (the write was refused)"),
        (RunDominantFailureTests.reArmed, "accessibility: read off on \(RunDominantFailureTests.udid) after the run"),
        (RunDominantFailureTests.alreadyOn, "accessibility: read on for \(RunDominantFailureTests.udid) after the run, yet the failures read empty trees"),
    ])
    func emptyTreeFailuresAreLedByTheDevicesLine(accessibility: [SimulatorAccessibility.Restoration], opening: String) throws {
        let report = try TestSources.runReport(Self.red)

        let answer = RunReportRenderer(
            kind: .xcodebuild,
            workingDirectory: URL(fileURLWithPath: "/Users/dev/Depot"),
            changedFiles: .of([]),
            accessibility: accessibility
        )
        .render(report, exitCode: 1, logURL: nil)
        let lines = answer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let measurement = try #require(lines.firstIndex { $0.hasPrefix("666 failures · ") })

        #expect(lines[measurement - 1].hasPrefix(opening))
        #expect(!lines[measurement - 2].isEmpty)
        #expect(lines.last?.hasPrefix("raw: ") == true)
        #expect(lines.filter { $0.hasPrefix("accessibility:") }.count == 1)
        #expect(answer.components(separatedBy: SimulatorAccessibility.command(udid: Self.udid)).count <= 2)
    }

    /// A run small enough for the block to name every failure has the values on the page already, and is given no class.
    @Test
    func aRunNoLongerThanTheSignatureCapHasNoClass() {
        let short = Array(Self.emptyTree.prefix(RunFailureCensus.signatureCap))
        let long = Array(Self.emptyTree.prefix(RunFailureCensus.signatureCap + 1))

        #expect(RunDominantFailureClass.of(short, census: Self.shape(of: short).census) == nil)
        #expect(RunDominantFailureClass.of(long, census: Self.shape(of: long).census) != nil)
    }

    /// The reading the line prints is bounded like every other line of a failure's own words in this block.
    @Test
    func theReadingTheLineNamesIsClippedLikeEveryOtherLineOfTheRunsOwnWords() {
        let block = Self.shape(of: Self.wideReading, accessibility: Self.reArmed).rendered()

        #expect(block[2].contains("(\(RunFailureCensus.clipped(#"\#(Self.wideName) → """#))) —"))
        #expect(!block[2].contains(Self.wideName))
    }
}

// MARK: - The claim the device clause is allowed to make

/// Covers the wording of the device clause itself, which is a claim about what the run's readings are consistent with and never a claim about what caused the failures.
///
/// Both readings the clause rests on are taken after the wrapped command has returned, so *the preference was off for the whole run* and *the session teardown switched it off as the run ended* are the same reading — and the second is what nearly every wrapped simulator run leaves behind. A line asserting the first, and denying the code, is therefore stating something this run has not established and ruling out something it has not ruled out: over a genuine regression on a clean tree — where the `0 in changed files` marker discriminates nothing — it talks the reader out of a true failure and sends them to re-run a suite that will fail the same way. Each case here pins that the line offers the consistency and names the ambiguity, for each of the two states that reach it.
extension RunDominantFailureTests {
    /// A device this run found off and re-armed gets the consistency, the ambiguity, and the one step left.
    @Test
    func theReArmedClauseClaimsConsistencyAndNamesWhatItCannotRuleOut() throws {
        let block = try Self.shape(ofCapture: Self.red, accessibility: Self.reArmed).rendered()

        #expect(block[2].contains("consistent with the simulator's accessibility preference having been off for this run"))
        #expect(block[2].contains("it was read only after the tests finished, so a teardown that switched it off at the end reads the same"))
        #expect(!block[2].contains("not the code"))
        #expect(block[2].hasSuffix("This run switched it back on for \(Self.udid), so re-run as it stands"))
    }

    /// A device left off gets the same claim, and the command it is owed regardless of which of the two worlds this is.
    @Test
    func theStillOffClauseClaimsConsistencyAndNamesWhatItCannotRuleOut() throws {
        let block = try Self.shape(ofCapture: Self.red, accessibility: Self.leftOff).rendered()

        #expect(block[2].contains("consistent with the simulator's accessibility preference having been off for this run"))
        #expect(block[2].contains("it was read only after the tests finished, so a teardown that switched it off at the end reads the same"))
        #expect(!block[2].contains("not the code"))
        #expect(block[2].hasSuffix("Re-arm it with the command in the accessibility line leading these failures, and re-run"))
    }
}

// MARK: - The runs those false alarms were rendered over

private extension RunDominantFailureTests {
    /// Three hundred failures of an XML parse, over three signatures, every one of them reading a node's children.
    static var parsedTree: [String] {
        let parsing = [
            #"Expectation failed: (document.elements → []).contains(node.name → "Alpha")"#,
            #"Expectation failed: (document.elements → []).contains(child.name → "Beta")"#,
            #"Expectation failed: (document.elements → []) == (wanted → ["Cogs"])"#,
        ]
        return (0 ..< 300).map { parsing[$0 % parsing.count] }
    }

    /// Three hundred failures of one shared provider returning an empty string, over four signatures.
    ///
    /// The plurality of them read it through a name the expression test accepts, and three in five read it through names nothing about accessibility explains.
    static var sharedProvider: [String] {
        let regression = [
            #"Expectation failed: (bay.signage → "") == (expected → "Alpha")"#,
            #"Expectation failed: (crate.signage → "") != (other → "Beta")"#,
            #"Expectation failed: (pallet.title → "").hasPrefix(prefix → "P")"#,
            #"Expectation failed: (chart.labels → "") == (expected → "Cogs")"#,
            #"Expectation failed: (chart.labels → "") == (expected → "Shims")"#,
        ]
        return (0 ..< 300).map { regression[$0 % regression.count] }
    }

    /// Three hundred failures whose empty string is the value each expectation was hoping for.
    static var expectedEmpty: [String] {
        let hoping = [
            #"Expectation failed: (bay.signage → "Alpha") == (labels → "")"#,
            #"Expectation failed: (crate.signage → "Beta") == (labels → "")"#,
            #"Expectation failed: (pallet.signage → "Cogs") == (labels → "")"#,
        ]
        return (0 ..< 300).map { hoping[$0 % hoping.count] }
    }

    /// A hundred failures reading one name once each, and sixty compound ones reading another name twice.
    static var compounded: [String] {
        let simple = #"Expectation failed: (bay.signage → "") == (expected → "Alpha")"#
        let compound = #"Expectation failed: (chart.labels → "").isEmpty && (chart.labels → "") == (expected → "Cogs")"#
        return Array(repeating: simple, count: 100) + Array(repeating: compound, count: 60)
    }

    /// The same arithmetic over a value every ordinary optional lookup misses with.
    static var nilTree: [String] {
        emptyTree.map { $0.replacingOccurrences(of: #"labels → """#, with: "labels → nil") }
    }

    /// And over a tree read into a dictionary rather than a string.
    static var emptyMap: [String] {
        emptyTree.map { $0.replacingOccurrences(of: #"labels → """#, with: "labels → [:]") }
    }

    /// An expression wider than one line of this answer may print.
    static var wideName: String {
        String(repeating: "bay.", count: 80) + "labels"
    }

    /// Forty failures that read the tree through it.
    static var wideReading: [String] {
        emptyTree.map { $0.replacingOccurrences(of: "labels → ", with: "\(wideName) → ") }
    }
}
