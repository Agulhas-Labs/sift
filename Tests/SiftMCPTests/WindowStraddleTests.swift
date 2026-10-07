//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers a call counted on one side of a window's edge whose result, round trip or follow-up lands on the other.
@Suite(.temporaryDirectories)
struct WindowStraddleTests {
    private static let midnight = ISO8601DateFormatter().date(from: "2026-08-02T00:00:00Z") ?? .distantPast

    /// `line` with `timestamp` written into it, as the harness stamps every line.
    private static func stamped(_ line: Data, at timestamp: String) -> Data {
        var object = (try? JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
        object["timestamp"] = timestamp
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// Every event a scan over `lines` reports inside the window, folded into one tally.
    private static func tally(_ lines: [Data], since: Date? = nil, until: Date? = nil) -> TranscriptTally {
        var state = TranscriptScanState()
        var tally = TranscriptTally()
        for line in lines {
            for event in TranscriptScan.events(line: line, state: &state, since: since, until: until, belowFloor: { _ in false }, couldAnswer: { _, _ in true }) {
                tally.fold(event)
            }
        }
        return tally
    }

    /// A digest two seconds before midnight that errors two seconds after it.
    private static let failedDigest = [
        stamped(TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "SummaryState"]), at: "2026-08-01T23:59:58Z"),
        stamped(TranscriptFixture.toolResult(id: "d1", isError: true, text: "the index could not be opened"), at: "2026-08-02T00:00:02Z"),
    ]

    /// An index call counted just inside `--until` whose error lands just past it is taken back, as its error would be anywhere inside the window.
    @Test
    func aCallCountedBeforeTheEndIsTakenBackByAnErrorAfterIt() {
        let tally = Self.tally(Self.failedDigest, until: Self.midnight)

        #expect(tally.indexed == 0)
        #expect(tally.failed == 1)
    }

    /// The same straddle at `--since`: the call was never counted, so its error takes nothing back and files no failure.
    @Test
    func aCallMadeBeforeTheStartIsNotTakenBackByAnErrorAfterIt() {
        let tally = Self.tally(Self.failedDigest, since: Self.midnight)

        #expect(tally.indexed == 0)
        #expect(tally.failed == 0)
    }

    /// A refused read alone in its turn, with the turn after it opening on a text line at the first time given and making its call at the second.
    private static func refusal(nextTurn: String, nextCall: String) -> [Data] {
        let path = "/repo/Sources/View.swift"
        let usage = TranscriptTurns.Usage(cacheRead: 1000)
        return [
            stamped(TranscriptTurns.call("Read", id: "r1", input: ["file_path": path], turn: "m1", usage: usage), at: "2026-08-01T23:59:50Z"),
            stamped(TranscriptTurns.result(id: "r1", text: TranscriptFixture.refusal(call: "digest View"), isError: true), at: "2026-08-01T23:59:51Z"),
            stamped(TranscriptTurns.text("Reading it whole.", turn: "m2", usage: usage), at: nextTurn),
            stamped(TranscriptTurns.call("Read", id: "r2", input: ["file_path": path], turn: "m2", usage: usage), at: nextCall),
        ]
    }

    /// A refusal whose round trip is counted just inside `--until` gets its follow-up row though the next call falls past it.
    @Test
    func aRoundTripCountedBeforeTheEndIsFollowedUpByACallAfterIt() {
        let tally = Self.tally(Self.refusal(nextTurn: "2026-08-01T23:59:58Z", nextCall: "2026-08-02T00:00:02Z"), until: Self.midnight)

        #expect(tally.refusals == 1)
        #expect(tally.soloRefusals == 1)
        #expect(tally.reRunFollowUp.count + tally.indexFollowUp.count + tally.otherFollowUp.count == 1)
    }

    /// A refusal counted just inside `--until` is priced by the turn that begins past it, and followed up by that turn's call.
    @Test
    func aRefusalCountedBeforeTheEndIsPricedByATurnAfterIt() {
        let tally = Self.tally(Self.refusal(nextTurn: "2026-08-02T00:00:01Z", nextCall: "2026-08-02T00:00:02Z"), until: Self.midnight)

        #expect(tally.refusals == 1)
        #expect(tally.soloRefusals == 1)
        #expect(tally.reRunFollowUp.count + tally.indexFollowUp.count + tally.otherFollowUp.count == 1)
    }

    /// A replay never puts a call past `--until` to the hook: it cannot be counted, and judging it is what a replay costs.
    @Test
    func aCallPastTheEndIsNeverPutToTheHook() throws {
        let directory = try TemporaryDirectory.make("straddle")
        let transcript = directory.appendingPathComponent("session.jsonl")
        let lines = try [
            TranscriptAuditReplayTests.call("cat Inside.swift", id: "c1", cwd: directory.path, at: "2026-08-01T23:59:58Z"),
            Self.stamped(TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Inside {}"), at: "2026-08-01T23:59:59Z"),
            TranscriptAuditReplayTests.call("cat Outside.swift", id: "c2", cwd: directory.path, at: "2026-08-02T00:00:02Z"),
            Self.stamped(TranscriptFixture.toolResult(id: "c2", isError: false, text: "struct Outside {}"), at: "2026-08-02T00:00:03Z"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)
        let hook = RecordingHook()
        let probes = ReplayProbes(
            since: nil,
            until: Self.midnight,
            timeZone: TimeZone(identifier: "UTC") ?? .current,
            belowFloor: { _ in false },
            couldAnswer: { _, _ in true },
            memberExists: { _, _, _ in true }
        )

        _ = TranscriptReplay.replay(transcript, session: transcript, isSubagent: false, probes: probes, hook: hook)

        #expect(hook.judged == ["cat Inside.swift"])
    }
}
