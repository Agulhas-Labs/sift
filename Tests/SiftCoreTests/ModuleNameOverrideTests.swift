//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A target's `PRODUCT_MODULE_NAME` or `PRODUCT_NAME` setting names its module, in an XcodeGen spec and an `.xcodeproj` alike, and one this tool cannot expand leaves the target's files guessed rather than counted as resolved under the target's name.
@Suite(.temporaryDirectories)
struct ModuleNameOverrideTests {
    /// A spec with one framework target `Kit` over `Sources/Kit`, carrying `settings`, and an app target importing it.
    private static func spec(settings: String) -> String {
        """
        name: Pair
        targets:
          Kit:
            type: framework
            platform: iOS
            sources: [Sources/Kit]
            settings:
        \(settings)
          App:
            type: application
            platform: iOS
            sources: [Sources/App]

        """
    }

    private static func resolver(settings: String) throws -> ModuleResolver {
        let root = try TemporaryDirectory.make("module-name").appendingPathComponent("module-name")
        try TestSources.write(spec(settings: settings), to: "project.yml", in: root)
        try TestSources.write("public struct Widget {}\n", to: "Sources/Kit/Widget.swift", in: root)
        try TestSources.write("struct Shell {}\n", to: "Sources/App/Shell.swift", in: root)
        return ModuleResolver(repoRoot: root, config: SiftConfig())
    }

    @Test
    func anXcodeGenProductModuleNameNamesTheModule() throws {
        let resolver = try Self.resolver(settings: "      PRODUCT_MODULE_NAME: Kit2")

        #expect(resolver.resolvedModule(for: "Sources/Kit/Widget.swift") == "Kit2")
        #expect(resolver.resolvedModule(for: "Sources/App/Shell.swift") == "App")
    }

    /// Xcode derives the module from the product name through `c99extidentifier`, so `My-App` builds `My_App`.
    @Test
    func anXcodeGenProductNameNamesTheModuleAsTheCompilerSpellsIt() throws {
        let resolver = try Self.resolver(settings: "      base:\n        PRODUCT_NAME: My-App")

        #expect(resolver.resolvedModule(for: "Sources/Kit/Widget.swift") == "My_App")
    }

    /// `$(TARGET_NAME)` is the one reference a spec can be read through; `PRODUCT_MODULE_NAME` outranks `PRODUCT_NAME`.
    @Test
    func aTargetNameReferenceExpandsAndTheModuleNameOutranksTheProductName() throws {
        let resolver = try Self.resolver(settings: "      PRODUCT_NAME: Other\n      PRODUCT_MODULE_NAME: $(TARGET_NAME)Core")

        #expect(resolver.resolvedModule(for: "Sources/Kit/Widget.swift") == "KitCore")
    }

    /// A reference to a setting this tool cannot see, or a rename in one configuration only, leaves the name a guess: the target's name, counted as guessed.
    @Test(arguments: [
        "      PRODUCT_MODULE_NAME: $(FOO)",
        "      configs:\n        Debug:\n          PRODUCT_MODULE_NAME: Kit2",
    ])
    func anUnreadableRenameLeavesTheModuleGuessed(settings: String) throws {
        let resolver = try Self.resolver(settings: settings)

        #expect(resolver.resolvedModule(for: "Sources/Kit/Widget.swift") == nil)
        #expect(resolver.module(for: "Sources/Kit/Widget.swift") == "Kit")
    }

    /// A one-target `.xcodeproj` over `Legacy/`, with `buildSettings` written into its only configuration, based on `Config/Almanac.xcconfig` when asked, and `projectSettings` into the project's configuration of the same name.
    static func xcodeProject(buildSettings: String, projectSettings: String = "", basedOnXcconfig: Bool = false) -> String {
        let base = basedOnXcconfig ? " baseConfigurationReference = X1;" : ""
        return """
        // !$*UTF8*$!
        {
            archiveVersion = 1;
            objectVersion = 56;
            objects = {
                ROOT = { isa = PBXProject; targets = (T1); mainGroup = G0; buildConfigurationList = CL0; };
                CL0 = { isa = XCConfigurationList; buildConfigurations = (C0); };
                C0 = { isa = XCBuildConfiguration; name = Debug; buildSettings = { \(projectSettings) }; };
                G0 = { isa = PBXGroup; children = (G1); sourceTree = "<group>"; };
                G1 = { isa = PBXGroup; path = Legacy; children = (F1); sourceTree = "<group>"; };
                F1 = { isa = PBXFileReference; path = Thing.swift; sourceTree = "<group>"; };
                X1 = { isa = PBXFileReference; path = "Config/Almanac.xcconfig"; sourceTree = SOURCE_ROOT; };
                B1 = { isa = PBXBuildFile; fileRef = F1; };
                P1 = { isa = PBXSourcesBuildPhase; files = (B1); };
                T1 = { isa = PBXNativeTarget; name = Almanac; buildPhases = (P1); buildConfigurationList = CL1; };
                CL1 = { isa = XCConfigurationList; buildConfigurations = (C1); };
                C1 = { isa = XCBuildConfiguration; name = Debug;\(base) buildSettings = { \(buildSettings) }; };
            };
            rootObject = ROOT;
        }
        """
    }

    /// ``xcodeProject(buildSettings:projectSettings:basedOnXcconfig:)`` beside `Legacy/Thing.swift`, and `xcconfig` at `Config/Almanac.xcconfig` where given.
    private static func xcodeProjectResolver(buildSettings: String, projectSettings: String = "", xcconfig: String? = nil) throws -> ModuleResolver {
        let root = try TemporaryDirectory.make("module-name-xcodeproj").appendingPathComponent("module-name-xcodeproj")
        try TestSources.write(
            xcodeProject(buildSettings: buildSettings, projectSettings: projectSettings, basedOnXcconfig: xcconfig != nil),
            to: "Almanac.xcodeproj/project.pbxproj",
            in: root
        )
        if let xcconfig {
            try TestSources.write(xcconfig, to: "Config/Almanac.xcconfig", in: root)
        }
        try TestSources.write("struct Thing {}\n", to: "Legacy/Thing.swift", in: root)
        return ModuleResolver(repoRoot: root, config: SiftConfig())
    }

    @Test
    func anXcodeProjectProductNameNamesTheModule() throws {
        let resolver = try Self.xcodeProjectResolver(buildSettings: "PRODUCT_NAME = \"My-App\";")

        #expect(resolver.resolvedModule(for: "Legacy/Thing.swift") == "My_App")
    }

    /// An xcconfig's `PRODUCT_MODULE_NAME` is what Xcode builds even beneath the target's own `PRODUCT_NAME`, since the module name's default is the only thing the product name feeds.
    @Test
    func anXcodeProjectXcconfigModuleNameOutranksTheTargetsProductName() throws {
        let resolver = try Self.xcodeProjectResolver(buildSettings: "PRODUCT_NAME = Other;", xcconfig: "PRODUCT_MODULE_NAME = Gizmo\n")

        #expect(resolver.resolvedModule(for: "Legacy/Thing.swift") == "Gizmo")
    }

    /// A target that sets neither takes the project configuration's `PRODUCT_NAME`.
    @Test
    func anXcodeProjectProjectLevelProductNameNamesTheModule() throws {
        let resolver = try Self.xcodeProjectResolver(buildSettings: "", projectSettings: "PRODUCT_NAME = \"Depot-Kit\";")

        #expect(resolver.resolvedModule(for: "Legacy/Thing.swift") == "Depot_Kit")
    }

    @Test
    func anXcodeProjectModuleNameThroughAnUnknownSettingLeavesTheModuleGuessed() throws {
        let resolver = try Self.xcodeProjectResolver(buildSettings: "PRODUCT_MODULE_NAME = \"$(FOO)\";")

        #expect(resolver.resolvedModule(for: "Legacy/Thing.swift") == nil)
        #expect(resolver.module(for: "Legacy/Thing.swift") == "Almanac")
    }

    /// The app extends `Widget` through the name it imports the renamed module by.
    private static func engine(settings: String, qualifier: String) async throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(spec(settings: settings), to: "project.yml", in: root)
        try TestSources.write("public struct Widget {}\n", to: "Sources/Kit/Widget.swift", in: root)
        try TestSources.write(
            "import \(qualifier)\n\nextension \(qualifier).Widget {\n    func app() {}\n}\n",
            to: "Sources/App/Touch.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "renamed module")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return engine
    }

    /// The rows of the extensions block `where Widget` answers with, heading first.
    private static func extensionsBlock(in engine: SiftEngine) async throws -> [String] {
        let output = try await engine.lookup(symbol: "Widget", freshness: engine.ensureFresh())
        let lines = output.components(separatedBy: "\n")
        guard let heading = lines.firstIndex(where: { $0.hasPrefix("extensions of ") }) else { return [output] }
        return [lines[heading]] + lines[(heading + 1)...].prefix { $0.hasPrefix("  extension ") }
    }

    /// Read under the target's name, `Kit2` would be a framework the file imports, and its extension of `Widget` would be dropped from a tree every build file mapped.
    @Test
    func whereListsAnExtensionThroughARenamedModule() async throws {
        let engine = try await Self.engine(settings: "      PRODUCT_MODULE_NAME: Kit2", qualifier: "Kit2")
        let block = try await Self.extensionsBlock(in: engine)

        #expect(block == [
            "extensions of Widget (1):",
            "  extension Kit2.Widget — 1 members — Sources/App/Touch.swift:3-5",
        ], "\(block)")
    }

    /// A rename this tool cannot read leaves the module guessed, so the qualifier may be its real name and the extension stays, marked.
    @Test
    func whereKeepsAnExtensionThroughAnUnreadableRenameMarked() async throws {
        let engine = try await Self.engine(settings: "      PRODUCT_MODULE_NAME: $(FOO)", qualifier: "Kit3")
        let block = try await Self.extensionsBlock(in: engine)

        #expect(block == [
            "extensions of Widget (1):",
            "  extension Kit3.Widget — 1 members — Sources/App/Touch.swift:3-5 — may extend another module's Widget",
        ], "\(block)")
    }

    /// An extension in another module counts as a use, and where that module split rests on a rename this tool cannot read the count says so, not that the module was guessed from the path.
    @Test
    func whereSaysAnUnreadableRenameSplitTheModules() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.spec(settings: "      PRODUCT_MODULE_NAME: $(FOO)"), to: "project.yml", in: root)
        try TestSources.write("public struct Widget {}\n", to: "Sources/Kit/Widget.swift", in: root)
        try TestSources.write("import Kit\n\nextension Widget {\n    func app() {}\n}\n", to: "Sources/App/Touch.swift", in: root)
        try TestSources.commitAll(in: root, message: "unreadably renamed module")
        let engine = try SiftEngine(directory: root)
        let output = try await engine.lookup(symbol: "Widget", freshness: engine.ensureFresh(), options: WhereOptions(standsInForSearch: true))

        #expect(output.contains(
            "1 extension in another module counted as use — deleting the type breaks that module (module renamed by a setting this tool cannot read)"
        ), "\(output)")
    }

    /// An alias writing the real module's name before a path where the build renames the module unreadably may name the type, so it is kept, and says why in words true of it.
    @Test
    func whereKeepsAnAliasThroughAnUnreadableRenameSayingWhy() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.spec(settings: "      PRODUCT_MODULE_NAME: $(FOO)"), to: "project.yml", in: root)
        try TestSources.write(
            "enum Net {\n    struct URL {\n        init() {}\n    }\n}\n\ntypealias Link = Kit2.Net.URL\n\nfunc f() {\n    _ = Link()\n}\n",
            to: "Sources/Kit/Net.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "alias through an unreadable rename")
        let engine = try SiftEngine(directory: root)
        let output = try await engine.lookup(symbol: "Net.URL", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))

        #expect(output.contains("kept as a use though not proven to name it, as this type's module is renamed by a setting this tool cannot read"), "\(output)")
    }
}
