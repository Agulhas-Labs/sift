//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A digest shows a signature with its whitespace collapsed, but a string literal inside it, a function's default or an enum case's raw value, is shown as written.
@Suite(.temporaryDirectories)
struct DigestLiteralWhitespaceTests {
    private static func digest(of source: String, target: String) throws -> String {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let parsed = try TestSources.parsed(source, path: "Sources/Alpha/Sep.swift", in: root)
        try store.replaceFiles([parsed]) { _ in ("Alpha", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
        return try renderer.render(target: target, options: DigestOptions())
    }

    /// Method bodies long enough that the digest is the smaller answer and the source is not returned in its place.
    private static func padding(_ count: Int) -> String {
        (0 ..< count).map { index in
            "    func pad\(index)() -> Int {\n        let first = \(index)\n        let second = first * 2\n        let third = second + first\n        return third\n    }\n"
        }.joined(separator: "\n")
    }

    @Test
    func aFunctionDefaultOfFourSpacesIsShownIntact() throws {
        let source = "struct Joiner {\n    func join(sep: String   =   \"    \") -> String { sep }\n\(Self.padding(12))}\n"

        let shown = try Self.digest(of: source, target: "Joiner")

        #expect(shown.contains("func join(sep: String = \"    \") -> String"))
    }

    /// A digest lists a case by name only, so an enum case's signature is read where it is shown: in the index and in `search`.
    @Test
    func anEnumCaseRawValueOfTwoSpacesIsShownIntactInTheIndexAndInSearch() throws {
        let source = "enum Sep: String {\n    case double   =   \"  \"\n}\n"
        let path = "Sources/Alpha/Sep.swift"

        let indexed = try TestSources.parsed(source, path: path).symbols.filter { $0.kind == .enumCase }.map(\.signature)
        let searched = try StructuralMatcher.matches(in: source, path: path, query: StructuralQuery("kind:case")).map(\.signature)

        #expect(indexed == ["case double = \"  \""])
        #expect(searched == ["case double = \"  \""])
    }
}
