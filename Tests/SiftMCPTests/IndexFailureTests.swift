//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers what a failed index call carries into the report, and what it deliberately does not.
@Suite(.temporaryDirectories)
struct IndexFailureTests {
    // MARK: Classifying what came back

    /// The kinds are pinned against the messages the server actually emits, taken from a live usage log.
    @Test
    func theServersOwnMessagesClassify() {
        let cases: [(String, IndexFailure.Kind)] = [
            ("/Users/someone/Developer/Orchard is not inside a git repository — sift index", .notIndexed),
            ("Theme is declared in 4 indexed repositories — pass root: with the one you mean:", .ambiguousRoot),
            ("digest needs a target", .missingArgument),
            ("where needs a symbol", .missingArgument),
            (#"unknown field "conforms" — terms are field:value, ANDed"#, .badQuery),
            (#"unknown kind "type" — kinds: struct class actor enum"#, .badQuery),
            ("step failed (code 10)", .indexBuild),
        ]

        for (reason, expected) in cases {
            #expect(IndexFailure(tool: "digest", target: nil, reason: reason).kind == expected, "\(reason)")
        }
    }

    /// Wording that has moved on falls to `other` rather than to a confident wrong answer — a visible bucket, not a silent misfiling.
    @Test
    func anUnrecognisedMessageIsNotGuessedAt() {
        #expect(IndexFailure(tool: "digest", target: nil, reason: "something new went wrong").kind == .other)
        #expect(IndexFailure(tool: "digest", target: nil, reason: "").kind == .other)
    }

    // MARK: What the scan recovers

    /// A failed call reports the tool it was and what it was asked — neither of which the result line carries.
    @Test
    func aFailedCallIsReportedAsTheCallItWas() {
        var state = TranscriptScanState()
        let call = TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "ParcelGateway"])
        _ = TranscriptScan.events(line: call, state: &state, belowFloor: { _ in false })
        let events = TranscriptScan.events(
            line: TranscriptFixture.toolResult(id: "d1", isError: true, text: "digest needs a target"),
            state: &state,
            belowFloor: { _ in false }
        )

        #expect(events == [
            .lookupRetracted(.indexed),
            .indexFailure(IndexFailure(tool: "digest", target: "ParcelGateway", reason: "digest needs a target")),
        ])
    }

    /// The reason collapses to its first line: several messages continue into an indented list of the roots they mean, and the sentence is the part a grouped report needs.
    @Test
    func theReasonIsTheSentenceNotItsAppendix() {
        var state = TranscriptScanState()
        let call = TranscriptFixture.toolUse("mcp__sift__where", id: "w1", input: ["symbol": "Theme"])
        _ = TranscriptScan.events(line: call, state: &state, belowFloor: { _ in false })
        let events = TranscriptScan.events(
            line: TranscriptFixture.toolResult(
                id: "w1",
                isError: true,
                text: "Theme is declared in 4 indexed repositories — pass root: with the one you mean:\n  /a/b\n  /c/d"
            ),
            state: &state,
            belowFloor: { _ in false }
        )

        guard case let .indexFailure(failure) = events.last else {
            Issue.record("expected a failure, got \(events)")
            return
        }

        #expect(failure.reason == "Theme is declared in 4 indexed repositories — pass root: with the one you mean:")
        #expect(failure.kind == .ambiguousRoot)
    }

    /// A call that succeeded leaves no failure behind, and stops being pending.
    @Test
    func aSuccessfulCallReportsNoFailure() {
        var state = TranscriptScanState()
        let call = TranscriptFixture.toolUse("mcp__sift__digest", id: "d2", input: ["target": "Theme"])
        _ = TranscriptScan.events(line: call, state: &state, belowFloor: { _ in false })
        let events = TranscriptScan.events(
            line: TranscriptFixture.indexAnswer(id: "d2", text: "Theme — Sources/Theme.swift:1-20"),
            state: &state,
            belowFloor: { _ in false }
        )

        #expect(events.isEmpty)
        #expect(state.pendingIndexCalls.isEmpty)
    }

    /// A key that is present but not a string must not swallow the fallbacks that do name the call.
    @Test
    func aNonStringKeyDoesNotHideTheNameBesideIt() {
        #expect(IndexCallTarget.of(["target": 5, "symbol": "ParcelGateway"], tool: "digest") == "ParcelGateway")
        #expect(IndexCallTarget.of(["target": NSNull(), "query": "kind:struct"], tool: "search") == "kind:struct")
    }

    /// A failed call that arrived under an alias key — `path:` for `digest`, `text:` for `strings` — is reported under that key's value: the transcript's record of a healed call still carries `path:`/`text:` and never the resolved `target:`/`query:` the usage log names it under, so an audit that read the call as sent would name a failed healed call with no target at all while the usage log named it correctly.
    @Test
    func aFailedHealedCallIsReportedUnderTheKeyItArrivedOn() {
        var state = TranscriptScanState()
        let call = TranscriptFixture.toolUse("mcp__sift__digest", id: "d3", input: ["path": "Sources/App/RecordDetailView.swift"])
        _ = TranscriptScan.events(line: call, state: &state, belowFloor: { _ in false })
        let events = TranscriptScan.events(
            line: TranscriptFixture.toolResult(id: "d3", isError: true, text: "digest needs a target"),
            state: &state,
            belowFloor: { _ in false }
        )

        #expect(events == [
            .lookupRetracted(.indexed),
            .indexFailure(IndexFailure(tool: "digest", target: "Sources/App/RecordDetailView.swift", reason: "digest needs a target")),
        ])
    }

    // MARK: Reaching the report

    /// A context whose every index call failed still reports them.
    ///
    /// A failed call is retracted from `indexed` on its way out, so such a transcript nets zero on every other counter — and the sweep drops contexts that counted nothing. The failures must not ride out with it, out of the one section of the report that is unambiguously a defect.
    @Test
    func aContextThatOnlyFailedIsStillReported() throws {
        let root = try TemporaryDirectory.make("failures")
            .appendingPathComponent("failures")
        let directory = root.appendingPathComponent("-Users-someone-Developer-App")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = [
            Self.line(TranscriptFixture.toolUse("mcp__sift__digest", id: "f1", input: ["target": "Theme"])),
            Self.line(TranscriptFixture.toolResult(id: "f1", isError: true, text: "digest needs a target")),
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: directory.appendingPathComponent("11112222-3333.jsonl"), atomically: true, encoding: .utf8)

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("index calls that failed"))
        #expect(report.contains("argument missing"))
    }

    private static func line(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8) ?? ""
    }

    // MARK: Naming a call the same way everywhere

    /// The audit and the usage log read a call's target through one helper, so a report never has to be reconciled with its own log.
    @Test
    func aCallsTargetIsReadTheSameWayEverywhere() {
        #expect(IndexCallTarget.of(["target": "Theme"], tool: "digest") == "Theme")
        #expect(IndexCallTarget.of(["symbol": "Theme.body"], tool: "where") == "Theme.body")
        #expect(IndexCallTarget.of(["concept": "networking"], tool: "concept") == "networking")
        #expect(IndexCallTarget.of(["query": "kind:struct"], tool: "search") == "kind:struct")
        // `path:` and `text:` are the alias keys a call still carries pre-healing — a raw, as-sent
        // argument read the same way `target:`/`query:` (its resolved form) is.
        #expect(IndexCallTarget.of(["path": "Sources/App/Theme.swift"], tool: "digest") == "Sources/App/Theme.swift")
        #expect(IndexCallTarget.of(["text": "Save changes"], tool: "strings") == "Save changes")
        #expect(IndexCallTarget.of(["root": "/a/b"], tool: "digest") == nil)
    }

    /// The key the calling tool reads names the call, ahead of any other key sent beside it — which the tool never read, so naming the call by it would name a call that was never answered.
    @Test
    func theCallingToolsOwnKeyNamesTheCall() {
        #expect(IndexCallTarget.of(["symbol": "Engine", "query": "Save changes"], tool: "strings") == "Save changes")
        #expect(IndexCallTarget.of(["symbol": "Engine", "target": "Widget"], tool: "where") == "Engine")
        #expect(IndexCallTarget.of(["symbol": "Engine", "target": "Widget"], tool: "digest") == "Widget")
        // `search` reads `query:`, so a `symbol:` sent beside it — a stray key from a run of another tool
        // — names nothing the answer was about; `symbol` sits ahead of `query` in the fallback order, so
        // naming this by anything but the tool's own key would name a call `search` never read.
        #expect(IndexCallTarget.of(["query": "kind:struct", "symbol": "Foo"], tool: "search") == "kind:struct")
    }
}
