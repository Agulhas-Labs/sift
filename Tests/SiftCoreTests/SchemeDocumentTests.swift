//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers what one `.xcscheme` document says: both shapes of `TestAction`, where Xcode reads a scheme from, and the file that will not parse.
///
/// The XML the cases are built from is ``SchemeAnswerTests``' own, so the documents this reads are the documents that suite's answers are made of.
@Suite(.temporaryDirectories)
struct SchemeDocumentTests {
    private static func read(
        _ xml: String,
        path: String = "Gizmo.xcodeproj/xcshareddata/xcschemes/Gizmo.xcscheme",
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> SchemeFile {
        let location = try #require(SchemeFile.location(ofRepoRelativePath: path), sourceLocation: sourceLocation)
        return try SchemeFile.read(Data(xml.utf8), name: "Gizmo", path: path, location: location)
    }

    /// The legacy shape: the targets a test action lists, the one it skips, and the app target of the build action it never confuses for either.
    @Test
    func theTestablesBlockIsReadWithoutTheBuildActionsOwnBuildableReference() throws {
        let scheme = try Self.read(SchemeAnswerTests.legacyScheme(running: "BetaTests", skipping: "LegacyTests"))

        let action = try #require(scheme.testAction)

        #expect(action.testables == [
            SchemeFile.Testable(target: "BetaTests", isSkipped: false),
            SchemeFile.Testable(target: "LegacyTests", isSkipped: true),
        ])
        #expect(action.runTargets == ["BetaTests"])
        #expect(action.planReferences.isEmpty)
    }

    /// The plan shape: the references as written, which one is the default, and the `Testables` block they supersede.
    @Test
    func aTestActionNamingPlansReadsThemAndSupersedesItsTestables() throws {
        let scheme = try Self.read(SchemeAnswerTests.planScheme(naming: "TestPlans/Default.xctestplan", alsoListing: "BetaTests"))

        let action = try #require(scheme.testAction)

        #expect(action.planReferences == [
            SchemeFile.PlanReference(reference: "container:TestPlans/Default.xctestplan", isDefault: true),
        ])
        #expect(action.runTargets.isEmpty)
        #expect(action.supersededTargets == ["BetaTests"])
        #expect(scheme.planPath(of: action.planReferences[0]) == "TestPlans/Default.xctestplan")
    }

    /// A reference climbing out of the scheme's own container names a plan beside it, resolved against the directory that holds the container.
    @Test
    func aPlanReferenceThatClimbsOutOfItsContainerResolvesAgainstTheContainersDirectory() throws {
        let scheme = try Self.read(
            SchemeAnswerTests.planScheme(naming: "../TestDemo/TestPlans/Default.xctestplan", alsoListing: "BetaTests"),
            path: "ValidationProjects/SchemeDemo/SchemeDemo.xcodeproj/xcshareddata/xcschemes/Planned.xcscheme"
        )

        let action = try #require(scheme.testAction)

        #expect(scheme.containerScope == "ValidationProjects/SchemeDemo")
        #expect(scheme.planPath(of: action.planReferences[0]) == "ValidationProjects/TestDemo/TestPlans/Default.xctestplan")
    }

    /// Where Xcode reads a scheme from, and the two shapes it reads: a file at this extension anywhere else is not a scheme anything runs.
    @Test
    func onlyAFileWhereXcodeReadsASchemeFromIsReadAsOne() {
        let shared = SchemeFile.location(ofRepoRelativePath: "App/Gizmo.xcodeproj/xcshareddata/xcschemes/Gizmo.xcscheme")
        #expect(shared == SchemeFile.Location(container: "App/Gizmo.xcodeproj", containerScope: "App", isShared: true))

        let workspace = SchemeFile.location(ofRepoRelativePath: "Gizmo.xcworkspace/xcshareddata/xcschemes/Gizmo.xcscheme")
        #expect(workspace == SchemeFile.Location(container: "Gizmo.xcworkspace", containerScope: "", isShared: true))

        let user = SchemeFile.location(ofRepoRelativePath: "Gizmo.xcodeproj/xcuserdata/tester.xcuserdatad/xcschemes/Gizmo.xcscheme")
        #expect(user?.isShared == false)
        #expect(user?.container == "Gizmo.xcodeproj")

        #expect(SchemeFile.location(ofRepoRelativePath: "Templates/Gizmo.xcscheme") == nil)
        #expect(SchemeFile.location(ofRepoRelativePath: "Gizmo.xcodeproj/xcschemes/Gizmo.xcscheme") == nil)
    }

    /// A scheme that will not parse is named rather than dropped, since what it runs is exactly what the claims above would have needed.
    @Test
    func aSchemeThatWillNotParseIsCarriedAsUnreadable() throws {
        let root = try TestSources.makeTempDirectory()
        try TestSources.write("<Scheme><TestAction>", to: SchemeAnswerTests.sharedSchemePath, in: root)

        let survey = try SchemeDiscovery.schemes(under: root)

        #expect(survey.schemes.isEmpty)
        #expect(survey.unreadable.map(\.path) == [SchemeAnswerTests.sharedSchemePath])
    }

    /// A document with no test action runs no tests, which is a fact about the scheme rather than a failure to read it.
    @Test
    func aSchemeWithNoTestActionIsReadAsRunningNothing() throws {
        let scheme = try Self.read("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Scheme version = \"1.7\"></Scheme>")

        #expect(scheme.testAction == nil)
        #expect(scheme.isShared)
    }

    /// The committed fixture is read as what it is: both shapes of test action, from the one place Xcode reads a shared scheme.
    @Test
    func theCommittedSchemeFixtureIsReadFromTheRepository() throws {
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let survey = try SchemeDiscovery.schemes(under: repositoryRoot.appendingPathComponent("ValidationProjects/SchemeDemo"))

        #expect(survey.unreadable.isEmpty)
        #expect(survey.schemes.map(\.name) == ["GizmoApp", "Planned"])
        #expect(survey.schemes[0].testAction?.runTargets == ["GizmoTests"])
        #expect(survey.schemes[0].testAction?.testables.last?.isSkipped == true)
        #expect(survey.schemes[1].testAction?.runTargets.isEmpty == true)
        #expect(survey.schemes[1].testAction?.planReferences.count == 2)
    }
}
