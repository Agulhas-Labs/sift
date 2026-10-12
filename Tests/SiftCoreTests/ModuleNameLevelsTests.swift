//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A module name is spelt as Xcode spells it, and read from whichever level of build settings Xcode reads it from: the target's own settings, its xcconfig, then the project's.
@Suite(.temporaryDirectories)
struct ModuleNameLevelsTests {
    /// Each pair measured with `xcodebuild -showBuildSettings` (Xcode 26); `swift package describe` agrees on the first three.
    @Test(arguments: [
        ("Café Ünï", "Café_Ünï"), ("3D", "_D"), ("A😀B", "A_B"), ("My-App", "My_App"), ("ü", "ü"), ("_x", "_x"),
        ("٣D", "_D"), ("x²", "x_"), ("a·b", "a·b"), ("ⅫX", "ⅫX"), ("e\u{301}x", "\u{E9}x"), ("\u{2126}", "\u{3A9}"),
    ])
    func aNameIsSpeltAsXcodeSpellsIt(name: String, module: String) {
        #expect(Array(C99ExtendedIdentifier.spelling(of: name).unicodeScalars) == Array(module.unicodeScalars))
    }

    private static func resolver(spec: String, files: [String: String] = [:]) throws -> ModuleResolver {
        let root = try TemporaryDirectory.make("module-levels").appendingPathComponent("module-levels")
        try TestSources.write(spec, to: "project.yml", in: root)
        for (path, text) in files {
            try TestSources.write(text, to: path, in: root)
        }
        try TestSources.write("public struct Widget {}\n", to: "Sources/Kit/Widget.swift", in: root)
        return ModuleResolver(repoRoot: root, config: SiftConfig())
    }

    private static func target(_ name: String, _ body: String) -> String {
        "name: Pair\ntargets:\n  \(name):\n    type: framework\n    platform: iOS\n    sources: [Sources/Kit]\n\(body)\n"
    }

    /// A target named with a letter Xcode keeps builds that letter; spelling it `_` dropped `extension Café.Widget` unmarked.
    @Test
    func aUnicodeTargetNameIsKept() throws {
        let resolver = try Self.resolver(spec: Self.target("Café", "    settings:\n      PRODUCT_NAME: $(TARGET_NAME)"))

        #expect(resolver.resolvedModule(for: "Sources/Kit/Widget.swift") == "Café")
    }

    /// An xcconfig's `PRODUCT_MODULE_NAME` outranks the default the target's `PRODUCT_NAME` would give: Xcode builds `Xcc`.
    @Test
    func anXcconfigModuleNameOutranksTheTargetsProductName() throws {
        let body = "    configFiles:\n      Debug: x.xcconfig\n      Release: x.xcconfig\n    settings:\n      PRODUCT_NAME: \"My Xcc\""
        let resolver = try Self.resolver(spec: Self.target("Xcc", body), files: ["x.xcconfig": "PRODUCT_MODULE_NAME = $(TARGET_NAME)\n"])

        #expect(resolver.resolvedModule(for: "Sources/Kit/Widget.swift") == "Xcc")
    }

    /// An xcconfig that includes another could set anything, so a module it could rename is a guess.
    @Test
    func anIncludingXcconfigLeavesTheModuleGuessed() throws {
        let body = "    configFiles:\n      Debug: x.xcconfig\n      Release: x.xcconfig\n    settings:\n      PRODUCT_NAME: Other"
        let resolver = try Self.resolver(spec: Self.target("Kit", body), files: ["x.xcconfig": "#include \"shared.xcconfig\"\n"])

        #expect(resolver.resolvedModule(for: "Sources/Kit/Widget.swift") == nil)
    }

    /// A project-wide `PRODUCT_NAME` names every target that sets none of its own (measured with xcodegen 2.46.0).
    @Test
    func aProjectProductNameNamesTheModule() throws {
        let spec = "settings:\n  PRODUCT_NAME: ProjectProduct\n" + Self.target("Kit", "")
        let resolver = try Self.resolver(spec: spec)

        #expect(resolver.resolvedModule(for: "Sources/Kit/Widget.swift") == "ProjectProduct")
    }

    /// The same rename in every configuration is the module, with or without `base`; each reference spelling expands.
    @Test(arguments: [
        ("      configs:\n        Debug:\n          PRODUCT_MODULE_NAME: Kit2\n        Release:\n          PRODUCT_MODULE_NAME: Kit2", "Kit2"),
        ("      PRODUCT_MODULE_NAME: ${TARGET_NAME}Core", "KitCore"),
        ("      PRODUCT_NAME: My Kit\n      PRODUCT_MODULE_NAME: $(PRODUCT_NAME:c99extidentifier)", "My_Kit"),
        ("      PRODUCT_NAME: Shell\n      PRODUCT_MODULE_NAME: $(PRODUCT_NAME)Core", "ShellCore"),
    ])
    func aReadableRenameNamesTheModule(settings: String, module: String) throws {
        let resolver = try Self.resolver(spec: Self.target("Kit", "    settings:\n" + settings))

        #expect(resolver.resolvedModule(for: "Sources/Kit/Widget.swift") == module)
    }
}
