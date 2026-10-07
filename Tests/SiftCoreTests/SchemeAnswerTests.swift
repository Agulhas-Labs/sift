//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the answer `test --analyse` gives once the schemes are read: which claim it makes about a target no plan names, and the claim it still declines to make.
///
/// The end-to-end cases go through ``SiftEngine/analyseTests(plan:freshness:)`` over a repository written for each one, because the property is about an answer a reader gets and not about a type: without the scheme read, every one of them comes back saying a target is named by no plan and that whether anything runs it is not read here.
@Suite(.temporaryDirectories)
struct SchemeAnswerTests {
    /// A repository with three test targets, a plan naming one of them, and whichever schemes the case states.
    private static func makeRepo(schemes: [(path: String, xml: String)]) throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            name: Gizmo
            targets:
              AlphaTests:
                type: bundle.unit-test
                platform: iOS
                sources:
                  - path: AlphaTests
              BetaTests:
                type: bundle.unit-test
                platform: iOS
                sources:
                  - path: BetaTests
              DepotKitTests:
                type: bundle.unit-test
                platform: iOS
                sources:
                  - path: DepotKitTests
            """,
            to: "project.yml",
            in: root
        )
        for target in ["AlphaTests", "BetaTests", "DepotKitTests"] {
            try TestSources.write(
                """
                import XCTest

                final class \(target)Cases: XCTestCase {
                    func testOne() {
                        XCTAssertTrue(true)
                    }
                }
                """,
                to: "\(target)/\(target)Cases.swift",
                in: root
            )
        }
        try TestSources.write(
            """
            {"version":1,"testTargets":[{"target":{"containerPath":"container:Gizmo.xcodeproj",
            "identifier":"30E1","name":"AlphaTests"}}]}
            """,
            to: "TestPlans/Default.xctestplan",
            in: root
        )
        for scheme in schemes {
            try TestSources.write(scheme.xml, to: scheme.path, in: root)
        }
        try TestSources.commitAll(in: root, message: "scheme fixture")
        return root
    }

    /// A scheme whose test action lists `Testables` directly, with no test plan involved.
    static func legacyScheme(running target: String, skipping skipped: String? = nil) -> String {
        let skippedBlock = skipped.map { name in
            """
                  <TestableReference skipped = "YES">
                     <BuildableReference BuildableIdentifier = "primary" BuildableName = "\(name).xctest" \
            BlueprintName = "\(name)" ReferencedContainer = "container:Gizmo.xcodeproj">
                     </BuildableReference>
                  </TestableReference>
            """
        } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme LastUpgradeVersion = "2700" version = "1.7">
           <BuildAction>
              <BuildActionEntries>
                 <BuildActionEntry buildForTesting = "YES">
                    <BuildableReference BuildableIdentifier = "primary" BuildableName = "GizmoApp.app" \
        BlueprintName = "GizmoApp" ReferencedContainer = "container:Gizmo.xcodeproj">
                    </BuildableReference>
                 </BuildActionEntry>
              </BuildActionEntries>
           </BuildAction>
           <TestAction buildConfiguration = "Debug">
              <Testables>
                 <TestableReference skipped = "NO" parallelizable = "NO">
                    <BuildableReference BuildableIdentifier = "primary" BuildableName = "\(target).xctest" \
        BlueprintName = "\(target)" ReferencedContainer = "container:Gizmo.xcodeproj">
                    </BuildableReference>
                 </TestableReference>
        \(skippedBlock)   </Testables>
           </TestAction>
        </Scheme>
        """
    }

    /// A scheme whose test action names a test plan, and carries a `Testables` block the plan supersedes.
    static func planScheme(naming plan: String, alsoListing target: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme LastUpgradeVersion = "2700" version = "1.7">
           <TestAction buildConfiguration = "Debug">
              <TestPlans>
                 <TestPlanReference reference = "container:\(plan)" default = "YES">
                 </TestPlanReference>
              </TestPlans>
              <Testables>
                 <TestableReference skipped = "NO">
                    <BuildableReference BuildableIdentifier = "primary" BuildableName = "\(target).xctest" \
        BlueprintName = "\(target)" ReferencedContainer = "container:Gizmo.xcodeproj">
                    </BuildableReference>
                 </TestableReference>
              </Testables>
           </TestAction>
        </Scheme>
        """
    }

    private static func answer(of root: URL) async throws -> String {
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try engine.analyseTests(plan: nil, freshness: freshness)
    }

    static var sharedSchemePath: String {
        "Gizmo.xcodeproj/xcshareddata/xcschemes/Gizmo.xcscheme"
    }

    // MARK: - The answer a reader gets

    /// The property the whole change exists for: a target a scheme's `Testables` runs is reported as run by that scheme, and a target neither a plan nor a scheme names is reported as one nothing runs.
    @Test
    func aTargetASchemeTestActionRunsIsReportedAsRunAndOneInNeitherAsRunByNothing() async throws {
        let root = try Self.makeRepo(schemes: [(path: Self.sharedSchemePath, xml: Self.legacyScheme(running: "BetaTests"))])

        let answer = try await Self.answer(of: root)

        #expect(answer.contains("whole targets a scheme's TestAction runs with no plan involved (1 target, 1 tests)"))
        #expect(answer.contains("  BetaTests — 1 declared tests, named by no plan under consideration and run by the TestAction of Gizmo"))
        #expect(answer.contains("⚠ whole targets nothing under this repository runs (1 target, 1 tests)"))
        #expect(answer.contains("  DepotKitTests — 1 declared tests"))
        #expect(answer.contains("named by no .xctestplan found under this repository, and by no TestAction of the 1 .xcscheme read above"))
        // The weaker claim the strong one replaces is gone wherever a scheme settled the question.
        #expect(answer.contains("whether anything runs them is not read here") == false)
    }

    /// With no scheme to read, the answer is the one it always was: no claim about what runs a target, and the sentence saying so.
    @Test
    func withNoSchemeTheAnswerClaimsNothingMoreThanItDidBefore() async throws {
        let root = try Self.makeRepo(schemes: [])

        let answer = try await Self.answer(of: root)

        #expect(answer.contains("whole targets named by no .xctestplan found under this repository (2 targets, 2 tests)"))
        #expect(answer.contains("whether anything runs them is not read here: a scheme's TestAction runs the targets it lists with no plan involved, and no .xcscheme is read for them here."))
        #expect(answer.contains("Whether a scheme is wired to any of them is not read here."))
        #expect(answer.contains("whole targets nothing under this repository runs") == false)
        #expect(answer.contains(".xcscheme read live off disk") == false)
    }

    /// A scheme that names a test plan says which plan, so an orphan `.xctestplan` and a wired one stop reading alike.
    @Test
    func aPlanASchemeNamesIsReportedAsWiredToIt() async throws {
        let root = try Self.makeRepo(schemes: [(
            path: Self.sharedSchemePath,
            xml: Self.planScheme(naming: "TestPlans/Default.xctestplan", alsoListing: "BetaTests")
        )])

        let answer = try await Self.answer(of: root)

        #expect(answer.contains("Default (TestPlans/Default.xctestplan, 1 enabled targets, named by scheme Gizmo)"))
        #expect(answer.contains("names test plans: TestPlans/Default.xctestplan"))
    }

    /// A target listed only in a `Testables` block that test plans supersede is claimed neither way: the exclusivity is Xcode's and unmeasured here, so the answer withholds the strong claim rather than making it on an assumption.
    @Test
    func aTargetOnlyASupersededTestablesBlockNamesIsClaimedNeitherWay() async throws {
        let root = try Self.makeRepo(schemes: [(
            path: Self.sharedSchemePath,
            xml: Self.planScheme(naming: "TestPlans/Default.xctestplan", alsoListing: "BetaTests")
        )])

        let answer = try await Self.answer(of: root)

        #expect(answer.contains("  BetaTests — 1 declared tests, named by no plan under consideration, named by the superseded Testables of Gizmo"))
        #expect(answer.contains("whether anything runs them is not read here"))
        // DepotKitTests is named by nothing at all, and that claim is made on the same answer.
        #expect(answer.contains("⚠ whole targets nothing under this repository runs (1 target, 1 tests)"))
    }

    /// A per-user scheme runs what it lists on one machine, so the answer names it and says which it is.
    @Test
    func aPerUserSchemeIsReadAndNamedAsPerUser() async throws {
        let root = try Self.makeRepo(schemes: [(
            path: "Gizmo.xcodeproj/xcuserdata/tester.xcuserdatad/xcschemes/Gizmo.xcscheme",
            xml: Self.legacyScheme(running: "BetaTests")
        )])

        let answer = try await Self.answer(of: root)

        #expect(answer.contains("Gizmo [per-user] (Gizmo.xcodeproj/xcuserdata/tester.xcuserdatad/xcschemes/Gizmo.xcscheme)"))
        #expect(answer.contains("run by the TestAction of Gizmo [per-user]"))
    }
}
