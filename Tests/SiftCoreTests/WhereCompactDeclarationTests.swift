//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the compact declaration-row form `where` switches to once a bare-name query has more declarations than a reader can pick among by signature alone.
@Suite(.temporaryDirectories)
struct WhereCompactDeclarationTests {
    private static func manyStore() throws -> IndexStore {
        let store = try TestSources.makeStore()
        let source = try TestSources.parsed(
            """
            struct Box {
                /// Runs the box.
                func run() -> Int { 1 }
                func run(a: Int) -> Int { 2 }
                func run(b: Int) -> Int { 3 }
                func run(c: Int) -> Int { 4 }
                func run(d: Int) -> Int { 5 }
                func run(e: Int) -> Int { 6 }
            }
            """,
            path: "Sources/Alpha/Runners.swift"
        )
        try store.replaceFiles([source]) { _ in ("Alpha", false) }
        return store
    }

    private static func fewStore() throws -> IndexStore {
        let store = try TestSources.makeStore()
        let source = try TestSources.parsed(
            """
            struct Box {
                /// Starts the box.
                func start() -> Int { 1 }
                func start(a: Int) -> Int { 2 }
                func start(b: Int) -> Int { 3 }
            }
            """,
            path: "Sources/Alpha/Starters.swift"
        )
        try store.replaceFiles([source]) { _ in ("Alpha", false) }
        return store
    }

    private static func render(_ query: String, store: IndexStore) async throws -> String {
        let renderer = WhereRenderer(store: store)
        return try await renderer.render(query: query, semantic: .inactive(note: "test run")).body
    }

    private static func declarationsBlock(_ output: String) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("declarations (") }) else { return "" }
        let rest = lines[start...]
        let end = rest.firstIndex(where: { $0.isEmpty }) ?? lines.endIndex
        return lines[start ..< end].joined(separator: "\n")
    }

    @Test
    func sixOrMoreDeclarationsDropSignatureAndDocAndNameTheEscapeHatch() async throws {
        let store = try Self.manyStore()
        let output = try await Self.render("run", store: store)

        #expect(output.contains("declarations (6):"))
        #expect(!output.contains("func run()"))
        #expect(!output.contains("/// Runs the box."))
        #expect(output.contains("Alpha.Box.run() — func — Sources/Alpha/Runners.swift"))
        #expect(output.contains("signatures: digest run for any one of these"))
    }

    @Test
    func fiveOrFewerDeclarationsKeepTheSignature() async throws {
        let store = try Self.fewStore()
        let output = try await Self.render("start", store: store)

        #expect(output.contains("declarations (3):"))
        #expect(output.contains("func start() -> Int"))
        #expect(output.contains("/// Starts the box."))
        #expect(!output.contains("signatures: digest start for any one of these"))
    }

    @Test
    func compactDeclarationsBlockStaysUnderByteBudget() async throws {
        let store = try Self.manyStore()
        let output = try await Self.render("run", store: store)

        // Measured 442 bytes for this fixture's six compact rows; 490 leaves about 10% headroom.
        let block = Self.declarationsBlock(output)

        #expect(block.utf8.count < 490)
    }
}
