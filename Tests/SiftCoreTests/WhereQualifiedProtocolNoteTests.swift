//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a nested protocol's name-matched uses and conformers where another owner declares a type of the same name: every line and conformer stays listed and counted, and those written only behind the other owner's qualifier are noted as possibly that type's, by spelling alone.
@Suite(.temporaryDirectories)
struct WhereQualifiedProtocolNoteTests {
    private static var source: String {
        """
        enum Search {
            protocol Answer {}
        }
        enum Log {
            enum Shelf {
                protocol Answer {}
            }
        }
        struct Vault {}
        struct Use: Log.Shelf.Answer {}
        extension Vault: Log.Shelf.Answer {}
        struct Crate: Search.Answer {}
        struct Mixed: Unknown.Answer {}
        struct Both: Log.Shelf.Answer, Search.Answer {}
        struct Pair: Log.Shelf.Answer & Sendable {}
        """
    }

    /// The rows every answer over `source` lists, as the scan reads them.
    private static var rows: String {
        "\n  Sources/Lib/Lib.swift (6):\n    :10  | struct Use: Log.Shelf.Answer {}\n    :11  | extension Vault: Log.Shelf.Answer {}\n    :12  | struct Crate: Search.Answer {}\n    :13  | struct Mixed: Unknown.Answer {}\n    :14  | struct Both: Log.Shelf.Answer, Search.Answer {}\n    :15  | struct Pair: Log.Shelf.Answer & Sendable {}"
    }

    /// `symbol` asked of an unbuilt repo holding `source`, so no index store answers.
    static func answer(_ symbol: String, source: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(source, to: "Sources/Lib/Lib.swift", in: root)
        try TestSources.commitAll(in: root, message: "two nested protocols of one name, unbuilt")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh())
    }

    /// `Search.Answer` keeps all six lines and counts them, and says three are written only behind `Log.Shelf`; the unknown qualifier and the line naming both are not among them.
    @Test
    func linesBehindTheOtherOwnersQualifierAreKeptAndNoted() async throws {
        let search = try await Self.answer("Search.Answer", source: Self.source)

        #expect(search.contains("\"Answer\" used by 6 lines in 1 file — 6 production · 0 tests, split on the XCTest or Testing import, never the path; 3 of them write \"Answer\" only behind Log.Shelf, which declares another \"Answer\", so may be that type's rather than this protocol's — counted all the same, as a qualifier is compared here by spelling, not resolved (for Sources.Search.Answer):" + Self.rows), "\(search)")
    }

    /// `Search.Answer`'s conformers stay six, the composition included, the three written only behind `Log.Shelf` marked with what their clause writes.
    @Test
    func conformersBehindTheOtherOwnersQualifierAreKeptAndMarked() async throws {
        let search = try await Self.answer("Search.Answer", source: Self.source)

        #expect(search.contains("\nconformers of Answer (6, by written name):\n  Sources.Use — struct — Sources/Lib/Lib.swift:10  (clause writes Log.Shelf.Answer)\n  Sources.Vault — extension — Sources/Lib/Lib.swift:11  (clause writes Log.Shelf.Answer)\n  Sources.Crate — struct — Sources/Lib/Lib.swift:12\n  Sources.Mixed — struct — Sources/Lib/Lib.swift:13\n  Sources.Both — struct — Sources/Lib/Lib.swift:14\n  Sources.Pair — struct — Sources/Lib/Lib.swift:15  (clause writes Log.Shelf.Answer)"), "\(search)")
        #expect(!search.contains("Lib.swift:14  ("), "\(search)")
    }

    /// Asked the other way, `Log.Shelf.Answer` keeps the same six lines and six conformers, and notes the one written only behind `Search`.
    @Test
    func theOtherProtocolNotesTheLineBehindTheFirstsQualifier() async throws {
        let log = try await Self.answer("Log.Shelf.Answer", source: Self.source)

        #expect(log.contains("\"Answer\" used by 6 lines in 1 file — 6 production · 0 tests, split on the XCTest or Testing import, never the path; 1 of them writes \"Answer\" only behind Search, which declares another \"Answer\", so may be that type's rather than this protocol's — counted all the same, as a qualifier is compared here by spelling, not resolved (for Sources.Log.Shelf.Answer):" + Self.rows), "\(log)")
        #expect(log.contains("\nconformers of Answer (6, by written name):\n  Sources.Use — struct — Sources/Lib/Lib.swift:10\n  Sources.Vault — extension — Sources/Lib/Lib.swift:11\n  Sources.Crate — struct — Sources/Lib/Lib.swift:12  (clause writes Search.Answer)\n  Sources.Mixed — struct — Sources/Lib/Lib.swift:13\n  Sources.Both — struct — Sources/Lib/Lib.swift:14\n  Sources.Pair — struct — Sources/Lib/Lib.swift:15"), "\(log)")
        #expect(!log.contains("Lib.swift:14  ("), "\(log)")
    }

    /// With no other type of the name, the answer is the one printed before the note existed.
    @Test
    func noOtherTypeOfTheNameLeavesTheAnswerAsItWas() async throws {
        let search = try await Self.answer("Search.Answer", source: "enum Search { protocol Answer {} }\nstruct Crate: Search.Answer {}\n")

        #expect(search.contains("\n\"Answer\" used by 1 line in 1 file — 1 production · 0 tests, split on the XCTest or Testing import, never the path (for Sources.Search.Answer):\n  Sources/Lib/Lib.swift (1):\n    :2  | struct Crate: Search.Answer {}\n\nconformers of Answer (1, by written name):\n  Sources.Crate — struct — Sources/Lib/Lib.swift:2"), "\(search)")
    }

    /// Another type of the name whose owner no line spells adds nothing.
    @Test
    func anOwnerNoLineSpellsLeavesTheAnswerAsItWas() async throws {
        let search = try await Self.answer("Search.Answer", source: "enum Search { protocol Answer {} }\nenum Log { protocol Answer {} }\nstruct Crate: Search.Answer {}\n")

        #expect(search.contains("\n\"Answer\" used by 1 line in 1 file — 1 production · 0 tests, split on the XCTest or Testing import, never the path (for Sources.Search.Answer):\n  Sources/Lib/Lib.swift (1):\n    :3  | struct Crate: Search.Answer {}\n\nconformers of Answer (1, by written name):\n  Sources.Crate — struct — Sources/Lib/Lib.swift:3"), "\(search)")
    }

    /// Asked by its bare name, both protocols are asked, so neither is another's and nothing is marked.
    @Test
    func bothProtocolsAskedLeaveNothingMarked() async throws {
        let both = try await Self.answer("Answer", source: Self.source)

        #expect(both.contains("declarations (2) under 2 owners"), "\(both)")
        #expect(!both.contains("only behind"), "\(both)")
        #expect(!both.contains("(clause writes"), "\(both)")
    }

    /// A struct asked for keeps the answer it had, with a protocol of its name under the qualifier's owner.
    @Test
    func aStructAskedForIsNotNoted() async throws {
        let base = try await Self.answer("Base.Item", source: "class Base {\n    struct Item {}\n}\nenum Shelf {\n    protocol Item {}\n}\nenum Outer {\n    class Shelf: Base {}\n    static let crate = Shelf.Item()\n}\n")

        #expect(base.contains("\n\"Item\" used by 1 line in 1 file — 1 production · 0 tests, split on the XCTest or Testing import, never the path (for Sources.Base.Item):\n  Sources/Lib/Lib.swift (1):\n    :9  | static let crate = Shelf.Item()"), "\(base)")
    }
}
