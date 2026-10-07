//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// An in-place answer is scored the same whether it arrives as the hook error the denial travels as or as an ordinary result, because the hook's answered log is the proof it was sift's answer — and without the log an ordinary result is read as what it looks like.
@Suite(.temporaryDirectories)
struct AnsweredLogScanTests {
    /// The call the fixture's answer is for.
    private static var answered: String {
        "toolu_answer"
    }

    private static func line(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private static func toolUse(_ name: String, id: String, input: [String: Any], second: Int) -> String {
        line([
            "type": "assistant",
            "timestamp": String(format: "2026-10-05T18:00:%02d.250Z", second),
            "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]],
        ])
    }

    private static func toolResult(id: String, text: String, isError: Bool) -> String {
        var result: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": [["type": "text", "text": text]]]
        if isError {
            result["is_error"] = true
        }
        return line(["type": "user", "message": ["content": [result]]])
    }

    /// The opening line of a digest answer to a whole read of the fixture's file.
    private static var opening: String {
        "sift answered this with `digest /repo/Sources/App/Depot.swift` instead of running it\(InPlaceAnswer.openingSuffix)"
    }

    /// The answer's text: its opening line, then the digest.
    private static func answer(prefix: String = "") -> String {
        [
            prefix + opening,
            "",
            "tree: App  head: 0000000  dirty: 0  parse_errors: 0",
            "/repo/Sources/App/Depot.swift — module: App",
            "imports: Foundation",
            "",
            "public struct Depot — 3 members  :1-40",
            "    public func stock() -> Int  :12-20",
        ].joined(separator: "\n")
    }

    /// An in-place answer to a whole `cat` of a Swift file, a ranged read of a member it located, then one unrelated cold lookup.
    private static func transcript(_ delivery: Delivery, prefix: String = "") -> [String] {
        [
            toolUse("Bash", id: answered, input: ["command": "cat /repo/Sources/App/Depot.swift"], second: 1),
            toolResult(id: answered, text: answer(prefix: prefix), isError: delivery == .hookError),
            toolUse("Read", id: "toolu_window", input: ["file_path": "/repo/Sources/App/Depot.swift", "offset": 12, "limit": 9], second: 3),
            toolResult(id: "toolu_window", text: "12\tpublic func stock() -> Int {", isError: false),
            toolUse("Read", id: "toolu_cold", input: ["file_path": "/repo/Sources/App/Other.swift"], second: 5),
            toolResult(id: "toolu_cold", text: "1\tstruct Other {}", isError: false),
        ]
    }

    /// Every event the scan reports for `lines`, in order, and the tally they fold into, with `answeredCalls` as the log read.
    private static func scanned(_ lines: [String], answeredCalls: Set<String>) -> (events: [TranscriptEvent], tally: TranscriptTally) {
        var state = TranscriptScanState()
        var tally = TranscriptTally()
        var events: [TranscriptEvent] = []
        for line in lines {
            let data = Data(line.utf8)
            let found = TranscriptScan.events(line: data, state: &state, belowFloor: { _ in false }, couldAnswer: { _, _ in true }, answeredCalls: answeredCalls)
            events += found
            for event in found {
                tally.fold(event)
            }
            tally.recordedToolListWithoutIndex = state.recordedToolListWithoutIndex
            tally.recordsWholeToolList = state.recordsWholeToolList
        }
        return (events, tally)
    }

    /// The tally the audit scores `lines` at, with the answered log holding `answeredCalls`.
    private static func scored(_ lines: [String], answeredCalls: [String]) throws -> TranscriptTally {
        let directory = try TemporaryDirectory.make("answered-log-scan")
        let transcript = directory.appendingPathComponent("session.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let suppressions = directory.appendingPathComponent("suppressions.jsonl")
        let log = AnsweredLog(fileURL: AnsweredLog.fileURL(besideSuppressionLog: suppressions), markers: directory.appendingPathComponent("answers"))
        for call in answeredCalls {
            log.note(call: call, opening: opening)
        }
        return TranscriptFixture.scored(transcript: transcript, suppressionLog: suppressions)
    }

    /// The lookups the index did not serve, in the order the scan scored them and net of the ones it took back: the misses the share counts.
    private static func misses(in events: [TranscriptEvent]) -> [SwiftLookup] {
        var misses: [SwiftLookup] = []
        for event in events {
            switch event {
            case let .lookup(lookup):
                switch lookup {
                case .cold, .readWholeAfterDigest: misses.append(lookup)
                default: break
                }
            case let .lookupRetracted(lookup):
                if let index = misses.lastIndex(of: lookup) {
                    misses.remove(at: index)
                }
            default: break
            }
        }
        return misses
    }

    /// **The property.** The same transcript with the answer delivered as an error and as an ordinary result, the call in the answered log, tallies, misses and events identically.
    @Test(arguments: ["", "PreToolUse:Bash hook error: ", "Error: "])
    func anAnswerScoresTheSameDeliveredAsAnErrorOrAsAResult(prefix: String) throws {
        let asError = Self.transcript(.hookError, prefix: prefix)
        let asResult = Self.transcript(.ordinaryResult, prefix: prefix)

        let error = Self.scanned(asError, answeredCalls: [])
        let result = Self.scanned(asResult, answeredCalls: [Self.answered])

        #expect(result.events == error.events)
        #expect(result.tally == error.tally)
        #expect(error.events.contains(.answeredInPlace))
        #expect(try Self.scored(asResult, answeredCalls: [Self.answered]) == Self.scored(asError, answeredCalls: []))
    }

    /// What the fixture is scored as when the answer arrives as the hook error: the cat is one lookup the index served, the window it located is guided, and the unrelated read is the one miss.
    @Test
    func theErrorDeliveredFixtureIsOneAnswerOneGuidedWindowAndOneMiss() throws {
        let tally = try Self.scored(Self.transcript(.hookError), answeredCalls: [])
        let events = Self.scanned(Self.transcript(.hookError), answeredCalls: []).events

        #expect(tally.total == 2)
        #expect(tally.indexed == 1)
        #expect(Self.misses(in: events) == [.cold(file: "/repo/Sources/App/Other.swift", missed: nil)])
    }

    /// Without a log entry an ordinary result is what it looks like, a whole read of a Swift file that went around the index: scored as it is today.
    @Test
    func anOrdinaryResultTheLogDoesNotNameIsScoredAsTheColdLookupItLooksLike() throws {
        let tally = try Self.scored(Self.transcript(.ordinaryResult), answeredCalls: [])
        let events = Self.scanned(Self.transcript(.ordinaryResult), answeredCalls: []).events

        #expect(tally.total == 3)
        #expect(tally.indexed == 0)
        #expect(Self.misses(in: events) == [
            .cold(file: nil, missed: .digest),
            .cold(file: "/repo/Sources/App/Depot.swift", missed: nil),
            .cold(file: "/repo/Sources/App/Other.swift", missed: nil),
        ])
        #expect(!events.contains(.answeredInPlace))
    }

    // MARK: - The hook writes the log, and its marker, only for the answer it prints

    private static var payload: [String: Any] {
        [
            "tool_name": "Bash",
            "tool_input": ["command": "cat /repo/Sources/App/Depot.swift"],
            "tool_use_id": "toolu_h1",
        ]
    }

    private static func outcome(answerer: @escaping (InPlaceShape.Match, Bool, TimeInterval) -> InPlaceAnswerer.Outcome, payload: [String: Any]? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws -> (json: String?, verdict: PreToolUseCommand.Verdict) {
        let scratch = try TemporaryDirectory.make("answered-log-hook")
        let suppressions = SuppressionLog(fileURL: scratch.appendingPathComponent("suppressions.jsonl"))
        let payload = payload ?? Self.payload
        let lookup = try #require(PreToolUseCommand.lookup(command: nil, payload: payload, in: "/repo", noting: suppressions, couldAnswer: { _, _ in true }), sourceLocation: sourceLocation)
        return PreToolUseCommand.outcome(
            to: lookup,
            session: "s1",
            context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: "a1"),
            payload: payload,
            cwd: "/repo",
            ledger: AdviceLedger(directory: scratch.appendingPathComponent("advice")),
            usage: UsageLog(fileURL: scratch.appendingPathComponent("usage.jsonl")),
            suppressions: suppressions,
            answerer: answerer
        )
    }

    private static func answered(_: InPlaceShape.Match, _: Bool, _: TimeInterval) -> InPlaceAnswerer.Outcome {
        let reason = "sift answered this with `digest /repo/Sources/App/Depot.swift` instead of running it\(InPlaceAnswer.openingSuffix)\n\nbody"
        let bytes = AnswerBytes(served: reason.utf8.count, source: nil)
        let call = InPlaceAnswerer.Call(tool: "digest", target: "/repo/Sources/App/Depot.swift", bytes: bytes)
        return .answered(InPlaceAnswerer.Answered(reason: reason, calls: [call], root: "/repo", milliseconds: 1))
    }

    private static func log(in scratch: URL) -> AnsweredLog {
        AnsweredLog(fileURL: scratch.appendingPathComponent("answered.jsonl"), markers: scratch.appendingPathComponent("answers", isDirectory: true))
    }

    /// An answer the hook prints is logged against its call with a time, and its marker holds the opening line.
    @Test
    func anEmittedAnswerWritesTheLogLineAndTheMarker() throws {
        let scratch = try TemporaryDirectory.make("answered-log-emitted")
        let outcome = try Self.outcome(answerer: Self.answered)
        #expect(outcome.verdict.token == "in-place")

        _ = PrintedAnswer.recorded(outcome, payload: Self.payload, in: Self.log(in: scratch))

        let lines = try String(contentsOf: scratch.appendingPathComponent("answered.jsonl"), encoding: .utf8).split(separator: "\n")
        let first = try #require(lines.first)
        let entry = try #require(try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        #expect(lines.count == 1)
        #expect(entry["call"] as? String == "toolu_h1")
        #expect(entry["ts"] is String)
        #expect(AnsweredLog.calls(in: scratch.appendingPathComponent("answered.jsonl")) == ["toolu_h1"])
        let marker = try String(contentsOf: scratch.appendingPathComponent("answers/toolu_h1"), encoding: .utf8)
        #expect(marker == "sift answered this with `digest /repo/Sources/App/Depot.swift` instead of running it\(InPlaceAnswer.openingSuffix)")
    }

    /// An answer built and then withheld prints nothing, so it writes neither.
    @Test
    func aWithheldAnswerWritesNeither() throws {
        let scratch = try TemporaryDirectory.make("answered-log-withheld")
        let outcome = try Self.outcome { _, _, _ in .withheld(.notExact) }
        #expect(outcome.json == nil)

        _ = PrintedAnswer.recorded(outcome, payload: Self.payload, in: Self.log(in: scratch))

        #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("answered.jsonl").path))
        #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("answers").path))
    }

    /// A call the harness gave no id for has nothing to be logged under.
    @Test
    func anAnswerForACallWithNoIdWritesNeither() throws {
        let scratch = try TemporaryDirectory.make("answered-log-no-id")
        var payload = Self.payload
        payload["tool_use_id"] = nil
        let outcome = try Self.outcome(answerer: Self.answered, payload: payload)
        #expect(outcome.verdict.token == "in-place")

        _ = PrintedAnswer.recorded(outcome, payload: payload, in: Self.log(in: scratch))

        #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("answered.jsonl").path))
    }

    /// Writing a marker removes the markers older than a day and keeps the rest, while the log keeps every line.
    @Test
    func markersPastADayArePrunedWhenOneIsWritten() throws {
        let scratch = try TemporaryDirectory.make("answered-log-prune")
        let log = Self.log(in: scratch)
        let now = Date()
        log.note(call: "toolu_old", opening: "old", now: now.addingTimeInterval(-3 * 86400))
        log.note(call: "toolu_recent", opening: "recent", now: now.addingTimeInterval(-3600))
        let markers = scratch.appendingPathComponent("answers")
        // Written just now, so their modification times are aged by hand to the instants they claim.
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3 * 86400)], ofItemAtPath: markers.appendingPathComponent("toolu_old").path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: markers.appendingPathComponent("toolu_recent").path)

        log.note(call: "toolu_new", opening: "new", now: now)

        #expect(try FileManager.default.contentsOfDirectory(atPath: markers.path).sorted() == ["toolu_new", "toolu_recent"])
        #expect(AnsweredLog.calls(in: scratch.appendingPathComponent("answered.jsonl")) == ["toolu_old", "toolu_recent", "toolu_new"])
    }

    /// A call id that is not one file name gets its log line and no marker, so a marker is never a path out of its directory.
    @Test
    func anIdWithASeparatorGetsNoMarker() throws {
        let scratch = try TemporaryDirectory.make("answered-log-separator")

        Self.log(in: scratch).note(call: "../escape", opening: "x")

        #expect(AnsweredLog.calls(in: scratch.appendingPathComponent("answered.jsonl")) == ["../escape"])
        #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("escape").path))
    }
}

private extension AnsweredLogScanTests {
    /// How the answer to the whole `cat` reaches the transcript.
    private enum Delivery {
        /// The denial as the harness records it: an error result.
        case hookError
        /// The same text as an ordinary result.
        case ordinaryResult
    }
}
