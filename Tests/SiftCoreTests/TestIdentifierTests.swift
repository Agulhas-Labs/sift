//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers the one normaliser between the three spellings of a test — the enumeration's, XCTest's log's and Swift Testing's.
///
/// The identifiers here are the ones `xcodebuild` itself printed for the `TestDemo` validation project (Xcode 27.0, 17 Sep 2026); `ValidationProjects/README.md` records them under *Measured behaviour*, and `Fixtures/RunOutput/xcodebuild-enumerate-tests.json` is the capture.
struct TestIdentifierTests {
    @Test
    func anEnumeratedIdentifierSplitsIntoItsThreeParts() throws {
        let test = try #require(TestIdentifier(enumerated: "DemoUnitTests/CalculatorTests/testAddition()"))

        #expect(test.target == "DemoUnitTests")
        #expect(test.type == "CalculatorTests")
        #expect(test.function == "testAddition()")
        #expect(test.enumerated == "DemoUnitTests/CalculatorTests/testAddition()")
    }

    @Test
    func aSelectorThatNamesASetOfTestsIsNotAnIdentifier() {
        // `Target` and `Target/Class` are what `--only` and `--skip` take, and each names a set.
        #expect(TestIdentifier(enumerated: "DemoUnitTests") == nil)
        #expect(TestIdentifier(enumerated: "DemoUnitTests/CalculatorTests") == nil)
        #expect(TestIdentifier(enumerated: "DemoUnitTests//testAddition()") == nil)
        #expect(TestIdentifier(enumerated: "A/B/C/D") == nil)
    }

    @Test
    func theFunctionNameDropsParenthesesAndLabels() throws {
        let plain = try #require(TestIdentifier(enumerated: "DemoUnitTests/MathSuite/addsTwoNumbers()"))
        let parameterised = try #require(TestIdentifier(enumerated: "DemoUnitTests/MathSuite/doublingIsEven(_:)"))

        #expect(plain.functionName == "addsTwoNumbers")
        #expect(parameterised.functionName == "doublingIsEven")
        #expect(parameterised.function == "doublingIsEven(_:)")
    }

    @Test
    func onlyTestingCarriesTheEnumerationsOwnSpelling() throws {
        // Measured: XCTest ran from the spelling without parentheses and Swift Testing needed them.
        // Neither is composed here — each is the string the enumeration printed.
        let xctest = try #require(TestIdentifier(enumerated: "DemoUnitTests/CalculatorTests/testAddition()"))
        let swiftTesting = try #require(TestIdentifier(enumerated: "DemoLogicTests/DemoLogicTests/evenNumbersAreEven()"))

        #expect(xctest.onlyTestingArgument == "-only-testing:DemoUnitTests/CalculatorTests/testAddition()")
        #expect(swiftTesting.onlyTestingArgument == "-only-testing:DemoLogicTests/DemoLogicTests/evenNumbersAreEven()")
    }

    @Test
    func bothXCTestLogSpellingsNameTheOneTest() throws {
        let test = try #require(TestIdentifier(enumerated: "DemoUnitTests/CalculatorTests/testAddition()"))

        #expect(test.matches(xctestLogName: "-[DemoUnitTests.CalculatorTests testAddition]"))
        #expect(test.matches(xctestLogName: "-[CalculatorTests testAddition]"))
    }

    @Test
    func anXCTestLogNameForAnotherTestDoesNotMatch() throws {
        let test = try #require(TestIdentifier(enumerated: "DemoUnitTests/CalculatorTests/testAddition()"))

        #expect(!test.matches(xctestLogName: "-[DemoUnitTests.CalculatorTests testDivision]"))
        #expect(!test.matches(xctestLogName: "-[DemoUnitTests.StringHelperTests testAddition]"))
        #expect(!test.matches(xctestLogName: "-[OtherTarget.CalculatorTests testAddition]"))
        #expect(!test.matches(xctestLogName: "testAddition()"))
    }

    @Test
    func aSwiftTestingLogNameMatchesBehindItsDecoration() throws {
        let test = try #require(TestIdentifier(enumerated: "DemoUnitTests/MathSuite/addsTwoNumbers()"))

        #expect(test.matches(swiftTestingLogName: "addsTwoNumbers()"))
        #expect(test.matches(swiftTestingLogName: "\u{200B}addsTwoNumbers()"))
        #expect(!test.matches(swiftTestingLogName: "subtractsTwoNumbers()"))
    }

    @Test
    func aQuotedDisplayNameIsNotGuessedOntoATest() throws {
        let test = try #require(TestIdentifier(enumerated: "DemoUnitTests/MathSuite/addsTwoNumbers()"))

        // A display name is nothing the enumeration printed, so it claims no test at all.
        #expect(!test.matches(swiftTestingLogName: "\"adds two numbers\""))
        #expect(!test.matches(swiftTestingLogName: "\"addsTwoNumbers()\""))
    }

    @Test
    func aParameterisedTestMatchesWhateverLabelsTheLogUsed() throws {
        let test = try #require(TestIdentifier(enumerated: "DemoUnitTests/MathSuite/doublingIsEven(_:)"))

        #expect(test.matches(swiftTestingLogName: "doublingIsEven(_:)"))
        #expect(test.matches(swiftTestingLogName: "doublingIsEven(number:)"))
    }

    @Test
    func aTargetSpelledWithSpacesIsNamedByItsModuleName() throws {
        // Measured on `Demo Spaced Tests`: the enumeration keeps the spaces, the log writes the module
        // name, and `-only-testing:` wants the spaces back — the three spellings of one test.
        let test = try #require(TestIdentifier(enumerated: "Demo Spaced Tests/SpacedTests/testCountsUp()"))

        #expect(test.moduleName == "Demo_Spaced_Tests")
        #expect(test.matches(xctestLogName: "-[Demo_Spaced_Tests.SpacedTests testCountsUp]"))
        #expect(test.matches(xctestLogName: "-[SpacedTests testCountsUp]"))
        #expect(test.onlyTestingArgument == "-only-testing:Demo Spaced Tests/SpacedTests/testCountsUp()")
    }

    @Test
    func aModuleNameNamesOnlyItsOwnTargetsTests() throws {
        let test = try #require(TestIdentifier(enumerated: "Demo Spaced Tests/SpacedTests/testCountsUp()"))

        #expect(!test.matches(xctestLogName: "-[Demo_Spaced_Tests.SpacedTests testCountsDown]"))
        #expect(!test.matches(xctestLogName: "-[Demo_Spaced_Tests.SomeOtherTests testCountsUp]"))
        #expect(!test.matches(xctestLogName: "-[Other_Spaced_Tests.SpacedTests testCountsUp]"))
    }

    @Test
    func aModuleNameIsASwiftIdentifierWhateverTheTargetIsCalled() throws {
        // The substitution is the measured half; the leading `_` is the other half of Xcode's
        // `c99ext_identifier` rule, since a module name cannot begin with a digit.
        let punctuated = try #require(TestIdentifier(enumerated: "Demo-Tests.iOS/SpacedTests/testCountsUp()"))
        let leadingDigit = try #require(TestIdentifier(enumerated: "2FA Tests/SpacedTests/testCountsUp()"))
        let alreadyAnIdentifier = try #require(TestIdentifier(enumerated: "DemoUnitTests/CalculatorTests/testAddition()"))

        #expect(punctuated.moduleName == "Demo_Tests_iOS")
        #expect(leadingDigit.moduleName == "_2FA_Tests")
        #expect(alreadyAnIdentifier.moduleName == "DemoUnitTests")
    }

    @Test
    func classAndMethodAloneMatchesWhateverQualifierTheLogPrinted() throws {
        // `matchesByClassAndMethod` is the loose tier `TestNameMatch` falls to for a hand-set
        // `PRODUCT_MODULE_NAME` — neither the target's own name nor its derived `moduleName`.
        let test = try #require(TestIdentifier(enumerated: "Demo Spaced Tests/SpacedTests/testCountsUp()"))

        #expect(test.matchesByClassAndMethod(xctestLogName: "-[Custom_Module.SpacedTests testCountsUp]"))
        #expect(test.matchesByClassAndMethod(xctestLogName: "-[SpacedTests testCountsUp]"))
        #expect(!test.matchesByClassAndMethod(xctestLogName: "-[Custom_Module.SpacedTests testCountsDown]"))
        #expect(!test.matchesByClassAndMethod(xctestLogName: "-[Custom_Module.SomeOtherTests testCountsUp]"))
    }

    @Test
    func aNestedTypeWithTheSameNameIsNotClaimedByItsTopLevelNamesake() throws {
        // Both classes are named `GizmoTests`; only the second is nested inside `WidgetTests`. A
        // hand-set `PRODUCT_MODULE_NAME` (`GhostKit`, neither `LibTests` nor its derived module name)
        // sends both log lines through `matchesByClassAndMethod`, which must tell them apart by more
        // than a class name the two share.
        let topLevel = try #require(TestIdentifier(enumerated: "LibTests/GizmoTests/testTwo()"))
        let nested = try #require(TestIdentifier(enumerated: "LibTests/WidgetTests.GizmoTests/testTwo()"))

        let reconciled = TestNameMatch.reconcile(
            expected: [topLevel, nested],
            reported: ["-[GhostKit.GizmoTests testTwo]", "-[GhostKit.WidgetTests.GizmoTests testTwo]"]
        )

        #expect(reconciled.named[topLevel] == ["-[GhostKit.GizmoTests testTwo]"])
        #expect(reconciled.named[nested] == ["-[GhostKit.WidgetTests.GizmoTests testTwo]"])
        #expect(reconciled.unclaimed.isEmpty)
        #expect(reconciled.byCountOnly.isEmpty)
    }
}
