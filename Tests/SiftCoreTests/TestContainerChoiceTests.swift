//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// What a directory's names decide about which project or workspace a run builds.
struct TestContainerChoiceTests {
    /// The one candidate comes back as an absolute path, since the directory that held it is not always the one the build is started from.
    @Test
    func theOneProjectIsNamedByItsWholePath() throws {
        let directory = URL(fileURLWithPath: "/repo/app")

        #expect(try TestContainerChoice.chosen(among: ["Gizmo.xcodeproj", "README.md"], in: directory) == .project("/repo/app/Gizmo.xcodeproj"))
    }

    /// A workspace is what its projects are built through, so one of them settles it however many projects sit beside it.
    @Test
    func theOneWorkspaceWinsOverEveryProjectBesideIt() throws {
        let names = ["Orchard.xcworkspace", "Gizmo.xcodeproj", "Depot.xcodeproj"]

        #expect(try TestContainerChoice.chosen(among: names, in: URL(fileURLWithPath: "/repo")) == .workspace("/repo/Orchard.xcworkspace"))
    }

    /// Two projects and no flag is a refusal that names both, and names the flag that settles it.
    @Test
    func twoProjectsAndNoFlagRefuseNamingBothAndTheFlag() {
        #expect(throws: TestContainerError.self) {
            try TestContainerChoice.chosen(among: ["Gizmo.xcodeproj", "Depot.xcodeproj"], in: URL(fileURLWithPath: "/repo"))
        }
        let refusal = TestContainerError.severalProjects(["Gizmo.xcodeproj", "Depot.xcodeproj"], directory: URL(fileURLWithPath: "/repo")).description

        #expect(refusal.contains("Gizmo.xcodeproj"))
        #expect(refusal.contains("Depot.xcodeproj"))
        #expect(refusal.contains("--project"))
    }

    /// Two workspaces refuse rather than falling through to the project beside them: the thing that would have decided is itself undecided.
    @Test
    func twoWorkspacesRefuseRatherThanFallingThroughToTheProject() {
        let names = ["Orchard.xcworkspace", "Depot.xcworkspace", "Gizmo.xcodeproj"]

        #expect(throws: TestContainerError.self) {
            try TestContainerChoice.chosen(among: names, in: URL(fileURLWithPath: "/repo"))
        }
    }

    /// Every `.xcodeproj` carries an `.xcworkspace` of Xcode's own, and counting it would make one project look like a workspace and a project.
    @Test
    func theWorkspaceInsideAProjectIsNotACandidate() throws {
        let names = ["Gizmo.xcodeproj", "Gizmo.xcodeproj/project.xcworkspace"]

        #expect(try TestContainerChoice.chosen(among: names, in: URL(fileURLWithPath: "/repo")) == .project("/repo/Gizmo.xcodeproj"))
    }

    /// A directory holding neither decides nothing, which is what lets a caller look in the next one before refusing.
    @Test
    func aDirectoryHoldingNeitherDecidesNothing() throws {
        #expect(try TestContainerChoice.chosen(among: ["Package.swift", "Sources"], in: URL(fileURLWithPath: "/repo")) == nil)
    }

    /// A SwiftPM package with no `.xcodeproj` of its own settles on no container at all — `xcodebuild` resolves the scheme from `Package.swift` with neither flag.
    @Test
    func aPackageWithNoProjectSettlesOnNoContainer() throws {
        let container = try TestContainerChoice.chosen(
            inWorkingDirectory: URL(fileURLWithPath: "/repo/Gizmo"),
            names: ["Package.swift", "Sources"],
            andRepositoryRoot: URL(fileURLWithPath: "/repo"),
            names: ["Gizmo"]
        )

        #expect(container == nil)
    }

    /// A package directory nested under a repository root that holds an app's own project resolves to the package, never to the root's project.
    @Test
    func aNestedPackageIsNeverMistakenForTheRootsProject() throws {
        let container = try TestContainerChoice.chosen(
            inWorkingDirectory: URL(fileURLWithPath: "/repo/Gizmo"),
            names: ["Package.swift", "Sources"],
            andRepositoryRoot: URL(fileURLWithPath: "/repo"),
            names: ["Gizmo.xcodeproj"]
        )

        #expect(container == nil)
    }

    /// A working directory with no manifest and no project of its own, and a repository root with no project either, refuses by naming the flags that settle it.
    @Test
    func neitherAManifestNorAProjectAnywhereRefusesNamingTheFlags() {
        #expect(throws: TestContainerError.self) {
            try TestContainerChoice.chosen(
                inWorkingDirectory: URL(fileURLWithPath: "/repo/Gizmo"),
                names: ["README.md"],
                andRepositoryRoot: URL(fileURLWithPath: "/repo"),
                names: ["README.md"]
            )
        }
        let refusal = TestContainerError.nothingFound([URL(fileURLWithPath: "/repo/Gizmo"), URL(fileURLWithPath: "/repo")]).description

        #expect(refusal.contains("--project"))
        #expect(refusal.contains("--workspace"))
    }
}
