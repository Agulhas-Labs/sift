//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a struct's qualified lines whose qualifier Swift reads through a name the scan never writes down — an implicit conformance's members, a type an attached macro adds, a supertype outside the index matched by its simple name: each stays listed and counted, noted as read by the index as another type's, never set apart.
///
/// Every fixture typechecks with `swiftc -parse-as-library -target arm64-apple-macos26`, and calls a member only the asked type has on the line's type, so Swift's own reading of the line is the asked type.
@Suite(.temporaryDirectories)
struct WhereQualifierImplicitNameTests {
    /// `ID` in a distributed actor is the `ActorID` its `DistributedActor` conformance declares, `LocalTestingActorID` here, though the index declares a top-level `ID` nesting an `Item`.
    @Test
    func anImplicitConformancesTypealiasKeepsTheLine() async throws {
        let item = try await WhereQualifiedProtocolNoteTests.answer("LocalTestingActorID.Item", source: "import Distributed\nextension LocalTestingActorID { struct Item { func searched() {} } }\nenum ID { struct Item {} }\ndistributed actor Worker {\n    typealias ActorSystem = LocalTestingDistributedActorSystem\n    func probe(_ x: ID.Item) { x.searched() }\n}\n")

        #expect(item.contains("\n    :6  | func probe(_ x: ID.Item) { x.searched() }"), "\(item)")
        #expect(item.contains("; 1 of them writes \"Item\" behind a qualifier the index reads as ID, which declares another \"Item\", so may be that type's rather than this struct's"), "\(item)")
        #expect(!item.contains("resolves to another type's"), "\(item)")
    }

    /// `PartiallyGenerated` in a `@Generable` struct is the nested type the macro adds, whose `Item` is `Search.Item`, though the index declares a top-level `PartiallyGenerated` nesting an `Item`.
    @Test
    func aTypeAnAttachedMacroAddsKeepsTheLine() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Item", source: "import FoundationModels\nstruct Search { struct Item { func searched() {} } }\nenum PartiallyGenerated { struct Item {} }\n@Generable struct Scope {\n    var name: String\n    func probe(_ x: PartiallyGenerated.Item) { x.searched() }\n}\nextension Scope.PartiallyGenerated { typealias Item = Search.Item }\n")

        #expect(search.contains("\n    :6  | func probe(_ x: PartiallyGenerated.Item) { x.searched() }"), "\(search)")
        #expect(search.contains("; 1 of them writes \"Item\" behind a qualifier the index reads as PartiallyGenerated, which declares another \"Item\", so may be that type's rather than this struct's"), "\(search)")
        #expect(!search.contains("resolves to another type's"), "\(search)")
    }

    /// `KeyDecodingStrategy` in a subclass of Foundation's `JSONDecoder` is the one it nests, though the index declares a `JSONDecoder` of its own, nested in `Net`, and a top-level `KeyDecodingStrategy` nesting an `Item`.
    @Test
    func aSupertypeOutsideTheIndexSharingANameKeepsTheLine() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Item", source: "import Foundation\nstruct Search { struct Item { func searched() {} } }\nenum KeyDecodingStrategy { struct Item {} }\nenum Net { class JSONDecoder {} }\nextension JSONDecoder.KeyDecodingStrategy { typealias Item = Search.Item }\nclass Scope: JSONDecoder {\n    func probe(_ x: KeyDecodingStrategy.Item) { x.searched() }\n}\n")

        #expect(search.contains("\n    :7  | func probe(_ x: KeyDecodingStrategy.Item) { x.searched() }"), "\(search)")
        #expect(search.contains("; 1 of them writes \"Item\" behind a qualifier the index reads as KeyDecodingStrategy, which declares another \"Item\", so may be that type's rather than this struct's"), "\(search)")
        #expect(!search.contains("resolves to another type's"), "\(search)")
    }
}
