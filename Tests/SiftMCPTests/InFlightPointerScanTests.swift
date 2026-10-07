//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A lookup held back with a pointer at an index call sent beside it is scored as the index serving the context: taken back and counted indexed, with no answer in place and no round trip.
struct InFlightPointerScanTests {
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

    /// One message holding a `digest` and a whole read of the same file, the read held back with the pointer.
    private static var transcript: [String] {
        [
            toolUse("\(IndexToolName.prefix)digest", id: "toolu_where", input: ["target": "/repo/Sources/App/Depot.swift"], second: 1),
            toolUse("Bash", id: "toolu_grep", input: ["command": "cat /repo/Sources/App/Depot.swift"], second: 1),
            toolResult(id: "toolu_where", text: "/repo/Sources/App/Depot.swift — module: App", isError: false),
            toolResult(id: "toolu_grep", text: "PreToolUse:Bash hook error: \(IndexSuggestion.heldBackReason(calls: ["digest /repo/Sources/App/Depot.swift"]))", isError: true),
        ]
    }

    private static func scanned(_ lines: [String]) -> (events: [TranscriptEvent], state: TranscriptScanState) {
        var state = TranscriptScanState()
        var events: [TranscriptEvent] = []
        for line in lines {
            events += TranscriptScan.events(line: Data(line.utf8), state: &state, belowFloor: { _ in false }, couldAnswer: { _, _ in true }, answeredCalls: [])
        }
        return (events, state)
    }

    @Test
    func aPointeredLookupIsRetractedAndCountedIndexedWithNoAnswerAndNoRoundTrip() {
        let scan = Self.scanned(Self.transcript)

        #expect(scan.events.filter { $0 == .lookup(.indexed) }.count == 2)
        #expect(scan.events.filter {
            if case .lookupRetracted = $0 {
                true
            } else {
                false
            }
        }.count == 1)
        #expect(!scan.events.contains(.answeredInPlace))
        #expect(!scan.events.contains(.lookupRefused))
        #expect(scan.state.awaitingRoundTrip.isEmpty)
        #expect(scan.state.hookDenied.count == 1)
    }

    @Test
    func theSameTranscriptWithoutThePointerKeepsTheReadCold() {
        let plain = Self.transcript.dropLast() + [Self.toolResult(id: "toolu_grep", text: "1\tstruct Depot {}", isError: false)]
        let scan = Self.scanned(Array(plain))

        #expect(scan.events.filter { $0 == .lookup(.indexed) }.count == 1)
        #expect(scan.state.hookDenied.isEmpty)
    }

    /// The pointer is recognised by its own stem and by nothing an answered refusal or a refusal carries.
    @Test
    func thePointerIsNeitherAnAnswerNorAnOfferedRefusal() {
        let reason = IndexSuggestion.heldBackReason(calls: ["where Depot", "digest Depot"])

        #expect(reason == "sift held this lookup back — already called in this context: `where Depot`, `digest Depot`, whose answer covers it. Re-run the identical command for the raw output.")
        #expect(reason.contains(IndexSuggestion.heldBackStem))
        #expect(InPlaceAnswer.calls(inOpeningLine: reason) == nil)
        #expect(!reason.hasSuffix(IndexSuggestion.lookupOfferSuffix))
        #expect(!reason.contains(InPlaceAnswer.openingStem))
    }
}
