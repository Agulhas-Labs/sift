//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers reading `xcodebuild`'s flat JSON test enumeration, against the real capture in `Fixtures/RunOutput`.
struct TestEnumerationTests {
    private func read(_ json: String) throws -> TestEnumeration {
        try TestEnumeration.read(Data(json.utf8))
    }

    @Test
    func theCaptureGivesOnePlansEnabledTests() throws {
        let data = try TestSources.runOutputData("xcodebuild-enumerate-tests", extension: "json")

        let enumeration = try TestEnumeration.read(data)

        #expect(enumeration.testPlan == "Default")
        #expect(enumeration.enabledTests.count == 6)
        #expect(enumeration.disabledTests.isEmpty)
        #expect(enumeration.enabledTests.map(\.enumerated).contains("DemoUnitTests/CalculatorTests/testAddition()"))
        // Both frameworks are spelled the same way, and a parameterised test is one entry.
        #expect(enumeration.enabledTests.map(\.enumerated).contains("DemoUnitTests/MathSuite/addsTwoNumbers()"))
        #expect(enumeration.enabledTests.map(\.enumerated).contains("DemoUnitTests/MathSuite/doublingIsEven(_:)"))
    }

    @Test
    func aDisabledTestIsReadAsOne() throws {
        let enumeration = try read("""
        {"errors":[],"values":[{"testPlan":"Excluding","enabledTests":[{"identifier":"A/B/c()"}],
        "disabledTests":[{"identifier":"A/B/d()"}]}]}
        """)

        #expect(enumeration.enabledTests.map(\.enumerated) == ["A/B/c()"])
        #expect(enumeration.disabledTests.map(\.enumerated) == ["A/B/d()"])
    }

    @Test
    func twoTestPlansAreADescribedFailure() throws {
        let json = """
        {"errors":[],"values":[{"testPlan":"Default","enabledTests":[],"disabledTests":[]},
        {"testPlan":"Excluding","enabledTests":[],"disabledTests":[]}]}
        """

        let error = try #require(throws: TestEnumerationError.self) {
            try read(json)
        }

        #expect(error.description.contains("Default"))
        #expect(error.description.contains("Excluding"))
        #expect(error.description.contains("one plan per run"))
    }

    @Test
    func noTestPlanAtAllIsADescribedFailure() throws {
        let error = try #require(throws: TestEnumerationError.self) {
            try read("""
            {"errors":[],"values":[]}
            """)
        }

        #expect(error.description.contains("named no test plan"))
    }

    @Test
    func aReportedErrorIsCarriedInWhateverShapeItArrived() throws {
        let asString = try #require(throws: TestEnumerationError.self) {
            try read("""
            {"errors":["the scheme has no test action"],"values":[]}
            """)
        }
        let asObject = try #require(throws: TestEnumerationError.self) {
            try read("""
            {"errors":[{"message":"no such test plan","code":"3"}],"values":[]}
            """)
        }
        let asSomethingElse = try #require(throws: TestEnumerationError.self) {
            try read("""
            {"errors":[17],"values":[]}
            """)
        }

        #expect(asString.description.contains("the scheme has no test action"))
        #expect(asObject.description.contains("message: no such test plan"))
        #expect(asSomethingElse.description.contains("an unreadable entry"))
    }

    @Test
    func anIdentifierOfAnotherShapeIsADescribedFailure() throws {
        let error = try #require(throws: TestEnumerationError.self) {
            try read("""
            {"errors":[],"values":[{"testPlan":"Default","enabledTests":[{"identifier":"A/B"}],"disabledTests":[]}]}
            """)
        }

        #expect(error.description.contains("`A/B`"))
    }

    @Test
    func somethingThatIsNotTheDocumentIsADescribedFailure() throws {
        let error = try #require(throws: TestEnumerationError.self) {
            try read("** TEST EXECUTE FAILED **")
        }

        #expect(error.description.contains("could not read"))
    }
}
