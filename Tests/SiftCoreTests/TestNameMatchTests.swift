//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers matching one shard's expected tests against the names its log reported.
///
/// The reported names are the keys `RunTestOutcomes` files an ending under: everything between the quotes for XCTest (`-[Suite testName]`), and the function or display name for Swift Testing.
struct TestNameMatchTests {
    private func identifier(_ enumerated: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> TestIdentifier {
        try #require(TestIdentifier(enumerated: enumerated), sourceLocation: sourceLocation)
    }

    @Test
    func bothFrameworksNamesReachTheirOwnTests() throws {
        let xctest = try identifier("DemoUnitTests/CalculatorTests/testAddition()")
        let swiftTesting = try identifier("DemoUnitTests/MathSuite/addsTwoNumbers()")

        let match = TestNameMatch.reconcile(
            expected: [xctest, swiftTesting],
            reported: ["-[DemoUnitTests.CalculatorTests testAddition]", "addsTwoNumbers()"]
        )

        #expect(match.named[xctest] == ["-[DemoUnitTests.CalculatorTests testAddition]"])
        #expect(match.named[swiftTesting] == ["addsTwoNumbers()"])
        #expect(match.unclaimed.isEmpty)
        #expect(match.byCountOnly.isEmpty)
        #expect(match.countOnlyNote == nil)
    }

    @Test
    func aTestThatNeverReportedIsNamedByNothing() throws {
        let ran = try identifier("DemoUnitTests/CalculatorTests/testAddition()")
        let missing = try identifier("DemoUnitTests/CalculatorTests/testDivision()")

        let match = TestNameMatch.reconcile(expected: [ran, missing], reported: ["-[CalculatorTests testAddition]"])

        #expect(match.named[ran]?.count == 1)
        #expect(match.named[missing] == [])
    }

    @Test
    func aReportedNameClaimingNoTestIsReturnedNotFatal() throws {
        let expected = try identifier("DemoUnitTests/MathSuite/addsTwoNumbers()")

        let match = TestNameMatch.reconcile(
            expected: [expected],
            reported: ["addsTwoNumbers()", "\"a display name\"", "-[SomeOtherTests testNothing]"]
        )

        #expect(match.named[expected] == ["addsTwoNumbers()"])
        #expect(match.unclaimed == ["-[SomeOtherTests testNothing]", "\"a display name\""])
    }

    @Test
    func oneFunctionNameInTwoSuitesIsCountedNotMatched() throws {
        let first = try identifier("DemoUnitTests/MathSuite/formatsUppercase()")
        let second = try identifier("DemoUnitTests/FormattingSuite/formatsUppercase()")

        let match = TestNameMatch.reconcile(
            expected: [first, second],
            reported: ["formatsUppercase()", "formatsUppercase()"]
        )

        // Swift Testing's log names no suite, so neither test can be said to be the one that ended.
        #expect(match.named[first] == [])
        #expect(match.named[second] == [])
        #expect(match.unclaimed.isEmpty)
        let ambiguity = try #require(match.byCountOnly.first)
        #expect(match.byCountOnly.count == 1)
        #expect(ambiguity.function == "formatsUppercase")
        #expect(ambiguity.expected == [second, first])
        #expect(ambiguity.reported == ["formatsUppercase()", "formatsUppercase()"])
        #expect(match.countOnlyNote?.contains("formatsUppercase") == true)
    }

    @Test
    func theLogDecidesWhichFrameworkAnIdentifierBelongsTo() throws {
        // Two tests spelled identically apart from their suite, one of each framework. Nothing in the
        // identifiers says which is which — the `-[…]` line does, and it goes first.
        let xctest = try identifier("DemoUnitTests/CalculatorTests/testAddition()")
        let swiftTesting = try identifier("DemoUnitTests/MathSuite/testAddition()")

        let match = TestNameMatch.reconcile(
            expected: [xctest, swiftTesting],
            reported: ["-[DemoUnitTests.CalculatorTests testAddition]", "testAddition()"]
        )

        #expect(match.named[xctest] == ["-[DemoUnitTests.CalculatorTests testAddition]"])
        #expect(match.named[swiftTesting] == ["testAddition()"])
        #expect(match.byCountOnly.isEmpty)
    }

    @Test
    func anUnqualifiedXCTestNameOverTwoTargetsIsCounted() throws {
        let first = try identifier("AlphaTests/CalculatorTests/testAddition()")
        let second = try identifier("BetaTests/CalculatorTests/testAddition()")

        let match = TestNameMatch.reconcile(expected: [first, second], reported: ["-[CalculatorTests testAddition]"])

        #expect(match.named[first] == [])
        #expect(match.named[second] == [])
        #expect(match.byCountOnly.map(\.function) == ["testAddition"])
    }

    @Test
    func theXCTestCountOnlyNoteNamesTheClassAndTarget() throws {
        let first = try identifier("AlphaTests/CalculatorTests/testAddition()")
        let second = try identifier("BetaTests/CalculatorTests/testAddition()")

        let match = TestNameMatch.reconcile(expected: [first, second], reported: ["-[CalculatorTests testAddition]"])

        #expect(match.countOnlyNote == "Reconciled by count only: testAddition. XCTest's log named these tests by their class without their target and its shard expected more than one target declaring that class, so an ending cannot be matched to one of them.")
    }

    @Test
    func theSwiftTestingCountOnlyNoteNamesTheFunctionAlone() throws {
        let first = try identifier("DemoUnitTests/MathSuite/formatsUppercase()")
        let second = try identifier("DemoUnitTests/FormattingSuite/formatsUppercase()")

        let match = TestNameMatch.reconcile(
            expected: [first, second],
            reported: ["formatsUppercase()", "formatsUppercase()"]
        )

        #expect(match.countOnlyNote == "Reconciled by count only: formatsUppercase. Swift Testing's log names these tests by their function alone and its shard expected more than one test declaring each, so an ending cannot be matched to one of them.")
    }

    @Test
    func bothFrameworksAmbiguousOverTheSameFunctionNameStayTwoGroups() throws {
        let xctestFirst = try identifier("AlphaTests/CalculatorTests/testAddition()")
        let xctestSecond = try identifier("BetaTests/CalculatorTests/testAddition()")
        let swiftTestingFirst = try identifier("AlphaTests/MathSuite/testAddition()")
        let swiftTestingSecond = try identifier("AlphaTests/FormattingSuite/testAddition()")

        let match = TestNameMatch.reconcile(
            expected: [xctestFirst, xctestSecond, swiftTestingFirst, swiftTestingSecond],
            reported: ["-[CalculatorTests testAddition]", "testAddition()", "testAddition()"]
        )

        #expect(match.byCountOnly.count == 2)
        #expect(match.byCountOnly.map(\.function) == ["testAddition", "testAddition"])
        let xctestAmbiguity = try #require(match.byCountOnly.first { $0.framework == .xctest })
        #expect(xctestAmbiguity.expected == [xctestFirst, xctestSecond])
        #expect(xctestAmbiguity.reported == ["-[CalculatorTests testAddition]"])
        let swiftTestingAmbiguity = try #require(match.byCountOnly.first { $0.framework == .swiftTesting })
        #expect(swiftTestingAmbiguity.expected == [swiftTestingSecond, swiftTestingFirst])
        #expect(swiftTestingAmbiguity.reported == ["testAddition()", "testAddition()"])
    }

    @Test
    func unclaimedNamesGroupXCTestBeforeSwiftTestingEachInReportedOrder() {
        let match = TestNameMatch.reconcile(
            expected: [],
            reported: ["\"z display name\"", "-[GizmoTests testOne]", "\"a display name\"", "-[GizmoTests testNothing]"]
        )

        #expect(match.unclaimed == [
            "-[GizmoTests testOne]",
            "-[GizmoTests testNothing]",
            "\"z display name\"",
            "\"a display name\"",
        ])
    }

    @Test
    func aHandSetModuleNameReconcilesWhenExactMatchingClaimsNothingForItsTarget() throws {
        // `Demo Spaced Tests` derives `Demo_Spaced_Tests`; a `PRODUCT_MODULE_NAME` of `Custom_Module` is
        // neither that nor the target's own name, so only the loose class-and-method tier reaches it.
        let test = try identifier("Demo Spaced Tests/SpacedTests/testCountsUp()")

        let match = TestNameMatch.reconcile(expected: [test], reported: ["-[Custom_Module.SpacedTests testCountsUp]"])

        #expect(match.named[test] == ["-[Custom_Module.SpacedTests testCountsUp]"])
        #expect(match.unclaimed.isEmpty)
    }

    @Test
    func twoTargetsWithASameNamedClassStillReconcileExactlyOnceEitherLogsItsOwnQualifier() throws {
        let first = try identifier("DemoUnitTests/CalculatorTests/testAddition()")
        let second = try identifier("Demo Spaced Tests/CalculatorTests/testAddition()")

        let match = TestNameMatch.reconcile(
            expected: [first, second],
            reported: ["-[DemoUnitTests.CalculatorTests testAddition]", "-[Demo_Spaced_Tests.CalculatorTests testAddition]"]
        )

        #expect(match.named[first] == ["-[DemoUnitTests.CalculatorTests testAddition]"])
        #expect(match.named[second] == ["-[Demo_Spaced_Tests.CalculatorTests testAddition]"])
        #expect(match.byCountOnly.isEmpty)
    }

    /// A full suite's log is matched in time that grows with its size, not with its size squared.
    ///
    /// Asking every reported name of every expected test took over a minute in a debug build for a suite of a few thousand tests, and `sift run` gives the check a budget measured in seconds, so a slow match is a note that says the run could not be checked on exactly the suites the check exists for.
    @Test
    func aSuiteOfThousandsIsMatchedInTimeLinearInItsSize() throws {
        let count = 3000
        let xctest = try (0 ..< count).map { try identifier("DemoUnitTests/CalculatorTests/testAddition\($0)()") }
        let swiftTesting = try (0 ..< count).map { try identifier("DemoUnitTests/MathSuite/addsTwoNumbers\($0)()") }
        let reported = (0 ..< count).map { "-[DemoUnitTests.CalculatorTests testAddition\($0)]" }
            + (0 ..< count).map { "addsTwoNumbers\($0)()" }

        var match: TestNameMatch?
        let elapsed = ContinuousClock().measure {
            match = TestNameMatch.reconcile(expected: xctest + swiftTesting, reported: reported)
        }
        let matched = try #require(match)

        #expect(matched.named.values.filter { $0.count == 1 }.count == 2 * count)
        #expect(matched.unclaimed.isEmpty)
        #expect(elapsed < .seconds(5), "matching \(2 * count) tests took \(elapsed)")
    }
}
