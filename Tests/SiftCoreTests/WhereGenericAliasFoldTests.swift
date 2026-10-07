//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// `where` with no store over typealiases that build a type from the name asked, through generic arguments or sugar, rather than naming it.
@Suite(.temporaryDirectories)
struct WhereGenericAliasFoldTests {
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(name: "Lib", targets: [.target(name: "Lib", path: "Sources/Lib")])

        """
    }

    private static var netFile: String {
        """
        public enum Net {
            public struct URL {
                public init() {}
            }
        }

        extension Array where Element == Int {}

        """
    }

    /// Aliases built from the type through a dictionary, an array and array sugar, each used once.
    private static var shelfFile: String {
        """
        typealias Book = Dictionary<String, Net.URL>
        typealias Shelf = Array<Net.URL>
        typealias Spare = [Net.URL]

        func f() {
            let book: Book = [:]
            let shelf: Shelf = []
            let spare: Spare = []
            _ = (book, shelf, spare)
        }

        """
    }

    /// The answer for `symbol` over a tree holding `files`, unbuilt.
    private static func answer(_ symbol: String, files: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        for (path, text) in files {
            try TestSources.write(text, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "built alias fixture, unbuilt")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh())
    }

    /// A use of an alias built from the type breaks with it, so it is folded in, while the alias's own line stays a use rather than another name for the type.
    @Test
    func usesOfAnAliasBuiltFromTheTypeAreFoldedIn() async throws {
        let output = try await Self.answer("Net.URL", files: ["Package.swift": Self.manifest, "Sources/Lib/Net.swift": Self.netFile, "Sources/Lib/Shelf.swift": Self.shelfFile])

        #expect(output.contains("\"URL\" used by 6 lines in 1 file — "), "\(output)")
        #expect(output.contains("3 written as Lib.Book, Lib.Shelf and Lib.Spare, typealiases naming it, folded in here"), "\(output)")
        #expect(output.contains("\n    :1  | typealias Book = Dictionary<String, Net.URL>\n"), "\(output)")
        #expect(output.contains("\n    :6  | let book: Book = [:]\n"), "\(output)")
        #expect(output.contains("\n    :7  | let shelf: Shelf = []\n"), "\(output)")
        #expect(output.contains("\n    :8  | let spare: Spare = []"), "\(output)")
        #expect(!output.contains("declaring a typealias of it"), "\(output)")
    }

    /// The generic type an alias builds on is folded too: a use of `Shelf` is a use of `Array`.
    @Test
    func usesOfAnAliasBuiltOnTheGenericTypeAreFoldedIn() async throws {
        let output = try await Self.answer("Array", files: ["Package.swift": Self.manifest, "Sources/Lib/Net.swift": Self.netFile, "Sources/Lib/Shelf.swift": Self.shelfFile])

        #expect(output.contains("\"Array\" used by 3 lines in 2 files — "), "\(output)")
        #expect(output.contains("1 written as Lib.Shelf, a typealias naming it, folded in here"), "\(output)")
        #expect(output.contains("\n    :2  | typealias Shelf = Array<Net.URL>\n"), "\(output)")
        #expect(output.contains("\n    :7  | let shelf: Shelf = []"), "\(output)")
        #expect(!output.contains("let book: Book"), "\(output)")
    }

    /// A path led by the alias's own generic parameter names that parameter rather than the type the tree declares of its name.
    @Test
    func anAliasWritingItsOwnGenericParameterIsNotFoldedIn() async throws {
        let output = try await Self.answer("Gizmo", files: [
            "Package.swift": Self.manifest,
            "Sources/Lib/Gizmo.swift": "struct Gizmo {}\n\ntypealias Depot<Gizmo> = [Gizmo]\n\nlet stock: Depot<Int> = []\n",
        ])

        #expect(!output.contains("let stock: Depot<Int>"), "\(output)")
        #expect(!output.contains("folded in here"), "\(output)")
    }
}
