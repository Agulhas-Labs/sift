//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A type digest lists the extensions `where` places under the asked type: never another module's same-named type's, and one the code cannot place is listed and marked.
@Suite(.temporaryDirectories)
struct DigestExtensionPlacementTests {
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(name: "Pair", targets: [
            .target(name: "Alpha", path: "Sources/Alpha"),
            .target(name: "Beta", path: "Sources/Beta"),
            .target(name: "Gamma", dependencies: ["Alpha", "Beta"], path: "Sources/Gamma"),
            .target(name: "Delta", path: "Sources/Delta"),
            .target(name: "Epsilon", dependencies: ["Alpha"], path: "Sources/Epsilon"),
        ])

        """
    }

    /// A generic `Box` with enough members that its digest is served rather than its source, a constrained extension and a specialised one.
    private static var boxFile: String {
        """
        public struct Box<T> {
            public init() {}

        \(steps)
        }

        extension Box where T == Int {
            func whole() {}
        }

        extension Box<String> {
            func text() {}
        }

        """
    }

    /// Eight long members, so a type declaring them is answered with a digest.
    private static var steps: String {
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
                    let mixed = wrapped ^ shifted
                    return mixed - value
                }
            """
        }
        return members.joined(separator: "\n\n")
    }

    /// A type of `module`'s own named `Scratch`, with enough members that its digest is served rather than its source, and a bare extension of it in the same module.
    private static func scratchFile(module: String) -> String {
        """
        public struct Scratch {
            public init() {}

        \(steps)
        }

        extension Scratch {
            func \(module.lowercased())() {}
        }

        """
    }

    /// Two modules each declaring `Scratch` with its own extension, a third importing both that extends `Scratch` bare, which the code cannot place as either, and a fourth extending a framework's `Scratch`; and a generic `Box` in the first with a constrained and a specialised extension, bare-extended by a fifth importing it.
    private static var files: [String: String] {
        [
            "Package.swift": manifest,
            "Sources/Alpha/Scratch.swift": scratchFile(module: "Alpha"),
            "Sources/Beta/Scratch.swift": scratchFile(module: "Beta"),
            "Sources/Gamma/Touch.swift": "import Alpha\nimport Beta\n\nextension Scratch {\n    func gamma() {}\n}\n",
            "Sources/Alpha/Box.swift": boxFile,
            "Sources/Epsilon/Box.swift": "import Alpha\n\nextension Box {\n    func epsilon() {}\n}\n",
            "Sources/Delta/Touch.swift": "import Foundation\n\nextension Foundation.Scratch {\n    func delta() {}\n}\n",
        ]
    }

    private static func engine() async throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        for (path, source) in files {
            try TestSources.write(source, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "two modules, one name")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return engine
    }

    /// The extension lines of a type digest.
    private static func extensionLines(of answer: String) -> [String] {
        answer.components(separatedBy: "\n").filter { $0.hasPrefix("extension ") }
    }

    /// `Alpha.Scratch` lists its own extension and the unplaced one, marked, and counts those two; `Beta`'s extension, placed as `Beta.Scratch`'s, is neither listed nor counted.
    @Test
    func aModuleQualifiedDigestListsOnlyTheExtensionsPlacedUnderItsType() async throws {
        let engine = try await Self.engine()
        let answer = try engine.digest(target: "Alpha.Scratch", options: DigestOptions())

        #expect(answer.contains("Scratch — Alpha — Sources/Alpha/Scratch.swift:1-"), "\(answer)")
        #expect(answer.contains("(+2 extensions)"), "\(answer)")
        #expect(Self.extensionLines(of: answer) == [
            "extension Scratch — Sources/Alpha/Scratch.swift:101-103",
            "extension Scratch — Sources/Gamma/Touch.swift:4-6 — may extend another module's Scratch",
        ], "\(answer)")
        #expect(answer.contains("func alpha()"), "\(answer)")
        #expect(!answer.contains("func beta()"), "\(answer)")
        #expect(!answer.contains("Sources/Beta/"), "\(answer)")
    }

    /// A member miss on `Alpha.Scratch` naming `Beta`'s extension member ranks only the members of the extensions placed under it, never `Beta`'s.
    @Test
    func aMemberMissRanksNoMemberOfAnotherModulesExtension() async throws {
        let engine = try await Self.engine()
        let answer = try engine.digest(target: "Alpha.Scratch.beta", options: DigestOptions())

        #expect(answer.contains("has no member beta"), "\(answer)")
        #expect(!answer.contains("Sources/Beta/"), "\(answer)")
    }

    /// Delta's extension of a framework's `Scratch` sets the tree's own extensions aside by the type each extends: `Alpha`'s two, as its digest counts them, and `Beta`'s one.
    @Test
    func anExternalTypeAnswerSetsEachLocalExtensionAsideUnderTheTypeItExtends() async throws {
        let engine = try await Self.engine()
        let answer = try engine.digest(target: "Delta.Scratch", options: DigestOptions())

        #expect(answer.contains("extension Foundation.Scratch"), "\(answer)")
        #expect(answer.contains("(+2 extensions of Alpha.Scratch, which this repo declares"), "\(answer)")
        #expect(answer.contains("(+2 extensions of Beta.Scratch, which this repo declares"), "\(answer)")
    }

    /// The miss answer and `Beta.Scratch`'s own digest count the same extensions: Beta's own and Gamma's unplaced one.
    @Test
    func theMissAnswerCountsAnUnplacedExtensionForEveryDeclarationItMayExtend() async throws {
        let engine = try await Self.engine()
        let miss = try engine.digest(target: "Delta.Scratch", options: DigestOptions())
        let digest = try engine.digest(target: "Beta.Scratch", options: DigestOptions())

        #expect(digest.contains("(+2 extensions)"), "\(digest)")
        #expect(miss.contains("(+2 extensions of Beta.Scratch, which this repo declares"), "\(miss)")
    }

    /// A specialised header and a constrained one are listed by the digest as `where` lists them, so the two answers agree on the count and on every row.
    @Test
    func aDigestListsExactlyTheExtensionsWhereListsForTheSameQuery() async throws {
        let engine = try await Self.engine()
        let freshness = try await engine.ensureFresh()
        let digest = try engine.digest(target: "Alpha.Box", options: DigestOptions())
        let found = try await engine.lookup(symbol: "Alpha.Box", freshness: freshness)

        // The extensions `where` prints once: those a `declarations` row carries and those the `extensions of` block goes on to list.
        let lines = found.components(separatedBy: "\n")
        let listed = lines.filter { $0.hasPrefix("  Alpha.Box — extension — ") }
            + lines.drop { !$0.hasPrefix("extensions of Box (") }.dropFirst().prefix { $0.hasPrefix("  extension ") }
        let wherePaths = listed.compactMap { $0.components(separatedBy: " — ").last }
        let digestPaths = Self.extensionLines(of: digest).compactMap { $0.components(separatedBy: " — ").last }

        #expect(wherePaths.count == 3, "\(found)")
        #expect(digest.contains("(+3 extensions)"), "\(digest)")
        #expect(digestPaths == wherePaths, "\(digest)\n\(found)")
        #expect(digest.contains("extension Box<String>"), "\(digest)")
    }
}
