//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a struct's or class's qualified lines that Swift reads as the asked type where the index could read them as another type of the name, through a supertype, a merged reach, an enclosing scope it does not hold, a generic typealias's own parameter, a typealias local to a function or a type's own typealias: each stays listed and counted, and a line the index reads as another type's is noted rather than set apart.
///
/// Every fixture typechecks with `swiftc`, and its last lines call a member only the asked type has, so Swift's own reading of the line is the asked type.
@Suite(.temporaryDirectories)
struct WhereStructQualifierKeepTests {
    /// The note's opening, said where a kept line is read by the index as another type's.
    private static var noted: String {
        "behind a qualifier the index reads as"
    }

    /// `Sub.Item` is the typealias `Sub` declares, which Swift finds before the struct nested in its superclass, so the line is kept and noted.
    @Test
    func aSupertypesNestedTypeDoesNotOutrankTheTypesOwnTypealias() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Item", source: "enum Search { struct Item { func searched() {} } }\nclass Base { struct Item {} }\nclass Sub: Base { typealias Item = Search.Item }\nfunc probe() -> Sub.Item? { nil }\nfunc check() { probe()?.searched() }\n")

        #expect(search.contains("\n    :4  | func probe() -> Sub.Item? { nil }"), "\(search)")
        #expect(search.contains("; 1 of them writes \"Item\" behind a qualifier the index reads as Base, which declares another \"Item\", so may be that type's rather than this struct's — counted all the same, as a qualifier read from the index alone may name another type in Swift"), "\(search)")
        #expect(!search.contains("resolves to another type's"), "\(search)")
    }

    /// Two types called `B` under different owners: `A.B` inherits `Base`'s typealias of `Search.Item`, whatever the other `B`'s superclass declares.
    @Test
    func twoTypesOfTheQualifiersNameKeepTheLine() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Item", source: "enum Search { struct Item { func searched() {} } }\nclass Base { typealias Item = Search.Item }\nclass Depot { struct Item {} }\nenum A { class B: Base {} }\nenum Log { class B: Depot {} }\nfunc probe() -> A.B.Item? { nil }\nfunc check() { probe()?.searched() }\n")

        #expect(search.contains("\n    :6  | func probe() -> A.B.Item? { nil }"), "\(search)")
        #expect(search.contains("; 1 of them writes \"Item\" behind a qualifier the index reads as Depot, which declares another \"Item\", so may be that type's rather than this struct's — counted all the same, as a qualifier read from the index alone may name another type in Swift"), "\(search)")
        #expect(!search.contains("resolves to another type's"), "\(search)")
    }

    /// `Element` inside an extension of `Collection` is its associated type, which the index does not hold, never the top-level `Element` enum.
    @Test
    func anEnclosingScopeTheIndexDoesNotHoldKeepsTheLine() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Item", source: "enum Search { struct Item { func searched() {} } }\nenum Element { struct Item {} }\nprotocol Answering {}\nextension Answering { typealias Item = Search.Item }\nextension Collection where Element: Answering {\n    func probe(_ x: Element.Item) { x.searched() }\n}\n")

        #expect(search.contains("\n    :6  | func probe(_ x: Element.Item) { x.searched() }"), "\(search)")
        #expect(!search.contains("resolves to another type's"), "\(search)")
    }

    /// `Log` in a generic typealias is its own parameter, whose `Item` is `Search.Item` through the protocol extension's typealias, though the index declares one `Log`, an enum nesting an `Item`.
    @Test
    func aGenericTypealiasesOwnParameterKeepsTheLine() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Item", source: "enum Search { struct Item { func searched() {} } }\nenum Log { struct Item {} }\nprotocol Shelved {}\nextension Shelved { typealias Item = Search.Item }\ntypealias Handler<Log: Shelved> = (Log.Item) -> Void\nstruct Crate: Shelved {}\nlet handler: Handler<Crate> = { $0.searched() }\n")

        #expect(search.contains("\n    :5  | typealias Handler<Log: Shelved> = (Log.Item) -> Void"), "\(search)")
        #expect(!search.contains("resolves to another type's"), "\(search)")
        #expect(!search.contains(Self.noted), "\(search)")
    }

    /// `Log` in `probe()` is its local typealias of `Search`, which the index does not hold, though it declares one `Log` nesting an `Item`.
    @Test
    func aTypealiasLocalToAFunctionKeepsTheLine() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Item", source: "enum Search { struct Item { func searched() {} } }\nenum Log { struct Item {} }\nfunc probe() {\n    typealias Log = Search\n    let x: Log.Item? = nil\n    x?.searched()\n}\n")

        #expect(search.contains("\n    :5  | let x: Log.Item? = nil"), "\(search)")
        #expect(!search.contains("resolves to another type's"), "\(search)")
        #expect(!search.contains(Self.noted), "\(search)")
    }

    /// `Log` in `Outer` is its nested enum, whose `Item` is a typealias of `Search.Item`, not the top-level `Log`'s struct.
    @Test
    func aTypeNestedBesideTheLineKeepsIt() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Item", source: "enum Search { struct Item { func searched() {} } }\nenum Log { struct Item {} }\nenum Outer {\n    enum Log { typealias Item = Search.Item }\n    static func probe(_ x: Log.Item) { x.searched() }\n}\n")

        #expect(search.contains("\n    :5  | static func probe(_ x: Log.Item) { x.searched() }"), "\(search)")
        #expect(!search.contains("resolves to another type's"), "\(search)")
    }

    /// `Sub`'s clause is read from outside `Sub`, where `Log` is `Search`, so its own `Log` does not make the line `Other.Item`'s; the line and the subclass are both kept.
    @Test
    func aSubclassesOwnTypealiasDoesNotSetItsClauseApart() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Item", source: "enum Search { class Item { func searched() {} } }\nenum Other { class Item {} }\ntypealias Log = Search\nclass Sub: Log.Item { typealias Log = Other }\nfunc check(_ s: Sub) { s.searched() }\n")

        #expect(search.contains("\n    :4  | class Sub: Log.Item { typealias Log = Other }"), "\(search)")
        #expect(search.contains("\nconformers of Item (1, by written name):\n  Sources.Sub — class — Sources/Lib/Lib.swift:4"), "\(search)")
        #expect(!search.contains("resolves to another type's"), "\(search)")
        #expect(!search.contains(Self.noted), "\(search)")
    }

    /// Each name the qualifier writes declared once, nested literally, with nothing around the line the index cannot see: the line is kept and noted all the same, since no reading of a qualifier from the index alone has proved sound.
    @Test
    func aLiteralQualifierIsKeptAndNoted() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Answer", source: "struct Search { struct Answer { func searched() {} } }\nstruct Log { struct Answer {} }\nstruct Use { let b: Log.Answer; let c = Log.Answer() }\n")

        #expect(search.contains("\n    :3  | struct Use { let b: Log.Answer; let c = Log.Answer() }"), "\(search)")
        #expect(search.contains("; 1 of them writes \"Answer\" behind a qualifier the index reads as Log, which declares another \"Answer\", so may be that type's rather than this struct's — counted all the same, as a qualifier read from the index alone may name another type in Swift (for "), "\(search)")
        #expect(!search.contains("resolves to another type's"), "\(search)")
    }
}
