//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A no-store `--refs` sweep fills each list's slot after the answer is rendered, and the answer quotes doc summaries, which may hold a private-use scalar and digits as an icon font's glyph does.
///
/// No such text is taken for a slot: the declaration line is left as written and every file of every list is listed once.
@Suite(.temporaryDirectories)
struct NoStoreSweepSlotLookalikeTests {
    private static let callerFiles = ["Sources/App/CrateData.swift", "Sources/App/DepotStore.swift"]

    private static func makeWorktree(named name: String, summary: String) throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("/// \(summary)\nfunc glyph() {}\n", to: "Sources/App/Glyph.swift", in: root)
        try TestSources.write("func buildCrate() { glyph() }\n", to: callerFiles[0], in: root)
        try TestSources.write("func applyCoupon() { glyph() }\n", to: callerFiles[1], in: root)
        try TestSources.commitAll(in: root, message: "seed")
        return try TestSources.makeWorktree(of: root, named: name)
    }

    @Test(arguments: ["\u{E000}0", "\u{E000}5"])
    func aDocSummaryLikeASlotIsLeftAsWritten(glyph: String) async throws {
        let summary = "Draws glyph \(glyph)"
        let worktree = try Self.makeWorktree(named: "lookalike", summary: summary)
        let engine = try SiftEngine(directory: worktree)
        let options = WhereOptions(includeSemantic: true, includeReferences: true)
        let answer = try await engine.lookup(symbol: "glyph", freshness: engine.ensureFresh(), options: options)
        let lines = answer.components(separatedBy: "\n")
        let declarations = lines.filter { $0.contains("Sources/App/Glyph.swift:2") && $0.contains("func glyph()") }
        #expect(declarations.count == 1, "\(answer)")
        #expect(declarations.first?.hasSuffix("/// \(summary)") == true, "\(answer)")
        // The only private-use scalar in the answer is the one the summary wrote: no slot is left unfilled.
        #expect(lines.filter { $0.contains("\u{E000}") } == declarations, "\(answer)")
        for file in Self.callerFiles {
            #expect(lines.count { $0.contains(file) } == 1, "\(file) in \(answer)")
        }
        #expect(lines.count { $0.contains("Sources/App/Glyph.swift") } == 1, "\(answer)")
    }
}
