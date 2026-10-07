//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// With no store, a name match in a test target that cannot load the module declaring the name is set aside and counted, never listed.
@Suite(.serialized, .temporaryDirectories)
struct AffectedModuleReachTests {
    static var package: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Lib",
            targets: [
                .target(name: "Lib"),
                .target(name: "Gizmo"),
                .testTarget(name: "LibTests", dependencies: ["Lib"]),
                .testTarget(name: "GizmoTests", dependencies: ["Gizmo"]),
            ]
        )
        """
    }

    static func gizmo(tone: Int) -> String {
        """
        public struct Gizmo {
            public init() {}
            public func polish() -> Int { \(tone) }
        }
        """
    }

    /// Two libraries each declaring a member named the same, and a test target for each that writes it.
    ///
    /// The change is to the second library only, so the first library's tests share nothing with it but the written name; whether an import in the first test target names the changed module is the one thing a test varies.
    static func makeRepo(libTestsImportGizmo: Bool) throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(package, to: "Package.swift", in: root)
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func polish() -> Int { 0 }\n}\n", to: "Sources/Lib/Widget.swift", in: root)
        try TestSources.write(gizmo(tone: 1), to: "Sources/Gizmo/Gizmo.swift", in: root)
        let extra = libTestsImportGizmo ? "import Gizmo\n" : ""
        try TestSources.write(
            "import Testing\n@testable import Lib\n\(extra)\nstruct Checks {\n    @Test func polishes() {\n        #expect(Widget().polish() == 0)\n    }\n}\n",
            to: "Tests/LibTests/Checks.swift",
            in: root
        )
        try TestSources.write(
            "import Testing\n@testable import Gizmo\n\nstruct Checks {\n    @Test func polishes() {\n        #expect(Gizmo().polish() > 0)\n    }\n}\n",
            to: "Tests/GizmoTests/Checks.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "seed")
        try TestSources.write(gizmo(tone: 2), to: "Sources/Gizmo/Gizmo.swift", in: root)
        try TestSources.commitAll(in: root, message: "change")
        return root
    }

    static func affected(_ root: URL) async throws -> String {
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(range: AffectedOptions.CommitRange(from: "HEAD~1", to: "HEAD")), freshness: freshness)
    }

    @Test
    func aTestTargetThatCannotLoadTheChangedModuleIsSetAsideAndCounted() async throws {
        let output = try await Self.affected(Self.makeRepo(libTestsImportGizmo: false))

        #expect(output.contains("NAME MATCH ONLY"), "\(output)")
        #expect(output.contains("GizmoTests.Checks/polishes()"), "\(output)")
        #expect(!output.contains("LibTests.Checks/polishes()"), "\(output)")
        #expect(output.contains("1 name-matched test or suite set aside in LibTests: its module cannot load the module declaring the name written there"), "\(output)")
    }

    @Test
    func anImportOfTheChangedModuleKeepsTheMatch() async throws {
        let output = try await Self.affected(Self.makeRepo(libTestsImportGizmo: true))

        #expect(output.contains("GizmoTests.Checks/polishes()"), "\(output)")
        #expect(output.contains("LibTests.Checks/polishes()"), "\(output)")
        #expect(!output.contains("set aside in"), "\(output)")
    }

    /// A project compiling `Model.swift` into both `App` and `AppTests`, where a second test target, `LibTests`, imports `App`; the change is to the shared file.
    static func makeSharedFileRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // !$*UTF8*$!
            {
                archiveVersion = 1;
                objectVersion = 56;
                objects = {
                    ROOT = { isa = PBXProject; targets = (T1, T2, T3); mainGroup = G0; };
                    G0 = { isa = PBXGroup; children = (GA, GT, GO); sourceTree = "<group>"; };
                    GA = { isa = PBXGroup; path = Sources/App; children = (F1); sourceTree = "<group>"; };
                    GT = { isa = PBXGroup; path = Tests/AppTests; children = (F2); sourceTree = "<group>"; };
                    GO = { isa = PBXGroup; path = Tests/LibTests; children = (F3); sourceTree = "<group>"; };
                    F1 = { isa = PBXFileReference; path = Model.swift; sourceTree = "<group>"; };
                    F2 = { isa = PBXFileReference; path = Checks.swift; sourceTree = "<group>"; };
                    F3 = { isa = PBXFileReference; path = Use.swift; sourceTree = "<group>"; };
                    B1 = { isa = PBXBuildFile; fileRef = F1; };
                    B2 = { isa = PBXBuildFile; fileRef = F2; };
                    B3 = { isa = PBXBuildFile; fileRef = F3; };
                    B4 = { isa = PBXBuildFile; fileRef = F1; };
                    P1 = { isa = PBXSourcesBuildPhase; files = (B1); };
                    P2 = { isa = PBXSourcesBuildPhase; files = (B4, B2); };
                    P3 = { isa = PBXSourcesBuildPhase; files = (B3); };
                    T1 = { isa = PBXNativeTarget; name = App; buildPhases = (P1); buildConfigurationList = CL1; };
                    T2 = { isa = PBXNativeTarget; name = AppTests; buildPhases = (P2); buildConfigurationList = CL1; };
                    T3 = { isa = PBXNativeTarget; name = LibTests; buildPhases = (P3); buildConfigurationList = CL1; };
                    CL1 = { isa = XCConfigurationList; buildConfigurations = (C1); };
                    C1 = { isa = XCBuildConfiguration; name = Debug; buildSettings = { SWIFT_VERSION = 6.0; }; };
                };
                rootObject = ROOT;
            }
            """,
            to: "Shop.xcodeproj/project.pbxproj",
            in: root
        )
        try TestSources.write(gizmo(tone: 1), to: "Sources/App/Model.swift", in: root)
        try TestSources.write("import Testing\nimport App\n\nlet depot = 1\n", to: "Tests/LibTests/Use.swift", in: root)
        try TestSources.write(
            "import Testing\n\nstruct Checks {\n    @Test func polishes() {\n        #expect(Gizmo().polish() > 0)\n    }\n}\n",
            to: "Tests/AppTests/Checks.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "seed")
        try TestSources.write(gizmo(tone: 2), to: "Sources/App/Model.swift", in: root)
        try TestSources.commitAll(in: root, message: "change")
        return root
    }

    @Test
    func aTestTargetCompilingASharedFileItselfIsListedWithoutAnImport() async throws {
        let output = try await Self.affected(Self.makeSharedFileRepo())

        #expect(output.contains("AppTests.Checks/polishes()"), "\(output)")
        #expect(!output.contains("set aside in"), "\(output)")
    }
}
