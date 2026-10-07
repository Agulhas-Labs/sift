//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a struct's qualified lines written where something around them brings names into scope the index cannot account for — a protocol's body, a where clause, an extended type's generic parameters, an extension of a type the index declares only nested elsewhere, a type local to a function: each stays listed and counted, and is noted as read by the index as another type's.
///
/// Every fixture typechecks with `swiftc -parse-as-library`, and calls a member only the asked type has on the line's type, so Swift's own reading of the line is the asked type.
@Suite(.temporaryDirectories)
struct WhereQualifierUnseenScopeTests {
    /// The note's opening, said where a kept line is read by the index as another type's.
    private static var noted: String {
        "behind a qualifier the index reads as Element, which declares another \"Item\""
    }

    /// `Element` in a protocol's body is the associated type it inherits from `Collection`, constrained to `Shelved`, whose `Item` is `Search.Item`.
    @Test
    func aProtocolsBodyKeepsTheLine() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Item", source: "enum Search { struct Item { func searched() {} } }\nenum Element { struct Item {} }\nprotocol Shelved {}\nextension Shelved { typealias Item = Search.Item }\nprotocol Shelf: Collection where Element: Shelved { func probe(_ x: Element.Item) }\nextension Shelf { func check() { probe(Search.Item()) } }\n")

        #expect(search.contains("\n    :5  | protocol Shelf: Collection where Element: Shelved { func probe(_ x: Element.Item) }"), "\(search)")
        #expect(search.contains(Self.noted), "\(search)")
        #expect(!search.contains("resolves to another type's"), "\(search)")
    }

    /// `Element` in an extension constrained by `where Self: Collection` is that protocol's associated type, though the extended protocol is one the index holds.
    @Test
    func anExtensionsWhereClauseKeepsTheLine() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Item", source: "enum Search { struct Item { func searched() {} } }\nenum Element { struct Item {} }\nprotocol Shelved {}\nextension Shelved { typealias Item = Search.Item }\nprotocol Shelf {}\nextension Shelf where Self: Collection, Element: Shelved {\n    func probe(_ x: Element.Item) { x.searched() }\n}\n")

        #expect(search.contains("\n    :7  | func probe(_ x: Element.Item) { x.searched() }"), "\(search)")
        #expect(search.contains(Self.noted), "\(search)")
        #expect(!search.contains("resolves to another type's"), "\(search)")
    }

    /// `Log` in an extension of `Outer.Inner` is `Outer`'s generic parameter, whose `Item` is `Search.Item`, with or without a where clause on the extension.
    @Test
    func anExtendedPathsGenericParameterKeepsTheLine() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Item", source: "enum Search { struct Item { func searched() {} } }\nenum Log { struct Item {} }\nprotocol Shelved {}\nextension Shelved { typealias Item = Search.Item }\nstruct Crate: Shelved {}\nstruct Outer<Log: Shelved> { struct Inner {} }\nextension Outer.Inner {\n    func probe(_ x: Log.Item) { x.searched() }\n}\nextension Outer.Inner where Log == Crate {\n    func probe2(_ x: Log.Item) { x.searched() }\n}\n")

        #expect(search.contains("\n    :8  | func probe(_ x: Log.Item) { x.searched() }\n    :11  | func probe2(_ x: Log.Item) { x.searched() }"), "\(search)")
        #expect(search.contains("behind a qualifier the index reads as Log, which declares another \"Item\""), "\(search)")
        #expect(!search.contains("resolves to another type's"), "\(search)")
    }

    /// `Element` in a constrained extension of `Array` is its generic parameter, though the index declares a type called `Array` nested in `Net`.
    @Test
    func anExtensionOfAnOutsideTypeSharingANestedTypesNameKeepsTheLine() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Item", source: "enum Search { struct Item { func searched() {} } }\nenum Element { struct Item {} }\nenum Net { struct Array {} }\nprotocol Shelved {}\nextension Shelved { typealias Item = Search.Item }\nextension Array where Element: Shelved {\n    func probe(_ x: Element.Item) { x.searched() }\n}\n")

        #expect(search.contains("\n    :7  | func probe(_ x: Element.Item) { x.searched() }"), "\(search)")
        #expect(search.contains(Self.noted), "\(search)")
        #expect(!search.contains("resolves to another type's"), "\(search)")
    }

    /// `Index` in an unconstrained extension of `Array` is its `Int` index, `Shelved` here, never the top-level `Index` enum, though the index declares a type called `Array` nested in `Net`.
    @Test
    func anExtendedNameIsATopLevelTypesAlone() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Item", source: "enum Search { struct Item { func searched() {} } }\nenum Index { struct Item {} }\nenum Net { struct Array {} }\nprotocol Shelved {}\nextension Shelved { typealias Item = Search.Item }\nextension Int: Shelved {}\nextension Array {\n    func probe(_ x: Index.Item) { x.searched() }\n}\n")

        #expect(search.contains("\n    :8  | func probe(_ x: Index.Item) { x.searched() }"), "\(search)")
        #expect(search.contains("behind a qualifier the index reads as Index, which declares another \"Item\""), "\(search)")
        #expect(!search.contains("resolves to another type's"), "\(search)")
    }

    /// `DateDecodingStrategy` in a class local to a function is the one its `JSONDecoder` superclass nests, though the index declares a top-level class of the local one's name.
    @Test
    func aTypeLocalToAFunctionKeepsTheLine() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Item", source: "import Foundation\nenum Search { struct Item { func searched() {} } }\nenum DateDecodingStrategy { struct Item {} }\nclass Crate {}\nprotocol Shelved {}\nextension Shelved { typealias Item = Search.Item }\nextension JSONDecoder.DateDecodingStrategy: Shelved {}\nfunc run() {\n    class Crate: JSONDecoder, @unchecked Sendable {\n        func probe(_ x: DateDecodingStrategy.Item) { x.searched() }\n    }\n}\n")

        #expect(search.contains("\n    :10  | func probe(_ x: DateDecodingStrategy.Item) { x.searched() }"), "\(search)")
        #expect(search.contains("behind a qualifier the index reads as DateDecodingStrategy, which declares another \"Item\""), "\(search)")
        #expect(!search.contains("resolves to another type's"), "\(search)")
    }

    /// In an extension of a plain struct the index holds whole, a literal qualifier is no longer set apart: the line is kept and noted, as every qualified line the index reads as another type's is.
    @Test
    func anExtensionOfAPlainStructKeepsALiteralQualifierAndNotesIt() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Answer", source: "struct Search { struct Answer { func searched() {} } }\nstruct Log { struct Answer {} }\nstruct Use {}\nextension Use { func probe(_ x: Log.Answer) {} }\n")

        #expect(search.contains("\n    :4  | extension Use { func probe(_ x: Log.Answer) {} }"), "\(search)")
        #expect(search.contains("; 1 of them writes \"Answer\" behind a qualifier the index reads as Log, which declares another \"Answer\", so may be that type's rather than this struct's — counted all the same, as a qualifier read from the index alone may name another type in Swift (for "), "\(search)")
        #expect(!search.contains("resolves to another type's"), "\(search)")
    }
}
