//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a nested type's name-matched uses where another type nests a type of the same name: a line writing the name with a qualifier the index resolves to the other type is counted apart, while a qualifier it cannot resolve keeps the line a use.
@Suite(.temporaryDirectories)
struct WhereQualifiedTypeNameTests {
    private static var source: String {
        """
        public struct Search {
            public struct Answer {}
        }
        public struct Log {
            public struct Answer {}
        }
        struct Use {
            let a: Search.Answer
            let b: Log.Answer
            let c = Log.Answer()
            let e: Unknown.Answer? = nil
            let g: Answer? = nil
            func pick() -> Any { .Answer }
        }
        """
    }

    /// Each of the two types is asked for in turn: the other's qualified spellings stay listed and counted, noted as read by the index as the other type's, since that reading is not sound, and the unresolved, bare and implicit-member spellings stay listed under both.
    @Test
    func aQualifierNamingTheOtherTypeIsKeptAndNoted() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.source, to: "Sources/Lib/Lib.swift", in: root)
        try TestSources.commitAll(in: root, message: "two nested types of one name, unbuilt")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let search = try await engine.lookup(symbol: "Search.Answer", freshness: freshness)
        let log = try await engine.lookup(symbol: "Log.Answer", freshness: freshness)

        #expect(search.contains("\"Answer\" used by 6 lines in 1 file — "), "\(search)")
        #expect(search.contains("; 2 of them write \"Answer\" behind a qualifier the index reads as Log, which declares another \"Answer\", so may be that type's rather than this struct's — counted all the same, as a qualifier read from the index alone may name another type in Swift (for "), "\(search)")
        #expect(search.contains("\n  Sources/Lib/Lib.swift (6):\n    :8  | let a: Search.Answer\n    :9  | let b: Log.Answer\n    :10  | let c = Log.Answer()\n    :11  | let e: Unknown.Answer? = nil\n    :12  | let g: Answer? = nil\n    :13  | func pick() -> Any { .Answer }"), "\(search)")
        #expect(!search.contains("resolves to another type's"), "\(search)")
        #expect(log.contains("\"Answer\" used by 6 lines in 1 file — "), "\(log)")
        #expect(log.contains("; 1 of them writes \"Answer\" behind a qualifier the index reads as Search, which declares another \"Answer\", so may be that type's rather than this struct's — counted all the same, as a qualifier read from the index alone may name another type in Swift (for "), "\(log)")
        #expect(log.contains("\n  Sources/Lib/Lib.swift (6):\n    :8  | let a: Search.Answer\n    :9  | let b: Log.Answer\n    :10  | let c = Log.Answer()\n    :11  | let e: Unknown.Answer? = nil\n    :12  | let g: Answer? = nil\n    :13  | func pick() -> Any { .Answer }"), "\(log)")
        #expect(!log.contains("resolves to another type's"), "\(log)")
    }

    /// Two types, and two lines whose qualifier is shadowed around them: `Log` in `Use` is a typealias of `Search`, and in `Gen` a generic parameter.
    private static var shadowed: String {
        """
        public protocol P {
            associatedtype Answer
        }
        public struct Search {
            public struct Answer {}
        }
        public struct Log {
            public struct Answer {}
        }
        struct Use {
            typealias Log = Search
            let a: Log.Answer
        }
        struct Gen<Log: P> {
            let b: Log.Answer?
        }
        extension Gen {
            var c: Log.Answer? { nil }
        }
        """
    }

    /// A qualifier's head is looked up around the line first: a typealias there is read through, so the line is `Search.Answer`'s, and since `Log` is declared twice that reading is not certain, so `Log.Answer` keeps the line and notes it rather than setting it apart; a generic parameter keeps the line a use of both.
    @Test
    func aQualifierShadowedAroundTheLineIsReadAsWhatShadowsIt() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.shadowed, to: "Sources/Lib/Lib.swift", in: root)
        try TestSources.commitAll(in: root, message: "a qualifier shadowed by a typealias and a generic parameter")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let search = try await engine.lookup(symbol: "Search.Answer", freshness: freshness)
        let log = try await engine.lookup(symbol: "Log.Answer", freshness: freshness)

        #expect(search.contains("\n  Sources/Lib/Lib.swift (3):\n    :12  | let a: Log.Answer\n    :15  | let b: Log.Answer?\n    :18  | var c: Log.Answer? { nil }"), "\(search)")
        #expect(!search.contains("resolves to another type's"), "\(search)")
        #expect(log.contains("\n  Sources/Lib/Lib.swift (3):\n    :12  | let a: Log.Answer\n    :15  | let b: Log.Answer?\n    :18  | var c: Log.Answer? { nil }"), "\(log)")
        #expect(log.contains("; 1 of them writes \"Answer\" behind a qualifier the index reads as Search, which declares another \"Answer\", so may be that type's rather than this struct's"), "\(log)")
        #expect(!log.contains("resolves to another type's"), "\(log)")
    }

    /// A typealias declared by one of two types sharing a name is no certain reading of the other's qualifier, so the other's line stays a use.
    @Test
    func aTypealiasOfASharedEnclosingNameKeepsTheLineAUse() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            public struct Search {
                public struct Answer {}
            }
            public struct Log {
                public struct Answer {}
            }
            enum Left {
                struct Use { typealias Log = Search }
            }
            enum Right {
                struct Use { let x: Log.Answer }
            }
            """,
            to: "Sources/Lib/Lib.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "two types named Use, one aliasing Log")
        let engine = try SiftEngine(directory: root)
        let log = try await engine.lookup(symbol: "Log.Answer", freshness: engine.ensureFresh())

        #expect(log.contains("\n  Sources/Lib/Lib.swift (1):\n    :11  | struct Use { let x: Log.Answer }"), "\(log)")
    }

    /// The same two shadows on constructions, which a same-named type's initializer is told apart by.
    private static var constructed: String {
        """
        public protocol P {
            associatedtype Answer
        }
        public struct Search {
            public struct Answer { public init() {} }
        }
        public struct Log {
            public struct Answer { public init() {} }
        }
        struct Use {
            typealias Log = Search
            func make() -> Any { Log.Answer() }
        }
        struct Gen<Log: P> {
            func make() -> Any { Log.Answer() }
        }
        """
    }

    /// A construction whose qualifier a typealias around it shadows builds what the alias names, and one whose qualifier is a generic parameter is kept.
    @Test
    func aConstructionsShadowedQualifierIsReadTheSameWay() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.constructed, to: "Sources/Lib/Lib.swift", in: root)
        try TestSources.commitAll(in: root, message: "constructions through a shadowed qualifier")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let search = try await engine.lookup(symbol: "Search.Answer.init", freshness: freshness)
        let log = try await engine.lookup(symbol: "Log.Answer.init", freshness: freshness)

        let searchSites = WhereAnswerRepetitionTests.sitesOnePerLine(search)
        let logSites = WhereAnswerRepetitionTests.sitesOnePerLine(log)

        #expect(searchSites.contains("Sources/Lib/Lib.swift:12  in Use.make()\n"), "\(search)")
        #expect(searchSites.contains("Sources/Lib/Lib.swift:15  in Gen.make() (builds "), "\(search)")
        #expect(!search.contains("of another type named Answer dropped"), "\(search)")
        #expect(logSites.contains("Sources/Lib/Lib.swift:12  in Use.make()\n"), "\(log)")
        #expect(log.contains("(2 call sites by name, 1 of them writes \"Answer\" behind a qualifier the index reads as Search, which declares another \"Answer\", so may be that type's rather than this struct's — counted all the same, as a qualifier read from the index alone may name another type in Swift, in 1 file"), "\(log)")
        #expect(!log.contains("of another type named Answer dropped"), "\(log)")
        #expect(logSites.contains("Sources/Lib/Lib.swift:15  in Gen.make() (builds "), "\(log)")
    }
}
