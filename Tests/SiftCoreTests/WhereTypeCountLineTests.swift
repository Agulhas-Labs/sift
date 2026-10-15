//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a plain `where` on a type with no index store: the scan by written name counts its uses on the verdict line alone and names the query that lists them, while a caller standing the answer in for a search's lines keeps every row.
@Suite(.temporaryDirectories)
struct WhereTypeCountLineTests {
    /// The source of a nested type used on two lines of another file.
    private static let files = [
        "Sources/App/Net.swift": "enum Net {\n    struct Gizmo {}\n}\n",
        "Sources/App/Use.swift": "let first = Net.Gizmo()\nlet second = Net.Gizmo()\n",
    ]

    /// The answer `where` gives for `symbol` over the fixture, with no index store.
    private static func answer(_ symbol: String, padded: Bool = false, options: WhereOptions = WhereOptions()) async throws -> String {
        let root = try TestSources.makeTempRepo()
        for (path, source) in files {
            try TestSources.write(source, to: path, in: root)
        }
        if padded {
            // Seven more lines make nine uses, past the few a plain answer lists in place.
            try TestSources.write((1 ... 7).map { "let pad\($0) = Net.Gizmo()\n" }.joined(), to: "Sources/App/Pad.swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "a nested type, unbuilt")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: options)
    }

    /// Asked where a type is, the answer counts its uses on the verdict line and lists none of them.
    @Test
    func aPlainAnswerCountsTheUsesAndNamesTheQueryListingThem() async throws {
        let output = try await Self.answer("Gizmo", padded: true)

        #expect(output.contains("\"Gizmo\" (9 uses by written name in 2 files) — 9 production · 0 tests"), "\(output)")
        #expect(output.contains("(for Sources.Net.Gizmo) — where --refs Gizmo lists them\n") || output.hasSuffix("(for Sources.Net.Gizmo) — where --refs Gizmo lists them"), "\(output)")
        #expect(!output.contains("Sources/App/Use.swift (2)"), "\(output)")
        #expect(!output.contains(":1  | let first"), "\(output)")
        #expect(!output.contains("Sources/App/Pad.swift ("), "\(output)")
    }

    /// A qualified query is named back as it was asked, so the pointer lists this type's uses and no other's of the name.
    @Test
    func aQualifiedQueryIsTheOneThePointerNames() async throws {
        let output = try await Self.answer("Net.Gizmo", padded: true)

        #expect(output.contains(" — where --refs Net.Gizmo lists them"), "\(output)")
        #expect(!output.contains(":2  | let second"), "\(output)")
    }

    /// Asked where a type is, with two uses, the answer lists them under the verdict and names no pointer.
    @Test
    func aFewUsesAreListedWithNoPointer() async throws {
        let output = try await Self.answer("Gizmo")

        #expect(output.contains("Sources/App/Use.swift (2):\n    :1  | let first = Net.Gizmo()\n    :2  | let second = Net.Gizmo()"), "\(output)")
        #expect(!output.contains("lists them"), "\(output)")
    }

    /// A caller standing the answer in for a search's lines keeps every row under the verdict, and no pointer.
    @Test
    func anAnswerStandingInForASearchKeepsTheRows() async throws {
        let output = try await Self.answer("Gizmo", options: WhereOptions(standsInForSearch: true))

        #expect(output.contains("(for Sources.Net.Gizmo):\n  Sources/App/Use.swift (2):\n    :1  | let first = Net.Gizmo()\n    :2  | let second = Net.Gizmo()"), "\(output)")
        #expect(!output.contains("lists them"), "\(output)")
    }

    /// The sweep asked for by `--refs` lists every row, as a rename needs.
    @Test
    func theSweepListsEveryRow() async throws {
        let output = try await Self.answer("Gizmo", options: WhereOptions(includeReferences: true))

        #expect(output.contains(":1  | let first = Net.Gizmo()"), "\(output)")
        #expect(output.contains(":2  | let second = Net.Gizmo()"), "\(output)")
        #expect(!output.contains("— where --refs Gizmo lists them"), "\(output)")
    }
}
