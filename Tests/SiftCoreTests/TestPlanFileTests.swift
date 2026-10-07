//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers reading one `.xctestplan` document, against the shapes the three committed plans do not carry — a disabled target, `selectedTests`, a configuration's own retry setting, and a document that is not a plan.
struct TestPlanFileTests {
    private func read(_ json: String) throws -> TestPlanFile {
        try TestPlanFile.read(Data(json.utf8), name: "Inline", path: "TestPlans/Inline.xctestplan")
    }

    @Test
    func anEntryKeepsItsWrittenFormAndItsParts() throws {
        let plan = try read("""
        {"version":1,"testTargets":[{"parallelizable":true,
        "skippedTests":["CalculatorTests/testAddition()","MathSuite/addsTwoNumbers()","LegacyTests"],
        "target":{"containerPath":"container:TestDemo.xcodeproj","identifier":"30E1","name":"DemoUnitTests"}}]}
        """)

        #expect(plan.name == "Inline")
        #expect(plan.path == "TestPlans/Inline.xctestplan")
        let target = try #require(plan.targets.first)
        #expect(plan.targets.count == 1)
        #expect(target.name == "DemoUnitTests")
        #expect(target.containerPath == "container:TestDemo.xcodeproj")
        #expect(target.isEnabled)
        #expect(target.selected.isEmpty)
        #expect(target.skipped.map(\.written) == ["CalculatorTests/testAddition()", "MathSuite/addsTwoNumbers()", "LegacyTests"])
        #expect(target.skipped.map(\.type) == ["CalculatorTests", "MathSuite", "LegacyTests"])
        #expect(target.skipped.map(\.function) == ["testAddition()", "addsTwoNumbers()", nil])
        #expect(target.skipped.map(\.carriesParentheses) == [true, true, false])
    }

    @Test
    func anEntryWithoutParenthesesIsCarriedAsItIsWritten() throws {
        let plan = try read("""
        {"version":1,"testTargets":[{"skippedTests":["MathSuite/addsTwoNumbers"],
        "target":{"name":"DemoUnitTests"}}]}
        """)

        let entry = try #require(plan.targets.first?.skipped.first)

        #expect(entry.written == "MathSuite/addsTwoNumbers")
        #expect(entry.type == "MathSuite")
        #expect(entry.function == "addsTwoNumbers")
        #expect(entry.carriesParentheses == false)
        #expect(plan.targets.first?.containerPath == nil)
    }

    @Test
    func aTargetIsEnabledUnlessTheDocumentSaysOtherwise() throws {
        let plan = try read("""
        {"version":1,"testTargets":[{"enabled":false,"target":{"name":"DemoUITests"}},
        {"target":{"name":"DemoUnitTests"}}]}
        """)

        #expect(plan.targets.map(\.name) == ["DemoUITests", "DemoUnitTests"])
        #expect(plan.targets.map(\.isEnabled) == [false, true])
    }

    @Test
    func selectedTestsAreCarriedBesideSkipped() throws {
        let plan = try read("""
        {"version":1,"testTargets":[{"selectedTests":["CalculatorTests/testAddition()","MathSuite"],
        "skippedTests":["CalculatorTests/testDivision()"],"target":{"name":"DemoUnitTests"}}]}
        """)

        let target = try #require(plan.targets.first)

        #expect(target.selected.map(\.written) == ["CalculatorTests/testAddition()", "MathSuite"])
        #expect(target.selected.map(\.function) == ["testAddition()", nil])
        #expect(target.skipped.map(\.written) == ["CalculatorTests/testDivision()"])
    }

    @Test
    func theRetrySettingsAreReadFromDefaultOptions() throws {
        let plan = try read("""
        {"version":1,"defaultOptions":{"codeCoverage":false,"testRepetitionMode":"retryOnFailure",
        "maximumTestRepetitions":3},"testTargets":[{"target":{"name":"DemoUnitTests"}}]}
        """)

        #expect(plan.repetitionMode == "retryOnFailure")
        #expect(plan.maximumRepetitions == 3)
    }

    @Test
    func aConfigurationsOwnRetrySettingIsNotRead() throws {
        let plan = try read("""
        {"version":1,"configurations":[{"id":"9C6C","name":"Test Scheme Configuration",
        "options":{"testRepetitionMode":"retryOnFailure","maximumTestRepetitions":3}}],
        "defaultOptions":{"codeCoverage":false},"testTargets":[{"target":{"name":"DemoUnitTests"}}]}
        """)

        #expect(plan.repetitionMode == nil)
        #expect(plan.maximumRepetitions == nil)
    }

    @Test
    func somethingThatIsNotThePlanDocumentIsADescribedFailure() throws {
        let error = try #require(throws: TestPlanError.self) {
            try read("this is not JSON at all")
        }

        #expect(error.description.contains("TestPlans/Inline.xctestplan"))
        #expect(error.description.contains("could not read the test plan"))
    }

    @Test
    func aDocumentWithNoTestTargetsIsADescribedFailure() throws {
        let error = try #require(throws: TestPlanError.self) {
            try read(#"{"version":1,"configurations":[],"defaultOptions":{"codeCoverage":false}}"#)
        }

        #expect(error.description.contains("TestPlans/Inline.xctestplan"))
        #expect(error.description.contains("testTargets"))
    }

    // MARK: - The steps of an identifier

    /// The identifier Xcode writes for a test of a nested type is read as the whole suite path, because splitting on the first `/` alone leaves the rest of the path in the function and matches nothing.
    @Test
    func aNestedIdentifierIsReadAsItsWholeSuitePath() throws {
        let plan = try read("""
        {"version":1,"testTargets":[{"skippedTests":["AlphaTests/NamedSuite/testX()","AlphaTests/NamedSuite","AlphaTests/testX"],
        "target":{"containerPath":"container:Alpha.xcodeproj","identifier":"30E1","name":"AlphaTests"}}]}
        """)

        let target = try #require(plan.targets.first)
        #expect(target.skipped.map(\.type) == ["AlphaTests.NamedSuite", "AlphaTests.NamedSuite", "AlphaTests"])
        #expect(target.skipped.map(\.function) == ["testX()", nil, "testX"])
        #expect(target.skipped.map(\.carriesParentheses) == [true, false, false])
        let readable = target.skipped.map(\.isReadable)
        #expect(readable == [true, true, true])
    }

    /// An entry with an empty step in it is neither a suite path nor a function, and is carried as unreadable rather than guessed at.
    @Test
    func anEntryWithAnEmptyStepIsUnreadable() throws {
        let plan = try read("""
        {"version":1,"testTargets":[{"skippedTests":["AlphaTests//testX()","AlphaTests/",""],
        "target":{"containerPath":"container:Alpha.xcodeproj","identifier":"30E1","name":"AlphaTests"}}]}
        """)

        let target = try #require(plan.targets.first)
        let readable = target.skipped.map(\.isReadable)

        #expect(readable == [false, false, false])
        #expect(target.skipped.map(\.written) == ["AlphaTests//testX()", "AlphaTests/", ""])
    }

    // MARK: - What a container confines a plan to

    /// A container written as a sibling of the plan is read as the wider of the two layouts that spelling covers, since narrowing would drop a target the plan does name.
    @Test
    func aContainerBesideThePlanIsReadAsTheDirectoryAboveTheFolderOfPlans() throws {
        let plan = try TestPlanFile.read(
            Data("""
            {"version":1,"testTargets":[{"target":{"containerPath":"container:Alpha.xcodeproj","identifier":"30E1","name":"AlphaTests"}}]}
            """.utf8),
            name: "Inline",
            path: "Alpha/TestPlans/Inline.xctestplan"
        )

        let target = try #require(plan.targets.first)

        #expect(plan.containerScope(of: target) == "Alpha")
    }

    /// A container written with `..` says where it is, and its own directory is the scope.
    @Test
    func aContainerWrittenWithADotDotStepScopesToItsOwnDirectory() throws {
        let plan = try TestPlanFile.read(
            Data("""
            {"version":1,"testTargets":[
            {"target":{"containerPath":"container:../../Alpha.xcodeproj","identifier":"30E1","name":"AlphaTests"}},
            {"target":{"identifier":"30E2","name":"BetaTests"}}]}
            """.utf8),
            name: "Inline",
            path: "Alpha/Plans/Nested/Inline.xctestplan"
        )

        #expect(plan.containerScope(of: plan.targets[0]) == "Alpha")
        #expect(plan.containerScope(of: plan.targets[1]) == nil)
    }
}
