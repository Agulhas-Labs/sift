//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// The transcript scan reads a header for the tree that answered, and a `clean` header must score exactly as the same answer written with both fields: transcripts already on disk carry the one form, new ones the other.
struct CleanHeaderTranscriptTests {
    private static var oldFields: String {
        "dirty: 0  parse_errors: 0"
    }

    private static func events(headerFields: String, tree: String, sourceLocation: SourceLocation = #_sourceLocation) -> [TranscriptEvent] {
        let answer = "tree: \(tree)  head: 0000000  \(headerFields)  semantic: syntactic-only\nSources/App/Depot.swift — module: App\n\nstruct Depot — 2 members  :1-9"
        let lines = [
            TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Depot"]),
            TranscriptFixture.indexAnswer(id: "d1", text: answer),
        ]
        var state = TranscriptScanState()
        let events = lines.flatMap { TranscriptScan.events(line: $0, state: &state) }
        #expect(state.pendingIndexCalls.isEmpty, sourceLocation: sourceLocation)
        return events
    }

    @Test(arguments: ["App", "App (worktree agent-1a2b3c4d)"])
    func aCleanHeaderScoresAsTheSameAnswerWithBothFields(tree: String) {
        let old = Self.events(headerFields: Self.oldFields, tree: tree)
        let new = Self.events(headerFields: "clean", tree: tree)

        #expect(!old.isEmpty)
        #expect(new == old)
    }
}
