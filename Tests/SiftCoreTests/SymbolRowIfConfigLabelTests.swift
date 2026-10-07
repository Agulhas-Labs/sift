//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A declaration row carries the `#if` condition it sits under, and an `#else` is named after its `#if` only where the file as it stands still shows which one that is.
@Suite(.temporaryDirectories)
struct SymbolRowIfConfigLabelTests {
    static var source: String {
        """
        #if os(macOS)
        public func flavor() -> String { "mac" }
        #else
        public func flavor() -> String { "other" }
        #endif

        #if DEBUG
        #if canImport(Darwin)
        public func tone() -> Int { 1 }
        #else
        public func tone() -> Int { 2 }
        #endif
        #endif
        """
    }

    /// With no store, the twins' rows still differ: each ends its range with its own condition, the `#else` named after its `#if`.
    @Test
    func twinsPrintTheConditionThatTellsThemApart() async throws {
        let root = try Self.indexedRepo()
        let engine = try SiftEngine(directory: root)
        let located = try await engine.lookup(symbol: "flavor", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: false))

        #expect(located.contains("Sources/Lib/Pick.swift:2  [#if os(macOS)]"), "\(located)")
        #expect(located.contains("Sources/Lib/Pick.swift:4  [#else of #if os(macOS)]"), "\(located)")
    }

    /// A nested `#else` is named after its own `#if`, inside the clause around it; where the file cannot be read, or no longer holds the clauses the index recorded, the stored text stands.
    @Test
    func anElseIsNamedOnlyWhereTheFileStillShowsItsIf() async throws {
        let root = try Self.indexedRepo()
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        let rows = try WhereRenderer(store: engine.store).declarations(for: "tone").sorted { $0.line < $1.line }
        let elseRow = try #require(rows.last)

        #expect(IfConfigLabel.label(for: elseRow, source: { _ in Self.source }) == "#if DEBUG && #else of #if canImport(Darwin)")
        #expect(IfConfigLabel.label(for: elseRow, source: nil) == "#if DEBUG && #else")
        #expect(IfConfigLabel.label(for: elseRow, source: { _ in Self.source.replacingOccurrences(of: "#if DEBUG", with: "#if RELEASE") }) == "#if DEBUG && #else")
        #expect(elseRow.declarationLine(qualifiedName: "Lib.tone()", compact: true) == "  Lib.tone() — func — Sources/Lib/Pick.swift:11  [#if DEBUG && #else]")
    }

    private static func indexedRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(source, to: "Sources/Lib/Pick.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        return root
    }
}
