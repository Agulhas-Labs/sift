//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers module attribution read straight out of an `.xcodeproj`, the build file the largest repositories use.
///
/// Written against hand-authored `project.pbxproj` fixtures rather than generated ones: the point of every case below is a shape the generator would never emit — a directory whose name is not its module, a target name that is not a legal module name, a folder-synchronized group — and a fixture that can only be produced by the tool under test proves nothing about the projects this has to read.
@Suite(.temporaryDirectories)
struct XcodeProjectTargetsTests {
    /// A project whose sources live in `Legacy/` but compile into `AlmanacCore`, so a directory-name guess is provably wrong rather than accidentally right.
    private static func writeProject(
        targetName: String = "AlmanacCore",
        productModuleName: String? = "AlmanacCore",
        in root: URL,
        at projectName: String = "AlmanacApp.xcodeproj"
    ) throws {
        let moduleSetting = productModuleName.map { "PRODUCT_MODULE_NAME = \($0); " } ?? ""
        try TestSources.write(
            """
            // !$*UTF8*$!
            {
                archiveVersion = 1;
                objectVersion = 56;
                objects = {
                    ROOT = { isa = PBXProject; targets = (T1); mainGroup = G0; };
                    G0 = { isa = PBXGroup; children = (G1); sourceTree = "<group>"; };
                    G1 = { isa = PBXGroup; path = Legacy; children = (F1, F2); sourceTree = "<group>"; };
                    F1 = { isa = PBXFileReference; path = Thing.swift; sourceTree = "<group>"; };
                    F2 = { isa = PBXFileReference; path = Other.swift; sourceTree = "<group>"; };
                    B1 = { isa = PBXBuildFile; fileRef = F1; };
                    B2 = { isa = PBXBuildFile; fileRef = F2; };
                    P1 = { isa = PBXSourcesBuildPhase; files = (B1, B2); };
                    T1 = {
                        isa = PBXNativeTarget;
                        name = "\(targetName)";
                        buildPhases = (P1);
                        buildConfigurationList = CL1;
                    };
                    CL1 = { isa = XCConfigurationList; buildConfigurations = (C1); };
                    C1 = { isa = XCBuildConfiguration; name = Debug; buildSettings = { \(moduleSetting)SWIFT_VERSION = 6.0; }; };
                };
                rootObject = ROOT;
            }
            """,
            to: "\(projectName)/project.pbxproj",
            in: root
        )
        try TestSources.write("struct Thing {}\n", to: "Legacy/Thing.swift", in: root)
        try TestSources.write("struct Other {}\n", to: "Legacy/Other.swift", in: root)
    }

    private static func makeRoot() throws -> URL {
        try TemporaryDirectory.make("xcodeproj").appendingPathComponent("xcodeproj")
    }

    /// The whole point: a file whose directory is named nothing like its module resolves, where the fallback would have named the directory.
    @Test
    func aTargetsSourcesResolveThroughTheGroupTree() throws {
        let root = try Self.makeRoot()
        try Self.writeProject(in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.resolvedModule(for: "Legacy/Thing.swift") == "AlmanacCore")
        #expect(resolver.module(for: "Legacy/Thing.swift") == "AlmanacCore")
    }

    /// `PRODUCT_MODULE_NAME` is what the compiler imports, so it outranks the target's own name.
    @Test
    func aDeclaredProductModuleNameOutranksTheTargetName() throws {
        let root = try Self.makeRoot()
        try Self.writeProject(targetName: "AlmanacCore-iOS", productModuleName: "AlmanacCore", in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.resolvedModule(for: "Legacy/Thing.swift") == "AlmanacCore")
    }

    /// A target may be named anything; a module may not, and the compiler substitutes `_` for what it cannot carry.
    @Test
    func aTargetNameThatIsNotALegalModuleNameIsSanitized() throws {
        let root = try Self.makeRoot()
        try Self.writeProject(targetName: "Almanac App-iOS", productModuleName: nil, in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.resolvedModule(for: "Legacy/Thing.swift") == "Almanac_App_iOS")
    }

    /// Two files in one directory become one prefix — the resolver matches by longest prefix with a linear scan per file, so an entry per source file would make attribution quadratic on the repositories this exists for.
    @Test
    func filesOfOneDirectoryCollapseToASinglePrefix() throws {
        let root = try Self.makeRoot()
        try Self.writeProject(in: root)

        let mappings = XcodeProjectTargets.mappings(
            projectPath: root.appendingPathComponent("AlmanacApp.xcodeproj"),
            repoRoot: root
        )

        #expect(mappings == ["Legacy": "AlmanacCore"])
    }

    /// An Xcode 16 folder-synchronized target names a directory and compiles whatever is in it — the whole mapping in one entry, and the shape a modern project is most likely to use.
    @Test
    func aFolderSynchronizedTargetMapsItsDirectory() throws {
        let root = try Self.makeRoot()
        try TestSources.write(
            """
            // !$*UTF8*$!
            {
                archiveVersion = 1;
                objectVersion = 77;
                objects = {
                    ROOT = { isa = PBXProject; targets = (T1); mainGroup = G0; };
                    G0 = { isa = PBXGroup; children = (S1); sourceTree = "<group>"; };
                    S1 = { isa = PBXFileSystemSynchronizedRootGroup; path = Features; sourceTree = "<group>"; };
                    T1 = {
                        isa = PBXNativeTarget;
                        name = Features;
                        fileSystemSynchronizedGroups = (S1);
                        buildPhases = ();
                        buildConfigurationList = CL1;
                    };
                    CL1 = { isa = XCConfigurationList; buildConfigurations = (C1); };
                    C1 = { isa = XCBuildConfiguration; name = Debug; buildSettings = { PRODUCT_MODULE_NAME = FeatureKit; }; };
                };
                rootObject = ROOT;
            }
            """,
            to: "App.xcodeproj/project.pbxproj",
            in: root
        )
        try TestSources.write("struct Screen {}\n", to: "Features/Screen.swift", in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.resolvedModule(for: "Features/Screen.swift") == "FeatureKit")
    }

    /// A hand-written `moduleMap` is a deliberate override and still has the last word over anything read from a build file.
    @Test
    func anExplicitModuleMapStillOutranksTheProject() throws {
        let root = try Self.makeRoot()
        try Self.writeProject(in: root)
        var config = SiftConfig()
        config.moduleMap = ["Legacy": "HandPicked"]
        let resolver = ModuleResolver(repoRoot: root, config: config)

        // Both halves, so the test fails if the project stops being read as well as if the override stops winning —
        // asserting only the override would pass identically against a resolver that never opened the project.
        #expect(ModuleResolver(repoRoot: root, config: SiftConfig()).resolvedModule(for: "Legacy/Thing.swift") == "AlmanacCore")
        #expect(resolver.resolvedModule(for: "Legacy/Thing.swift") == "HandPicked")
    }

    /// An upgraded binary must re-attribute an existing index without anyone running `init` or `reset`, and the fingerprint carrying `logicVersion` is the whole mechanism that makes it happen.
    @Test
    func theResolutionLogicVersionIsCarriedInTheFingerprint() throws {
        let root = try Self.makeRoot()
        try Self.writeProject(in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.fingerprint.hasPrefix("v\(ModuleResolver.logicVersion):"))
        #expect(ModuleResolver.logicVersion >= 3)
    }

    /// A project regenerated to say exactly what it said before must not move the fingerprint, or every XcodeGen run re-attributes the whole index for nothing.
    @Test
    func regeneratingAProjectWithNewObjectIDsLeavesTheFingerprintAlone() throws {
        let root = try Self.makeRoot()
        try Self.writeProject(in: root)
        let before = ModuleResolver(repoRoot: root, config: SiftConfig()).fingerprint

        // The same project with every object ID rewritten, which is what XcodeGen does on each generate.
        let original = try String(contentsOf: root.appendingPathComponent("AlmanacApp.xcodeproj/project.pbxproj"), encoding: .utf8)
        var rewritten = original
        for (old, new) in [("ROOT", "AAA1"), ("G0", "AAA2"), ("G1", "AAA3"), ("F1", "AAA4"), ("F2", "AAA5"), ("B1", "AAA6"), ("B2", "AAA7"), ("P1", "AAA8"), ("T1", "AAA9"), ("CL1", "AAB1"), ("C1", "AAB2")] {
            rewritten = rewritten.replacingOccurrences(of: old, with: new)
        }
        try TestSources.write(rewritten, to: "AlmanacApp.xcodeproj/project.pbxproj", in: root)

        #expect(ModuleResolver(repoRoot: root, config: SiftConfig()).fingerprint == before)
    }

    /// A project whose targets change meaning must move it, or the upgrade path above has nothing to trigger on.
    @Test
    func retargetingSourcesMovesTheFingerprint() throws {
        let root = try Self.makeRoot()
        try Self.writeProject(in: root)
        let before = ModuleResolver(repoRoot: root, config: SiftConfig()).fingerprint

        try Self.writeProject(targetName: "AlmanacCore", productModuleName: "SomethingElse", in: root)

        #expect(ModuleResolver(repoRoot: root, config: SiftConfig()).fingerprint != before)
    }
}
