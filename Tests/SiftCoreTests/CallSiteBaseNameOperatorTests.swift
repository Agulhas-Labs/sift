//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A call site's base name for an operator keeps its dots: `..<` and `...` are not member separators, and `Lib.Box.==` is member `==` of `Lib.Box`.
@Suite(.serialized, .temporaryDirectories)
struct CallSiteBaseNameOperatorTests {
    @Test(arguments: [
        ("..<(lhs:rhs:)", "..<"),
        ("...(_:_:)", "..."),
        ("..<", "..<"),
        ("Lib.Box.==(_:_:)", "=="),
        ("Lib.Box.==", "=="),
        ("Lib...<", "..<"),
        ("Lib....(_:_:)", "..."),
        ("Lib.+(_:_:)", "+"),
        ("Lib.Box.init?(rawValue:)", "init?"),
        ("Lib.Box.init(rawValue:)", "init"),
    ])
    func anOperatorKeepsItsDots(symbol: String, expected: String) {
        #expect(CallSiteScanner.baseName(of: symbol) == expected)
    }

    /// The operator declaration `where` is asked for finds a use written `a ..< b`, with no index store behind it.
    @Test
    func whereFindsAnOperatorUseWrittenWithItsDots() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            public struct Span {
                public let low: Int
                public let high: Int
                public static func ..< (lhs: Int, rhs: Int) -> Span { Span(low: lhs, high: rhs) }
            }
            """,
            to: "Sources/Lib/Span.swift",
            in: root
        )
        try TestSources.write(
            """
            func widths(a: Int, b: Int) -> Span { a ..< b }
            """,
            to: "Sources/Lib/Use.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        let located = try await engine.lookup(symbol: "..<", freshness: engine.ensureFresh())

        #expect(located.contains(":1  in widths(a:b:)"), "\(located)")
        #expect(
            located.contains("\"..<\" (1 call site by name, any type's ..<, as an applied operator writes no receiver to tell Span's apart, in 1 file)"),
            "\(located)"
        )
    }
}
