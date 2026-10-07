//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Typealiases a no-store `where` cannot prove name a type, because the leading name they write before its path may be its module: their uses are kept, never dropped, and never worded as folded.
@Suite(.temporaryDirectories)
struct WhereGuessedModuleAliasFoldTests {
    /// `Sources/App/Net.swift`, whose module is guessed as `Sources` where no `Package.swift` says it is `App`, with an alias writing `App`.
    private static var guessedModuleFile: String {
        """
        enum Net {
            struct URL {
                init() {}
            }
        }

        typealias Link = App.Net.URL

        func f() {
            _ = Link()
        }

        """
    }

    /// The `--refs` answer for `symbol` over a tree holding `files`, with no `Package.swift` unless one is among them.
    private static func references(of symbol: String, files: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        for (path, text) in files {
            try TestSources.write(text, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "guessed-module alias fixture, unbuilt")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
    }

    /// An alias writing the real module where the module is guessed from the path may name the type, so its uses are kept and say why, and its declaration line stays a use.
    @Test
    func anAliasWritingTheRealModuleBehindAGuessedOneIsKept() async throws {
        let output = try await Self.references(of: "Net.URL", files: ["Sources/App/Net.swift": Self.guessedModuleFile])

        #expect(output.contains(":10  | _ = Link()"), "\(output)")
        #expect(output.contains(":7  | typealias Link = App.Net.URL"), "\(output)")
        #expect(output.contains(
            "2 lines in 1 file — 2 production · 0 tests, split on the XCTest or Testing import, never the path; 1 written as Sources.Link (App.Net.URL), a typealias of its path behind a leading name that may be its module, kept as a use though not proven to name it, as this type's module is guessed from the path"
        ), "\(output)")
        #expect(!output.contains("folded in here"), "\(output)")
    }

    /// Where a `Package.swift` declares the module, an alias writing another module's name before the path names that module's type, so it stays out.
    @Test
    func anAliasWritingAnotherModuleBesideADeclaredOneIsNotKept() async throws {
        let output = try await Self.references(of: "Net.URL", files: [
            "Package.swift": """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Lib", path: "Sources/App")]
            )

            """,
            "Sources/App/Net.swift": Self.guessedModuleFile,
        ])

        #expect(output.contains("Lib.Net.URL"), "\(output)")
        #expect(!output.contains("_ = Link()"), "\(output)")
        #expect(!output.contains("kept as"), "\(output)")
    }

    /// Sites a name-matched answer cannot see through, beside the guessed-module alias, leave its uses kept: a type of the leading name invisible where the alias is written (private, under `#if`, in another module), a macro that may declare one, an alias in a type whose supertype is outside the tree, and a dependency's dynamic member of the alias's name.
    @Test(arguments: [
        ("Sources/App/Hidden.swift", "private enum App {}\n"),
        ("Sources/App/Platform.swift", "#if os(Linux)\nenum App {}\n#endif\n"),
        ("Lib/App.swift", "public enum App {}\n"),
        ("Sources/App/Made.swift", "#makeGizmo()\n"),
        ("Sources/App/Holder.swift", "class Holder: Base {\n    typealias Link = App.Net.URL\n    func g() { _ = Link() }\n}\n"),
        ("Sources/App/Proxy.swift", "func g(_ proxy: Proxy) { _ = proxy.Link }\n"),
    ])
    func aHiddenSiteBesideTheAliasLeavesItsUsesKept(path: String, text: String) async throws {
        let output = try await Self.references(of: "Net.URL", files: ["Sources/App/Net.swift": Self.guessedModuleFile, path: text])

        #expect(output.contains(":10  | _ = Link()"), "\(output)")
        #expect(output.contains("kept as a use though not proven to name it") || output.contains("kept as uses though not proven to name it"), "\(output)")
        #expect(!output.contains("folded in here"), "\(output)")
        if path.hasSuffix("Holder.swift") {
            #expect(output.contains("func g() { _ = Link() }"), "\(output)")
        }
    }
}
