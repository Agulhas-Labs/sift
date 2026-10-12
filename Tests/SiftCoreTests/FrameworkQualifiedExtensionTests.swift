//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// An extension qualified by a module its file imports that the tree neither declares nor writes as a type extends that module's type, so neither `where` nor a type digest lists it under the tree's type of the name.
@Suite(.temporaryDirectories)
struct FrameworkQualifiedExtensionTests {
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(name: "Pair", targets: [
            .target(name: "Alpha", path: "Sources/Alpha"),
            .target(name: "Delta", path: "Sources/Delta"),
            .target(name: "Epsilon", dependencies: ["Alpha"], path: "Sources/Epsilon"),
            .target(name: "Zeta", path: "Sources/Zeta"),
        ])

        """
    }

    /// Alpha's `Scratch`, with enough long members that its digest is served rather than its source.
    private static var scratchFile: String {
        let members = (1 ... 8).map { index in
            """
                public func step\(index)(_ value: Int) -> Int {
                    let doubled = value * 2
                    let shifted = doubled + \(index)
                    let halved = shifted / 2
                    let squared = halved * halved
                    let offset = squared - doubled
                    let clamped = max(offset, 0)
                    let wrapped = clamped % 97
                    return wrapped - value
                }
            """
        }
        return "public struct Scratch {\n    public init() {}\n\n\(members.joined(separator: "\n\n"))\n}\n"
    }

    /// Delta extends Foundation's `Scratch` through the framework it imports; Epsilon extends Alpha's through Alpha's name, and a nested type of Alpha through a leading name that is both a type of the tree and a module the file imports; Zeta extends `Scratch` through a qualifier it never imports.
    private static var files: [String: String] {
        [
            "Package.swift": manifest,
            "Sources/Alpha/Scratch.swift": scratchFile,
            "Sources/Alpha/Outer.swift": "public enum Outer {\n    public struct Inner {}\n}\n",
            "Sources/Delta/Touch.swift": "import Foundation\n\nextension Foundation.Scratch {\n    func delta() {}\n}\n",
            "Sources/Epsilon/Touch.swift": "import Alpha\n\nextension Alpha.Scratch {\n    func epsilon() {}\n}\n",
            "Sources/Epsilon/Inner.swift": "import Alpha\nimport Outer\n\nextension Outer.Inner {\n    func inner() {}\n}\n",
            "Sources/Zeta/Touch.swift": "extension Mystery.Scratch {\n    func zeta() {}\n}\n",
            "Sources/Alpha/Box.swift": "public struct Box<Element> {}\n",
            "Sources/Delta/Shelf.swift": "import Shelf\n\nextension Shelf.Box<Int> {\n    func shelf() {}\n}\n",
        ]
    }

    /// No build file: every module is guessed from a first path component, so Alpha's `Scratch` is the guessed module `Sources`'s, and the test file reaches it through the module's real name.
    private static var guessedFiles: [String: String] {
        [
            "Sources/Alpha/Scratch.swift": "struct Scratch {}\n",
            "Tests/AlphaTests/T.swift": "@testable import Alpha\n\nextension Alpha.Scratch {\n    func probe() {}\n}\n",
        ]
    }

    /// An XcodeGen target named `Foo-iOS`, which the compiler builds as the module `Foo_iOS` and the app imports by that name.
    private static var hyphenatedFiles: [String: String] {
        [
            "project.yml": """
            name: Pair
            targets:
              Foo-iOS:
                type: framework
                platform: iOS
                sources: [Sources/Foo]
              App:
                type: application
                platform: iOS
                sources: [Sources/App]

            """,
            "Sources/Foo/Scratch.swift": "public struct Scratch {}\n",
            "Sources/App/Touch.swift": "import Foo_iOS\n\nextension Foo_iOS.Scratch {\n    func app() {}\n}\n",
        ]
    }

    private static func engine(files: [String: String] = files) async throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        for (path, source) in files {
            try TestSources.write(source, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "framework-qualified extensions")
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

    /// `where Alpha.Scratch` leaves Foundation's extension out, lists Alpha's own name unmarked, and still marks the one through a qualifier no file imports.
    @Test
    func whereLeavesAnImportedFrameworksExtensionOut() async throws {
        let engine = try await Self.engine()
        let block = try await Self.extensionsBlock(of: "Alpha.Scratch", in: engine)

        #expect(block.first == "extensions of Scratch (2):", "\(block)")
        #expect(!block.contains { $0.contains("Foundation.Scratch") || $0.contains("Sources/Delta/") }, "\(block)")
        #expect(block.contains("  extension Alpha.Scratch — 1 members — Sources/Epsilon/Touch.swift:3-5"), "\(block)")
        #expect(block.contains("  extension Mystery.Scratch — 1 members — Sources/Zeta/Touch.swift:1-3 — may extend another module's Scratch"), "\(block)")
    }

    /// A leading name that is a type of the tree is that type even where the file also imports a module of the name, so `extension Outer.Inner` stays placed under Alpha's nested type.
    @Test
    func aLeadingNameThatIsATypeOfTheTreeKeepsItsExtensionPlaced() async throws {
        let engine = try await Self.engine()
        let block = try await Self.extensionsBlock(of: "Alpha.Outer.Inner", in: engine)

        #expect(block == [
            "extensions of Inner (1):",
            "  extension Outer.Inner — 1 members — Sources/Epsilon/Inner.swift:4-6",
        ], "\(block)")
    }

    /// The digest of `Alpha.Scratch` leaves Foundation's extension out and lists the one through Alpha's own name; one through a qualifier that is not the type's own path stays the external type's, as it did.
    @Test
    func theDigestLeavesAnImportedFrameworksExtensionOut() async throws {
        let engine = try await Self.engine()
        let answer = try engine.digest(target: "Alpha.Scratch", options: DigestOptions())
        let lines = answer.components(separatedBy: "\n").filter { $0.hasPrefix("extension ") }

        #expect(!answer.contains("Foundation.Scratch"), "\(answer)")
        #expect(!answer.contains("func delta()"), "\(answer)")
        #expect(answer.contains("(+1 extension)"), "\(answer)")
        #expect(lines == ["extension Alpha.Scratch — Sources/Epsilon/Touch.swift:3-5"], "\(answer)")
    }

    /// Where a module's name was guessed from its directory, the qualifier may be the module's real name, so `where` keeps the extension a test file writes through it, marked.
    @Test
    func aGuessedModulesRealNameKeepsItsExtensionMarked() async throws {
        let engine = try await Self.engine(files: Self.guessedFiles)
        let block = try await Self.extensionsBlock(of: "Scratch", in: engine)

        #expect(block == [
            "extensions of Scratch (1):",
            "  extension Alpha.Scratch — 1 members — Tests/AlphaTests/T.swift:3-5 — may extend another module's Scratch",
        ], "\(block)")
    }

    /// A qualifier that is a target's name as the compiler spells it (`Foo_iOS` for `Foo-iOS`) is that module, so `where` keeps the extension written through it, and the module is the declared one, so it is not marked.
    @Test
    func aTargetsCompilerSpellingKeepsItsExtension() async throws {
        let engine = try await Self.engine(files: Self.hyphenatedFiles)
        let block = try await Self.extensionsBlock(of: "Scratch", in: engine)

        #expect(block == [
            "extensions of Scratch (1):",
            "  extension Foo_iOS.Scratch — 1 members — Sources/App/Touch.swift:3-5",
        ], "\(block)")
    }

    /// An imported framework's generic type written with arguments (`extension Shelf.Box<Int>`) is left out of the tree's type of the name like any other.
    @Test
    func whereLeavesAnImportedFrameworksSpecialisedExtensionOut() async throws {
        let engine = try await Self.engine()
        let answer = try await engine.lookup(symbol: "Alpha.Box", freshness: engine.ensureFresh())

        #expect(!answer.contains("Shelf.Box"), "\(answer)")
        #expect(!answer.contains("Sources/Delta/Shelf.swift"), "\(answer)")
    }
}
