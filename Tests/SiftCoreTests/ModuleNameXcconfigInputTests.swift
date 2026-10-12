//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// An xcconfig a module name is read from is a resolution input like the build file naming it: editing its `PRODUCT_MODULE_NAME` re-attributes the files on the next query, and one named but not yet written is watched for, so creating it does too.
@Suite(.temporaryDirectories)
struct ModuleNameXcconfigInputTests {
    /// A spec whose one framework target `Kit` over `Sources/Kit` takes its settings from `Config/Kit.xcconfig`.
    private static var spec: String {
        """
        name: Pair
        targets:
          Kit:
            type: framework
            platform: iOS
            sources: [Sources/Kit]
            configFiles:
              Debug: Config/Kit.xcconfig
              Release: Config/Kit.xcconfig

        """
    }

    /// Rewrites a file in place, as an editor saving it does, and nudges its mtime past the last stat.
    ///
    /// In place matters: an atomic write renames a new file over the old one, which moves the directory's mtime, and the directory stamps would notice that without the xcconfig being an input at all.
    private static func edit(_ relativePath: String, to text: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
        let current = try (FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
        try FileManager.default.setAttributes([.modificationDate: current.addingTimeInterval(2)], ofItemAtPath: url.path)
    }

    private static func indexedEngine(buildFile: String, at buildFilePath: String, source: String, xcconfig: String) async throws -> (SiftEngine, URL) {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(buildFile, to: buildFilePath, in: root)
        try TestSources.write(xcconfig, to: "Config/" + (buildFilePath.hasSuffix(".yml") ? "Kit" : "Almanac") + ".xcconfig", in: root)
        try TestSources.write("struct Thing {}\n", to: source, in: root)
        try TestSources.commitAll(in: root, message: "xcconfig-named module")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return (engine, root)
    }

    @Test
    func anEditedXcconfigReattributesAnXcodeGenTarget() async throws {
        let (engine, root) = try await Self.indexedEngine(
            buildFile: Self.spec, at: "project.yml", source: "Sources/Kit/Thing.swift", xcconfig: "PRODUCT_MODULE_NAME = Kit2\n"
        )
        #expect(try engine.store.fileRow(path: "Sources/Kit/Thing.swift")?.module == "Kit2")

        try Self.edit("Config/Kit.xcconfig", to: "PRODUCT_MODULE_NAME = Kit3\n", in: root)
        _ = try await engine.ensureFresh()

        #expect(try engine.store.fileRow(path: "Sources/Kit/Thing.swift")?.module == "Kit3")
    }

    @Test
    func anEditedXcconfigReattributesAnXcodeProjectTarget() async throws {
        let (engine, root) = try await Self.indexedEngine(
            buildFile: ModuleNameOverrideTests.xcodeProject(buildSettings: "", basedOnXcconfig: true),
            at: "Almanac.xcodeproj/project.pbxproj",
            source: "Legacy/Thing.swift",
            xcconfig: "PRODUCT_MODULE_NAME = Almanac2\n"
        )
        #expect(try engine.store.fileRow(path: "Legacy/Thing.swift")?.module == "Almanac2")

        try Self.edit("Config/Almanac.xcconfig", to: "PRODUCT_MODULE_NAME = Almanac3\n", in: root)
        _ = try await engine.ensureFresh()

        #expect(try engine.store.fileRow(path: "Legacy/Thing.swift")?.module == "Almanac3")
    }

    /// A named xcconfig not written yet leaves the module guessed and is stamped all the same, so writing it is noticed even in a directory nothing else stamps.
    @Test
    func aMissingXcconfigIsAnInputForAnXcodeGenTarget() throws {
        let root = try TemporaryDirectory.make("xcconfig-input").appendingPathComponent("xcconfig-input")
        try TestSources.write(Self.spec, to: "project.yml", in: root)
        try TestSources.write("struct Thing {}\n", to: "Sources/Kit/Thing.swift", in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.resolvedModule(for: "Sources/Kit/Thing.swift") == nil)
        #expect(resolver.inputPaths.contains("Config/Kit.xcconfig"), "\(resolver.inputPaths)")
    }

    @Test
    func aMissingXcconfigIsAnInputForAnXcodeProjectTarget() throws {
        let root = try TemporaryDirectory.make("xcconfig-input").appendingPathComponent("xcconfig-input")
        try TestSources.write(
            ModuleNameOverrideTests.xcodeProject(buildSettings: "", basedOnXcconfig: true),
            to: "Almanac.xcodeproj/project.pbxproj",
            in: root
        )
        try TestSources.write("struct Thing {}\n", to: "Legacy/Thing.swift", in: root)
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(resolver.resolvedModule(for: "Legacy/Thing.swift") == nil)
        #expect(resolver.inputPaths.contains("Config/Almanac.xcconfig"), "\(resolver.inputPaths)")
    }
}
