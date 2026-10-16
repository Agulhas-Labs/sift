//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `where <Type>` prints an extension the name lookup found once, as a row under `declarations` with its member count, and the `extensions of` block lists only the extensions that section did not print.
@Suite(.temporaryDirectories)
struct WhereExtensionsOnceTests {
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(name: "Pair", targets: [
            .target(name: "Alpha", path: "Sources/Alpha"),
            .target(name: "Beta", path: "Sources/Beta"),
            .target(name: "Gamma", dependencies: ["Alpha", "Beta"], path: "Sources/Gamma"),
        ])

        """
    }

    private static func engine(_ files: [String: String]) async throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        for (path, source) in files {
            try TestSources.write(source, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "extensions once")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return engine
    }

    private static func answer(_ query: String, in engine: SiftEngine) async throws -> String {
        try await engine.lookup(symbol: query, freshness: engine.ensureFresh())
    }

    /// A type declared in `Alpha`, with `count` bare extensions in files of their own.
    private static func gizmoFiles(extensions count: Int, specialised: Bool = false) -> [String: String] {
        var files = ["Package.swift": manifest, "Sources/Alpha/Gizmo.swift": "public struct Gizmo<T> {\n    public init() {}\n}\n"]
        for index in 1 ... count {
            files["Sources/Alpha/E\(index).swift"] = "extension Gizmo {\n    func spin\(index)() {}\n}\n"
        }
        if specialised {
            files["Sources/Alpha/Special.swift"] = "extension Gizmo<Int> {\n    func ints() {}\n}\n"
        }
        return files
    }

    /// A type extended in several files of its module prints each extension once, under `declarations`, with its member count, and no block follows.
    @Test
    func sameFileExtensionsArePrintedOnce() async throws {
        let engine = try await Self.engine(Self.gizmoFiles(extensions: 3))
        let answer = try await Self.answer("Gizmo", in: engine)

        #expect(answer.contains("declarations (4):"), "\(answer)")
        for index in 1 ... 3 {
            #expect(answer.components(separatedBy: "Sources/Alpha/E\(index).swift:1-3").count == 2, "\(answer)")
            #expect(answer.contains("extension — extension Gizmo — 1 members — Sources/Alpha/E\(index).swift:1-3"), "\(answer)")
        }
        #expect(!answer.contains("extensions of Gizmo"), "\(answer)")
    }

    /// A spelling the name lookup does not return stays in the block, whose heading counts every extension and says how many are under `declarations`.
    @Test
    func aGenericSpellingStaysInTheBlock() async throws {
        let engine = try await Self.engine(Self.gizmoFiles(extensions: 3, specialised: true))
        let answer = try await Self.answer("Gizmo", in: engine)

        #expect(answer.contains("extensions of Gizmo (4, 3 under declarations):\n  extension Gizmo<Int> — 1 members — Sources/Alpha/Special.swift:1-3"), "\(answer)")
        #expect(answer.components(separatedBy: "Sources/Alpha/E1.swift").count == 2, "\(answer)")
    }

    /// An extension the code cannot place as the type's or another's carries the mark on its declarations row and is not in the block.
    @Test
    func anUnplaceableExtensionIsMarkedOnItsDeclarationsRow() async throws {
        let engine = try await Self.engine([
            "Package.swift": Self.manifest,
            "Sources/Alpha/Gizmo.swift": "public struct Gizmo {}\n\nextension Gizmo {\n    func alpha() {}\n}\n",
            "Sources/Gamma/Touch.swift": "import Mystery\n\nextension Gizmo {\n    func gamma() {}\n}\n",
        ])
        let answer = try await Self.answer("Gizmo", in: engine)

        #expect(answer.contains("extension — extension Gizmo — 1 members — Sources/Gamma/Touch.swift:3-5 — may extend another module's Gizmo"), "\(answer)")
        #expect(answer.contains("extension — extension Gizmo — 1 members — Sources/Alpha/Gizmo.swift:3-5\n"), "\(answer)")
        #expect(!answer.contains("extensions of Gizmo"), "\(answer)")
    }

    /// Past both caps the declarations line says how many of its cut rows the block lists, and the block says how many more it cut.
    @Test
    func theCapsReportWhatTheBlockListsAndWhatItCuts() async throws {
        let engine = try await Self.engine(Self.gizmoFiles(extensions: 100, specialised: true))
        let answer = try await Self.answer("Gizmo", in: engine)

        #expect(answer.contains("  truncated: 61 more declarations, 40 of them under extensions of Gizmo"), "\(answer)")
        #expect(answer.contains("extensions of Gizmo (101, 39 under declarations):"), "\(answer)")
        #expect(answer.contains("  truncated: 22 more extensions"), "\(answer)")
    }

    /// A compact extension row keeps after its kind what the block printed after the name: its access, the conformances it adds and its `where` clause.
    @Test
    func aCompactExtensionRowKeepsItsContext() async throws {
        var files = Self.gizmoFiles(extensions: 12)
        files["Sources/Alpha/Equatable.swift"] = "public extension Gizmo: Equatable where T: Equatable {\n    static func == (lhs: Self, rhs: Self) -> Bool { true }\n}\n"
        let engine = try await Self.engine(files)
        let answer = try await Self.answer("Gizmo", in: engine)

        #expect(answer.contains("declarations (14):"), "\(answer)")
        #expect(answer.contains("Alpha.Gizmo — extension (public) (: Equatable) where T: Equatable — 1 members — Sources/Alpha/Equatable.swift:1-3"), "\(answer)")
        #expect(!answer.contains("extensions of Gizmo"), "\(answer)")
    }

    /// An extension of a nested type written in another module, which the type's listing does not hold, carries the `extends another module's` mark on its declarations row.
    @Test
    func anExtensionFromAnotherModuleIsMarkedAsExtendingIt() async throws {
        let engine = try await Self.engine([
            "Package.swift": Self.manifest,
            "Sources/Alpha/Outer.swift": "public enum Outer {\n    public struct Widget {}\n}\n",
            "Sources/Beta/Widget.swift": "extension Widget {\n    func f() {}\n}\n",
        ])
        let answer = try await Self.answer("Widget", in: engine)

        #expect(answer.contains("Sources/Beta/Widget.swift:1-3 — extends another module's Widget"), "\(answer)")
    }
}
