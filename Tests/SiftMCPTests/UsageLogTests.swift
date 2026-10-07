//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Covers the usage log's append semantics, its failure tolerance, and the server wiring — one line per tool call, success and failure alike, never a protocol-stream side effect.
@Suite(.temporaryDirectories)
struct UsageLogTests {
    @Test
    func recordCreatesTheDirectoryAndAppendsOneParseableLineEach() throws {
        let file = try Self.scratchFile()
        let log = UsageLog(fileURL: file)

        log.record(tool: "digest", target: "Alpha", root: "/tmp/repo", milliseconds: 12, succeeded: true)
        log.record(tool: "where", target: nil, root: "/tmp/repo", milliseconds: 3, succeeded: false)

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)

        let first = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(first["tool"] as? String == "digest")
        #expect(first["target"] as? String == "Alpha")
        #expect(first["root"] as? String == "/tmp/repo")
        #expect(first["ms"] as? Int == 12)
        #expect(first["ok"] as? Bool == true)
        let timestamp = try #require(first["ts"] as? String)
        #expect(ISO8601DateFormatter().date(from: timestamp) != nil)

        let second = try #require(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        #expect(second["ok"] as? Bool == false)
        #expect(second["target"] == nil)
    }

    @Test
    func aFailedWriteIsSwallowedWithANoteNotACrash() throws {
        // The parent path is a *file*, so directory creation must fail beneath it.
        let blocker = try TemporaryDirectory.make("usage-blocker")
            .appendingPathComponent("usage-blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let notes = NoteBox()
        let log = UsageLog(fileURL: blocker.appendingPathComponent("nested/usage.jsonl"), note: { notes.add($0) })

        log.record(tool: "digest", target: "Alpha", root: "/tmp/repo", milliseconds: 1, succeeded: true)

        #expect(notes.all.count == 1)
        #expect(notes.all.first?.contains("usage log write failed") == true)
    }

    /// `SIFT_USAGE_LOG` points a server's writes at another file — how a test that makes real tool calls leaves the record a person reads alone — and an empty value is no value.
    @Test
    func theServersUsageLogCanBePointedElsewhere() {
        let standard = SiftPaths.home.appendingPathComponent("usage.jsonl")

        #expect(UsageLog.standardFileURL(environment: ["SIFT_USAGE_LOG": "/tmp/sift-usage-elsewhere.jsonl"]).path == "/tmp/sift-usage-elsewhere.jsonl")
        #expect(UsageLog.standardFileURL(environment: [:]) == standard)
        #expect(UsageLog.standardFileURL(environment: ["SIFT_USAGE_LOG": ""]) == standard)
    }

    @Test
    func serverAppendsOneLinePerToolCallIncludingFailures() async throws {
        let root = try MCPTestRepo.make()
        let file = try Self.scratchFile()
        let toServer = Pipe()
        let fromServer = Pipe()
        let callers = try Self.scratchCallers()
        let server = MCPServer(
            input: toServer.fileHandleForReading,
            output: fromServer.fileHandleForWriting,
            defaultRoot: root,
            log: { _ in },
            usage: UsageLog(fileURL: file),
            callers: callers.store,
            session: callers.session
        )
        let task = Task { await server.run() }
        var responses = FileHandleLines.lines(from: fromServer.fileHandleForReading).makeAsyncIterator()

        try Self.send(
            [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": ["name": "digest", "arguments": ["target": "Alpha"]],
            ],
            to: toServer
        )
        _ = await responses.next()
        try Self.send(
            [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": ["name": "digest", "arguments": [String: Any]()],
            ],
            to: toServer
        )
        _ = await responses.next()
        toServer.fileHandleForWriting.closeFile()
        _ = await task.value

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)

        let success = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(success["tool"] as? String == "digest")
        #expect(success["target"] as? String == "Alpha")
        #expect(success["ok"] as? Bool == true)
        // The repository the answer was computed against, as the engine names it — see `UsageRootTests`.
        #expect(success["root"] as? String == GitContext.discoverRoot(from: root)?.path)
        #expect((success["ms"] as? Int).map { $0 >= 0 } == true)

        let failure = try #require(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        #expect(failure["ok"] as? Bool == false)
        #expect((failure["err"] as? String)?.contains("digest needs a target") == true)
    }

    /// A healed argument is recorded under what the call actually resolved to — not the pre-healing arguments dispatch started from — or a whole-file read of the same file afterwards finds no `target:` to match it against (``DigestedFiles``) and is refused as if nothing had been digested at all.
    ///
    /// Healed under `name:` rather than `path:`: `path:` is one of ``IndexCallTarget/of(_:tool:)``'s own fallback keys, so a raw, pre-healing `path:` already names the same file on its own and a log that recorded the *sent* arguments instead of the *resolved* ones would read identically here — proving nothing about which one it actually read. `name:` names nothing under any fallback key until healing gives it `target:`, so only the resolved arguments answer at all.
    @Test
    func aHealedNameArgumentIsRecordedUnderItsResolvedTarget() async throws {
        let root = try MCPTestRepo.make()
        let file = try Self.scratchFile()
        let toServer = Pipe()
        let fromServer = Pipe()
        let callers = try Self.scratchCallers()
        let server = MCPServer(
            input: toServer.fileHandleForReading,
            output: fromServer.fileHandleForWriting,
            defaultRoot: root,
            log: { _ in },
            usage: UsageLog(fileURL: file),
            callers: callers.store,
            session: callers.session
        )
        let task = Task { await server.run() }
        var responses = FileHandleLines.lines(from: fromServer.fileHandleForReading).makeAsyncIterator()

        try Self.send(
            [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": ["name": "digest", "arguments": ["name": "Sources/App/Alpha.swift"]],
            ],
            to: toServer
        )
        _ = await responses.next()
        toServer.fileHandleForWriting.closeFile()
        _ = await task.value

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        let entry = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(entry["ok"] as? Bool == true)
        #expect(entry["target"] as? String == "Sources/App/Alpha.swift")
    }

    /// A failure records why.
    ///
    /// A bare `ok:false` line leaves its cause to be found by re-running the call — the log is ground truth for *whether* calls fail, so it has to carry *what* failed too.
    @Test
    func aFailureRecordsItsReasonOnOneBoundedLine() throws {
        let file = try Self.scratchFile()
        let log = UsageLog(fileURL: file)

        log.record(tool: "where", target: "Ghost", root: "/tmp/repo", milliseconds: 3, succeeded: false, error: "no symbol named Ghost\nsecond line")
        log.record(tool: "digest", target: "Alpha", root: "/tmp/repo", milliseconds: 1, succeeded: true)
        log.record(tool: "search", target: "q", root: "/tmp/repo", milliseconds: 1, succeeded: false, error: String(repeating: "x", count: 500))

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        let flattened = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(flattened["err"] as? String == "no symbol named Ghost second line")

        let success = try #require(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        #expect(success["err"] == nil)

        let truncated = try #require(try (JSONSerialization.jsonObject(with: Data(lines[2].utf8)) as? [String: Any])?["err"] as? String)
        #expect(truncated.count == 160)
        #expect(truncated.hasSuffix("…"))
    }

    /// Every answered call records what it served; only the ones that read source record a denominator.
    ///
    /// The two halves are not an atomic pair, because the pair is the wrong unit. A served size needs no counterfactual at all — it is the length of what went out — so withholding it wherever there is no denominator leaves every lookup call carrying nothing, which a savings figure summed over the rest silently reads as a saving of zero. The asymmetry is deliberate and runs one way only: `srcBytes` never appears without `outBytes`, because a denominator with no numerator measures nothing.
    @Test
    func everyAnsweredCallRecordsWhatItServedAndOnlyAMeasuredOneRecordsASource() throws {
        let file = try Self.scratchFile()
        let log = UsageLog(fileURL: file)

        log.record(
            tool: "digest",
            target: "Alpha",
            root: "/tmp/repo",
            milliseconds: 4,
            succeeded: true,
            answer: AnswerBytes(served: 320, source: 4100)
        )
        log.record(tool: "where", target: "Alpha", root: "/tmp/repo", milliseconds: 2, succeeded: true, answer: AnswerBytes(served: 512))
        log.record(tool: "digest", target: "Ghost", root: "/tmp/repo", milliseconds: 1, succeeded: false, error: "no type named Ghost")

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        let measured = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(measured["outBytes"] as? Int == 320)
        #expect(measured["srcBytes"] as? Int == 4100)

        let unpriced = try #require(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        #expect(unpriced["outBytes"] as? Int == 512)
        #expect(unpriced["srcBytes"] == nil)

        // A refusal replaces nothing and answers nothing; counting its text as served would pad the
        // numerator of a figure whose whole worth is that it can be checked.
        let failed = try #require(try JSONSerialization.jsonObject(with: Data(lines[2].utf8)) as? [String: Any])
        #expect(failed["outBytes"] == nil)
        #expect(failed["srcBytes"] == nil)
    }

    /// The server records what every answer served, and a denominator only for the shapes that read source.
    @Test
    func everyToolLogsWhatItServedAndOnlyADigestLogsWhatItReplaced() async throws {
        let root = try MCPTestRepo.make()
        let file = try Self.scratchFile()
        let toServer = Pipe()
        let fromServer = Pipe()
        let callers = try Self.scratchCallers()
        let server = MCPServer(
            input: toServer.fileHandleForReading,
            output: fromServer.fileHandleForWriting,
            defaultRoot: root,
            log: { _ in },
            usage: UsageLog(fileURL: file),
            callers: callers.store,
            session: callers.session
        )
        let task = Task { await server.run() }
        var responseLines = FileHandleLines.lines(from: fromServer.fileHandleForReading).makeAsyncIterator()

        try Self.send(
            [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": ["name": "digest", "arguments": ["target": "Alpha"]],
            ],
            to: toServer
        )
        var responses: [String] = []
        try responses.append(#require(await Self.servedText(responseLines.next())))
        try Self.send(
            [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": ["name": "where", "arguments": ["symbol": "Alpha"]],
            ],
            to: toServer
        )
        try responses.append(#require(await Self.servedText(responseLines.next())))
        toServer.fileHandleForWriting.closeFile()
        _ = await task.value

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        let digest = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        let served = try #require(digest["outBytes"] as? Int)
        let source = try #require(digest["srcBytes"] as? Int)
        #expect(served > 0)
        #expect(source > 0)
        // Docs/Design.md §4: `outBytes` is what was *served*, framing included. Measured before the freshness header is
        // prepended it would understate the answer's cost by a few hundred bytes every time — and always in the
        // flattering direction, which is the one direction a savings figure must never lean.
        #expect(served == responses[0].utf8.count)
        // The framing is really there to be counted: this answer led with the freshness header.
        #expect(responses[0].hasPrefix("tree: "))

        // A symbol lookup stands in for a grep, not for a run of source, so it has no denominator to report —
        // but what it served is the length of what went out, which needs no counterfactual and is recorded.
        // Withheld, this call and every one like it would be absent from the savings figure's numerator *and*
        // present in its denominator, which is a saving of zero stated as a measurement.
        let lookup = try #require(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        #expect(lookup["tool"] as? String == "where")
        #expect(lookup["outBytes"] as? Int == responses[1].utf8.count)
        #expect(lookup["srcBytes"] == nil)
        // And the file it resolved the declaration in, which locates it for a later window as a digest would.
        #expect(lookup["located"] as? [String] == ["Sources/App/Alpha.swift"])
    }

    private static func scratchFile() throws -> URL {
        try TemporaryDirectory.make("usage")
            .appendingPathComponent("usage", isDirectory: true)
            .appendingPathComponent("usage.jsonl")
    }

    /// A caller store and a session id of this test's own, for a server that is going to log.
    ///
    /// `MCPServer` defaults `callers` to the machine's own `~/.sift/callers` and `session` to the live `CLAUDE_CODE_SESSION_ID`, so a test that logs anything reads — and, on a tool-and-target match, *deletes* — the slip the real hook left for the real session running this suite. Stated here rather than defaulted, like every other real-user path this suite touches.
    private static func scratchCallers() throws -> (store: CallAttribution, session: String) {
        let id = UUID().uuidString
        return try (
            CallAttribution(
                directory: TemporaryDirectory.make("callers")
                    .appendingPathComponent("callers", isDirectory: true)
            ),
            "usage-log-tests-\(id)"
        )
    }

    /// The text an MCP response actually carried — what the caller paid for, framing and all.
    private static func servedText(_ line: String?) -> String? {
        guard let line,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]]
        else {
            return nil
        }
        return content.first?["text"] as? String
    }

    private static func send(_ payload: [String: Any], to pipe: Pipe) throws {
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        pipe.fileHandleForWriting.write(data)
    }
}

extension UsageLogTests {
    /// Collects stderr notes across the log's @Sendable boundary.
    private final class NoteBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }

        func add(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
    }
}
