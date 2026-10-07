//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP

/// Transcript lines in the shapes the scanner has to classify, shared by the suites that fold them.
struct TranscriptFixture {
    /// A call as the transcript records it, with the working directory the line carries when `cwd` is given.
    static func toolUse(_ name: String, id: String = "t1", input: [String: Any] = [:], cwd: String? = nil) -> Data {
        var object: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]],
        ]
        object["cwd"] = cwd
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// A result line in the shape the transcript writes it: the call's id and, on a failure, the error flag — never the tool's name, which a real result does not carry.
    ///
    /// That absence is the point. The byte pre-filter decides whether a line is parsed at all, and a successful result matches none of its fixed markers, so it is parsed only because its id is one the scan is still holding. A fixture that smuggled a marker in — a tool name, say — would let a test pass on a line the scanner would never have read, which is the exact shape of green that hides a broken guard. The flag is written only on a failure for the same reason: a successful `Read` or index call carries no `is_error` at all.
    ///
    /// `bareText` writes the message as a plain string rather than as typed content blocks. Both shapes occur — Claude Code writes the bare string for a hook denial and the blocks for an MCP server's error — and `answerText` reads either, so a suite that only ever built one of them would pin half the parser.
    static func toolResult(id: String, isError: Bool, text: String? = nil, bareText: Bool = false) -> Data {
        var result: [String: Any] = ["type": "tool_result", "tool_use_id": id]
        if isError {
            result["is_error"] = true
        }
        // A real failing result carries the server's message in the same content blocks a successful one uses; a
        // fixture without it would let a test about *what* failed pass over a line that never carried a reason.
        if let text {
            result["content"] = bareText ? text : [["type": "text", "text": text]]
        }
        let object: [String: Any] = ["type": "user", "message": ["content": [result]]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// A successful index call's answer, carrying its reply text.
    ///
    /// Deliberately built with none of the fixed byte markers on it — a real answer has no tool name and no failure flag, and a helper that smuggled one in would let a test pass on a line the scanner would never have parsed.
    static func indexAnswer(id: String, text: String) -> Data {
        let object: [String: Any] = [
            "type": "user",
            "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": [["type": "text", "text": text]]]]],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// An index call and the answer that says it went through: the pair a call locates anything by, since a call credits nothing until it answers.
    ///
    /// The answer names no file, so what the call locates is what its arguments named and nothing more.
    static func answeredCall(_ name: String, id: String, input: [String: Any]) -> [Data] {
        [toolUse(name, id: id, input: input), indexAnswer(id: id, text: "tree: App  head: 0000000  dirty: 0  parse_errors: 0")]
    }

    /// A `digest` call of `target` and the answer that says it went through, whose header names `file` as a real answer names the file it resolved the target to — which is all a digest locates.
    static func answeredDigest(_ target: String, id: String, file: String) -> [Data] {
        let header = target.hasSuffix(".swift") ? "\(file) — module: App" : "\(target) — App — \(file):2-40"
        return [
            toolUse("mcp__sift__digest", id: id, input: ["target": target]),
            indexAnswer(id: id, text: "tree: App  head: 0000000  dirty: 0  parse_errors: 0\n\(header)"),
        ]
    }

    /// A whole-file digest's answer as the index writes it: the file's source when it sits below the floor, a summary when it does not.
    ///
    /// The header names `tree` as a real one names the checkout that answered — the name of the directory it sits in — so a fixture modelling a call from `/work/small` says `small`.
    static func fileDigest(_ path: String, servedSource: Bool, tree: String = "App") -> String {
        let body = servedSource
            ? "(12 lines; a digest would cost 140% of the source\(SourcePassthrough.servedSourceSuffix)\n\nstruct ChuteTap {}"
            : "imports: Foundation\n\npublic struct ChuteTap — 9 members  :4-120"
        return "tree: \(tree)  head: 0000000  dirty: 0  parse_errors: 0\n\(path) — module: App\n\(body)"
    }

    /// The refusal the advice hook writes into the transcript, as a result line's text.
    ///
    /// Only the opening line is what the scan reads, and the suffix is the whole of what it matches on — the tool's own name sits outside the match.
    static func refusal(_ name: String = "sift", call: String = "where SummaryState") -> String {
        """
        \(name) \(IndexSuggestion.lookupOfferSuffix)

            \(call)
            → its declaration, callers, conformers and overrides

        If you want the text match anyway — re-run this exact command and it will be allowed.
        """
    }

    /// A refused lookup as the pair of lines a transcript holds it in: the call, then the hook's denial of it.
    ///
    /// `index` distinguishes both the `tool_use_id` and the command, because the ledger denies one command once — a context taking a run of refusals took a run of *different* ones, and repeating a single command would be one refusal and then a sanctioned re-run.
    static func refusedRead(_ index: Int) -> [Data] {
        [
            toolUse("Read", id: "x\(index)", input: ["file_path": "/repo/Sources/App/Refused\(index).swift"]),
            toolResult(id: "x\(index)", isError: true, text: refusal(call: "digest Refused\(index)")),
        ]
    }

    /// Folds a sequence of lines through one scan state and returns the tally they add up to.
    ///
    /// Each line's events are folded one at a time, as the audit's scan folds them, and the tool-list evidence is copied across from the state after every line.
    static func tally(
        _ lines: [Data],
        belowFloor: (String) -> Bool = { _ in false },
        couldAnswer: @escaping (String, String?) -> Bool = { _, _ in true },
        answeredCalls: Set<String> = []
    ) -> TranscriptTally {
        var state = TranscriptScanState()
        var tally = TranscriptTally()
        for line in lines {
            for event in TranscriptScan.events(line: line, state: &state, belowFloor: belowFloor, couldAnswer: couldAnswer, answeredCalls: answeredCalls) {
                tally.fold(event)
            }
            tally.recordedToolListWithoutIndex = state.recordedToolListWithoutIndex
            tally.recordsWholeToolList = state.recordsWholeToolList
        }
        return tally
    }

    /// The counts the audit scores a transcript file at, folded event by event as its sweep folds them.
    ///
    /// The file is read whole and scored on its own access, with the machine's real floor and name check as the audit has them, so a fixture that depends on a file on disk or on the index answers as it would in a sweep. `suppressionLog` supplies the calls the hook let run and, beside it, the calls it answered in place; `nil` supplies none.
    static func scored(transcript: URL, suppressionLog: URL? = nil) -> TranscriptTally {
        let snapshot = TranscriptSnapshot.take(projectsDirectory: transcript.deletingLastPathComponent(), since: nil, transcript: transcript.path)
        let options = TranscriptAudit.ScanOptions(
            since: nil,
            until: nil,
            belowFloor: DigestFloor.memoised(),
            couldAnswer: AdvisableName.memoised(in: snapshot.indexes),
            memberExists: AdvisableName.memoisedMember(in: snapshot.indexes),
            timeZone: .current,
            datesEveryLookup: false,
            loggedLetThrough: suppressionLog.map { SuppressionLog.callsLetThrough(in: $0) } ?? [:],
            answeredCalls: suppressionLog.map { AnsweredLog.calls(in: AnsweredLog.fileURL(besideSuppressionLog: $0)) } ?? []
        )
        return TranscriptAudit.scan(transcript, label: "fixture", session: "fixture", isSubagent: false, options: options, snapshot: snapshot).tally.scored
    }

    /// Folds a sequence of lines through one scan state and returns every lookup, in order.
    ///
    /// `couldAnswer` defaults to "yes" rather than to the machine's real answer, which is what keeps these fixtures hermetic: the live check opens whatever index the test host happens to have, so a suite pinning classification would answer differently on a machine with an index of its own. Every test that means the other answer says so.
    ///
    /// `belowFloor` stands in for the disk, which is where the floor is judged when the transcript holds no digest of the file.
    static func lookups(
        _ lines: [Data],
        belowFloor: (String) -> Bool = DigestFloor.wouldServeSource,
        couldAnswer: @escaping (String, String?) -> Bool = { _, _ in true }
    ) -> [SwiftLookup] {
        var state = TranscriptScanState()
        return lines.flatMap { line in
            TranscriptScan.events(line: line, state: &state, belowFloor: belowFloor, couldAnswer: couldAnswer).compactMap { event in
                guard case let .lookup(lookup) = event else { return nil }
                return lookup
            }
        }
    }
}
