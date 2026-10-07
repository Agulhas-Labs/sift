//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `search`'s `owner:` field — the members of a type, its extensions included — and the miss line that names the term which emptied the answer.
@Suite(.temporaryDirectories)
struct StructuralSearchOwnerTests {
    /// A type with members in its body, in an extension, and in a nested type extended from outside, beside a top-level function.
    private static var depot: String {
        """
        struct Depot {
            static func opened() -> Depot { Depot() }
            func restock() {}
            struct Shelf {
                static func labelled() {}
            }
        }

        extension Depot {
            static func sealed() -> Depot { Depot() }
        }

        extension Depot.Shelf {
            static func emptied() {}
        }

        func stocktake() {}
        """
    }

    private static func names(_ query: String, in source: String = depot) throws -> [String] {
        try StructuralMatcher.matches(in: source, path: "Sources/App/Depot.swift", query: StructuralQuery(query)).map(\.qualifiedName)
    }

    /// Runs `query` over the depot fixture written to disk, the way `search` reads a tree.
    private static func searched(_ query: String) async throws -> (result: StructuralSearch.Result, query: StructuralQuery) {
        let root = try TemporaryDirectory.make("search-owner")
        let file = root.appendingPathComponent("Sources/App/Depot.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try depot.write(to: file, atomically: true, encoding: .utf8)
        let enumerator = FileEnumerator(repoRoot: root, config: SiftConfig(), gitListing: { ["Sources/App/Depot.swift"] })
        let parsed = try StructuralQuery(query)
        return await (StructuralSearch(repoRoot: root, enumerator: enumerator).run(parsed), parsed)
    }

    private static func missLine(_ rendered: String) -> String? {
        rendered.split(separator: "\n").first { $0.hasPrefix("no declarations match") }.map(String.init)
    }

    // MARK: owner:

    /// The question the field exists for: a type's static functions, wherever they were written — and only its own, not a nested type's.
    @Test
    func ownerFindsATypesStaticFunctionsInItsBodyAndItsExtensions() throws {
        #expect(try Self.names("kind:func modifier:static owner:Depot") == ["Depot.opened()", "Depot.sealed()"])
    }

    /// A nested type answers to its own name and to its qualified path, from its body and from an extension written as `Outer.Inner`.
    @Test
    func aNestedTypeAnswersToItsNameAndItsQualifiedPath() throws {
        let shelf = ["Depot.Shelf.labelled()", "Depot.Shelf.emptied()"]

        #expect(try Self.names("kind:func owner:Shelf") == shelf)
        #expect(try Self.names("kind:func owner:Depot.Shelf") == shelf)
        #expect(try Self.names("kind:struct owner:Depot") == ["Depot.Shelf"])
    }

    /// A top-level declaration has no owner, so it never matches `owner:` and always matches its negation.
    @Test
    func aTopLevelDeclarationHasNoOwner() throws {
        #expect(try !Self.names("kind:func owner:Depot").contains("stocktake()"))
        #expect(try Self.names("kind:func !owner:Depot !owner:Shelf") == ["stocktake()"])
    }

    /// Generic arguments on an extended type are not part of the owner's name, on either side of the comparison.
    @Test
    func genericArgumentsAreDroppedFromTheOwner() throws {
        let source = """
        struct Box<Item> {}
        extension Box where Item == Int { static func single() {} }
        extension Box<String> { static func pair() {} }
        """

        #expect(try Self.names("kind:func owner:Box", in: source) == ["Box.single()", "Box<String>.pair()"])
        #expect(try Self.names("kind:func owner:Box<Int>", in: source) == ["Box.single()", "Box<String>.pair()"])
    }

    // MARK: The miss

    /// The issue's shape: a member query carrying `inherits:`, which only a type can satisfy, names that term and how many it took.
    @Test
    func aMissNamesTheTermThatRemovedTheLastDeclarations() async throws {
        let (result, query) = try await Self.searched("kind:func modifier:static sig:Depot inherits:DepotStore")

        let rendered = SearchRenderer.render(result: result, query: query)

        #expect(Self.missLine(rendered) == "no declarations match — scanned 1 file(s); inherits:DepotStore removed the last 2 declaration(s)")
    }

    /// Where the first term applied leaves nothing, the line says it removed all of them, with the count.
    @Test
    func aMissWhoseFirstTermEmptiedItSaysAll() async throws {
        let (result, query) = try await Self.searched("kind:actor")

        let rendered = SearchRenderer.render(result: result, query: query)

        #expect(Self.missLine(rendered) == "no declarations match — scanned 1 file(s); kind:actor removed all 10 declaration(s)")
    }

    /// "All" means no other term removed any, even where an earlier term was applied first and passed everything.
    @Test
    func aMissSaysAllWhereNoOtherTermRemovedAny() async throws {
        let (result, query) = try await Self.searched("!kind:actor kind:protocol")

        let rendered = SearchRenderer.render(result: result, query: query)

        #expect(Self.missLine(rendered) == "no declarations match — scanned 1 file(s); kind:protocol removed all 10 declaration(s)")
    }

    /// Body terms apply after declaration terms, so a `calls:` written first is still the term that took the last survivors.
    @Test
    func aMissNamesTermsInTheOrderTheScanAppliesThem() async throws {
        let (result, query) = try await Self.searched("calls:restock kind:func modifier:static")

        let rendered = SearchRenderer.render(result: result, query: query)

        #expect(Self.missLine(rendered) == "no declarations match — scanned 1 file(s); calls:restock removed the last 4 declaration(s)")
    }

    /// `--count` answers the same verdict line as the full answer, a negated term spelled with its `!`.
    @Test
    func theCountAnswerCarriesTheSameMissLine() async throws {
        let (result, query) = try await Self.searched("kind:func owner:Shelf !modifier:static")

        let counted = SearchRenderer.renderCount(result: result, query: query) { _ in "App" }

        #expect(Self.missLine(counted) == "no declarations match — scanned 1 file(s); !modifier:static removed the last 2 declaration(s)")
    }
}
