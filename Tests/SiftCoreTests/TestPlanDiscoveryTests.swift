//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers finding `.xctestplan` files in a tree: the three committed plans of the `TestDemo` validation project, the trees no configuration opts back in, and a file that looks like a plan and is not.
@Suite(.temporaryDirectories)
struct TestPlanDiscoveryTests {
    private static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent() // SiftCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // the repository root

    /// A plan with nothing in it but the one key a plan document has to carry.
    private let emptyPlan = #"{"version":1,"testTargets":[]}"#

    private func write(_ contents: String, to relativePath: String, in root: URL) throws {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test
    func theThreeCommittedPlansDecodeAsTheyAreWritten() throws {
        let survey = try TestPlanDiscovery.plans(under: Self.repository)

        #expect(survey.unreadable.isEmpty)
        #expect(survey.plans.map(\.name) == ["Default", "Excluding", "Retrying"])
        for plan in survey.plans {
            #expect(plan.path == "ValidationProjects/TestDemo/TestPlans/\(plan.name).xctestplan")
            #expect(plan.targets.map(\.name) == ["DemoUnitTests", "DemoLogicTests", "Demo Spaced Tests", "DemoUITests"])
            #expect(plan.targets.map(\.isEnabled) == [true, true, true, true])
            #expect(plan.targets.allSatisfy { $0.containerPath == "container:TestDemo.xcodeproj" })
            #expect(plan.targets.flatMap(\.selected).isEmpty)
        }

        let excluding = try #require(survey.plans.first { $0.name == "Excluding" })
        let unit = try #require(excluding.targets.first { $0.name == "DemoUnitTests" })
        #expect(unit.skipped.map(\.written) == ["CalculatorTests/testAddition()", "MathSuite/addsTwoNumbers()"])
        #expect(unit.skipped.map(\.type) == ["CalculatorTests", "MathSuite"])
        #expect(unit.skipped.map(\.function) == ["testAddition()", "addsTwoNumbers()"])
        #expect(unit.skipped.map(\.carriesParentheses) == [true, true])
        #expect(excluding.targets.filter { $0.name != "DemoUnitTests" }.flatMap(\.skipped).isEmpty)
        #expect(excluding.repetitionMode == nil)

        let retrying = try #require(survey.plans.first { $0.name == "Retrying" })
        #expect(retrying.repetitionMode == "retryOnFailure")
        #expect(retrying.maximumRepetitions == 3)
        #expect(retrying.targets.flatMap(\.skipped).isEmpty)

        let byDefault = try #require(survey.plans.first { $0.name == "Default" })
        #expect(byDefault.targets.flatMap(\.skipped).isEmpty)
        #expect(byDefault.repetitionMode == nil)
        #expect(byDefault.maximumRepetitions == nil)
    }

    @Test
    func aTreeNoConfigurationOptsBackInIsNotWalked() throws {
        let root = try TemporaryDirectory.make("testplans")
        try write(emptyPlan, to: "TestPlans/Visible.xctestplan", in: root)
        try write(emptyPlan, to: ".build/Built.xctestplan", in: root)
        try write(emptyPlan, to: "Pods/Vendored.xctestplan", in: root)
        try write(emptyPlan, to: "node_modules/deep/Installed.xctestplan", in: root)

        let survey = try TestPlanDiscovery.plans(under: root)

        #expect(survey.plans.map(\.name) == ["Visible"])
        #expect(survey.plans.map(\.path) == ["TestPlans/Visible.xctestplan"])
        #expect(survey.unreadable.isEmpty)
    }

    @Test
    func twoPlansOfOneNameAreBothAnsweredInPathOrder() throws {
        let root = try TemporaryDirectory.make("testplans")
        try write(emptyPlan, to: "Beta/Shared.xctestplan", in: root)
        try write(emptyPlan, to: "Alpha/Shared.xctestplan", in: root)
        try write(emptyPlan, to: "Alpha/Another.xctestplan", in: root)

        let survey = try TestPlanDiscovery.plans(under: root)

        #expect(survey.plans.map(\.name) == ["Another", "Shared", "Shared"])
        #expect(survey.plans.map(\.path) == [
            "Alpha/Another.xctestplan",
            "Alpha/Shared.xctestplan",
            "Beta/Shared.xctestplan",
        ])
    }

    @Test
    func aPlanThatCannotBeReadIsNamedRatherThanLeftOut() throws {
        let root = try TemporaryDirectory.make("testplans")
        try write(emptyPlan, to: "TestPlans/Good.xctestplan", in: root)
        try write("half a document {", to: "TestPlans/Broken.xctestplan", in: root)

        let survey = try TestPlanDiscovery.plans(under: root)

        #expect(survey.plans.map(\.name) == ["Good"])
        #expect(survey.unreadable.map(\.path) == ["TestPlans/Broken.xctestplan"])
        let reason = try #require(survey.unreadable.first?.reason)
        #expect(reason.contains("TestPlans/Broken.xctestplan"))
        #expect(reason.contains("could not read the test plan"))
    }

    @Test
    func aRootThatIsNotADirectoryIsADescribedRefusal() throws {
        let root = try TemporaryDirectory.make("testplans")
        let missing = root.appending(path: "DepotStore")

        let error = try #require(throws: TestPlanError.self) {
            try TestPlanDiscovery.plans(under: missing)
        }

        #expect(error.description.contains("DepotStore"))
        #expect(error.description.contains("could not walk"))
    }
}
