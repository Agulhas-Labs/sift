//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the shape a cold search is recorded with — the call that would have answered it, and nothing else.
@Suite(.temporaryDirectories)
struct MissedCallTests {
    // MARK: Reading the verb off a suggestion

    /// Each of the three lookup shapes maps to its verb, so the audit's account of a miss agrees with the hook's.
    @Test
    func eachLookupShapeYieldsItsVerb() {
        #expect(MissedCall(IndexSuggestion.forLookup(symbol: "BaySnapshot", file: nil)) == .resolve)
        #expect(MissedCall(IndexSuggestion.forLookup(symbol: nil, file: nil)) == .shape)
        #expect(MissedCall(IndexSuggestion.forLookup(symbol: nil, file: "Sources/App/View.swift")) == .digest)
        #expect(MissedCall(IndexSuggestion.forLookup(symbol: "body", file: "Sources/App/View.swift")) == .digest)
    }

    /// A suggestion that is not a lookup at all names no call — it must not be filed under one.
    @Test
    func aToolchainRunSuggestionNamesNoLookupCall() {
        #expect(MissedCall(IndexSuggestion.forToolchainRun("swift test")) == nil)
    }

    // MARK: What the scan records

    /// A grep for a bare symbol is the `where` question, which is the single most common miss and the one a habit closes.
    @Test
    func aGrepForABareSymbolIsRecordedAsAResolve() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("Grep", input: ["output_mode": "content", "pattern": "BaySnapshot", "glob": "**/*.swift"]),
        ])

        #expect(lookups == [.cold(file: nil, missed: .resolve)])
    }

    /// A shell sweep for a symbol is the same question asked at the shell, and must record the same call — a miss that classified differently by which tool spelled it would split one habit across two rows and hide its size.
    @Test
    func theSameQuestionAtTheShellRecordsTheSameCall() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("Bash", input: ["command": "grep -rn --include=*.swift BaySnapshot Sources/"]),
        ])

        #expect(lookups == [.cold(file: nil, missed: .resolve)])
    }

    /// A miss that names a file is deliberately left unclassified: the call is always `digest`, and the report already names it.
    @Test
    func aMissThatNamesItsFileCarriesNoCall() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/BaySnapshot.swift"]),
        ])

        #expect(lookups == [.cold(file: "/repo/BaySnapshot.swift", missed: nil)])
    }

    /// A retraction takes back *its own* verb, not whichever search landed last.
    ///
    /// Asserted on the rendered breakdown rather than on the event, because the event is right either way: the hazard is the audit's handling of it, dropping the newest entry regardless. Two searches in flight at once are ordinarily classified differently, and taking back the wrong one moves a count between verb buckets — the one thing the breakdown is read for.
    @Test
    func aRetractionTakesBackItsOwnVerbNotTheNewest() throws {
        let root = try TemporaryDirectory.make("retract")
            .appendingPathComponent("retract")
        let directory = root.appendingPathComponent("-Users-someone-Developer-App")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = [
            // A `where` question and a shape question, in flight together …
            TranscriptFixture.toolUse("Grep", id: "g1", input: ["output_mode": "content", "pattern": "BaySnapshot", "glob": "**/*.swift"]),
            TranscriptFixture.toolUse("Grep", id: "g2", input: ["output_mode": "content", "pattern": "final class", "glob": "**/*.swift"]),
            // … of which the *first* is the one that errored.
            TranscriptFixture.toolResult(id: "g1", isError: true),
        ].map { String(bytes: $0, encoding: .utf8) ?? "" }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: directory.appendingPathComponent("11112222-3333.jsonl"), atomically: true, encoding: .utf8)

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("1 search"), "the shape question survived and must be what is counted")
        #expect(!report.contains("1 where"), "the `where` question was retracted and must not be counted")
    }

    /// `memberExists` reaches the search advisor through `TranscriptScan.events` itself, not just through the advisor's own tests.
    ///
    /// A member-shaped grep (the regex form of a member access, `Foo\.bar\b`, confined to `Foo.swift`) is offered `where Foo.bar` when the member is declared and `where Foo` — the type alone — when it is not, and this pins the second half of that by making `couldAnswer` know only the dotted spelling. Dropping the `memberExists:` argument at either of `TranscriptScan.swift`'s two call sites (`Grep`/`Glob` and `Bash`) always asks for the member and turns this back into `.cold(missed: .resolve)`, which is what makes the test fail without them.
    @Test
    func aMemberOfferWithheldByTheProbeIsNoLongerAKnownSymbol() {
        let call = TranscriptFixture.toolUse("Grep", input: ["output_mode": "content", "pattern": "Foo\\.bar\\b", "path": "Sources/App/Foo.swift"])
        let couldAnswer: @Sendable (String, String?) -> Bool = { symbol, _ in symbol == "Foo.bar" }

        var granted = TranscriptScanState()
        let grantedEvents = TranscriptScan.events(
            line: call,
            state: &granted,
            belowFloor: { _ in false },
            couldAnswer: couldAnswer,
            memberExists: { _, _, _ in true }
        )
        #expect(grantedEvents == [.lookup(.cold(file: nil, missed: .resolve))])

        var withheld = TranscriptScanState()
        let withheldEvents = TranscriptScan.events(
            line: call,
            state: &withheld,
            belowFloor: { _ in false },
            couldAnswer: couldAnswer,
            memberExists: { _, _, _ in false }
        )
        #expect(withheldEvents == [.lookup(.textSearch(cause: .undeclaredName))])

        // The same question asked at the shell, through the other of the two call sites `memberExists` is
        // threaded through.
        let shellCall = TranscriptFixture.toolUse("Bash", input: ["command": "grep -n 'Foo\\.bar\\b' Sources/App/Foo.swift"])

        var shellGranted = TranscriptScanState()
        let shellGrantedEvents = TranscriptScan.events(
            line: shellCall,
            state: &shellGranted,
            belowFloor: { _ in false },
            couldAnswer: couldAnswer,
            memberExists: { _, _, _ in true }
        )
        #expect(shellGrantedEvents == [.lookup(.cold(file: nil, missed: .resolve))])

        var shellWithheld = TranscriptScanState()
        let shellWithheldEvents = TranscriptScan.events(
            line: shellCall,
            state: &shellWithheld,
            belowFloor: { _ in false },
            couldAnswer: couldAnswer,
            memberExists: { _, _, _ in false }
        )
        #expect(shellWithheldEvents == [.lookup(.textSearch(cause: .undeclaredName))])
    }

    /// A retracted search takes its classification back with it, or the breakdown would outlive the count it explains.
    @Test
    func aRetractedSearchIsNotLeftInTheBreakdown() {
        var state = TranscriptScanState()
        let call = TranscriptFixture.toolUse("Grep", id: "g1", input: ["output_mode": "content", "pattern": "BaySnapshot", "glob": "**/*.swift"])
        _ = TranscriptScan.events(line: call, state: &state, belowFloor: { _ in false })
        let events = TranscriptScan.events(line: TranscriptFixture.toolResult(id: "g1", isError: true), state: &state, belowFloor: { _ in false })

        #expect(events == [.lookupRetracted(.cold(file: nil, missed: .resolve))])
    }
}
