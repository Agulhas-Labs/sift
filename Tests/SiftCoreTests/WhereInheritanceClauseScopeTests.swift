//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a name written bare in an inheritance clause, which Swift reads from outside the type the clause belongs to: a same-named type the class, struct or extension declares inside itself is not in scope there, so the line stays the asked type's use and agrees with the conformer block.
///
/// Every fixture typechecks with `swiftc`, and its last line uses the conformance or superclass as the asked type's.
@Suite(.temporaryDirectories)
struct WhereInheritanceClauseScopeTests {
    /// `Sub`'s superclass is `Search.Item`, not the `Item` it nests.
    @Test
    func aClassesNestedTypeIsNotReadInItsOwnClause() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Item", source: "enum Search {\n    class Item { func searched() {} }\n    class Sub: Item { class Item {} }\n}\nfunc check(_ s: Search.Sub) { s.searched() }\n")

        #expect(search.contains("\n    :3  | class Sub: Item { class Item {} }"), "\(search)")
        #expect(search.contains("\nconformers of Item (1, by written name):\n  Sources.Search.Sub — class — Sources/Lib/Lib.swift:3"), "\(search)")
        #expect(!search.contains("bare inside a type that declares its own"), "\(search)")
    }

    /// `S` conforms to `Search.Answer`, not the protocol it nests.
    @Test
    func aStructsNestedProtocolIsNotReadInItsOwnClause() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Answer", source: "enum Search {\n    protocol Answer {}\n    struct S: Answer { protocol Answer {} }\n}\nfunc check(_ s: Search.S) { let _: any Search.Answer = s }\n")

        #expect(search.contains("\n    :3  | struct S: Answer { protocol Answer {} }"), "\(search)")
        #expect(search.contains("\nconformers of Answer (1, by written name):\n  Sources.Search.S — struct — Sources/Lib/Lib.swift:3"), "\(search)")
        #expect(!search.contains("bare inside a type that declares its own"), "\(search)")
    }

    /// An extension's clause is read at file scope, so `V`'s own `Answer` does not make the conformance its own.
    @Test
    func anExtensionsNestedProtocolIsNotReadInItsClause() async throws {
        let answer = try await WhereQualifiedProtocolNoteTests.answer("Sources.Answer", source: "protocol Answer {}\nstruct V {}\nextension V { protocol Answer {} }\nextension V: Answer {}\nfunc check(_ v: V) { let _: any Answer = v }\n")

        #expect(answer.contains("\n    :4  | extension V: Answer {}"), "\(answer)")
        #expect(answer.contains("Sources.V — extension — Sources/Lib/Lib.swift:4"), "\(answer)")
        #expect(!answer.contains("bare inside a type that declares its own"), "\(answer)")
    }
}
