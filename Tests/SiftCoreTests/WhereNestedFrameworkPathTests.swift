//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// An extension written through a framework type's nested name (`extension URLSession.Configuration`) cannot extend a local nested type of the same final name whose owner is another type, so `where` leaves it out of that type's extensions; one the code cannot rule out, through the owner's own name, a typealias, or a type of the tree called by the leading name, is still listed.
@Suite(.temporaryDirectories)
struct WhereNestedFrameworkPathTests {
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(name: "Pair", targets: [
            .target(name: "Alpha", path: "Sources/Alpha"),
        ])

        """
    }

    /// Alpha's nested `Loader.Configuration`, a typealias of the framework's session type and one of the loader, and the extensions written through each.
    private static var files: [String: String] {
        [
            "Package.swift": manifest,
            "Sources/Alpha/Loader.swift": "public struct Loader {\n    public struct Configuration {}\n}\n",
            "Sources/Alpha/Aliases.swift": "import Foundation\n\ntypealias Pipe = URLSession\ntypealias Fetcher = Loader\n",
            "Sources/Alpha/Framework.swift": "import Foundation\n\nextension URLSession.Configuration {\n    func framework() {}\n}\n",
            "Sources/Alpha/Own.swift": "extension Loader.Configuration {\n    func own() {}\n}\n",
            "Sources/Alpha/Pipework.swift": "extension Pipe.Configuration {\n    func pipework() {}\n}\n",
            "Sources/Alpha/Fetching.swift": "extension Fetcher.Configuration {\n    func fetching() {}\n}\n",
        ]
    }

    /// The same tree, declaring its own `URLSession` with a nested `Configuration` as well.
    private static var sharedNameFiles: [String: String] {
        var files = files
        files["Sources/Alpha/Session.swift"] = "public struct URLSession {\n    public struct Configuration {}\n}\n"
        return files
    }

    private static func engine(files: [String: String]) async throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        for (path, source) in files {
            try TestSources.write(source, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "a framework type's nested name")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return engine
    }

    /// The rows of the extensions block `where` answers `symbol` with, heading first.
    private static func extensionsBlock(of symbol: String, in engine: SiftEngine) async throws -> [String] {
        let output = try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh())
        let lines = output.components(separatedBy: "\n")
        guard let heading = lines.firstIndex(where: { $0.hasPrefix("extensions of ") }) else { return [output] }
        return [lines[heading]] + lines[(heading + 1)...].prefix { $0.hasPrefix("  extension ") }
    }

    /// The framework's nested name is no extension of `Loader.Configuration`: the written outer name is neither the loader nor anything the tree declares.
    @Test
    func aFrameworkTypesNestedNameIsLeftOut() async throws {
        let engine = try await Self.engine(files: Self.files)
        let block = try await Self.extensionsBlock(of: "Loader.Configuration", in: engine)

        #expect(!block.contains { $0.contains("URLSession.Configuration") || $0.contains("Framework.swift") }, "\(block)")
    }

    /// The owner's own name is the type's extension, unmarked; a typealias of the loader is too, and a typealias of the framework's type stays marked as one that may be another module's.
    @Test
    func theOwnersNameAndTypealiasesStayListed() async throws {
        let engine = try await Self.engine(files: Self.files)
        let block = try await Self.extensionsBlock(of: "Loader.Configuration", in: engine)

        #expect(block.first == "extensions of Configuration (3):", "\(block)")
        #expect(block.contains("  extension Loader.Configuration — 1 members — Sources/Alpha/Own.swift:1-3"), "\(block)")
        #expect(block.contains("  extension Fetcher.Configuration — 1 members — Sources/Alpha/Fetching.swift:1-3"), "\(block)")
        #expect(block.contains("  extension Pipe.Configuration — 1 members — Sources/Alpha/Pipework.swift:1-3 — may extend another module's Configuration"), "\(block)")
    }

    /// Where the tree declares its own `URLSession` with a nested `Configuration`, the extension is that type's, so asking for it lists the extension and asking for the loader's still does not.
    @Test
    func aTreeTypeOfTheLeadingNameKeepsItsExtension() async throws {
        let engine = try await Self.engine(files: Self.sharedNameFiles)
        let session = try await Self.extensionsBlock(of: "URLSession.Configuration", in: engine)
        let loader = try await Self.extensionsBlock(of: "Loader.Configuration", in: engine)

        #expect(session.contains { $0.contains("extension URLSession.Configuration") && $0.contains("Framework.swift") }, "\(session)")
        #expect(!loader.contains { $0.contains("Framework.swift") }, "\(loader)")
    }

    /// A module-qualified extension through a typealias of the loader's nested type, which compiles and extends it, is not dropped by `where`.
    @Test
    func aModuleQualifiedPathThroughATypealiasStaysListed() async throws {
        var files = Self.files
        files["Sources/Alpha/Qualified.swift"] = "public typealias Configuration = Loader.Configuration\n\nextension Alpha.Configuration {\n    func qualified() {}\n}\n"
        let engine = try await Self.engine(files: files)
        let block = try await Self.extensionsBlock(of: "Loader.Configuration", in: engine)

        #expect(block.contains { $0.contains("Qualified.swift") }, "\(block)")
        #expect(!block.contains { $0.contains("Framework.swift") }, "\(block)")
    }

    /// With no manifest the tree's module name is a guess the compiler may not share, so an extension written through a typealias and an unknown leading name is kept as one that may extend the loader's nested type.
    @Test
    func aGuessedModuleKeepsAnExtensionThroughAnUnknownLeadingName() async throws {
        let engine = try await Self.engine(files: [
            "App/Loader.swift": "public struct Loader {\n    public struct Configuration {}\n}\n",
            "App/Qualified.swift": "public typealias Configuration = Loader.Configuration\n\nextension Orchard.Configuration {\n    func qualified() {}\n}\n",
        ])
        let block = try await Self.extensionsBlock(of: "Loader.Configuration", in: engine)

        #expect(block.contains { $0.contains("Qualified.swift") }, "\(block)")
    }
}
