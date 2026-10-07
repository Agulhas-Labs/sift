//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// A call the server heals before answering is named and scored as the call it became on every surface — never as it resolved in the usage log and as it was sent in the transcript audit.
///
/// Each naming shape goes through a real server for the log and through the transcript scan for the audit's failure row, and the two must name it alike: a report whose audit names a call differently from its own log is one that has to be reconciled before it can be read.
@Suite(.temporaryDirectories)
struct HealedCallNamingTests {
    /// Every donor key the server heals is read as the key it became, not only `path:`: a `digest name:` is answered as a `digest target:`, so the ranged read after it is the guided read that digest earned.
    @Test
    func aHealedNameArgumentLocatesItsFile() {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["name": "RecordDetailView"]),
                TranscriptFixture.indexAnswer(id: "d1", text: "tree: App  head: 0000000  dirty: 0  parse_errors: 0\nRecordDetailView — App — Sources/App/RecordDetailView.swift:2-40"),
            ] + [
                TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/Sources/App/RecordDetailView.swift", "offset": 40, "limit": 20]),
            ]
        )

        #expect(lookups == [.indexed, .guided(file: "/repo/Sources/App/RecordDetailView.swift")])
    }

    /// `name:` is a donor key for `digest`, healed into `target:` because its value reads as a Swift name.
    @Test
    func aDigestSentUnderNameIsNamedByTheTargetItBecame() async throws {
        try await Self.expectLogAndAuditAgree(calling: "digest", with: ["name": "Engine"], naming: "Engine")
    }

    /// A `root:` term inside a search query is lifted out to the root argument before the query is read, so the query the server searched for carries no `root:`.
    @Test
    func aSearchWithItsRootInsideTheQueryIsNamedByTheQueryItBecame() async throws {
        try await Self.expectLogAndAuditAgree(calling: "search", with: ["query": "kind:struct root:/x"], naming: "kind:struct")
    }

    /// A `query:` that is not a Swift name is never healed, and the `path:` beside it is — so the call is about the path, though a key read ahead of `path` in the naming order sits in the call as sent.
    @Test
    func aDigestWhoseQueryIsNotANameIsNamedByThePathThatWasHealed() async throws {
        try await Self.expectLogAndAuditAgree(
            calling: "digest",
            with: ["query": "kind:struct", "path": "Sources/App/Alpha.swift"],
            naming: "Sources/App/Alpha.swift"
        )
    }

    /// `strings` reads `query:`, which a `text:` heals into; a `symbol:` beside it is read by nothing `strings` does, so the call searched for the text and is named by it on both surfaces.
    @Test
    func aStringsCallIsNamedByTheTextItSearchedNotAStraySymbol() async throws {
        try await Self.expectLogAndAuditAgree(calling: "strings", with: ["symbol": "Engine", "text": "Save changes"], naming: "Save changes")
    }

    /// `where` reads `symbol:`, so a `target:` sent beside it names nothing the answer was about.
    @Test
    func aWhereCallIsNamedByTheSymbolItReadsNotATargetBesideIt() async throws {
        try await Self.expectLogAndAuditAgree(calling: "where", with: ["symbol": "Engine", "target": "Widget"], naming: "Engine")
    }

    /// `search` reads `query:`, so a `symbol:` sent beside it — a stray key from a run of another tool — names nothing the answer was about, on the usage log and the audit alike.
    @Test
    func aSearchCallIsNamedByTheQueryItReadsNotAStraySymbolBesideIt() async throws {
        try await Self.expectLogAndAuditAgree(calling: "search", with: ["query": "kind:struct", "symbol": "Foo"], naming: "kind:struct")
    }

    private static func expectLogAndAuditAgree(
        calling tool: String,
        with arguments: [String: Any],
        naming expected: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let root = try MCPTestRepo.make()
        let scratch = try HealedCallAttributionTests.Scratch()
        defer { scratch.cleanup() }

        let logged = try await HealedCallAttributionTests.loggedEntry(
            calling: tool,
            with: arguments,
            on: root,
            scratch: scratch,
            sourceLocation: sourceLocation
        )

        #expect(logged["target"] as? String == expected, sourceLocation: sourceLocation)
        #expect(auditedFailureTarget(calling: tool, with: arguments) == expected, sourceLocation: sourceLocation)
    }

    /// The target the transcript audit's failure row names, for the same call answered with an error.
    private static func auditedFailureTarget(calling tool: String, with arguments: [String: Any]) -> String? {
        var state = TranscriptScanState()
        _ = TranscriptScan.events(
            line: TranscriptFixture.toolUse("mcp__sift__\(tool)", id: "h1", input: arguments),
            state: &state,
            belowFloor: { _ in false }
        )
        let events = TranscriptScan.events(
            line: TranscriptFixture.toolResult(id: "h1", isError: true, text: "the call failed"),
            state: &state,
            belowFloor: { _ in false }
        )
        for case let .indexFailure(failure) in events {
            return failure.target
        }
        return nil
    }
}
